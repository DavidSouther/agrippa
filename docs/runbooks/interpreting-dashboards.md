# Runbook: interpreting dashboards

`USAGE.md` § Observability documents where the datasources and the Web
Analytics dashboard live. This runbook is the next layer down: for each
panel, what a healthy reading looks like on a single-operator personal site,
what an anomaly looks like, and what command to run next. It assumes
`kubectl` is already pointed at the cluster:

```bash
export KUBECONFIG="$(k3d kubeconfig write agrippa-dev)"
kubectl config use-context k3d-agrippa-dev
```

For the fuller triage flow once you've identified a real problem, see
`./incident-response.md`. If a panel points at cluster-wide resource
pressure rather than one service, see `./capacity-and-resource-pressure.md`.

## 1. Start with ArgoCD, not Grafana

Before opening a single dashboard, ask GitOps whether anything is actually
broken. This is a faster and more reliable signal than any Grafana panel,
because it doesn't depend on the metrics pipeline being healthy (see § 3
below for what happens when it isn't):

```bash
kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

A healthy platform reads, verified live against this cluster:

```
NAME               SYNC     HEALTH
argocd             Synced   Healthy
core               Synced   Healthy
observability      Synced   Healthy
platform           Synced   Healthy
root               Synced   Healthy
storage            Synced   Healthy
workloads-resume   Synced   Healthy
workloads-trips    Synced   Healthy
```

Every row should say `Synced` / `Healthy`. Anything else, read as:

| SYNC | HEALTH | Meaning | Next step |
| --- | --- | --- | --- |
| `OutOfSync` | any | Live state has drifted from git, or a push hasn't synced yet | `kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite`, then re-check |
| `Synced` | `Progressing` | A rollout is mid-flight (new image, replica change) | Wait a minute, re-check; if stuck, `kubectl -n <ns> get pods` for the app's namespace |
| `Synced` | `Degraded` | A resource synced but isn't reporting healthy (pod crashlooping, PVC unbound) | `kubectl -n argocd get application <name> -o jsonpath='{.status.conditions}' \| jq .` |
| any | `Missing` | A manifest ArgoCD expects doesn't exist live | Check whether it was deleted out-of-band; `kubectl -n argocd exec deploy/argocd-repo-server -- kustomize build --enable-helm <path>` to diff intended vs. rendered |

Same check via the UI at `https://argocd.127.0.0.1.nip.io/` (`admin` /
password from `argocd-initial-admin-secret`, per `USAGE.md`): the
application tree view shows the same sync/health state per app, one glance,
color-coded. Make this the reflex before touching Grafana. If ArgoCD says
everything is Synced/Healthy, a dashboard anomaly is a runtime problem
worth chasing; if ArgoCD itself is unhappy, fix that first since it's
usually the root cause of whatever Grafana would otherwise show.

## 2. Web Analytics (Istio Gateway) dashboard, panel by panel

`https://dashboard.davidsouther.com.127.0.0.1.nip.io/d/web-analytics/`,
`admin` / `admin`. Default window is the last 6 hours, auto-refreshing
every 30 seconds. All panels query Mimir (uid `PAE45454D0EDB9216`) against
Istio's `reporter="source"` telemetry, the only reporter that exists in
this ambient-mode deployment (only the Gateway runs full Envoy; there are
no sidecars or waypoint proxies to report `reporter="destination"`).

**Read this dashboard against its actual baseline, not a production
mental model.** This is one operator's personal site plus a handful of
platform UIs (ArgoCD, Grafana, Keycloak, Forgejo, Flagsmith), not a
service under load. A live query against this cluster during a quiet
period returned a current request rate around 0.03 req/s (roughly two
requests a minute, mostly kube-probe health checks) and a handful of
single-digit-count destinations over a 6-hour window. That sparse,
bursty, near-zero pattern is the normal state. Sustained load, not
occasional spikes, is the thing to notice.

### Headline stats row: Total Requests, Requests/sec, Error Rate (5xx), p95 Latency

Four `stat` panels reducing the current window to one number each.

- **Healthy**: Total Requests in the low tens to low hundreds over 6 hours
  on a quiet cluster; Requests/sec near zero with occasional short bumps;
  Error Rate (5xx) at 0%; p95 Latency in the tens of milliseconds (static
  content, small cluster, no external network hop).
