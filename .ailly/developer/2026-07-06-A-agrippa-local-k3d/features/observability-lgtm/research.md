# Feature Research: Observability (LGTM + Alloy)

*Reviewed 2026-07-08*

## Topic and Intent

> Feature 8: **Observability (LGTM + Alloy)**. [...] Research the standard way
> to run the Grafana LGTM stack (Loki, Grafana, Tempo, Mimir) + Grafana Alloy on
> Kubernetes for local dev at reduced scale (a combined `grafana/loki`+
> `grafana/mimir`+`grafana/tempo`+`grafana/grafana`+`grafana/alloy` multi-chart
> composition, vs. Grafana's own "LGTM" or "Grafana Cloud Stack" all-in-one
> distribution chart if one exists and fits single-instance dev use, vs.
> individual charts), what minimal reduced-replica/single-binary-mode config
> each component needs for a k3d dev cluster (Loki/Mimir/Tempo all support a
> "monolithic"/single-binary deployment mode, much lighter than their
> microservices mode — very likely the right choice here), how Alloy should be
> configured to scrape/collect from the cluster (metrics via ServiceMonitor-style
> discovery or static scrape configs — check if the Prometheus Operator CRDs are
> assumed or if Alloy can self-discover without them) and forward to
> Mimir/Loki/Tempo, and whether Grafana needs external Postgres or can use
> SQLite for a single-dev-instance deployment. Produce the research draft per
> `research.md`'s own format.

The loosely-stated goal, in the coordinator's own framing: this is the seventh
of the project's eight feature-steps, and the fourth of the four-way parallel
band (Auth, Git hosting, Feature flags, Observability) that all depend on the
now-landed Storage feature-step and integrate against the now-landed Networking
feature-step's Gateway contract. Its own direct target is Closing Bell critical
task 4 — "Grafana at the dashboard dev host authenticates with the documented
local dev credentials and renders a dashboard" — so the research question is
narrowly practical: what is the standard, minimal, GitOps-composable way to
stand up Loki+Grafana+Tempo+Mimir+Alloy at reduced scale on a single k3d node,
reusing (not re-inventing) the storage-class and Gateway/HTTPRoute/hostname/TLS
contracts the two already-landed feature-steps established.

## Search/Expand

The general-lens expand pass (full findings and citations in
`research/public.md`) surfaced five load-bearing facts about the public state
of the Grafana observability ecosystem as of this research date:

1. **No official, current, all-in-one "LGTM" chart exists to adopt wholesale.**
   `lgtm-distributed` is deprecated; a standing feature request for a real
   preconfigured all-in-one chart (`grafana/helm-charts` #1397) remains open and
   unaddressed. The individual-chart composition the task brief already
   anticipated is the correct default, not a fallback.
2. **Loki, Tempo, and Mimir do not offer symmetric "monolithic mode" support.**
   Loki's official chart exposes monolithic mode as a first-class values toggle
   (`deploymentMode: Monolithic`). Tempo's monolithic mode is a **separate
   chart** (`tempo`, distinct from `tempo-distributed`) whose local-disk
   storage backend is documented as monolithic-only. Mimir has **no** official
   monolithic Helm chart at all — the binary supports `-target=all`, but
   `mimir-distributed` is microservices-only, and a three-year-old feature
   request for monolithic Helm support is still open. This asymmetry is the
   single biggest surprise the expand pass found relative to the task brief's
   framing ("Loki/Mimir/Tempo all support a monolithic/single-binary
   deployment mode" is two-thirds true, not uniformly true).
3. **Alloy needs no Prometheus Operator CRDs.** `discovery.kubernetes` talks to
   the Kubernetes API directly (pod/service/endpoints/node roles); ServiceMonitor/
   PodMonitor consumption is optional, additive behavior on top of that, not a
   prerequisite. Combined with the codebase finding that no Prometheus Operator
   CRDs exist anywhere in this cluster today, self-discovery is the only path
   that doesn't add unbudgeted cluster-level scope.
4. **The SQLite-vs-Postgres choice for Grafana is a scaling question, not a
   correctness question.** Every source frames it the same way: SQLite is fully
   supported and "robust enough for most use cases"; Postgres becomes necessary
   only once Grafana is scaled beyond one replica (SQLite is embedded per-pod).
   This project's own Specification calls for reduced replicas, so the scaling
   trigger for Postgres does not fire here.
5. **The Grafana Helm chart ecosystem is mid-reorganization right now.** Grafana
   Labs began moving charts out of the shared `grafana/helm-charts` repo on
   2026-01-30; live-checking each chart's current docs page this session found
   `grafana` and `loki` already moved to `grafana-community/helm-charts`, while
   `alloy` has not moved. This is a moving target, not a fact this research
   should freeze into a pinned table.

## Libraries & Skills

Per the parent `design.md` (§ Libraries & Skills) and `plan.md`, carried
forward and reconfirmed by this feature-step's own research: **no
library-shipped agentic skill exists for Loki, Grafana, Tempo, Mimir, Alloy,
Kustomize's `helmCharts:` mechanism, or ArgoCD** — this research's own expand
pass checked specifically (no `SKILL.md`, no MCP server, no published agentic
skill turned up anywhere in the public search results or the chart
repositories themselves) and found nothing to add to the parent's
already-recorded finding.

**Before doing any work in this feature, load these skills via the active
harness's skill-loading mechanism:**

- **`developer:initialize`** — for any tool/mise gap this feature-step's own
  build surfaces (none anticipated; `helm`, `kubectl`, `kustomize`, `sops`,
  `age`, `bitwarden` are already pinned).
- **`research:public`** and **`research:codebase`** — this feature-step's own
  design phase will still need targeted follow-up lookups (exact chart
  versions/repo URLs at the moment of authoring, exact Grafana Service
  port/protocol, exact Mimir/Loki/Tempo Service names for datasource
  provisioning) that this research phase deliberately deferred to build time.
- **`developer:ailly` project-shape references** (`shapes/project/project-cycle.md`,
  `closing-bell.md`, `release-flags.md`) — this feature-step's own design/plan/
  build still operate inside the parent Project Shape.

The authoritative in-repo contracts stand in for a component skill exactly as
the parent design already decided: `DEVELOPMENT.md` (`## Testing`, `## Secrets`),
`ARCHITECTURE.html` (Observability layer view), `ROUTING.md`, and this
feature-step's own two sibling research notes (`research/public.md`,
`research/codebase.md`) — build to those, not to a from-scratch reinvention.

## Falsification/Refine

**Size.** A single feature-step, already fixed by the parent plan (Feature 8)
— this research does not re-litigate that sizing, only confirms nothing
uncovered during expand argues for splitting or merging it. Nothing did: the
five components (Loki, Grafana, Tempo, Mimir, Alloy) are one cohesive delivery
(Closing Bell task 4 needs all of them working together — Grafana rendering a
dashboard implies at least one upstream datasource has real data flowing
through Alloy), and none of them individually justifies its own feature-step
at this project's altitude.

**Off-the-shelf fit.** Partially. Four of the five components (Loki, Grafana,
Tempo's monolithic chart, Alloy) have official, well-maintained, chart-native
support for exactly this reduced-scale shape — genuinely off-the-shelf.
Mimir is the one component without an off-the-shelf single-binary Helm
answer; the choice between "stay on the official chart with every component's
replica count set to 1" (more pods, fully supported) and "hand-author a
minimal monolithic Mimir manifest" (fewer pods, off-chart) is real, load-
bearing, and correctly left to the design phase rather than pre-decided here
— falsifying an initial assumption (from the task brief) that all three
signal stores would have symmetric, equally off-the-shelf monolithic options.

**Should another team collaborate?** No — this mirrors the already-settled
project-wide answer (single operator, one repo, no cross-team coordination
needed for any feature-step).

**Smallest version that still meets the intent.** Loki: `deploymentMode:
Monolithic`, `singleBinary.replicas: 1`. Tempo: the `tempo` chart (not
`tempo-distributed`), default `-target=all`, `storage.trace.backend: local`.
Mimir: reduced-replica `mimir-distributed` (replicas: 1 per component) as the
conservative default, with the hand-authored monolithic alternative recorded
as an available lighter-weight option for the design phase to pick instead.
Grafana: embedded SQLite, `persistence.enabled: true` on `local-path`, no
Postgres. Alloy: one DaemonSet (chart default), three self-discovery pipelines
(metrics via `discovery.kubernetes`+`prometheus.scrape`+`prometheus.remote_write`;
logs via `discovery.kubernetes`+`loki.source.kubernetes`+`loki.write`; traces
via `otelcol.receiver.otlp`+`otelcol.exporter.otlp`), no Prometheus Operator
CRDs installed. One `HTTPRoute` (Grafana only — Loki/Tempo/Mimir/Alloy have no
end-user UI and need no ingress) appended to the already-shared Gateway, one
hostname appended to the already-shared Certificate's SAN list. This is the
smallest version that still lets an operator sign in to Grafana at a real dev
hostname and see a real dashboard with real data behind it — the exact shape
Closing Bell task 4 asks for, nothing broader.

## Scope

**In scope for this feature-step's design phase:**

- Chart selection and composition (`loki`, `grafana`, `tempo`, `mimir-distributed`
  or a hand-authored Mimir manifest, `alloy`) under a Kustomize `helmCharts:`
  block in `observability/overlays/dev/`, matching the storage/networking
  feature-steps' own established composition pattern.
- Deployment-mode values for each component (monolithic where chart-native;
  the reduced-replica-vs-hand-rolled decision for Mimir specifically).
- Alloy's three collection pipelines (metrics/logs/traces) and their
  forward-to targets.
- Grafana's persistence (SQLite + `local-path` PVC), admin credential
  (dev: literal `admin`/`admin`; prod: preserved seam via `admin.existingSecret`,
  not built), and datasource provisioning against Loki/Mimir/Tempo.
- The `observability` namespace, one `HTTPRoute` for Grafana, the one-line
  append to the shared `agrippa-gateway-tls` Certificate's `dnsNames`, and the
  dev hostname `dashboard.davidsouther.com.127.0.0.1.nip.io`.
- `apps/observability.yaml`'s `syncOptions`/`compare-options` — anticipate the
  same `ServerSideDiff=true` fix the storage and core layers both needed, and
  confirm live at build time rather than pre-applying speculatively.
- Per-component SLOs (Prometheus/Mimir queries, Grafana alert thresholds) per
  `DEVELOPMENT.md`'s `## Testing` § SLOs and the parent plan's own note that
  these belong in this feature-step's own design.

**Out of scope (deferred, seams preserved, not built):**

- Rook-Ceph object storage for Loki/Mimir/Tempo (parent design already defers
  this explicitly; `local-path` block volumes are the dev substrate throughout).
- Any multi-replica/HA shape for Loki, Mimir, Tempo, or Grafana (the parent
  Specification calls for reduced replicas; HA is a production-cycle concern).
- External Postgres for Grafana (the SQLite finding above defers this to a
  later cycle if Grafana is ever scaled beyond one replica — the storage
  feature-step's consumption contract is ready and unchanged if that day
  comes).
- Installing the Prometheus Operator / `kube-prometheus-stack` for
  ServiceMonitor/PodMonitor discovery (not needed; would be new, unbudgeted
  cluster-level scope).
- Scraping Istio ambient's ztunnel telemetry (`/stats/prometheus` on port
  15020) — available, low-effort, but not required by Closing Bell task 4 or
  named in the parent Specification; left as an explicit follow-on for the
  design phase to accept or decline, not silently folded in.
- Freezing exact chart `repoURL`/version pins in this document — the Grafana
  Helm chart ecosystem is actively reorganizing (see Search/Expand finding 5);
  the design/build phases re-verify live, the same "defer exact version pins
  to build time" pattern the storage feature-step's own research already used.

## Resolved Decisions

**Resolved by this research:**

1. **Chart composition.** Individual official charts (`loki`, `grafana`,
   `tempo`, `mimir-distributed`, `alloy`), not an all-in-one distribution —
   none fits or is maintained. Matches the task brief's own primary hypothesis.
2. **Loki deployment mode.** `deploymentMode: Monolithic`,
   `singleBinary.replicas: 1`, `commonConfig.replication_factor: 1`. Chart-native,
   no caveats found.
3. **Tempo deployment mode and chart.** The `tempo` chart (not
   `tempo-distributed`), default monolithic `-target=all`,
   `storage.trace.backend: local`. Chart-native; the one open community issue
   found (#3096) concerns a different target (`scalable-single-binary`), not
   this one.
4. **Alloy collection mechanism.** `discovery.kubernetes`-based self-discovery
   for metrics, logs, and OTLP receivers for traces — no Prometheus Operator
   CRDs needed or present in this cluster. DaemonSet is the chart's own
   default controller type, matching the parent Specification's stated intent
   without an override.
5. **Grafana database.** Embedded SQLite with a `local-path` PVC
   (`persistence.enabled: true`); no external Postgres for this single-replica
   dev deployment. The storage feature-step's per-app Postgres consumption
   contract remains available, unused, and unchanged as a seam for a later
   multi-replica cycle.
6. **Grafana dev credentials.** The dev overlay must **explicitly** set
   `adminUser: admin` / `adminPassword: admin` (the chart's own unconfigured
   default generates a random 40-character password, which would silently
   break both `DEVELOPMENT.md`'s documented `admin:admin` convention and the
   committed `tests/agrippa.bats` dev-path assertion). This is not the
   sops-sealing convention the storage feature-step established for Postgres
   credentials — it is a deliberate exception because the dev credential is
   already a committed, human-facing, intentionally-non-secret contract (the
   Closing Bell literally asks the study participant to sign in with "the
   documented local dev credentials"). The sops-sealing convention is instead
   the natural fit for a **production** overlay's Grafana admin credential
   (`admin.existingSecret`), which stays a preserved, unbuilt seam like every
   other prod-only mechanism this project defers.
7. **Dev hostname.** `dashboard.davidsouther.com.127.0.0.1.nip.io` — corrects
   the task brief's own suggested `dashboard.127.0.0.1.nip.io` (which matches
   neither `tests/agrippa.bats`'s `DASHBOARD_HOST` default nor the parent
   design's own resolved-item-6 worked example). Full derivation in
   `research/codebase.md`.
8. **Gateway/HTTPRoute/Certificate consumption.** One new `HTTPRoute` for
   Grafana against the already-live shared `agrippa-gateway`, plus one
   appended `dnsNames` entry on the already-live shared `agrippa-gateway-tls`
   Certificate (both `core`-owned files, both one-line, append-only edits per
   the networking feature-step's own stated seam). Loki/Tempo/Mimir/Alloy need
   no `HTTPRoute` — none exposes an end-user UI.

**Resolved by the long-loop reviewer (2026-07-08):**

1. **Mimir's deployment shape. Decided: reduced-replica `mimir-distributed`
   (`replicas: 1` per component), the official chart, not a hand-authored
   monolithic manifest.** Researched via `research:public`: the default
   `mimir-distributed` `values.yaml` renders ~14 pods out of the box (ingester
   ×3, querier ×2, query-scheduler ×2, plus one each for distributor,
   query-frontend, store-gateway, compactor, ruler, alertmanager,
   overrides-exporter, and a bundled minio); driven to `replicas: 1` per
   component it lands at ~10 pods — heavier than Loki's or Tempo's single
   binary, but confirmed to be the chart's supported reduced-scale shape. No
   source documents an official *monolithic* `mimir-distributed` path (the
   `small.yaml` preset is a 4-core/16GiB production preset, not minimal), so
   the only lighter alternative is a from-scratch off-chart manifest. This
   project's own established convention is decisive and points at the official
   chart: every third-party infra component is delivered through its official
   chart or operator and accepts the overhead — CNPG operator over a
   hand-rolled Postgres StatefulSet (storage `design.md`: "Operator-plus-
   authored-CRs is the same shape the `core` layer already uses for cert-manager
   and metallb"), the official Valkey chart, Istio ambient's four charts,
   cert-manager, metallb. Hand-authoring is precedented in this project **only**
   for first-party workloads (`charts/resume`, `charts/trips`), never for a
   third-party infra component; hand-rolling Mimir would break that pattern and
   add standing maintenance burden (tracking Mimir's config schema and upgrades
   by hand). The footprint cost is real but reversible (the k3d node already
   carries CNPG + Istio ambient + Valkey + ArgoCD; a lighter shape stays
   available as a later optimization) and neither option blocks Closing Bell
   task 4. Conservative default: stay on the officially-supported chart.
2. **Whether a `DestinationRule` is needed for Grafana's `HTTPRoute`. Decided:
   none — Grafana's chart Service serves plain HTTP (port 3000) by default, so
   the `backendRefs` needs no backend-TLS re-origination.** Unlike
   `argocd-server` (HTTPS-internal, which forced the ArgoCD `DestinationRule`),
   Grafana ships plain HTTP with no TLS by default. This is the materially
   simpler case the codebase note already anticipated; it is reversible (add a
   `DestinationRule` only if a future TLS-internal override is chosen). Confirm
   the chart's `service.yaml`/port default at build time, but the conservative
   default is no `DestinationRule`.
3. **Whether `apps/observability.yaml` will need
   `compare-options: ServerSideDiff=true`. Decided: add it proactively,
   matching `storage`/`core`.** Both prior CRD-adjacent layers needed exactly
   this annotation to escape a perma-`OutOfSync` SMD-mispredict symptom, and
   the annotation is harmless when unneeded (it only changes the diff strategy).
   The conservative default is to carry it forward rather than rediscover the
   symptom mid-build; confirm live once the layer's `HTTPRoute` lands. Adding a
   harmless annotation is lower-risk than omitting a likely-needed one.
4. **Exact chart `repoURL`/version pins. Decided: defer to build-time live
   verification** (`helm search repo` against both
   `https://grafana.github.io/helm-charts` and
   `https://grafana-community.github.io/helm-charts`, or each chart's current
   docs page). Given the active Grafana Helm chart migration (Search/Expand
   finding 5, still in flux as of this review), freezing pins now would be less
   accurate than resolving them at authoring time — the exact "defer the
   version/source pin to build time" pattern the storage feature-step's own
   research already used for the CNPG chart. This is the conservative default,
   not a deferral of a real decision.
5. **Whether to scrape Istio ambient's ztunnel telemetry. Decided: decline for
   this feature-step; keep it as a documented follow-on seam.** ztunnel's
   `/stats/prometheus` (port 15020) is available and low-effort, but neither the
   parent Specification ("Loki, Grafana, Tempo, Mimir + an Alloy DaemonSet,
   reduced replicas") nor Closing Bell task 4 (Grafana renders *a* dashboard)
   requires it. Adding unbudgeted scope is the non-conservative move; the
   conservative default is to not fold it in silently. It stays a reversible,
   named opt-in for a later iteration (Alloy would target it via
   `discovery.kubernetes` pod-role, no new CRDs).
6. **Whether a literal `adminPassword: admin` in a committed `valuesInline:`
   block needs any accommodation from the plaintext-Secret conftest guard.
   Decided: none needed — verified directly against the guard.**
   `scripts/test-static.sh` walks only `apps/`, `charts/*/rendered/`, and
   `secrets/`; it never scans `observability/`, where this feature-step's
   `helmCharts:`/`valuesInline:` composition lives. Independently,
   `tests/policy/secrets.rego` evaluates only manifests whose `input.kind ==
   "Secret"`, and a `valuesInline:` field inside a Kustomization is not a
   `kind: Secret` object at all — so the value would not trip the guard even if
   it were in scope. No accommodation required; no change to the guard.

## Sources

Full citation lists with per-claim inline references live in the two
companion notes this research phase produced:

- `research/public.md` — external/public findings (39 sources: official
  Grafana Labs documentation for Loki, Tempo, Mimir, Grafana, and Alloy; the
  `grafana/helm-charts`, `grafana/mimir`, and `grafana-community/helm-charts`
  GitHub repositories directly; Istio and Ambient Mesh's own metrics docs;
  and third-party analysis of the January 2026 Grafana Helm chart repository
  migration).
- `research/codebase.md` — internal findings (direct `research:codebase`
  inspection of `apps/observability.yaml`, `apps/storage.yaml`, `apps/core.yaml`,
  `apps/platform/argocd/kustomization.yaml`, `tests/agrippa.bats`,
  `DEVELOPMENT.md`, `ARCHITECTURE.html`, and the already-landed/already-cleared
  storage and networking feature-steps' own `design.md`/`plan.md`).

Selected load-bearing citations, reproduced here for convenience (full IEEE
entries in `research/public.md`):

- [1] "Preconfigured and all-in-one LGTM stack helm chart," grafana/helm-charts
  Issue #1397. https://github.com/grafana/helm-charts/issues/1397
- [2] "Install the monolithic Helm chart," Grafana Loki documentation.
  https://grafana.com/docs/loki/latest/setup/install/helm/install-monolithic/
- [3] "Monolithic and microservices modes," Grafana Tempo documentation.
  https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/plan/deployment-modes/
- [4] "Helm chart for monolithic and read-write deployment mode," grafana/mimir
  Issue #4832 (open since 2023, no official monolithic Helm chart).
  https://github.com/grafana/mimir/issues/4832
- [5] "Collect Prometheus metrics," Grafana Alloy documentation
  (`discovery.kubernetes` self-discovery, no Prometheus Operator dependency).
  https://grafana.com/docs/alloy/latest/collect/prometheus-metrics/
- [6] "Setting up Grafana to persist in PostgreSQL with Helm," Frank Wiles
  blog (SQLite-vs-Postgres trade-off is about horizontal scaling).
  https://frankwiles.com/posts/grafana-postgresql-helm/
- [7] "charts/grafana/templates/_config.tpl" and "_helpers.tpl,"
  grafana-community/helm-charts (unset `adminPassword` generates a random
  40-character password, not a literal `admin`).
  https://github.com/grafana-community/helm-charts/blob/main/charts/grafana/templates/_config.tpl
- [8] "Deploy Grafana using Helm Charts," Grafana documentation (current
  chart repo: `grafana-community.github.io/helm-charts`).
  https://grafana.com/docs/grafana/latest/setup-grafana/installation/helm/
- [9] "Install Grafana Alloy on Kubernetes," Grafana Alloy documentation
  (unmigrated chart repo: `grafana.github.io/helm-charts`; DaemonSet default).
  https://grafana.com/docs/alloy/latest/set-up/install/kubernetes/
- [10] `tests/agrippa.bats` (this repository) — `DASHBOARD_HOST` default and
  the dev-path Grafana basic-auth assertion.
- [11] `.ailly/developer/2026-07-06-A-agrippa-local-k3d/design.md` — resolved
  item 6, the `<prod-host>.127.0.0.1.nip.io` hostname scheme.
