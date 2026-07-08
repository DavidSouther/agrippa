# Public: Grafana LGTM stack (Loki, Grafana, Tempo, Mimir) + Grafana Alloy on Kubernetes for a reduced-scale local dev cluster

## Findings

**There is no official, current, all-in-one "LGTM" distribution chart fit for
this project.** Grafana Labs' own `lgtm-distributed` umbrella chart (which
composed distributed Loki + Grafana + Tempo + Mimir) is deprecated on
ArtifactHub [1][2], and a standing, still-open feature request against
`grafana/helm-charts` (#1397) asks for exactly "a preconfigured and all-in-one
LGTM stack helm chart" that does not exist officially [3]. The closest
community substitutes (e.g. `garovu/lgtm-minimal`, a third-party chart
explicitly built for "small kubernetes cluster" in monolithic mode [4]) are
unofficial, single-maintainer projects, not Grafana Labs releases. The correct
default is therefore **a composition of the four individual official charts**
(`loki`, `grafana`, `tempo`, `mimir-distributed`) plus `alloy`, each pinned and
composed under this project's own Kustomize `helmCharts:` mechanism — the same
shape already used for CNPG (storage feature-step) and the four-chart Istio
ambient composition (networking feature-step). This is not a novel pattern for
this repo.

**Each of Loki, Tempo, and Mimir has its own deployment-mode story, and they
are not symmetric — this is the single most load-bearing finding for a
reduced-scale dev cluster.**

- **Loki** natively supports a **Monolithic** deployment mode via its official
  chart: set `deploymentMode: Monolithic`, `singleBinary.replicas: 1`, and
  `loki.commonConfig.replication_factor: 1`, zeroing every other deployment
  mode's replica count (backend/read/write/ingester/querier/etc.) [5][6]. This
  is a first-class, chart-native, single-values-block toggle — the easiest of
  the three.
- **Tempo** also natively supports monolithic mode, but through a **separate
  chart**: `tempo` (single-binary, `-target=all` by default) is distinct from
  `tempo-distributed` (microservices) [7][8]. The monolithic `tempo` chart is
  explicitly documented as the one to use "if you are getting started with
  Tempo or evaluating it," or when trace volume is under roughly 25-35 MB/s
  [7] — squarely this project's dev-scale case. Its `storage.trace.backend:
  local` option is documented as **"only supported in the monolithic mode"**
  [9] — i.e., the local-disk backend and monolithic mode are a matched pair;
  choosing monolithic here is also what makes a `local-path` PVC (no object
  store) viable at all. One open community issue (`grafana/helm-charts`
  #3096) reports a `frontend worker address not specified` failure when
  attempting `scalable-single-binary` (a **different**, in-between target,
  not plain monolithic `-target=all`) — a caveat to avoid that specific
  target, not evidence against monolithic mode itself [10].
- **Mimir has *no* monolithic/single-binary Helm chart, and Grafana Labs has
  no stated intention to build one.** `mimir-distributed` is microservices-only
  [11][12]; a standing, still-open feature request (`grafana/mimir` #4832,
  filed 2023, still open as of this research) asks for exactly this and
  remains unresolved — the issue's own text states "the only alternative now
  is to run a minimalistic version of the mimir-distributed helm chart" [13].
  A community PR attempting to add a monolithic Helm deployment mode
  (`grafana/mimir` #4858) exists but is not confirmed merged into the
  mainline chart [14]. Mimir the *binary* does support `-target=all` (true
  single-process monolithic mode, documented for local/Docker use with a
  `blocks_storage: backend: filesystem` local disk backend) [15][16] — the
  binary capability exists, but the *official Helm chart* does not expose it
  as a values toggle the way Loki's does. The chart's own `small.yaml`
  reference values file is Grafana's closest "smaller" preset, but it targets
  "production ingestion of ~1M active series" on a **minimum 4-core/16GiB
  node** [17] — still full microservices mode (distributor, ingester,
  querier, query-frontend, compactor, store-gateway, ruler, alertmanager,
  etc., each its own Deployment/StatefulSet), just with lighter-than-default
  resource requests. It is not a monolithic preset and is oversized for a
  single k3d dev node.

**Practical consequence for Mimir on this project:** two real options exist,
and neither is "use `mimir-distributed` with `deploymentMode: Monolithic`"
(that key does not exist for this chart).
1. **Set every `mimir-distributed` component's replica count to 1** (the
   chart's own documented shape for reduced-but-still-microservices scale
   [12][17]) — stays on the officially-supported, GitOps-composable chart,
   but still renders on the order of 8-10 separate Deployments/StatefulSets
   (one pod each), each needing its own `local-path` PVC where stateful. This
   is more pods than Loki's or Tempo's single-binary shape, but is still the
   *chart-supported* path and the conservative default for staying inside
   official tooling.
2. **Hand-author a minimal manifest running the `grafana/mimir` container
   image directly** with `-target=all` and `blocks_storage.backend:
   filesystem` (a single Deployment + Service + PVC on `local-path`) — true
   monolithic, lightest footprint, but is *not* the official Helm chart and
   would be this project's own from-scratch chart (matching the precedent the
   project's own design already accepts for the Workloads feature-step's
   hand-authored resume/trips charts, but a new precedent for a third-party
   component). This is a legitimate, documented deployment target for the
   `mimir` binary itself [15][16], just not Helm-packaged by Grafana Labs.

Both are reversible and neither blocks the Closing Bell's Grafana-dashboard
probe; the choice is a resource/footprint-vs.-stay-on-official-tooling
trade-off for the design phase to make explicitly, not one this research
resolves.

**No official Prometheus Operator CRDs (ServiceMonitor/PodMonitor/Probe) are
installed anywhere in this cluster** (confirmed by `research:codebase` — see
companion note) — and Grafana Alloy does not require them. Alloy's
`discovery.kubernetes` component discovers Pods, Services, Endpoints, and
Nodes directly against the Kubernetes API (pod/service/endpoints/node roles),
independent of any Prometheus Operator CRD [18][19]. A minimal metrics
pipeline is three components: `discovery.kubernetes` (targets) →
`prometheus.scrape` (collect) → `prometheus.remote_write` (forward to Mimir's
push endpoint) [18]. Alloy *can* additionally consume `ServiceMonitor`/
`PodMonitor`/`Probe` objects via `prometheus.operator.servicemonitors` etc. if
those CRDs and objects exist [20][21], but this is strictly additive — since
this cluster has no Prometheus Operator CRDs installed and installing it
solely to get ServiceMonitor CRDs would be unplanned scope creep contrary to
the "reduced replicas" dev intent, the `discovery.kubernetes` +
`prometheus.scrape` self-discovery path is the correct default here, not the
CRD-based path. Grafana's own heavier `k8s-monitoring` Helm chart (which
*does* install node-exporter, kube-state-metrics, and an Alloy Operator
tuned around ServiceMonitor discovery) [22] is the "real" production-shaped
answer but is more machinery than a reduced-scale local dev target needs;
worth naming as an alternative, not adopting by default.

**Logs and traces follow the same self-discovery pattern.** Alloy's official
Helm chart ships as a **DaemonSet by default** (`controller.type: daemonset`)
[23] — matching the parent design's own already-stated intent ("an Alloy
DaemonSet") without needing to override the chart default. Kubernetes pod log
collection uses `discovery.kubernetes` (pod role) → `discovery.relabel` →
`loki.source.kubernetes` → `loki.write` (to Loki's push endpoint), again with
no Prometheus/Loki Operator CRD dependency, run from a hostPath-mounted
DaemonSet pod so each node's Alloy instance reads only that node's local
container logs [24][25]. Traces use the standard OpenTelemetry Collector
components Alloy embeds: `otelcol.receiver.otlp` (gRPC :4317 / HTTP :4318)
feeding `otelcol.exporter.otlp` pointed at Tempo's OTLP ingest endpoint
[26][27] — this is the same OTLP wire protocol any instrumented workload
(including the project's own resume/trips workloads, later) would emit
against, so no Agrippa-specific tracing SDK choice is implied here.

**Istio ambient's own telemetry (ztunnel) is a separate, optional signal
source from the cluster's general pod/node metrics, and is not required for
the Closing Bell's Grafana probe.** ztunnel (the ambient mesh's per-node proxy)
exposes its own Prometheus-format metrics at `/stats/prometheus` on port
15020 [28][29]. Because ztunnel runs as a DaemonSet with no backing Service,
scraping it through the Prometheus-Operator idiom would need a `PodMonitor`,
not a `ServiceMonitor` [28] — moot here since no Prometheus Operator CRDs
exist in this cluster (see above); Alloy would instead target it directly via
`discovery.kubernetes` (pod role, namespace `istio-system` or wherever ztunnel
lives, port 15020) if mesh-level TCP metrics are wanted. This is additive
scope beyond what the parent design's Specification names ("Loki, Grafana,
Tempo, Mimir + an Alloy DaemonSet, reduced replicas") and beyond what Closing
Bell critical task 4 requires (Grafana renders *a* dashboard, not specifically
an Istio mesh dashboard) — worth flagging as an available, low-effort
follow-on for the design phase to accept or explicitly defer, not something
this research treats as required scope.

**Grafana does not need external Postgres for a single-replica dev
deployment; its embedded SQLite is the documented, supported default for
exactly this shape.** Grafana's own Helm chart defaults to SQLite (no
`[database]` section override); switching to Postgres/MySQL is a documented,
supported option via `grafana.ini`'s `[database]` section (`type: postgres`,
`host`, `user`, `password`, `name`) [30][31], but every source framing this
choice frames it the same way: SQLite is "robust enough for most use cases"
and the deciding factor for switching is **horizontal scaling** — "the
default SQLite database will not work with scaling beyond 1 instance, since
the SQLite3 DB is embedded inside Grafana container" [30]. This project's own
Specification explicitly calls for "reduced replicas," and Closing Bell
critical task 4 only requires one Grafana instance to authenticate and render
one dashboard — there is no HA/multi-replica requirement pulling toward
Postgres. Recommendation: **use Grafana's embedded SQLite with
`persistence.enabled: true` on a `local-path` PVC** (survives pod restarts,
no fifth Postgres consumer, no new `Database`/role/sealed-credential
triplet to add to the storage feature-step's shared contract). External
Postgres stays an available, reversible seam (documented, one `grafana.ini`
section) for a later cycle if Grafana is ever scaled beyond one replica —
consistent with this project's general pattern of preserving seams rather
than pre-building them.

**Grafana's admin-credential default is *not* literally `admin`/`admin` —
it must be set explicitly to match this project's already-documented
convention.** Direct inspection of the current Grafana Helm chart source
(`grafana-community/helm-charts`, post-migration — see below) shows
`adminUser: admin` as the literal default, but `adminPassword` ships
**commented out** (unset) in `values.yaml` [32]. When unset, the chart's
`grafana.secretsData` template helper falls through to a `grafana.password`
helper that looks up any existing chart-managed Secret and otherwise
**generates a random 40-character password** (`randAlphaNum 40`, base64-
encoded) baked into a chart-rendered Secret [33][34]. Left at chart defaults,
Grafana would *not* authenticate against the literal `admin`/`admin`
`DEVELOPMENT.md` already documents ("`GRAFANA_USER`, `GRAFANA_PASSWORD` are
local-only dev credentials (default `admin:admin`); never valid in
production") or the committed `tests/agrippa.bats` dev-path assertion (which
sends exactly `admin:admin` via HTTP basic auth against
`/api/dashboards/home` and asserts `200` [internal source, not this note]).
**The dev overlay must therefore explicitly set `adminUser: admin` /
`adminPassword: admin`** (or route the same literal values through
`env.GF_SECURITY_ADMIN_PASSWORD`) to satisfy both already-committed
contracts — this is not optional chart-default behavior, it is a value the
design phase must author. The chart's `admin.existingSecret` /
`admin.userKey` / `admin.passwordKey` fields [32] are the documented
mechanism for pointing at a **separate, sops-sealed random credential**
instead — the natural fit for a later **production** overlay, mirroring
exactly the per-app `passwordSecret`/`managed.roles[]` sealing convention the
storage feature-step already established for Postgres consumers (seal via
`kubectl create secret --dry-run=client -o yaml | sops --encrypt`, reference
via `existingSecret`, never commit plaintext). The dev/prod split is
therefore not a single either/or choice: **dev keeps the literal, documented
`admin:admin`** (already a committed, human-facing contract — the Closing
Bell scenario literally instructs the study participant to "sign in with the
local dev credentials" per the repo's own docs) while **prod (out of this
project's scope, but the preserved seam) would use `admin.existingSecret`
against a sops-sealed random password**, the same seam-preservation pattern
this project already applies everywhere else (Longhorn declared-but-deferred,
Rook-Ceph deferred, terraform/tflint deferred). One residual, design-phase
question this research does not resolve: whether a literal `adminPassword:
admin` value sitting in a committed `valuesInline:` block (inside this
project's Kustomize `helmCharts:` composition, not a raw `kind: Secret`
manifest) needs any accommodation from the plaintext-Secret conftest guard —
`research:codebase`'s companion note confirms that guard currently scans only
`apps/` and `charts/*/rendered/`, so a `valuesInline` field is very likely
outside its current scan scope either way, but this is worth a one-line
confirmation at design/build time rather than an assumption.

**Grafana Helm chart repository locations are mid-migration as of this
research date (2026-07-08) — pin the exact repo URL at design/build time,
not from this note.** Grafana Labs began moving charts out of the single
`grafana/helm-charts` repo on 2026-01-30 [35]. As directly verified against
each chart's current official docs page this session:
- **`grafana` (the dashboard chart)** has moved: `helm repo add
  grafana-community https://grafana-community.github.io/helm-charts` is the
  chart's own current documented command [36].
- **`loki`** has also moved, per its own current docs page: "Grafana
  Community Champions now maintain the Loki Helm charts in the
  [Grafana-community/helm-charts repo]" [37] — this is a *later* migration
  than the initial January wave, which one third-party migration-announcement
  blog (dated close to the original announcement) still describes as "Mimir
  and Loki are not affected" [35]; the live docs supersede that now-stale
  blog snapshot.
- **`mimir-distributed`**'s current docs reference `github.com/grafana/mimir`
  as its source without an explicit `helm repo add` command in the fetched
  page [38] — consistent with the reported pattern of some charts
  relocating into their own product repo rather than the shared community
  repo.
- **`alloy`** has **not** moved: its own current docs page still gives
  `helm repo add grafana https://grafana.github.io/helm-charts` /
  `helm install ... grafana/alloy` verbatim [39].
- **`tempo` / `tempo-distributed`** are reported (third-party migration
  summary, not independently re-verified against a live docs page this
  session) as moved to `grafana-community/helm-charts` alongside `grafana`
  [35].

This is an active, ongoing reorganization, not a settled fact this research
can freeze into a single citation-stable table. **Recommendation: the design
and build phases re-verify each chart's exact `repoURL`/`chart` pin live
(`helm search repo` against both `https://grafana.github.io/helm-charts` and
`https://grafana-community.github.io/helm-charts`, or the current docs page)
at the time each is actually authored**, the same "defer the exact version/
source pin to build time" pattern the storage feature-step's own research
already used for the CNPG operator chart version and Postgres major version.

## Sources

- [1] "lgtm-distributed 3.0.1," ArtifactHub (grafana org), marked deprecated.
  https://artifacthub.io/packages/helm/grafana/lgtm-distributed
- [2] "GitHub - mohammadll/grafana-stack," various LGTM-stack example
  repositories confirming the deprecated-umbrella-chart landscape.
  https://github.com/mohammadll/grafana-stack
- [3] "Preconfigured and all-in-one LGTM stack helm chart," grafana/helm-charts
  Issue #1397 (open feature request, no official chart exists).
  https://github.com/grafana/helm-charts/issues/1397
- [4] "garovu/lgtm-minimal: A helm chart for run LGTM stack (Grafana, Mimir,
  Loki, Tempo) with monolithic mode in small kubernetes cluster," GitHub
  (third-party, unofficial). https://github.com/garovu/lgtm-minimal
- [5] "Install the monolithic Helm chart," Grafana Loki documentation.
  https://grafana.com/docs/loki/latest/setup/install/helm/install-monolithic/
- [6] "Loki deployment modes," Grafana Loki documentation.
  https://grafana.com/docs/loki/latest/get-started/deployment-modes/
- [7] "Monolithic and microservices modes," Grafana Tempo documentation.
  https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/plan/deployment-modes/
- [8] "Deploy Tempo with Helm," Grafana Tempo documentation (distinguishes
  the `tempo` monolithic chart from `tempo-distributed`).
  https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/deploy/kubernetes/helm-chart/
- [9] Community discussion / values reference on Tempo's `storage.trace.backend`
  options, confirming `local` is monolithic-mode-only.
  https://github.com/grafana/helm-charts/tree/main/charts/tempo-distributed
- [10] "[tempo] helm chart is not ready for monolithic scaling," grafana/helm-charts
  Issue #3096 (reports a `scalable-single-binary` target failure, not plain
  monolithic `-target=all`). https://github.com/grafana/helm-charts/issues/3096
- [11] "Grafana Mimir deployment modes," Grafana Mimir documentation (confirms
  monolithic mode exists at the binary level via `-target=all`).
  https://grafana.com/docs/mimir/latest/references/architecture/deployment-modes/
- [12] "Deploy Mimir with Helm," Grafana Mimir documentation (mimir-distributed
  is microservices-only). https://grafana.com/docs/mimir/latest/set-up/helm-chart/
- [13] "Helm chart for monolithic and read-write deployment mode," grafana/mimir
  Issue #4832 (open since 2023). https://github.com/grafana/mimir/issues/4832
- [14] "Attempt to introduce a monolithic deployment with Helm," grafana/mimir
  PR #4858 (rubenvw-ngdata). https://github.com/grafana/mimir/pull/4858
- [15] "How to Run Grafana Mimir in Docker for Metrics Storage," OneUptime
  (documents `-target=all` + `blocks_storage.backend: filesystem` for local
  single-process Mimir). https://oneuptime.com/blog/post/2026-02-08-how-to-run-grafana-mimir-in-docker-for-metrics-storage/view
- [16] "HA Monolithic configuration," grafana/mimir Discussion #2179 (confirms
  monolithic mode can itself be horizontally replicated if ever needed).
  https://github.com/grafana/mimir/discussions/2179
- [17] "mimir/operations/helm/charts/mimir-distributed/small.yaml," grafana/mimir
  GitHub (production-oriented reduced-scale reference values; 4-core/16GiB
  minimum node). https://github.com/grafana/mimir/blob/main/operations/helm/charts/mimir-distributed/small.yaml
- [18] "Collect Prometheus metrics," Grafana Alloy documentation
  (discovery.kubernetes -> prometheus.scrape -> prometheus.remote_write).
  https://grafana.com/docs/alloy/latest/collect/prometheus-metrics/
- [19] "discovery.kubernetes," Grafana Agent/Alloy component reference.
  https://grafana.com/docs/agent/latest/flow/reference/components/discovery.kubernetes/
- [20] "prometheus.operator.servicemonitors," Grafana Alloy documentation
  (optional, CRD-dependent discovery path). https://grafana.com/docs/alloy/latest/reference/components/prometheus/prometheus.operator.servicemonitors/
- [21] "Monitor Kubernetes cluster performance with the Prometheus operator,"
  Grafana Labs blog (general ServiceMonitor/PodMonitor background).
  https://grafana.com/blog/2023/01/19/how-to-monitor-kubernetes-clusters-with-the-prometheus-operator/
- [22] "k8s-monitoring-helm/charts/k8s-monitoring/README.md," grafana/k8s-monitoring-helm
  (the heavier, ServiceMonitor/node-exporter/kube-state-metrics-bundled
  alternative, not adopted by default here).
  https://github.com/grafana/k8s-monitoring-helm/blob/main/charts/k8s-monitoring/README.md
- [23] "Install Grafana Alloy on Kubernetes," Grafana Alloy documentation
  (`helm repo add grafana https://grafana.github.io/helm-charts`; DaemonSet
  default). https://grafana.com/docs/alloy/latest/set-up/install/kubernetes/
- [24] "Monitor Kubernetes logs with Grafana Alloy," Grafana Alloy
  documentation. https://grafana.com/docs/alloy/latest/monitor/monitor-kubernetes-logs/
- [25] "Collect Kubernetes logs and forward them to Loki," Grafana Alloy
  documentation. https://grafana.com/docs/alloy/latest/collect/logs-in-kubernetes/
- [26] "otelcol.receiver.otlp," Grafana Alloy documentation.
  https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.receiver.otlp/
- [27] "otelcol.exporter.otlp," Grafana Alloy documentation.
  https://grafana.com/docs/alloy/latest/reference/components/otelcol/otelcol.exporter.otlp/
- [28] "Configure and view metrics," Ambient Mesh documentation (ztunnel
  `/stats/prometheus` on port 15020; PodMonitor not ServiceMonitor since
  ztunnel has no backing Service). https://ambientmesh.io/docs/observability/metrics/
- [29] "Istio / Prometheus," Istio documentation.
  https://istio.io/latest/docs/ops/integrations/prometheus/
- [30] "Setting up Grafana to persist in PostgreSQL with Helm," Frank Wiles
  blog (SQLite-vs-Postgres trade-off framed around horizontal scaling, not
  correctness). https://frankwiles.com/posts/grafana-postgresql-helm/
- [31] "How to change the embedded sqlite db to external sqlite or Postgres or
  mysql," grafana/helm-charts Issue #22 (confirms `grafana.ini` `[database]`
  section is the mechanism). https://github.com/grafana/helm-charts/issues/22
- [32] "charts/grafana/values.yaml," grafana-community/helm-charts (current
  chart source; `adminUser: admin` literal default, `adminPassword`
  commented out, `admin.existingSecret`/`userKey`/`passwordKey` fields).
  https://github.com/grafana-community/helm-charts/blob/main/charts/grafana/values.yaml
- [33] "charts/grafana/templates/_config.tpl," grafana-community/helm-charts
  (`grafana.secretsData` helper: falls through to `grafana.password` when
  `adminPassword` is unset). https://github.com/grafana-community/helm-charts/blob/main/charts/grafana/templates/_config.tpl
- [34] "charts/grafana/templates/_helpers.tpl," grafana-community/helm-charts
  (`grafana.password` helper: reuses an existing Secret's password if
  present, else `randAlphaNum 40 | b64enc`).
  https://github.com/grafana-community/helm-charts/blob/main/charts/grafana/templates/_helpers.tpl
- [35] "Grafana Helm Charts Are Moving on 30 Jan 2026," iits-consulting blog
  (initial migration-wave announcement summary; stated "Mimir and Loki are
  not affected" — superseded for Loki by [37], a later live docs snapshot).
  https://iits-consulting.de/blog/grafana-helm-charts-moved-what-do
- [36] "Deploy Grafana using Helm Charts," Grafana documentation (current
  live command: `helm repo add grafana-community
  https://grafana-community.github.io/helm-charts`).
  https://grafana.com/docs/grafana/latest/setup-grafana/installation/helm/
- [37] "Install Grafana Loki with Helm," Grafana Loki documentation (current
  live statement that Loki's chart is now community-maintained in
  grafana-community/helm-charts). https://grafana.com/docs/loki/latest/setup/install/helm/
- [38] "Deploy Mimir with Helm," Grafana Mimir documentation (references
  `github.com/grafana/mimir` as chart source).
  https://grafana.com/docs/mimir/latest/set-up/helm-chart/
- [39] "Install Grafana Alloy on Kubernetes," Grafana Alloy documentation
  (unmigrated; still `grafana.github.io/helm-charts`).
  https://grafana.com/docs/alloy/latest/set-up/install/kubernetes/