- **Error Rate (5xx) thresholds are baked into the panel itself**: green
  below 1%, orange from 1%, red from 5%. Trust those colors directly, no
  need to eyeball a raw percentage.
- **Anomaly**: Error Rate (5xx) sitting in orange or red for more than one
  refresh cycle (not a single 30-second blip, a sustained reading); p95
  Latency climbing over several minutes instead of sitting flat.
- **Next step**: if only Error Rate moved, jump to "Error Rate by
  Destination" below to find which service, then Explore → Loki (§ 4)
  filtered to that namespace. If p95 Latency moved while Error Rate stayed
  at 0%, check "Latency Percentiles" below to see whether it's one
  destination or everything at once; everything-at-once means
  `./capacity-and-resource-pressure.md`, not this dashboard.

### Request Rate by Destination (stacked timeseries)

Per-destination `rate()` over 5-minute windows, one colored band per
`destination_service_name`.

- **Healthy**: thin, mostly-flat bands near zero, occasionally spiking
  when you're actively testing something. Different destinations spike at
  different times, matching whatever you're doing at the keyboard.
- **Anomaly**: a destination that used to show up (even sparsely) stops
  appearing in the legend entirely over a window where you'd expect
  traffic (e.g. `resume` during a browser session against
  `davidsouther.com.127.0.0.1.nip.io`). A brand-new destination appearing
  at nontrivial volume you didn't generate is also worth a look (an
  unexpected client, or a route sending traffic somewhere it shouldn't).
- **Next step**: `kubectl -n <ns> get pods,httproute` for the missing
  service's namespace; then Explore → Loki (§ 4) scoped to that namespace
  for what the pod itself is logging around the time it went quiet.

### Requests by Status Code (stacked timeseries)

Same shape, split by `response_code` instead of destination.

- **Healthy**: dominated by `200`, plus routine `304`s and the occasional
  benign `404` (see the Alloy-scraping-a-nonexistent-`/metrics`-path
  example under § 4, which is a real 404 on this cluster and
  not a problem).
- **Anomaly**: a `5xx` band appears and holds, or `4xx` volume jumps well
  above its usual trickle (could be a broken client, a bad redirect, or a
  route misconfiguration after a manifest change).
- **Next step**: Explore → Loki (§ 4) with a status-code text filter
  against the specific namespace to read the actual failing request.

### Top Destinations (bargauge, by request count)

`topk(10, increase(...))`, instant query over the dashboard's time range.

- **Healthy**: every platform service you'd expect appears with a small
  count; a destination can legitimately show `0` (it exists as a time
  series but had no traffic this window) without being a problem.
- **Anomaly, and a real distinction worth knowing**: `0` in this panel and
  *absent from this panel* mean different things. `0` means Istio recorded
  the destination at some point in its recent history and the series still
  exists with no increase this window, normal for something you haven't
  touched recently. A destination missing outright means no request to it
  was recorded at all in the range, which for something you *did* just hit
  in a browser (like `resume` or `trips`) is the anomaly, not the `0`.
- **Next step**: for a destination that's actually gone missing while you
  were exercising it, `kubectl -n <ns> get pods` (is it even running?),
  then `kubectl get httproute -A` (is the route still pointed at it?).

### Latency Percentiles p50 / p95 / p99 (all destinations)

Three lines from the same duration histogram.

- **Healthy**: p50, p95, and p99 sitting close together in the tens of
  milliseconds, live-measured around 45ms for p95 during a quiet period.
  Tight spread between the percentiles means requests are consistently
  fast.
- **Anomaly, and how to tell the two kinds apart**: p99 climbing while p50
  stays flat means a specific slow path or a subset of requests are
  degraded (worth chasing per-destination in the panel below). All three
  climbing together, especially in lockstep with the whole dashboard's
  Requests/sec staying flat, points at something upstream of any one
  service, most often node-level resource pressure.
- **Next step**: one line moving → check "Error Rate by Destination" and
  that service's own logs. All lines moving together →
  `./capacity-and-resource-pressure.md`.

### Error Rate by Destination (5xx)

Same shape as the headline Error Rate stat, but broken out per
`destination_service_name` over time.

- **Healthy**: flat at zero for every destination.
- **Anomaly**: any nonzero, sustained band. A single short-lived spike
  coinciding with something you just deployed (a rolling restart briefly
  5xx-ing before the new pod is ready) is expected and self-resolves in
  under a minute; anything longer is real.
