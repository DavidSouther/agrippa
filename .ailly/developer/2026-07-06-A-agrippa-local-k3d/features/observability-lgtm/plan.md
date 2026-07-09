# Implementation Plan: Observability (LGTM + Alloy)

*Reviewed 2026-07-08*

> Feature-step plan (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. Transcribes the already-cleared feature
> `design.md`'s Specification into an incremental build sequence, mirroring the
> two most recently completed siblings' plan conventions
> (`networking-istio/plan.md`, `storage-postgres-valkey/plan.md`): a Step 0 that
> fixes every file path, directory layout, and object name as inert stubs, then
> one step per natural unit of wave-scoped or component-scoped work, closing
> with a full-GREEN-plus-regression-sweep step. This plan has not been built;
> per this session's own long-loop shape, a separately dispatched reviewer
> clears its draft gate next — this document does not self-clear.

**Feature test:** `tests/observability.bats`
**User story:** Given the bootstrapped `agrippa-dev` cluster (Features 1-7) with
this Observability content committed and reconciled by ArgoCD into the
`observability` layer (Loki, Tempo, Mimir, Grafana, Alloy), when an operator
requests `https://dashboard.davidsouther.com.127.0.0.1.nip.io/` through the k3d
`:443` host port-map and signs in to Grafana with the documented local dev
credentials (`admin`/`admin`), then the `observability` layer is Synced/Healthy,
an anonymous Grafana API call is challenged, the documented credential
authenticates and the home dashboard renders, and the three LGTM datasources
(`loki`, `prometheus`/Mimir, `tempo`) are provisioned — proving
authenticate-and-render with real signal sources behind it, the exact bar of
Closing Bell critical task 4.

**Steps:**
- [x] Step 0: API surface area
- [x] Step 1: Wave `-10`/`0` (part) — namespace, Loki, Tempo
- [ ] Step 2: Wave `0` (part) — Mimir
- [ ] Step 3: Wave `5` (part) — Grafana
- [ ] Step 4: Wave `5` (rest) — Alloy, the Grafana `HTTPRoute`, the gateway-cert SAN
- [ ] Step 5: Full GREEN and the regression sweep

**Libraries & Skills (carried forward from `design.md`/`research.md`; load
before each build step):**

- `developer:initialize` — carried forward per convention, but this
  feature-step exercises no residual `mise` work: it adds **no** new
  mise-managed CLI. Loki, Tempo, Mimir, Grafana, and Alloy are all in-cluster
  Kubernetes resources ArgoCD reconciles via Helm, not local tools; every CLI
  this plan's steps need (`helm`, `kubectl`, `kustomize`, `sops`, `age`, the
  Bitwarden CLI, `bats`, `curl`) is already pinned. Nothing in `mise.toml`
  changes across any step below.
- `research:public` and `research:codebase` — for the per-tool detail each
  step below explicitly defers to build time: each chart's exact current
  `repoURL`/`version` pin (the Grafana Helm chart ecosystem is mid-migration —
  `grafana`/`loki` confirmed moved to `grafana-community.github.io/helm-charts`
  at research time, `alloy` confirmed **not** moved, `tempo`/`mimir` to
  re-verify live), Grafana's exact Service port/protocol, and the exact
  in-cluster Service names/ports of Loki, Mimir, and Tempo for datasource
  provisioning and Alloy forward targets.
