# Feature Design: Observability (LGTM + Alloy)

*Draft 2026-07-08*

> Feature-step design (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 8: Observability (LGTM +
> Alloy)** of that project's plan: Loki, Grafana, Tempo, Mimir, and a Grafana
> Alloy DaemonSet, at reduced replicas, on `local-path`, composed into the
> `observability` layer (sync-wave 3). It has its own feature test (recorded
> below). The project as a whole is measured by `closing-bell.md`, not by this
> test; this feature-step's own direct target is **Closing Bell critical task 4**
> — "Grafana at the dashboard dev host authenticates with the documented local
> dev credentials and renders a dashboard" (5 min ceiling, <= 1 misstep, 0
> errors).
>
> This is a **larger, ensemble** feature-step (five distinct upstream charts
> composed under one Application, plus datasource and collection wiring between
> them), so it runs longer than the one-page norm, per `design.md`'s "confirm
> before making a larger doc" — matching the sibling Networking ensemble's own
> larger doc. Its research (`research.md`, `research/public.md`,
> `research/codebase.md`) is Reviewed (draft gate cleared, including six
> long-loop-reviewer decisions); those decisions are carried in as settled
> inputs here, not re-litigated.

## Libraries & Skills (carry forward to plan and build)

Per the project's cleared `research.md` (§ Libraries & Skills), this
feature-step's own cleared `research.md` (§ Libraries & Skills), and the project
`design.md`, the plan and build phases MUST load these skills via the harness's
skill-loading mechanism before working:

- **`developer:initialize`** — for any residual `mise` tool-pin work. This
  feature adds **no** new mise-managed CLI: Loki, Grafana, Tempo, Mimir, and
  Alloy are all in-cluster Kubernetes resources reconciled by ArgoCD, not local
  CLIs. `helm`, `kubectl`, `kustomize`, `sops`, `age`, and the Bitwarden CLI are
  already pinned; the feature test needs only `bats`, `curl`, and `kubectl`,
  all already present.
- **`research:public`** and **`research:codebase`** — for the per-tool details
  this research deliberately deferred to authoring time: each chart's exact
  current `repoURL`/`version` pin (the Grafana Helm chart ecosystem is
  mid-migration, see below), Grafana's exact Service port/protocol, and the
  exact in-cluster Service names/ports of Loki, Mimir, and Tempo for datasource
  provisioning and Alloy forward targets.
- **`developer:ailly` project-shape references** (`shapes/project/project-cycle.md`,
  `closing-bell.md`, `release-flags.md`) — this feature-step still operates
  inside the parent Project Shape.

**No library-shipped agentic skill exists for Loki, Grafana, Tempo, Mimir,
Alloy, Kustomize's `helmCharts:` mechanism, or ArgoCD** (both the project
research and this feature's research recorded a deliberate per-tool check that
turned up no `SKILL.md` and no MCP server). Build to the in-repo contracts:
`DEVELOPMENT.md` (`## Testing`, `## Secrets`), `ARCHITECTURE.html` (the
Observability layer view), `ROUTING.md` (host-vs-path policy for the Grafana
HTTPRoute), and this feature-step's two sibling research notes
(`research/public.md`, `research/codebase.md`).

## Purpose

Stand up the Grafana LGTM observability stack (Loki, Grafana, Tempo, Mimir) plus
a Grafana Alloy collection DaemonSet into the already-Synced-but-empty
`observability` layer, at the smallest reduced-scale shape that still lets an
operator sign in to Grafana at a real dev hostname and see a dashboard with real
signal data behind it. That last clause is the whole point: Closing Bell task 4
asks the study participant to "open the observability dashboard, sign in with the
local dev credentials, and see a dashboard that shows the platform is healthy" —
which implies not just that Grafana authenticates, but that at least one upstream
datasource has real data flowing into it through Alloy.

The deliverable is five official Helm charts plus their wiring, all reconciled by
ArgoCD under the single existing `observability` Application (sync-wave 3):

1. **Loki** (monolithic single binary) — the log store.
2. **Tempo** (the monolithic `tempo` chart, `-target=all`, local trace backend)
   — the trace store.
3. **Mimir** (`mimir-distributed` at one replica per component) — the metrics
   store.
4. **Grafana** (embedded SQLite on a `local-path` PVC) — the dashboard UI, the
   one component with an end-user surface, exposed through the shared Gateway.
5. **Alloy** (DaemonSet, chart default) — the collector that self-discovers the
   cluster and forwards metrics to Mimir, logs to Loki, and traces to Tempo.