- **Next step**: Explore → Loki (§ 4) filtered to that destination's
  namespace, or straight to `kubectl -n <ns> logs deploy/<name> --previous`
  if the pod's also restarting.

### Bytes Transferred (request/response, Bps)

- **Healthy**: small, spiky, tracking whatever page or asset you just
  loaded.
- **Anomaly**: sustained elevated bytes/s with request volume (the
  Requests/sec stat) staying flat. That combination means a small number
  of requests are moving unusually large payloads, worth knowing whether
  that's an expected large asset or something scraping/pulling more than
  it should.
- **Next step**: the Traffic Detail table below to identify which source
  and destination pair is carrying the volume.

### Traffic Detail table (source → destination → status)

`source_workload`, `destination_service_name`, `response_code`, and a
request count, sorted by count descending, over the dashboard's time
range.

- **Healthy**: mostly `kube-probe`-driven health checks and your own
  browser/curl sessions, spread thin across destinations.
- **Anomaly**: use this table to answer "who" when another panel raised a
  "what": an unfamiliar `source_workload` generating volume, or a
  source/destination pair sitting at a non-`200` status repeatedly.
- **Next step**: once you have the specific namespace and workload from
  this table, go straight to Explore → Loki (§ 4) scoped to it.

## 3. When a panel is empty: rule out a broken pipeline first

An empty panel is not proof of "nothing happening." It can also mean the
metrics pipeline itself is broken, and it will look identical to "no
traffic yet" in Grafana, no error banner, just blank.

That happened on this cluster: Mimir's ingester ring `replication_factor`
defaulted to `3` against a single-ingester dev deployment, so every metric
write was silently rejected for roughly 13 hours before it was caught (see
`USAGE.md`'s "Known dev-cluster quirk" note and the `fix(otel):` commits
touching `observability/overlays/dev/mimir/kustomization.yaml`). Nothing
in Grafana signaled this; the actual evidence was in
`mimir-distributor`'s own logs:

```bash
kubectl -n observability logs deploy/mimir-distributor --tail=50 | grep -i error
# the historical signal was repeated:
#   "at least 2 live replicas required, could only find 1"
```

The `mimir-distributor` logs show only harmless `memberlist` transport
noise, no `push.go` rejections, but the failure mode it demonstrates is
permanent: if you're ever unsure whether "no data" means "healthy and
idle" or "the pipeline is broken," don't trust the dashboard, ask Mimir
directly:

```bash
kubectl -n observability port-forward svc/mimir-gateway 8888:80 &
curl -sG http://localhost:8888/prometheus/api/v1/query \
  -H "X-Scope-OrgID: anonymous" \
  --data-urlencode 'query=up'
```

If that returns real time series, ingestion is working and the dashboard's
emptiness is a true "no traffic." If it errors or comes back empty too,
the pipeline itself is the incident, not whatever the dashboard was trying
to show you.

## 4. Explore → Loki: pivoting to log lines