- No library-shipped agentic skill exists for Loki, Grafana, Tempo, Mimir,
  Alloy, Kustomize's `helmCharts:` mechanism, or ArgoCD (reconfirmed by both
  `research.md` and `design.md`). Build to `DEVELOPMENT.md` (`## Testing`,
  `## Secrets`), `ARCHITECTURE.html` (the Observability layer view),
  `ROUTING.md`, and the two completed sibling designs/plans directly —
  `networking-istio` (the shared Gateway/HTTPRoute/cert append-only-SAN
  precedent this plan's Step 4 consumes verbatim) and
  `storage-postgres-valkey` (the multi-chart-under-one-Application
  composition, the kustomize `#6058` namespace-stamp patch, and the
  `skipTests: true` helm-hook-Pod caveat this plan's Steps 1-4 each inherit).

**Patterns beat (`patterns:using-patterns` consulted):** Same conclusion as
both completed siblings, re-verified for this feature-step's own pressures
(five independently-versioned upstream charts, one authored `HTTPRoute`,
declarative Grafana datasource provisioning) rather than assumed. This
feature-step has no typed application code — only GitOps infrastructure config
(Kustomize kustomizations, `helmCharts:` inflation, one authored `HTTPRoute`
CR, declarative chart `valuesInline:`, one bats suite) — so `newtype`,
`domain-objects`, `builder`, `visibility`, `parse-dont-validate`,
`type-states`, `repository`, `aggregate`, `unit-of-work`, and
`bootstrap-and-service` all require a typed domain model that does not exist
here, and none is invoked. The Grafana datasource list and the `managed.roles`-
style append-only pattern Storage/Networking established do not recur here in
mutable form (this feature-step's own datasource list is authored once, not
appended to by later consumers), so no structural echo of those siblings'
noted pressure applies. Two patterns shape *how* the surface and its tests are
written: **`arrange-act-assert`** for the one bats `@test` (the existing
`run`/assert shape `tests/observability.bats` already follows), and
**`errors-typed-untyped`**, resolved to the untyped side — a `kubectl`/`curl`
exit code and an ArgoCD `Application`'s `sync`/`health` status are the correct,
sufficient failure signals here, consumed only by an operator's shell, `bats`,
and ArgoCD's own reconcile loop; no in-process caller needs to match distinct
typed failure modes.

## Step 0: API surface area

Fix every file path, directory layout, and object name before any has real
content, mirroring both siblings' Step 0 convention (fixed identifiers, honest
inert stubs, no logic/spec). Three changes land here, all additive to the
already-live cluster and none of which changes what ArgoCD applies:

**1. The `apps/observability.yaml` sync seam** (proactive, matching
`apps/core.yaml`'s and `apps/storage.yaml`'s identical fix for the same
SMD-mispredict symptom both prior layers hit once real content landed):

```diff
 metadata:
   name: observability
   namespace: argocd
   annotations:
     argocd.argoproj.io/sync-wave: "3"
+    argocd.argoproj.io/compare-options: ServerSideDiff=true
 spec:
   ...
   syncPolicy:
     automated:
       prune: true
       selfHeal: true
+    syncOptions:
+      - ServerSideApply=true
+      - SkipDryRunOnMissingResource=true
```

Additive only; does not touch `automated.prune`/`selfHeal`. Harmless if
unneeded — confirmed live once the `HTTPRoute` lands (Step 4's own edge case),
not assumed necessary from day one.

**2. The `.gitignore` chart-cache entry**, extending the pattern
`core`/`storage` already established (both confirmed present; `observability`
does not yet have its own line, and local `kustomize build --enable-helm`
verification runs against the five new `helmCharts:` sub-kustomizations would
otherwise pollute `git status` with a locally-pulled chart cache):

```diff
 core/overlays/dev/*/charts/
 storage/overlays/dev/*/charts/
+observability/overlays/dev/*/charts/
```

**3. The `observability/overlays/dev/` directory layout**, fixing every file
and object name the cleared `design.md` Specification already resolved
(including its reviewer-resolved Open Artifact Decisions 1-2). Each nested
kustomization gets its sync-wave fixed now via `commonAnnotations`; each
authored CR gets an apiVersion/kind/metadata-only stub (no `spec:`, mirroring
both siblings' stub convention) — except `namespace.yaml`, whose entire
content *is* `metadata.name`, so it is written in full now, exactly as
`core/overlays/dev/istio-base/namespace.yaml` and
`storage/overlays/dev/namespace.yaml` were. **The top-level
`observability/overlays/dev/kustomization.yaml` stays the existing
`resources: []`** — none of these new files are referenced yet, so
`observability` stays trivially Synced/Healthy exactly as today and nothing
new is applied to the live cluster this step:

```text
observability/overlays/dev/
├── kustomization.yaml            # UNCHANGED this step: resources: []
├── namespace.yaml                # Namespace observability (full content now; wave -10)
├── loki/
│   └── kustomization.yaml        # wave 0; helmCharts: [] (Loki lands Step 1)
├── tempo/
│   └── kustomization.yaml        # wave 0; helmCharts: [] (Tempo lands Step 1)
├── mimir/
│   └── kustomization.yaml        # wave 0; helmCharts: [] (Mimir lands Step 2)
├── grafana/
│   └── kustomization.yaml        # wave 5; helmCharts: [] (Grafana lands Step 3)
├── alloy/
│   └── kustomization.yaml        # wave 5; helmCharts: [] (Alloy lands Step 4)
└── grafana-httproute.yaml        # wave 5; HTTPRoute grafana name-only stub (spec lands Step 4)
```

Representative stubs (every chart sub-kustomization follows the identical
shape at its own wave — `loki`/`tempo` at `"0"`, `mimir` at `"0"`,
`grafana`/`alloy` at `"5"`):

```yaml
# observability/overlays/dev/namespace.yaml -- full content now (a Namespace has no spec)
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
```

```yaml
# observability/overlays/dev/loki/kustomization.yaml -- Step 0 skeleton
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: "0"
helmCharts: []   # loki chart (Monolithic mode) lands Step 1
```

```yaml
# observability/overlays/dev/grafana-httproute.yaml -- Step 0 skeleton (name-only stub, no spec)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: observability
  annotations:
    argocd.argoproj.io/sync-wave: "5"
```

This fixes: the `apps/observability.yaml` sync seam, the `.gitignore`
chart-cache entry, the directory layout, every shared-contract object name
(`observability` namespace, `loki`/`tempo`/`mimir`/`grafana`/`alloy`
`releaseName`s, `HTTPRoute` `grafana`), and the three-tier sync-wave scheme
(`-10`/`0`/`5`) as constants every remaining step reuses.
`tests/observability.bats` is a `design.md` artifact and already exists (RED
baseline: `observability` trivially Synced/Healthy on the empty placeholder,
failing from THEN 1 onward — no `observability` namespace, no Grafana
route/backend, so the shared Gateway answers every Grafana probe with 404).
Step 0 does not touch the test and does not change that RED state — the
top-level `resources:` list is unchanged, so nothing new reaches the live
cluster yet — but every name and file the remaining steps fill in now exists
and is fixed. `scripts/test-feature.sh`'s probe-suite exclusion list already
carries `observability.bats` (confirmed live this session, landed with the
feature test at design time), so Step 0 needs no change there.

**Tests**

```bash
test "the sync seam and gitignore land; observability stays Synced/Healthy on the unchanged placeholder":
  run bash -c 'grep -c "observability/overlays/dev/\*/charts/" .gitignore'
  assert output == "1"
  run kubectl --context k3d-agrippa-dev -n argocd get application observability \
    -o jsonpath='{.spec.syncPolicy.syncOptions}'
  assert output contains "ServerSideApply=true"
  run kubectl --context k3d-agrippa-dev -n argocd get application observability \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"    # unchanged -- still the empty placeholder
```

- Edge case: the `apps/observability.yaml` diff must be purely additive — verify
  `automated.prune`/`selfHeal` and `spec.source`/`destination` are untouched.
- Edge case: confirm none of the five new namespace-scoped kustomization
  directories (`loki/`, `tempo/`, `mimir/`, `grafana/`, `alloy/`) collides with
  a namespace or directory name any already-landed layer (`core`, `storage`)
  or in-flight sibling (`platform`) uses — `observability` is a new, distinct
  namespace name, so no collision is expected, but confirm live rather than
  assume.
- Edge case: re-running `mise run test:push`/`test:static` after this step
  must still pass — nothing new is fed to kubeconform/conftest yet (the five
  `kustomization.yaml` stubs have `helmCharts: []`, no `kind:` conftest would
  inspect, matching the existing `kustomization.yaml`-exclusion convention).

**Implementation Outline**

```text
apps/observability.yaml:
  metadata.annotations["argocd.argoproj.io/compare-options"] <- "ServerSideDiff=true"
  spec.syncPolicy.syncOptions <- [ServerSideApply=true, SkipDryRunOnMissingResource=true]

.gitignore:
  + observability/overlays/dev/*/charts/

observability/overlays/dev/kustomization.yaml:
  resources: []   # unchanged

observability/overlays/dev/{namespace.yaml, loki/kustomization.yaml,
  tempo/kustomization.yaml, mimir/kustomization.yaml,
  grafana/kustomization.yaml, alloy/kustomization.yaml,
  grafana-httproute.yaml}: name-only stubs, as above
```

## Step 1: Wave `-10`/`0` (part) — namespace, Loki, Tempo

**Enables:** no feature-test assertion flips yet (`observability` was already
trivially Synced/Healthy on empty `resources: []`, and stays Synced/Healthy
once real-but-unrouted content lands — THEN 1 onward still fails, nothing
serves the Grafana host). Substrate-only: this step lands the namespace every
later resource needs and the two straightforward chart-native-monolithic
signal stores, deliberately **before** the heavier, riskier Mimir (Step 2) —
isolating the design's own flagged highest-footprint risk into its own step.

Wire `namespace.yaml`, `loki/`, and `tempo/` into the top-level
`observability/overlays/dev/kustomization.yaml`'s `resources:` list — the
first real content this feature-step applies to the live cluster. Fill
`loki/kustomization.yaml`'s `helmCharts:` with the `loki` chart (`repo:`
`research:public` at build — `grafana-community.github.io/helm-charts` per
this feature-step's own cleared research, re-verify live), pinned `version:`,
`releaseName: loki`, target namespace `observability`, `valuesInline:
{deploymentMode: Monolithic, singleBinary: {replicas: 1}, loki:
{commonConfig: {replication_factor: 1}}}` plus a `local-path`
`persistence`/storage block per the chart's monolithic values shape (exact
key path confirmed live at build). Fill `tempo/kustomization.yaml`'s
`helmCharts:` with the `tempo` chart (not `tempo-distributed`; `repo:`
`research:public` at build), pinned `version:`, `releaseName: tempo`, target
namespace `observability`, `valuesInline: {storage: {trace: {backend:
local}}}` plus a `local-path` storage block for its default `-target=all`
monolithic mode.

**Tests**

```bash
test "the observability namespace, Loki (monolithic), and Tempo (monolithic) land; observability stays Synced/Healthy":
  run kubectl --context k3d-agrippa-dev -n argocd get application observability \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"
  run kubectl --context k3d-agrippa-dev get namespace observability
  assert status == 0
  run kubectl --context k3d-agrippa-dev -n observability get pods -l app.kubernetes.io/name=loki \
    -o jsonpath='{.items[0].status.phase}'
  assert output == "Running"
  run kubectl --context k3d-agrippa-dev -n observability get pods -l app.kubernetes.io/name=tempo \
    -o jsonpath='{.items[0].status.phase}'
  assert output == "Running"
  run kubectl --context k3d-agrippa-dev -n observability get pvc -l app.kubernetes.io/name=loki \
    -o jsonpath='{.items[0].spec.storageClassName}'
  assert output == "local-path"
```

- Edge case (design's flagged near-certain hit, "five times"): the kustomize
  `#6058` namespace-stamp regression may apply to either chart's inflated
  resources if their templates don't hardcode `{{ .Release.Namespace }}` —
  confirm live per chart; apply the Storage-style `patches:`
  `add /metadata/namespace` workaround, scoped to the offending
  sub-kustomization only, if resources land in `argocd` instead of
  `observability`.
- Edge case: `helm template` semantics (no hooks, no cluster `lookup`) — check
  whether either chart ships a `helm.sh/hook: test` Pod; set `skipTests: true`
  if so (Storage hit this on Valkey).
- Edge case: Loki's chunk/index PVC and Tempo's trace-storage PVC must both
  bind lazily (`WaitForFirstConsumer`) on the single k3d node without
  conflicting with each other or the already-bound Storage/Core PVCs.
- Edge case: confirm the exact pod label spelling (`app.kubernetes.io/name=loki`
  / `=tempo`) and the monolithic values key paths (chunk/index storage,
  `local-path` PVC size) against the pinned chart versions at build.

**Implementation Outline**

```text
observability/overlays/dev/kustomization.yaml:
  resources:
    - namespace.yaml
    - loki/
    - tempo/

observability/overlays/dev/loki/kustomization.yaml:
  helmCharts:
    - name: loki
      repo: <TBD; research:public at build -- grafana-community.github.io/helm-charts per research, re-verify>
      version: <pinned; research:public at build>
      releaseName: loki
      namespace: observability
      valuesInline:
        deploymentMode: Monolithic
        singleBinary: {replicas: 1}
        loki: {commonConfig: {replication_factor: 1}}
        # local-path persistence block: exact key path confirmed at build

observability/overlays/dev/tempo/kustomization.yaml:
  helmCharts:
    - name: tempo
      repo: <TBD; research:public at build>
      version: <pinned; research:public at build>
      releaseName: tempo
      namespace: observability
      valuesInline:
        storage: {trace: {backend: local}}
        # local-path storage block: exact key path confirmed at build
```

## Step 2: Wave `0` (part) — Mimir

**Enables:** no feature-test assertion flips yet, but `observability`'s
Synced/Healthy check now covers the heaviest, most component-dense workload in
the whole feature-step — the design's own named highest-footprint risk
(`mimir-distributed` at one replica per component, ~10 pods including the
bundled minio).

Wire `mimir/` into the top-level `resources:` list. Fill
`mimir/kustomization.yaml`'s `helmCharts:` with the `mimir-distributed` chart
(`repo:` `research:public` at build), pinned `version:`, `releaseName: mimir`,
target namespace `observability`, `valuesInline:` driving every component's
replica count to `1` (ingester, querier, query-scheduler, distributor,
query-frontend, store-gateway, compactor, ruler, alertmanager,
overrides-exporter) and each stateful component's PVC onto `local-path` —
keeping the chart's bundled minio (chart default) for blocks storage rather
than hand-configuring a filesystem backend, per the design's
operator-over-hand-rolled convention.

**Tests**

```bash
test "mimir-distributed reconciles at replicas:1 per component; observability stays Synced/Healthy":
  run kubectl --context k3d-agrippa-dev -n argocd get application observability \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"
  run kubectl --context k3d-agrippa-dev -n observability get pods -l app.kubernetes.io/name=mimir --no-headers
  assert output does not contain "CrashLoopBackOff|Pending|Error"
  run bash -c "kubectl --context k3d-agrippa-dev -n observability get pods -l app.kubernetes.io/name=mimir --no-headers | wc -l"
  assert output is roughly 10   # one per component + bundled minio, per design's estimate
```

- Edge case (design's own flagged risk): Mimir's ~10-pod first reconcile is
  the slowest of the whole feature-step — expect real wait time here, and
  confirm the feature test's own `wait_for_observability_synced_healthy`
  window (allows ~5 min, matching `storage.bats`) covers it in practice, not
  just on paper.
- Edge case: several `mimir-distributed` defaults (e.g. the ingester
  replication factor, quorum-sized read paths) are tuned for a multi-replica
  ratio, none of which the reduced-replica default zeroes out incorrectly on
  its own — confirm no component needs an explicit override the chart's
  `replicas: 1` alone doesn't cover.
- Edge case: the kustomize `#6058` namespace-stamp patch and `skipTests: true`
  caveats from Step 1 apply identically here — confirm live per this chart's
  own templates.
- Edge case: the bundled minio sub-chart's PVC must also land on `local-path`
  — confirm it is not silently defaulted to `emptyDir` or a different
  storage class.

**Implementation Outline**

```text
observability/overlays/dev/kustomization.yaml:
  resources:
    - namespace.yaml
    - loki/
    - tempo/
    - mimir/

observability/overlays/dev/mimir/kustomization.yaml:
  helmCharts:
    - name: mimir-distributed
      repo: <TBD; research:public at build>
      version: <pinned; research:public at build>
      releaseName: mimir
      namespace: observability
      valuesInline:
        # every component driven to replicas: 1; each stateful component's
        # PVC on local-path; bundled minio kept at chart default.
        # Exact per-component value keys confirmed against the pinned
        # chart's values.yaml at build (ingester, querier, query-scheduler,
        # distributor, query-frontend, store-gateway, compactor, ruler,
        # alertmanager, overrides-exporter, minio).
```

## Step 3: Wave `5` (part) — Grafana

**Enables:** no externally-reachable feature-test assertion yet (no
`HTTPRoute` exists until Step 4), but this step lands the single most
easily-missed value in the whole feature-step (design's own words) — the
explicit `admin`/`admin` dev credential — plus the datasource provisioning the
final feature-test assertion (THEN 3) keys on, and is independently
verifiable in-cluster before the Gateway wiring lands.

Wire `grafana/` into the top-level `resources:` list. Fill
`grafana/kustomization.yaml`'s `helmCharts:` with the `grafana` chart (`repo:`
`research:public` at build — `grafana-community.github.io/helm-charts` per
this feature-step's own cleared research), pinned `version:`,
`releaseName: grafana`, target namespace `observability`, `valuesInline:`
carrying **explicitly** `adminUser: admin` / `adminPassword: admin` (the
chart's own unset default generates a random 40-char password — the
deliberate, contract-driven exception to the sops-sealing discipline, per
`design.md`), `persistence: {enabled: true, storageClassName: local-path}`,
and a `datasources` block provisioning three datasources — `loki` (`type:
loki`), `prometheus`/Mimir (`type: prometheus`, `/prometheus` API prefix), and
`tempo` (`type: tempo`) — each pointed at its store's in-cluster Service
(exact Service names/ports confirmed live at build against the charts pinned
in Steps 1-2), via the chart's native `datasources.yaml` sidecar/ConfigMap
provisioning mechanism (`datasources: {datasources.yaml: {apiVersion: 1,
datasources: [...]}}`) — the standard chart-native path, not a hand-rolled
ConfigMap.

**Tests**

```bash
test "Grafana is Running with SQLite persistence on local-path; the documented admin/admin credential and the three datasources work in-cluster":
  run kubectl --context k3d-agrippa-dev -n observability get pods -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].status.phase}'
  assert output == "Running"
  run kubectl --context k3d-agrippa-dev -n observability get pvc -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].spec.storageClassName}'
  assert output == "local-path"
  run bash -c '
    kubectl --context k3d-agrippa-dev -n observability port-forward svc/grafana 3000:3000 &
    pf=$!; sleep 2
    code=$(curl -s -u admin:admin -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/api/dashboards/home)
    body=$(curl -s -u admin:admin http://127.0.0.1:3000/api/datasources)
    kill $pf
    echo "$code"; echo "$body"
  '
  assert first line == "200"
  assert body contains '"type":"loki"' and '"type":"prometheus"' and '"type":"tempo"'
```

- Edge case (the design's flagged single most easily-missed value): verify the
  literal `admin`/`admin` credential actually round-trips into the running
  instance (some chart versions read admin creds from a Secret the chart
  itself creates from `adminUser`/`adminPassword`, not straight from
  `valuesInline`) — a mismatch here silently regenerates the random-password
  failure mode `design.md` names.
- Edge case: confirm the chart's datasource-provisioning mechanism doesn't
  additionally require `sidecar.datasources.enabled: true` in some chart
  versions — verify against the pinned chart's own values/docs at build.
- Edge case: confirm Grafana's chart Service name/port (`grafana`:`3000`)
  matches what Step 4's `HTTPRoute` `backendRefs` and this step's own
  datasource URLs assume.
- Edge case: the Loki/Mimir/Tempo Service names used in the datasource URLs
  are `releaseName`-derived (`loki`, `mimir-nginx`-or-equivalent gateway
  Service, `tempo`) — confirm exact spellings against the pinned charts from
  Steps 1-2, the same caveat Storage hit for CNPG/Valkey Service names.
- Edge case: Grafana tolerates an unreachable datasource at startup and
  retries (`design.md`'s own Failure-modes note) — this step's datasource
  check exercises provisioning against already-Healthy stores from Steps 1-2,
  so it should not need to account for datasource warm-up timing here.

**Implementation Outline**

```text
observability/overlays/dev/kustomization.yaml:
  resources:
    - namespace.yaml
    - loki/
    - tempo/
    - mimir/
    - grafana/

observability/overlays/dev/grafana/kustomization.yaml:
  helmCharts:
    - name: grafana
      repo: <TBD; research:public at build -- grafana-community.github.io/helm-charts per research, re-verify>
      version: <pinned; research:public at build>
      releaseName: grafana
      namespace: observability
      valuesInline:
        adminUser: admin
        adminPassword: admin
        persistence: {enabled: true, storageClassName: local-path}
        datasources:
          datasources.yaml:
            apiVersion: 1
            datasources:
              - {name: Loki, type: loki, access: proxy, url: "http://<loki svc; confirmed at build>:3100"}
              - {name: Mimir, type: prometheus, access: proxy, url: "http://<mimir gateway svc; confirmed at build>/prometheus"}
              - {name: Tempo, type: tempo, access: proxy, url: "http://<tempo svc; confirmed at build>:3100"}
```

## Step 4: Wave `5` (rest) — Alloy, the Grafana `HTTPRoute`, the gateway-cert SAN

**Enables:** WHEN + THEN 1 (anonymous `/api/dashboards/home` → 401) and THEN 2
(`admin`/`admin` → 200) — the two assertions that exercise the request path
for the first time — and, since Steps 1-3 already landed the stores and
Grafana's datasource provisioning, THEN 3 (`/api/datasources` → 200
enumerating `loki`/`prometheus`/`tempo`) as well. This is the step where
`tests/observability.bats` is expected to go fully GREEN for the first time,
pending build-time verification.

Wire `alloy/` and `grafana-httproute.yaml` into the top-level `resources:`
list. Fill `alloy/kustomization.yaml`'s `helmCharts:` with the `alloy` chart
(`repo: https://grafana.github.io/helm-charts` — confirmed **not** moved by
this feature-step's own cleared research; re-verify live at build regardless,
the ecosystem is mid-migration), pinned `version:`, `releaseName: alloy`,
target namespace `observability`, `valuesInline:` configuring the chart's
default DaemonSet controller with three self-discovery pipelines in Alloy's
River/Flow config: metrics (`discovery.kubernetes` → `prometheus.scrape` →
`prometheus.remote_write` to Mimir's push endpoint), logs
(`discovery.kubernetes` → `loki.source.kubernetes` → `loki.write` to Loki's
push endpoint), and traces (`otelcol.receiver.otlp` gRPC/HTTP →
`otelcol.exporter.otlp` to Tempo's OTLP ingest) — no Prometheus Operator CRDs.
Fill `grafana-httproute.yaml`'s spec: `parentRefs: [{name: agrippa-gateway,
namespace: istio-ingress, sectionName: https}]`, `hostnames:
[dashboard.davidsouther.com.127.0.0.1.nip.io]`, an **explicitly authored**
`rules[].matches` PathPrefix `/` (the omitted-`matches` SMD-diff caveat the
Networking step found and fixed the identical way), `backendRefs:
[{name: grafana, port: 3000}]` — no `DestinationRule`, since Grafana serves
plain HTTP (confirmed at build against the pinned chart's `service.yaml`
default). Append one `dnsNames` entry,
`dashboard.davidsouther.com.127.0.0.1.nip.io`, to the shared, append-only
`core/overlays/dev/gateway-cert.yaml`'s `agrippa-gateway-tls` Certificate — a
`core`-owned file, the exact one-line append-only seam the Networking
feature-step's plan already established and used itself.

**Tests**

```bash
test "the grafana HTTPRoute, the gateway-cert SAN, and the Alloy DaemonSet land; the feature test's Grafana probes pass through the Gateway":
  run kubectl --context k3d-agrippa-dev -n observability get httproute grafana \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
  assert output == "True"
  run bash -c "kubectl --context k3d-agrippa-dev -n istio-ingress get secret agrippa-gateway-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text"
  assert output contains "dashboard.davidsouther.com.127.0.0.1.nip.io"
  run kubectl --context k3d-agrippa-dev -n observability get daemonset alloy \
    -o jsonpath='{.status.numberReady}'
  assert output == desired count (all nodes)
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    https://dashboard.davidsouther.com.127.0.0.1.nip.io/api/dashboards/home
  assert output == "401"    # THEN 1
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -u admin:admin https://dashboard.davidsouther.com.127.0.0.1.nip.io/api/dashboards/home
  assert output == "200"    # THEN 2
```

- Edge case: `agrippa-gateway-tls`'s `dnsNames` must include exactly
  `dashboard.davidsouther.com.127.0.0.1.nip.io` (matching the `HTTPRoute`'s
  `hostnames` and the feature test's `DASHBOARD_HOST`) or SNI-based cert
  selection fails even with an Accepted `HTTPRoute` — the same caveat
  Networking's own plan flagged for its own single-hostname append.
  `core/overlays/dev/gateway-cert.yaml`'s `dnsNames` **is** a shared,
  append-only list all three concurrently-planning `platform`-layer siblings
  also write to (Keycloak `auth.`, Forgejo, and Flagsmith `flagsmith.` each
  append their own host — verified live in their own plans' Step 4/Step 3).
  The append-only-SAN pattern is exactly the coordination mechanism, not an
  absence of one: re-inspect the file's live committed content immediately
  before editing and append **only** this feature's own
  `dashboard.davidsouther.com.127.0.0.1.nip.io` entry, never replacing the
  list — a last-writer-wins overwrite would silently drop a sibling's already
  landed SAN and break SNI/TLS for that host. cert-manager re-issues
  `agrippa-gateway-tls` on the `dnsNames` change through the already-landed
  `core` Application (an async cross-layer reconcile the build tolerates via
  poll/retry, not assumed instantaneous with the commit), the same treatment
  the sibling plans give this shared edit.
- Edge case: confirm whether `apps/observability.yaml` actually needs
  `compare-options: ServerSideDiff=true` (added proactively in Step 0) now
  that a real Gateway-API-defaulted `HTTPRoute` exists — this is the exact
  symptom both `core` (Gateway/HTTPRoute) and `storage` (CNPG `Cluster`) hit
  once their own CRD-adjacent objects landed; harmless if unneeded, already in
  place if needed.
- Edge case: Alloy's DaemonSet must schedule on the single k3d node without a
  hostPath/hostNetwork/port conflict against the other DaemonSets already
  running there (`ztunnel`, `istio-cni-node`) — confirm live.
- Edge case: the feature test's THEN 3 (datasource enumeration) checks
  provisioning, not live query success (per `design.md`'s own Failure-modes
  note) — Alloy landing in this same step is not required for THEN 3 to pass
  (Grafana's datasources were already provisioned in Step 3 against
  already-Healthy stores), so a slow or not-yet-flowing Alloy pipeline should
  not block this step's own test from passing.
- Edge case: no workload in this cluster emits OTLP traces yet, so Tempo's
  ingest path stays empty even once wired — expected and not a failure signal;
  the feature test does not assert live trace volume.

**Implementation Outline**

```text
observability/overlays/dev/kustomization.yaml:
  resources:
    - namespace.yaml
    - loki/
    - tempo/
    - mimir/
    - grafana/
    - alloy/
    - grafana-httproute.yaml

observability/overlays/dev/alloy/kustomization.yaml:
  helmCharts:
    - name: alloy
      repo: https://grafana.github.io/helm-charts   # confirmed not moved; re-verify at build
      version: <pinned; research:public at build>
      releaseName: alloy
      namespace: observability
      valuesInline:
        alloy:
          configMap:
            content: |
              discovery.kubernetes "pods" { role = "pod" }

              prometheus.scrape "cluster" {
                targets    = discovery.kubernetes.pods.targets
                forward_to = [prometheus.remote_write.mimir.receiver]
              }
              prometheus.remote_write "mimir" {
                endpoint { url = "http://<mimir push svc; confirmed at build>/api/v1/push" }
              }

              loki.source.kubernetes "pods" {
                targets    = discovery.kubernetes.pods.targets
                forward_to = [loki.write.loki.receiver]
              }
              loki.write "loki" {
                endpoint { url = "http://<loki svc; confirmed at build>:3100/loki/api/v1/push" }
              }

              otelcol.receiver.otlp "default" {
                grpc {}
                http {}
                output { traces = [otelcol.exporter.otlp.tempo.input] }
              }
              otelcol.exporter.otlp "tempo" {
                client { endpoint = "<tempo svc; confirmed at build>:4317" }
              }

observability/overlays/dev/grafana-httproute.yaml (filled):
  HTTPRoute grafana (ns observability):
    parentRefs: [{name: agrippa-gateway, namespace: istio-ingress, sectionName: https}]
    hostnames: [dashboard.davidsouther.com.127.0.0.1.nip.io]
    rules: [{matches: [{path: {type: PathPrefix, value: "/"}}], backendRefs: [{name: grafana, port: 3000}]}]

core/overlays/dev/gateway-cert.yaml:
  spec.dnsNames: [ ...whatever is live committed..., dashboard.davidsouther.com.127.0.0.1.nip.io ]
  # APPEND ONLY this feature's own host onto the live list -- never replace.
  # Shared with the Keycloak/Forgejo/Flagsmith siblings, each appending their
  # own SAN; the live list may already read e.g.
  # [argocd, auth., <forgejo host>, flagsmith.] before this append.
```

## Step 5: Full GREEN and the regression sweep

**Enables:** no new substrate — the request path already works after Step 4 —
but this step closes the two remaining items `design.md`'s Metrics names as
measures of done: the feature test passing end-to-end against the fully
reconciled layer, and no regression to earlier harness.

Run `bats tests/observability.bats` against the fully reconciled
`observability` layer. If build-time verification (Steps 1-4's own recorded
edge cases) found any chart's pod-label spelling, Service name/port, or
datasource `type` string diverges from what the test or this plan's own
sketches assumed, correct the affected manifest or (only if the test itself
was wrong, not the manifest) the test's own assertions here — a
test-definition correction inherited from build-time re-verification, not new
test authorship, mirroring both completed siblings' own final step. Then
re-run the full harness `design.md`'s Metrics section names as no-regression
evidence.

**Tests**

```bash
test "tests/observability.bats passes end-to-end":
  run bats tests/observability.bats
  assert status == 0

test "no regression to earlier harness":
  run mise run test:push
  assert status == 0
  run mise run test:feature
  assert status == 0
  run bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats tests/storage.bats
  assert status == 0
```

- Edge case: `scripts/test-feature.sh` already excludes `observability.bats`
  from its throwaway-cluster auto-discovery loop (confirmed live this
  session, landed with the feature test at design time) — this step only
  needs to confirm that exclusion still holds, not add it.
- Edge case: re-running `bats tests/observability.bats` a second time
  back-to-back must not error or disrupt the long-lived `observability` layer
  — ArgoCD's `selfHeal` should leave an already-Synced/Healthy state alone,
  matching every sibling suite's own idempotency expectation.
- Edge case: `mise run test:static`'s kubeconform/conftest pass does not walk
  `observability/` (only `apps/`, `charts/*/rendered/`, and `secrets/`) — do
  not assume `test:push` exercises any of Steps 1-4's new chart YAML; ArgoCD's
  own live reconcile and this bats suite are the only validators of that
  content, exactly as Networking's and Storage's own final steps recorded for
  `core/` and `storage/`.
- Edge case: the regression list intentionally omits the three
  concurrently-in-flight `platform`-layer sibling suites (`git-hosting.bats`,
  `auth.bats`, `feature-flags.bats`) — they are being planned in parallel
  right now and may not be landed yet; re-check `scripts/test-feature.sh`'s
  own exclusion list at build time and extend this sweep only if those
  suites are already green and stable by then.

**Implementation Outline**

```text
# no new manifests; this step is verification-only plus any build-time-discovered
# corrections to observability/overlays/dev/**/kustomization.yaml's chart values
# or tests/observability.bats' own assumptions, surfaced by actually running the
# suite against the live reconciled cluster
run bats tests/observability.bats
run mise run test:push && mise run test:feature
run bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats tests/storage.bats
```

## Resolved by the long-loop reviewer (2026-07-08)

The plan-gate reviewer read this artifact cold, checked its transcription
fidelity against the cleared `design.md`, verified every repo-state and
live-cluster claim, sanity-checked the five-chart step ordering, and re-verified
the chart-repo migration live. One transcription defect was found and corrected
in place (item 5); all other claims held. No item escalated. Recorded here as one
audit trail, per the long-loop recording contract.

**1. Transcription fidelity against the cleared `design.md`. Decided: faithful,
with one corrected exception (item 5).** The plan transcribes the design's
composition (five charts, one `observability` Application), the `-10`/`0`/`5`
sync-wave scheme, every deployment mode (Loki monolithic, `tempo` chart local
backend, `mimir-distributed` at `replicas: 1`, Grafana SQLite + `local-path`,
Alloy DaemonSet with three self-discovery pipelines), the explicit
`admin`/`admin` credential, the three `loki`/`prometheus`/`tempo` datasources,
the single `grafana` `HTTPRoute` (explicit `matches` PathPrefix `/`, no
`DestinationRule`), the one appended cert SAN, and the proactive
`apps/observability.yaml` seam — all one-to-one with the design. Conservative
default: no change needed beyond item 5.

**2. Repo-state claims. Decided: all verified true, live.** `apps/observability.yaml`
carries no seam yet (no `syncOptions`, no `compare-options` annotation; live app
returns an empty `syncOptions`). `observability/overlays/dev/` holds only the
`resources: []` placeholder `kustomization.yaml` — no `loki/`/`tempo/`/`mimir/`/
`grafana/`/`alloy/` sub-dirs, no `namespace.yaml`, no `grafana-httproute.yaml` —
the true Step-0 state. `.gitignore` carries `core/overlays/dev/*/charts/` and
`storage/overlays/dev/*/charts/` but **not** an `observability/` line, so Step 0's
claim and its `+observability/overlays/dev/*/charts/` fix are both correct.
`scripts/test-feature.sh` already excludes `observability.bats` (present in the
probe-suite `case` list). `core/overlays/dev/gateway-cert.yaml`'s current
`dnsNames` is exactly `[argocd.127.0.0.1.nip.io]`. Live cluster confirms the
`observability` Application is `Synced Healthy` on the empty placeholder and the
`observability` namespace does not exist.

**3. Five-chart step ordering (Loki+Tempo → Mimir → Grafana → Alloy+HTTPRoute+
cert-SAN → full green). Decided: sound, no hidden cross-chart ordering risk.**
Grafana's Step-3 datasource provisioning references the Loki/Tempo/Mimir Services,
which land in Steps 1-2 — satisfied three independent ways: (a) build-step
ordering commits the stores before Grafana, so at Step 3 they are already
reconciled; (b) runtime sync-wave ordering places the stores at wave `0` (ArgoCD
waits each wave Healthy) before Grafana at wave `5`, so the stores are actually
Healthy, not merely resolvable, by the time Grafana provisions; (c) datasource
provisioning is declarative config writing to Grafana's store with **no**
connectivity or DNS lookup at provision time, and the design's own Failure-modes
note confirms Grafana tolerates an unreachable datasource at startup and retries.
The datasource-enumeration assertion checks provisioning (objects exist), not live
query success, so store warm-up cannot regress it. The wave-5 `HTTPRoute` →
`grafana:3000` backend and the wave-5 Alloy → wave-0 store push endpoints are both
dynamically/eventually resolved (Istio backend resolution; Alloy WAL/retry), not
hard sync-blocking. No analogue of the "Database CR before the app" class exists
here.

**4. Chart-repo migration re-check (`research:public`, live today). Decided: all
three load-bearing claims still accurate.** `grafana` **moved** to
`grafana-community.github.io/helm-charts` (chart `12.7.2`, released 2026-07-01,
the sole general-purpose chart in that index) — general-purpose charts migrated
2026-01-30. `loki` **moved** to `grafana-community.github.io/helm-charts` (forked
2026-03-16; OSS users use the community repo). `alloy` has **not** moved — still
`grafana.github.io/helm-charts` (chart `1.10.0`, active 2026 releases, no
deprecation). The plan pins `grafana`/`loki` to grafana-community with a
"re-verify live" note and `alloy` to `grafana.github.io/helm-charts` with
"confirmed not moved; re-verify at build" — all correct. `tempo`/`mimir` remain
plan-deferred to build (the 2026-01-30 announcement lists `tempo` among the
migrated general-purpose charts, so `tempo` most likely also reads
`grafana-community`; `mimir-distributed`'s index was not resolvable in this pass);
the plan correctly defers both to live build-time verification.

**5. Step 4's `core/overlays/dev/gateway-cert.yaml` "not shared with siblings"
claim. Decided: corrected in place — the file IS a shared, append-only list all
three platform siblings write to.** As authored, Step 4's edge case asserted
`gateway-cert.yaml` "is **not** a file any of the three concurrently-planning
`platform`-layer siblings touch, so no coordination is needed," and the Step 4
Implementation Outline showed the result as a literal two-entry
`[argocd, dashboard]` list. Both are wrong: `auth-keycloak/plan.md` (Step 4),
`git-hosting-forgejo/plan.md` (Step 3), and `feature-flags-flagsmith/plan.md`
(Step 4) each **append their own hostname SAN** to that exact file's `dnsNames`,
and each explicitly guards it as a shared, concurrently-contended append-only
list. The plan author transplanted the design's *true* claim about
`apps/observability.yaml` (genuinely unshared — observability has its own apps
file while the platform trio share `apps/platform.yaml`) onto the wrong file. The
`design.md` itself does not make this error: it calls the cert "the **shared**
`agrippa-gateway-tls` Certificate" and "a one-line, **append-only** edit." Left
uncorrected, a builder trusting the "no coordination needed" rationale and the
two-entry outline could overwrite the list, silently dropping the auth/forgejo/
flagsmith SANs and breaking SNI/TLS for those hosts. Corrected the Step 4 edge
case and Implementation Outline to state the append-only-SAN pattern is the
coordination mechanism (re-inspect live, append only the `dashboard.` host, never
replace) and to note the async cross-layer cert re-issue, matching all three
siblings' own treatment. Conservative default, not an escalation: reversible
(doc-only correction), in recorded scope (this feature's own plan), and
determined by an existing project convention (the append-only-SAN seam Networking
established and Storage's `managed.roles[]` mirrors). The append action the plan's
prose already prescribed is unchanged; only the false rationale and the
replace-flavored outline were fixed.