The value is the platform's observability front door: it is what the dev
gestalt's Grafana probe (`tests/agrippa.bats`) exercises, and the direct target
of Closing Bell task 4. It **consumes** two already-landed shared contracts
without re-inventing either: the Storage feature-step's `local-path` storage
class (every signal store's PVC binds there) and the Networking feature-step's
Gateway/HTTPRoute/hostname/TLS contract (one new Grafana HTTPRoute against the
shared `agrippa-gateway`, one host appended to the shared certificate's SANs).

Out of scope, kept as seams for a deferred cloud/production cycle: **external
Postgres for Grafana** (a scaling trigger that does not fire at one replica),
**Rook-Ceph object storage** for the signal stores (`local-path` is the dev
substrate throughout), **any HA/multi-replica shape**, **the Prometheus Operator
/ `kube-prometheus-stack`** (Alloy self-discovers without ServiceMonitor CRDs),
**scraping Istio ambient's ztunnel telemetry** (available, low-effort, but not
required by task 4 — a named follow-on seam), and a **production Grafana admin
credential via `admin.existingSecret`** against a sops-sealed password (the dev
overlay uses the documented literal `admin`/`admin`; the sealed-credential path
is the prod seam, not built here).

## Prior Art

- **Storage feature-step (`storage/overlays/dev/`), already landed and cleared.**
  The authoritative in-repo precedent for **multi-chart composition under one
  layer Application**: `cnpg-operator/` and `valkey/` are each a nested
  kustomization with its own `commonAnnotations` sync-wave and its own
  `helmCharts:` block, both reconciled under the single `storage` Application.
  This feature-step extends that exact shape from two charts to five. It also
  fixes the reusable details this step inherits: `local-path` as the confirmed
  dev `StorageClass`; the per-app namespace = layer-name convention (`storage`
  → `observability`); the `valkey/kustomization.yaml` `helmCharts:` +
  `valuesInline:` + `skipTests: true` + the **kustomize 5.8.0 namespace-stamp
  workaround** (`patches:` adding `metadata.namespace` to helm-inflated
  resources — kustomize issue #6058, which this step will hit identically for
  every chart whose templates do not hardcode `{{ .Release.Namespace }}`);
  the operator-over-hand-rolled precedent (CNPG chart over a hand-authored
  Postgres StatefulSet) that decides Mimir's shape here.
- **Networking feature-step (`core/overlays/dev/`), already landed and cleared.**
  Defines the shared Gateway/HTTPRoute/hostname/TLS contract this step consumes.
  The concrete precedents this step copies: `argocd-httproute.yaml` (an
  `HTTPRoute` with `parentRefs` to `agrippa-gateway`/`istio-ingress`/`https`, an
  explicit `hostnames:` list, an **explicitly authored** `rules[].matches`
  PathPrefix `/` — required because ArgoCD's pre-sync SMD diff does not reliably
  replicate the omitted-`matches` API default — and `backendRefs` to the target
  Service); `gateway-cert.yaml` (the single shared, **append-only-SAN**
  `agrippa-gateway-tls` Certificate this step appends one `dnsNames` entry to);
  and `argocd-destinationrule.yaml` (the backend-TLS re-origination
  DestinationRule that Grafana, serving plain HTTP, will **not** need — see
  Specification).
- **`apps/observability.yaml` + `observability/overlays/dev/kustomization.yaml`,
  the current empty shell.** The ArgoCD `Application` named `observability`
  (sync-wave 3, `path: observability/overlays/dev`, header comment
  "Observability owns loki, grafana, tempo, mimir, alloy") is landed and
  trivially Synced/Healthy against a `resources: []` placeholder — a true Step-0
  state this step replaces with real content. It does **not** yet carry the
  `ServerSideApply`/`ServerSideDiff` seam its CRD-adjacent siblings needed.
- **`apps/platform/argocd/kustomization.yaml`.** The repo-server's
  `kustomize.buildOptions` already carries `--enable-helm` (added by the
  Networking step for its own `helmCharts:` composition), so this step needs
  **no** repo-server wiring change — the precondition is already live.
- **External worked examples** (full citations in `research/public.md`): the
  Grafana Loki monolithic Helm docs; the Tempo monolithic-vs-microservices and
  local-backend docs; the Mimir deployment-modes docs and the still-open
  monolithic-Helm feature request (#4832); the Alloy `discovery.kubernetes` /
  `prometheus.scrape` / `loki.source.kubernetes` / `otelcol.receiver.otlp`
  collection docs; the Grafana SQLite-vs-Postgres framing; the Grafana chart's
  random-`adminPassword` default; and the January 2026 Grafana Helm chart
  repository migration.

## User Journey and Metrics

**The operator's flow, from the bootstrapped `agrippa-dev` cluster (Features
1–7), with this Observability content committed and ArgoCD reconciling
`observability`:**

1. ArgoCD syncs the `observability` layer in intra-layer sync-wave order: the
   `observability` namespace, then the three signal stores (Loki, Tempo, Mimir)
   with their `local-path` PVCs, then Grafana + Alloy + the Grafana HTTPRoute.
   The operator runs `kubectl -n argocd get application observability` and sees
   it **Synced/Healthy**.
2. Alloy's DaemonSet pods come up on the node, self-discover the cluster via
   `discovery.kubernetes`, and begin forwarding: metrics to Mimir, logs to Loki,
   traces (when any workload emits OTLP) to Tempo. Real signal data starts
   accumulating in the stores.
3. The operator opens `https://dashboard.davidsouther.com.127.0.0.1.nip.io/` in a
   browser (or the gestalt `curl -k`): the request goes host `:443` → k3d
   loadbalancer port-map → node IP via the Gateway's `externalIPs` → gateway
   pods → the Grafana `HTTPRoute` → the Grafana Service (plain HTTP `:3000`),
   TLS terminated at the gateway with the local-CA cert. Grafana's login page
   renders. The browser shows an untrusted-CA warning by design (`curl -k`
   accepts it).
4. The operator signs in with the documented local dev credentials
   (`admin`/`admin`). Grafana authenticates and renders the home dashboard; the
   Loki, Mimir, and Tempo datasources are already provisioned, so a dashboard
   built on them shows real platform health — the exact bar Closing Bell task 4
   sets.

**Metrics / measures of done for this feature-step:**

- The feature test (`tests/observability.bats`) is green: through the shared
  Gateway at the dev host, an anonymous Grafana API call is challenged (401),
  the documented `admin`/`admin` credential authenticates and the home
  dashboard renders (`/api/dashboards/home` → 200), and the three LGTM
  datasources (`loki`, `prometheus`/Mimir, `tempo`) are provisioned
  (`/api/datasources` → 200 enumerating them) — proving authenticate-and-render
  with real signal sources behind it, end-to-end.
- `kubectl -n argocd get application observability` is **Synced/Healthy** with
  all five charts reconciled.
- Adding this step does not regress earlier harness: `mise run test:push`,
  `mise run test:feature`, and the sibling suites (`cluster-core.bats`,
  `gitops.bats`, `networking.bats`, `storage.bats`) stay green (the
  `observability.bats` `test:feature` exclusion lands with the test, below).

**Per-component SLOs (defined here, watched in Grafana; not a CI step, per
`DEVELOPMENT.md` § Testing).** Observability is the platform's own health
mirror, so its SLOs are about the observability plane staying trustworthy:

- **Grafana availability — 99.5%** of dashboard-UI requests succeed (non-5xx)
  over a rolling 28-day window, measured from Alloy's own scrape of Grafana's
  `/metrics` (`grafana_http_request_duration_seconds_count` by status). Grafana
  is the one component a human depends on directly; a burn-rate alert fires at
  2% budget consumed in 1h.
- **Ingest-pipeline liveness — 99%** of 5-minute windows have Alloy's
  `prometheus.remote_write` to Mimir, `loki.write` to Loki, and OTLP export to
  Tempo all reporting zero sustained send failures
  (`prometheus_remote_write_wal_samples_appended_total` advancing;
  `loki_write_sent_bytes_total` advancing), so "the dashboard shows the platform
  is healthy" reflects fresh data, not a stalled collector. Burn-rate alert at
  5% budget in 6h (looser than Grafana's front-door budget — a brief collector
  stall degrades freshness but does not black out the UI).
- **Store query success — 99%** of Grafana→datasource queries to Loki, Mimir,
  and Tempo return non-error over 28 days (from each store's own request
  metrics). These SLOs are recorded here and instrumented once this stack is
  live (they are self-hosted: the observability plane measures itself); they are
  not asserted by the feature test.

**Failure modes to design against.**

- **The kustomize 5.8.0 namespace-stamp regression (issue #6058), hit five
  times.** The top-level `namespace:`/`commonAnnotations` transformer does not
  stamp `metadata.namespace` onto `helmCharts:`-inflated resources whose
  templates do not hardcode `{{ .Release.Namespace }}` — the Storage step hit
  this on Valkey and every Loki/Mimir/Tempo/Grafana/Alloy chart is liable to the
  same. Mitigated by the same per-sub-kustomization `patches:` workaround Storage
  used (add `metadata.namespace: observability` to the inflated kinds), scoped
  per chart; confirm live per chart at build, since which resources need it
  depends on each chart's own templates.
- **A Grafana random admin password silently breaking the documented
  contract.** The chart's own default `adminPassword` is unset, which makes it
  generate a random 40-char password — Grafana would then reject `admin`/`admin`
  and both `DEVELOPMENT.md` and `tests/agrippa.bats` would fail. Mitigated by the
  dev overlay **explicitly** setting `adminUser: admin` / `adminPassword: admin`
  (Specification). This is the single most easily-missed value in the whole step.
- **Mimir's footprint on a single k3d node.** `mimir-distributed` at one replica
  per component still renders ~10 pods (including a bundled minio). Mitigated by
  accepting it as the chart-supported reduced-scale shape (the
  operator-over-hand-rolled convention, Alternatives); it is heavier than Loki's
  or Tempo's single binary but reversible, and the node already carries CNPG +
  Istio ambient + Valkey + ArgoCD.
- **A perma-`OutOfSync` symptom on `apps/observability.yaml`.** The CRD-adjacent
  siblings (`core`, `storage`) both needed `ServerSideDiff=true` +
  `ServerSideApply`/`SkipDryRunOnMissingResource` to escape ArgoCD's SMD
  diff-mispredict. These charts render no CRDs of their own, so the class of
  problem is a priori less likely here, but the Grafana HTTPRoute is a
  Gateway-API-defaulted object of exactly the kind that tripped `core`.
  Mitigated by adding the same annotations proactively (Specification,
  cross-step touches) — harmless if unneeded, cheap insurance if needed.
- **Grafana starting before its datasources exist.** Grafana provisions
  datasources declaratively and tolerates an unreachable datasource at startup
  (it retries), so ordering Grafana after the stores is cleanliness, not
  correctness; the store Services need not be Healthy for Grafana to render its
  login page and authenticate. The datasource-enumeration assertion in the
  feature test checks provisioning (the datasource objects exist in Grafana),
  not live query success, precisely to stay robust to store warm-up timing.

## Specification

### Composition: one `observability` Application, five charts under one KSOPS+Helm `kustomize build`

The five charts compose under the **single, already-existing `observability`
Application** (sync-wave 3) as a Kustomize overlay at `observability/overlays/dev/`,
following the Storage step's multi-chart precedent exactly: a top-level
`observability/overlays/dev/kustomization.yaml` listing a `namespace.yaml`, one
nested per-chart directory per component, and the authored Grafana `HTTPRoute`.
Each nested kustomization carries its own `commonAnnotations` sync-wave, its own
`helmCharts:` block (pinned `repo`/`version`, `releaseName`, `namespace:
observability`, `valuesInline:`), and — where the chart's templates do not
hardcode the release namespace — the kustomize-#6058 `metadata.namespace` patch.
The repo-server already has `--enable-helm` (Networking landed it), so no
repo-server change is needed.

Proposed layout (concrete directory/object names surfaced in Open Artifact
Decisions):

```
observability/overlays/dev/
  kustomization.yaml            # lists namespace.yaml, loki/, tempo/, mimir/, grafana/, alloy/, grafana-httproute.yaml
  namespace.yaml                # Namespace observability (wave -10)
  loki/kustomization.yaml       # helmChart loki (monolithic),        wave 0
  tempo/kustomization.yaml      # helmChart tempo (monolithic),       wave 0
  mimir/kustomization.yaml      # helmChart mimir-distributed (r=1),  wave 0
  grafana/kustomization.yaml    # helmChart grafana (SQLite+PVC),     wave 5
  alloy/kustomization.yaml      # helmChart alloy (DaemonSet),        wave 5
  grafana-httproute.yaml        # HTTPRoute grafana -> grafana:3000,  wave 5
```

### Intra-`observability` sync-wave scheme (this feature-step defines it)

These charts render **no CRDs of their own** (only Deployment/StatefulSet/
Service/PVC/ConfigMap/Secret), so the scheme is simpler than `core`'s or
`storage`'s CRD-gated ones:

- **wave `-10` — the `observability` namespace.**
- **wave `0` — the three signal stores** (Loki, Tempo, Mimir) and their
  `local-path` PVCs. Independent of each other; they only need the namespace.
- **wave `5` — Grafana, Alloy, and the Grafana HTTPRoute.** Grafana's
  datasources point at the wave-0 stores and Alloy forwards to them, so ordering
  them last is clean (though Grafana tolerates a not-yet-ready datasource, per
  Failure modes). The HTTPRoute needs the Grafana Service to exist to attach.

ArgoCD syncs waves in ascending order and waits for each wave Healthy before the
next. (Cross-layer, `observability`=3 already sits after `core` and `storage`,
so the Gateway, cert issuer, and storage class are all live before this layer
reconciles.)

### Per-component chart configuration (deployment-mode values)

Exact `repoURL`/`version` pins are **deferred to build-time live verification**
(`helm search repo` against both `https://grafana.github.io/helm-charts` and
`https://grafana-community.github.io/helm-charts`, or each chart's current docs
page) — the Grafana Helm chart ecosystem is mid-migration (research Search/Expand
finding 5): `grafana` and `loki` have moved to `grafana-community.github.io/helm-charts`,
`alloy` has **not** (still `grafana.github.io/helm-charts`), and `tempo`/`mimir`
are to be re-verified live. The same "defer the exact source/version pin to build
time" pattern the Storage step used for the CNPG chart. Deployment-mode values,
settled by cleared research:

- **Loki — monolithic.** `deploymentMode: Monolithic`, `singleBinary.replicas:
  1`, `loki.commonConfig.replication_factor: 1`, every microservices-mode replica
  count zeroed, chunk storage on a `local-path` PVC. Chart-native single-values
  toggle.
- **Tempo — the `tempo` chart (not `tempo-distributed`).** Default `-target=all`
  monolithic, `storage.trace.backend: local` (the local-disk backend documented
  as monolithic-only), trace storage on a `local-path` PVC. Avoid the
  `scalable-single-binary` target (a distinct, known-broken in-between mode,
  research #3096).
- **Mimir — `mimir-distributed` at one replica per component.** No monolithic
  Mimir Helm chart exists; drive every component's replica count to 1 (~10 pods
  including the chart's bundled minio for blocks storage), each stateful
  component's PVC on `local-path`. This is the chart's supported reduced-scale
  shape and the project's operator-over-hand-rolled convention (see
  Alternatives). Keep the bundled minio (chart default) rather than
  hand-configuring a filesystem backend, to minimize hand-authoring; confirm its
  PVC lands on `local-path` at build.
- **Grafana — embedded SQLite + `local-path` PVC.** `persistence.enabled: true`,
  `persistence.storageClassName: local-path`; no `[database]` override (SQLite is
  the default and sufficient at one replica). Datasources and admin credential
  below.
- **Alloy — DaemonSet (chart default), three self-discovery pipelines.** No
  Prometheus Operator CRDs (none exist in this cluster; none installed).
  - **metrics:** `discovery.kubernetes` (pod/service/endpoints/node roles) →
    `prometheus.scrape` → `prometheus.remote_write` to Mimir's push endpoint.
  - **logs:** `discovery.kubernetes` (pod role) → `discovery.relabel` →
    `loki.source.kubernetes` → `loki.write` to Loki's push endpoint (hostPath
    log mount, one node's logs per Alloy pod).
  - **traces:** `otelcol.receiver.otlp` (gRPC `:4317` / HTTP `:4318`) →
    `otelcol.exporter.otlp` to Tempo's OTLP ingest — the standard OTLP wire any
    later instrumented workload emits against, so no Agrippa-specific tracing
    SDK is implied.

### Grafana admin credential (dev) and the prod seam

The dev overlay **must explicitly** set `adminUser: admin` / `adminPassword:
admin` in the Grafana chart values (the chart's own unset default generates a
random 40-char password — verified against chart source — which would break both
`DEVELOPMENT.md`'s documented `GRAFANA_USER`/`GRAFANA_PASSWORD` local-dev
convention and the committed `tests/agrippa.bats` dev-path assertion). This is a
deliberate, contract-driven exception to the Storage step's sops-sealing
discipline: the dev credential is an intentionally-non-secret, committed,
human-facing contract (the Closing Bell literally instructs the participant to
"sign in with the local dev credentials"). The plaintext-Secret conftest guard is
not tripped — verified in cleared research: `scripts/test-static.sh` scans only
`apps/`, `charts/*/rendered/`, and `secrets/` (never `observability/`), and
`tests/policy/secrets.rego` evaluates only `kind: Secret` objects, which a
`valuesInline:` field is not.

A future **production** overlay would instead use `admin.existingSecret` (with
`admin.userKey`/`admin.passwordKey`) against a sops-sealed random password,
reusing the Storage step's seal-in-memory discipline verbatim (`kubectl create
secret --dry-run=client -o yaml | sops --encrypt`, never plaintext to disk). That
is a **preserved, unbuilt seam** — noted, not built.

### Grafana datasources (provisioned, declarative)

Grafana's chart `datasources` values provision three datasources at startup,
each pointing at the in-cluster Service of its store (exact Service names/ports
**confirmed live at build** — deferred by research):

- **Loki** — `type: loki`, URL the Loki monolithic Service (HTTP `:3100`).
- **Mimir** — `type: prometheus` (Mimir speaks PromQL), URL the Mimir
  query-frontend/gateway Service with its `/prometheus` API prefix.
- **Tempo** — `type: tempo`, URL the Tempo query Service (HTTP `:3100`).

The `prometheus`/`loki`/`tempo` datasource `type` strings are what the feature
test's datasource-enumeration assertion keys on, so the provisioning names these
types explicitly.

### Grafana ingress: one HTTPRoute, no DestinationRule

Consuming the Networking shared contract, exactly as `argocd-httproute.yaml`
established:

- **`HTTPRoute` `grafana`** in the `observability` namespace, `parentRefs: [{name:
  agrippa-gateway, namespace: istio-ingress, sectionName: https}]`, `hostnames:
  [dashboard.davidsouther.com.127.0.0.1.nip.io]`, an **explicitly authored**
  `rules[].matches` PathPrefix `/` (the omitted-`matches` SMD-diff caveat the
  Networking step found), and `backendRefs: [{name: <grafana-service>, port:
  3000}]`.
- **No `DestinationRule`.** Grafana's chart Service serves **plain HTTP** on port
  3000 by default (unlike `argocd-server`'s internal HTTPS, which forced the
  ArgoCD backend-TLS DestinationRule), so the `backendRefs` needs no backend-TLS
  re-origination. Confirm the chart's `service.yaml` port/protocol default at
  build; add a DestinationRule only if a future TLS-internal override is chosen
  (reversible).
- **One SAN appended** to the shared `agrippa-gateway-tls` Certificate
  (`core/overlays/dev/gateway-cert.yaml`): add
  `dashboard.davidsouther.com.127.0.0.1.nip.io` to its `dnsNames` — a one-line,
  append-only edit to a `core`-owned file, the exact seam the Networking step's
  plan named. The Gateway object itself is never touched
  (`allowedRoutes.namespaces.from: All` already admits this namespace's route).

### Cross-step touches (summary)

- **`observability/overlays/dev/kustomization.yaml`** — replace `resources: []`
  with the real composition above (this feature-step's own file; build phase).
- **`apps/observability.yaml`** — add the proactive sync seam matching
  `core`/`storage`: `syncPolicy.syncOptions: [ServerSideApply=true,
  SkipDryRunOnMissingResource=true]` and annotation
  `argocd.argoproj.io/compare-options: ServerSideDiff=true`. This file is **not**
  shared with the three parallel `platform`-layer sibling feature-steps (Keycloak,
  Forgejo, Flagsmith), so no coordination is needed. Build phase; confirm live
  once the HTTPRoute lands (harmless if unneeded).
- **`core/overlays/dev/gateway-cert.yaml`** — append one `dnsNames` entry
  (above). A `core`-owned file; the append-only seam. Build phase.
- **`scripts/test-feature.sh`** — add `observability.bats` to the auto-discovery
  exclusion list (it drives the long-lived `agrippa-dev` cluster and the
  GitOps-reconciled `observability` layer, not the throwaway `agrippa-feature`
  cluster), the same one-line edit `storage.bats` and `networking.bats` already
  made. **This exclusion lands with the feature test in this design phase** (not
  deferred to build): the test file is committed now, so without the exclusion
  `mise run test:feature` would pick it up and loop ~5 min against a
  storeless/routeless `observability` before failing. This is test-harness
  plumbing, not feature implementation — the same design-phase precedent the
  cleared Networking sibling set.

### Challenges

- **Exact chart pins in a mid-migration ecosystem.** Re-verify each chart's
  `repoURL`/`version` live at build (both `grafana.github.io` and
  `grafana-community.github.io` indexes); do not hardcode from the research
  snapshot. `grafana`/`loki` moved; `alloy` did not; `tempo`/`mimir` to confirm.
- **Exact in-cluster Service names/ports.** Loki/Mimir/Tempo Service names and
  ports (for datasource URLs and Alloy forward targets) and Grafana's Service
  name/port (for the HTTPRoute `backendRefs`) are `releaseName`-derived; confirm
  each against the pinned chart at build, as the Storage step confirmed CNPG and
  Valkey label/Service spellings.
- **The #6058 namespace patch, per chart.** Apply the Storage-style
  `metadata.namespace` patch to each chart's inflated kinds as needed; confirm
  live which resources land in the wrong namespace without it.
- **Mimir's ~10-pod first reconcile.** The wave-0 Mimir StatefulSets/Deployments
  and bundled minio take the longest to reach Healthy; the feature test's
  `wait_for_observability_synced_healthy` allows a generous window
  (matching `storage.bats`).
- **`helm template` semantics.** `helmCharts:` inflation runs `helm template`
  (no hooks, no cluster `lookup`). Use `skipTests: true` on any chart that ships
  a `helm.sh/hook: test` Pod (Storage hit this on Valkey), so ArgoCD does not
  apply a hook Pod as a permanent object.

## Alternatives

**Chart composition (the shape research handed to this design):**

- **Recommended — five individual official charts under one `observability`
  Application, one KSOPS+Helm `kustomize build`, nested per-chart
  kustomizations ordered by sync-wave.** Matches the Storage step's cleared
  two-chart precedent extended to five; keeps one Application, one build, hard
  per-resource sync-wave ordering; stays entirely on official Grafana Labs
  tooling. **Chosen** (settled by cleared research decision 1).
- **An all-in-one "LGTM" distribution chart.** Rejected: none current and
  maintained exists — `lgtm-distributed` is deprecated and the standing feature
  request (#1397) is unaddressed. The closest community substitutes are
  unofficial single-maintainer charts.
- **Hand-authored monolithic Mimir manifest (`-target=all`, filesystem
  backend).** The lightest Mimir footprint (one Deployment + Service + PVC), and
  a documented target for the Mimir binary — but **rejected as the default**.
  Hand-authoring is precedented in this project **only** for first-party
  workloads (`charts/resume`, `charts/trips`), never for a third-party infra
  component; every third-party component ships through its official chart/operator
  and accepts the overhead (CNPG operator over a hand-rolled StatefulSet, the
  official Valkey chart, Istio ambient's four charts, cert-manager, metallb).
  Hand-rolling Mimir would break that pattern and add standing
  config-schema/upgrade maintenance burden. The footprint cost is real but
  reversible; a lighter shape stays available as a later optimization (settled by
  cleared research long-loop-reviewer decision 1).
- **Grafana's `k8s-monitoring` umbrella chart** (bundles node-exporter,
  kube-state-metrics, an Alloy operator tuned around ServiceMonitor discovery).
  Rejected: more machinery than a reduced-scale dev target needs, and it pulls in
  Prometheus-Operator-style discovery this cluster deliberately does not run.
  Named as the production-shaped answer, not adopted.

**Other alternatives:**

- **External Postgres for Grafana** instead of embedded SQLite. Rejected at this
  scale: SQLite is the chart default and "robust enough for most use cases"; the
  only trigger for Postgres is scaling Grafana beyond one replica (SQLite is
  embedded per-pod), which the reduced-replica Specification does not do. The
  Storage step's per-app Postgres consumption contract stays available, unused,
  and unchanged as a seam (settled by cleared research decision 5).
- **A sops-sealed dev Grafana admin credential** (`admin.existingSecret`).
  Rejected for **dev**: the dev credential is a committed, documented,
  intentionally-non-secret contract the Closing Bell depends on. Sealing is the
  right fit for the **prod** overlay's credential — a preserved seam (settled by
  cleared research decision 6).
- **Installing the Prometheus Operator / `kube-prometheus-stack`** for
  ServiceMonitor/PodMonitor discovery. Rejected: Alloy's `discovery.kubernetes`
  self-discovers directly against the Kubernetes API with no CRD dependency;
  installing the operator solely for ServiceMonitor CRDs is new, unbudgeted
  cluster-level scope the "reduced replicas" Specification argues against
  (settled by cleared research decision 4).
- **Scraping Istio ambient's ztunnel telemetry** (`/stats/prometheus` on port
  15020). Declined for this feature-step: available and low-effort, but required
  by neither the parent Specification nor Closing Bell task 4. A named,
  reversible follow-on seam (Alloy would target it via `discovery.kubernetes`
  pod-role, no new CRDs) — settled by cleared research long-loop-reviewer
  decision 5.
- **A Grafana backend-TLS DestinationRule** (the ArgoCD shape). Rejected:
  Grafana serves plain HTTP by default, so no backend-TLS re-origination is
  needed — the materially simpler case (settled by cleared research
  long-loop-reviewer decision 2).

## Summary

This feature-step lands the Grafana LGTM stack plus a Grafana Alloy collector
into the already-Synced-but-empty `observability` layer, at reduced dev scale:
**Loki** monolithic, **Tempo** monolithic (`tempo` chart, local trace backend),
**Mimir** as `mimir-distributed` at one replica per component (the official
chart, per the project's operator-over-hand-rolled convention), **Grafana** on
embedded SQLite + a `local-path` PVC, and **Alloy** as a DaemonSet with three
`discovery.kubernetes`-based self-discovery pipelines (metrics→Mimir, logs→Loki,
traces→Tempo, no Prometheus Operator CRDs). The five compose under the single
existing `observability` Application as one KSOPS+Helm `kustomize build` (nested
per-chart kustomizations, sync-waves `-10` namespace / `0` stores / `5`
Grafana+Alloy+route), extending the Storage step's cleared multi-chart precedent
from two charts to five. Grafana is the one UI-exposed component: it consumes the
Networking shared contract with one `HTTPRoute` (`grafana` → Grafana Service
`:3000`, plain HTTP, **no** DestinationRule) at
`dashboard.davidsouther.com.127.0.0.1.nip.io` and one SAN appended to the shared
`agrippa-gateway-tls` Certificate, and it **explicitly** sets `adminUser: admin`
/ `adminPassword: admin` to honor the documented dev credential the Closing Bell
depends on. The one feature test proves the whole path by authenticating to
Grafana through the Gateway with the documented credentials and confirming the
home dashboard renders with the three LGTM datasources provisioned behind it —
the exact bar of Closing Bell critical task 4.

This Design-phase run does **not** deploy the Observability content: reconciling
it is a full ArgoCD sync of five newly-committed charts and the route (build-phase
work), and the chart pins, Service names/ports, and per-chart namespace patches
want live re-verification at build time. The feature test is therefore left
**RED** (baseline recorded below); the build phase turns it green after committing
the `observability` composition and letting ArgoCD reconcile it.

### Open Artifact Decisions

Concrete artifact choices this design invents that are not fixed by a skill
template, an existing project convention, or the cleared `research.md`. (The
composition pattern, the SQLite/`local-path` choice, the `admin`/`admin` dev
credential, the dev hostname, the Alloy pipelines, the Mimir shape, the
`ServerSideDiff` seam, the "no DestinationRule" decision, and the ztunnel
deferral are all resolved above from the cleared research and the parent design
— stated as conclusions, not surfaced here.)

**`observability/overlays/dev/` internal layout and directory names
(`loki/`, `tempo/`, `mimir/`, `grafana/`, `alloy/`, `namespace.yaml`,
`grafana-httproute.yaml`):** whether each chart gets its own nested kustomization
directory (the Storage `cnpg-operator/`+`valkey/` shape) versus a single flat
`helmCharts:` list in one kustomization.
Proposed: **one nested directory per chart** (mirroring Storage), because the
#6058 namespace patch and per-chart sync-waves are cleanest scoped per
sub-kustomization, and a flat single kustomization would tangle five charts'
`valuesInline`, patches, and waves into one file.

**The authored object names (`HTTPRoute` `grafana`, `Namespace` `observability`,
the `observability` namespace itself, and each chart `releaseName`):** the
concrete spellings this step's manifests and its feature test bind to.
Proposed: `observability` namespace (the layer-name = namespace convention every
sibling layer follows, and the ArgoCD Application's own header comment); HTTPRoute
`grafana` (component-named, matching `argocd-httproute.yaml`'s `argocd`);
per-chart `releaseName`s `loki`/`tempo`/`mimir`/`grafana`/`alloy` (bare
component names, matching Valkey's `releaseName: valkey`, which collapse each
chart's `fullname` to the bare Service/pod-label name the datasource URLs and
HTTPRoute `backendRefs` assume). Settle them here since consumers (the feature
test, the datasource URLs) reference them.

**The dev hostname `dashboard.davidsouther.com.127.0.0.1.nip.io`:** already fixed
by the parent design's resolved decision 6 and `tests/agrippa.bats`'s
`DASHBOARD_HOST` — a derived conclusion, not open, but repeated here because the
feature test binds to it directly.

## Feature Test

**Path:** `tests/observability.bats` (following `DEVELOPMENT.md`'s
`tests/<feature>.bats` convention, feature = "observability"; the `-lgtm`
qualifier is dropped just as `cluster-core.bats` dropped `-k3d`,
`networking.bats` dropped `-istio`, and `storage.bats` dropped
`-postgres-valkey`).

**User story (Given / When / Then):** *Given* the bootstrapped long-lived
`agrippa-dev` cluster (Features 1–7) with this Observability content committed and
reconciled by ArgoCD into the `observability` layer (Loki, Tempo, Mimir, Grafana,
Alloy), *When* an operator requests
`https://dashboard.davidsouther.com.127.0.0.1.nip.io/` through the k3d `:443`
host port-map and signs in to Grafana with the documented local dev credentials
(`admin`/`admin`), *Then* the `observability` layer is Synced/Healthy, an
anonymous Grafana API call is challenged (proving auth is enforced, not
anonymous), the documented credential authenticates and the home dashboard
renders (`/api/dashboards/home` → 200), and the three LGTM datasources (`loki`,
`prometheus`/Mimir, `tempo`) are provisioned (`/api/datasources` → 200
enumerating them) — proving authenticate-and-render with real signal sources
behind it, the exact bar of Closing Bell critical task 4. `curl -k` tolerates the
deliberately-untrusted local CA (`research.md` decision 3). Like the sibling
suites it deliberately does **not** tear the cluster or ArgoCD down.

**Current state: RED (baseline captured this run against the live cluster).**
With `observability/overlays/dev` still the empty `resources: []` placeholder, the
`observability` Application is already trivially **Synced/Healthy** (so the THEN 0
GitOps-precondition gate passes even now, exactly as `storage.bats`' and
`networking.bats`' THEN 0 pass on their empty layers), the `observability`
namespace does not exist, and no Grafana route/backend exists — so the shared
Istio Gateway answers every Grafana probe with **404** (no route matched):
anonymous `/api/dashboards/home` → 404 (the suite expects 401), authenticated
`/api/dashboards/home` → 404 (expects 200), authenticated `/api/datasources` →
404 (expects 200 + the three datasources). The suite fails at the first Grafana
probe. That red state defines "done" for this feature-step. This Design-phase run
does **not** turn it green: reconciling the `observability` composition is a full
ArgoCD sync of five newly-committed charts and the route, with chart pins and
Service names to re-verify live — build-phase work outside this phase's
write-only-the-test gate. The build phase turns it green after committing the
`observability` content and letting ArgoCD reconcile it.