Explore → select the Loki datasource (uid `P8E80F9AEF21F6940`, pre-selected
if you land there from a dashboard panel's "Explore" button).

**A real schema note, checked live against this cluster rather than
assumed**: the label set Loki actually exposes here is `instance`, `job`,
`service_name`, and `detected_level`, there is no separate `namespace`,
`pod`, or `container` label. Everything namespace/pod/container-shaped is
packed into one `instance` label formatted `<namespace>/<pod-name>:
<container-name>`, e.g. `forgejo/forgejo-55b7d58798-vc9hm:forgejo`. Scope
a query to a namespace with a regex match on that label, not an exact
match on a `namespace` label that doesn't exist:

```logql
{instance=~"forgejo/.*"}
```

Verified live, real output from this cluster:

```
2026/07/10 10:43:24 ...eb/routing/logger.go:102:func1() [I] router: completed GET /api/healthz for 10.42.0.1:45192, 200 OK in 1.5ms @ healthcheck/check.go:67(healthcheck.Check)
```

Two more patterns that reflect what's actually on this cluster
(neither `resume`/`trips` nor `forgejo` logs JSON, so `| json` doesn't
apply to anything running here; see the note below):

```logql
# resume/trips are nginx-style access logs (Common Log Format). Text-match
# for a specific path or client:
{instance=~"resume/.*"} |= "healthz"

# Regex-match the CLF status-code field to surface 4xx/5xx lines. Verified
# live: this matches a real (benign) 404 -- Alloy's own /metrics
# scrape hitting a path resume doesn't serve, not an incident.
{instance=~"resume/.*"} |~ " [45][0-9]{2} "
```

If a future workload does log structured JSON, the pattern to reach for is
`{instance=~"<ns>/.*"} | json | <field>="<value>"`, but no workload here
needs it: `forgejo` logs its own bracketed
`[I]`/`[E]`-prefixed text format, `resume`/`trips` log nginx CLF, and the
Gateway pod (`istio-ingress/agrippa-gateway-istio`) doesn't emit
per-request access logs at all (Envoy access logging isn't enabled
on the shared Gateway), just its own control-plane text log. If you need
a per-request view of Gateway traffic specifically, the Web Analytics
dashboard's Mimir-backed panels are the source of truth, not
Loki.

## 5. Explore → Tempo: trace lookup (honest status)

Explore → select the Tempo datasource (uid `P214B5B846CF3925F`) gets you
to a trace search UI, but checked live against this cluster there is
nothing to find yet:

```bash
kubectl -n observability port-forward svc/tempo 3200:3200 &
curl -s "http://localhost:3200/api/search/tag/service.name/values"
# {"tagValues":[],"metrics":{}}
curl -s "http://localhost:3200/api/search?start=<7-days-ago>&end=<now>&limit=20"
# {"traces":[],"metrics":{"completedJobs":3,"totalJobs":3}}
```

Zero known service names, zero traces over the last 7 days. There's also
no `Telemetry` resource configured anywhere in the cluster
(`kubectl get telemetry -A` returns nothing), which is the Istio-native
way to turn tracing on and point it at a collector.

This is expected given what's actually deployed, not a bug to chase:
`resume` and `trips` are static sites with zero application-level tracing
instrumentation, and ambient-mode Istio without a waypoint proxy only
gets you L4 telemetry for most traffic; the Gateway's own Envoy is the one
component capable of emitting spans, and it isn't configured to do so.
**Nothing is traced on this cluster.** Getting real value out
of the Tempo datasource would need, at minimum, a `Telemetry` resource
turning on Gateway-level tracing (cheapest first step, no app changes),
and eventually OpenTelemetry instrumentation in any workload that grows
actual application logic worth tracing (Forgejo, Keycloak, and Flagsmith
are third-party and unlikely to get custom instrumentation; a future
dynamic backend behind `resume`/`trips` would be the more likely
candidate). Until then, treat Tempo as provisioned-but-idle and lean on
Mimir (dashboard panels) and Loki (§ 4) for everything.

## 6. Symptom → panel → next step quick reference

| Symptom | Panel to check | Likely next step |
| --- | --- | --- |
| Something feels broken, don't know what | ArgoCD applications (§ 1) | `kubectl -n argocd get applications ...`; fix any non-Synced/Healthy app first |
| A dashboard panel is completely empty | § 3 first, before assuming "no traffic" | `kubectl -n observability logs deploy/mimir-distributor`, then a direct `up` query against Mimir |
| Site feels slow, one page/service | Latency Percentiles; Error Rate by Destination | Explore → Loki scoped to that namespace (§ 4); `kubectl -n <ns> logs` |
| Everything feels slow at once | Latency Percentiles (all lines moving together) | `./capacity-and-resource-pressure.md` |
| Error Rate (5xx) stat is orange/red | Error Rate by Destination to find which service | Explore → Loki scoped to that namespace (§ 4) |
| A known destination vanished from Top Destinations | Request Rate by Destination (is it `0` or truly absent, § 2) | `kubectl -n <ns> get pods,httproute` |
| Unexpected traffic volume or source | Traffic Detail table | Identify `source_workload`/namespace, then Explore → Loki (§ 4) |
| Bytes Transferred elevated, request rate flat | Traffic Detail table for the heavy pair | Confirm expected large asset vs. unexpected pull |
| Want to see a request's actual error message | (any) | Explore → Loki, not Tempo (§ 5: nothing is traced yet) |
| Anything that looks like a real incident, not just a curiosity | -- | `./incident-response.md` for the full triage flow |
