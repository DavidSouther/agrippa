# Project Plan: Agrippa Local (k3d, no cloud)

*Reviewed 2026-07-07*

> Project Shape plan (project-cycle.md, "Plan Steps Are Features"). Each entry
> below is itself a full feature loop with its own session folder, its own
> `design.md`, its own feature test, its own plan of several steps, and its own
> build & cleanup — not a red-green-refactor increment. This document transcribes
> `design.md`'s Specification into a feature-step checklist with explicit
> Sequential/Parallel dependency markers, per project-cycle.md's plan format.

**Closing Bell:** `ailly/developer/2026-07-06-A-agrippa-local-k3d/closing-bell.md`

**Libraries & Skills (carry into every feature-step's own design/plan/build):**
Per `design.md` § Libraries & Skills, every feature-step below loads
`developer:initialize` (for its own tool/mise needs), `research:public` and
`research:codebase` (each feature-step owes its own per-component research), and
the `developer:ailly` project-shape references (`shapes/project/project-cycle.md`,
`closing-bell.md`, `release-flags.md`). No library-shipped agentic skill exists
for k3d/k3s/Helm/ArgoCD/Istio/Gateway API/metallb/cert-manager/Longhorn/Postgres/
Valkey/Keycloak/Forgejo/Flagsmith/LGTM/SOPS-KSOPS/kubeconform/helm-unittest/
conftest/chainsaw/bats/mise — build to `DEVELOPMENT.md`, `ROUTING.md`, and
`ARCHITECTURE.html` as the authoritative in-repo contracts instead.

**Features:**
- [x] Feature 0: Prerequisites (mise + test harness)    (no dependencies, can start now)
- [x] Feature 1: Cluster core                           Depends on: Feature 0
- [x] Feature 2: GitOps (ArgoCD)                         Depends on: Feature 1
- [x] Feature 3: Networking (Istio + cert-manager)       Depends on: Feature 1; applied via Feature 2
- [x] Feature 4: Storage (Postgres + Valkey)             Depends on: Feature 1, Feature 2
- [x] Feature 5: Auth (Keycloak)                         Depends on: Feature 4. Parallel with: Feature 6, Feature 7, Feature 8; shared contract: storage class + DB naming
- [x] Feature 6: Git hosting (Forgejo)                   Depends on: Feature 4. Parallel with: Feature 5, Feature 7, Feature 8; shared contract: storage class + DB naming
- [x] Feature 7: Feature flags (Flagsmith)               Depends on: Feature 4. Parallel with: Feature 5, Feature 6, Feature 8; shared contract: storage class + DB naming
- [x] Feature 8: Observability (LGTM + Alloy)            Depends on: Feature 4. Parallel with: Feature 5, Feature 6, Feature 7; shared contract: storage class
- [ ] Feature 9: Workloads (resume + trips)              Depends on: Feature 3, Feature 5 (and Feature 7 where a workload uses feature flags)

Nine feature-steps (Feature 0 through Feature 9) matching `design.md`'s roadmap
items 1-9 plus the Step 0 prerequisite the design itself names. This is one more
entry than "a handful," but the design's own Specification already fixed this
decomposition and its Purpose section argues the whole only delivers value
together (long-loop reviewer, 2026-07-06); this plan does not re-litigate scope,
only sequences it.

## Shared Contracts (settle before parallel work — the project-altitude Step 0)

Per project-cycle.md, these must be agreed before Features 5-8 run in parallel:

- **App-of-apps layout and sync-waves** — the five `ARCHITECTURE.html` layer
  directories (`core`, `storage`, `platform`, `observability`, `workloads`), the
  `overlays/dev` vs `overlays/prod` split, and sync-wave numbering (CRDs low,
  controllers next, custom resources last). Settled by Feature 2 (GitOps); every
  later GitOps-managed feature consumes it.
- **Storage class + per-app DB naming** — the dev storage class (`local-path`)
  and the per-app Postgres DB/role naming that Features 5-8 all bind to. Settled
  by Feature 4 (Storage).
- **Gateway + HTTPRoute + local hostname + TLS scheme** — the shared Istio
  Gateway listener(s), HTTPRoute conventions, the `*.nip.io` loopback hostname
  scheme reached through the k3d gateway port-map, and the local CA `Certificate`
  pattern. Settled by Feature 3 (Networking); every UI-exposed service and every
  workload (Feature 9) consumes it.

Parallel features that have not agreed on these three collide; parallel features
that have settled them integrate cleanly.

## Feature 0: Prerequisites (mise + test harness)

**No dependencies, can start now.**

Scope: `mise.toml` pinning kubeconform, helm, kubectl, k3d, chainsaw, conftest,
bats; a `setup` task installing the helm-unittest Helm plugin; the `test:*` tasks
(`test:static`, `test:chart`, `test:policy`, `test:feature`, `test:push`
umbrella). The plaintext-`Secret` conftest guard from `DEVELOPMENT.md` § Secrets
lands here. Per `research.md` decision 6, omit the terraform/tflint pins and
`test:tf` lane (cloud cycle).

**Advances Closing Bell:** foundation for every critical task — nothing else can
be built or tested without it — and directly underwrites the `bats`/`kubeconform`
tooling the automated backstop (`tests/agrippa.bats`) runs on.

**Shared contract this feature owes:** the tooling and `test:*` task names every
later feature's own build phase calls.

## Feature 1: Cluster core

**Depends on: Feature 0** — needs the pinned `k3d`/`kubectl`/`helm` toolchain.

Scope: a `k3d` cluster definition (config file + `mise` task) replacing
Terraform/cloud-init/DigitalOcean: single node, ServiceLB **and** Traefik
disabled (`--k3s-arg --disable=servicelb`, Traefik disabled), metallb installed
with an `IPAddressPool` inside the k3d Docker-network subnet, and a gateway host
port-map (e.g. `-p "443:443@loadbalancer"`) so host `:443` reaches the Istio
Gateway. No GPU pool. Nuance carried from the design: metallb may need to move
into the manual bootstrap (Feature 2) if a chicken-and-egg surfaces at build,
per `research.md` decision 8 — no rework elsewhere if so; flag it as a risk to
re-check in this feature's own design, not a decision to make now.

**Advances Closing Bell:** critical task 1 (the platform comes up from a clean
checkout) — the cluster substrate stands up first.

## Feature 2: GitOps (ArgoCD)

**Depends on: Feature 1** — needs a running cluster to install ArgoCD into.

Scope: ArgoCD app-of-apps; the manual bootstrap boundary (`research.md` decision
8) is the minimum that gets a decrypting ArgoCD running: `k3d cluster create`,
the `sops-age` Secret, ArgoCD with its KSOPS-enabled repo-server, then the root
app-of-apps applied once. Everything after is ArgoCD-reconciled via sync-waves.
A `mise` **`bootstrap`** task creates the `sops-age` Secret in the `argocd`
namespace from Bitwarden item `agrippa-age-dev` before first sync, in place of
Terraform's injection (`research.md` decision 4). ArgoCD is reached by `kubectl
port-forward` until Feature 3 (Networking) lands ingress.

**Defines shared contract:** app-of-apps layout / sync-wave numbering (see
Shared Contracts above). Per the design's resolved item 5, use the five
`ARCHITECTURE.html` layer names verbatim and the `overlays/dev`/`overlays/prod`
split; settle the exact path spelling (`apps/core` vs `core`, chart vs app
directories) in this feature's own design.

**Advances Closing Bell:** underwrites critical task 1 (a Synced/Healthy
app-of-apps) and the secondary task (probes the GitOps/parity intent).

## Feature 3: Networking (Istio + cert-manager)

**Depends on: Feature 1; applied via Feature 2** — the Gateway API CRDs and
Istio control plane are cluster-level installs, but land through the GitOps
spine once Feature 2 exists (sync-wave ordering: CRDs before the resources that
use them).

Scope: Istio ambient + Gateway API with `global.platform=k3d` (Gateway API CRDs
installed first); cert-manager with a SelfSigned→CA local `ClusterIssuer` chain.
cloudflared and ExternalDNS excluded. Local name resolution via `*.nip.io`
loopback + the k3d port-map; local TLS is real-but-not-publicly-trusted, probed
with `curl -k` (`research.md` decisions 2, 3).

**Defines shared contract:** Gateway + HTTPRoute + local hostname + TLS scheme
(see Shared Contracts above). Per the design's resolved item 6, mirror each
production hostname as `<prod-host>.127.0.0.1.nip.io` (e.g.
`davidsouther.com.127.0.0.1.nip.io`, `trips.davidsouther.com.127.0.0.1.nip.io`,
`dashboard.davidsouther.com.127.0.0.1.nip.io`); settle the exact pattern in this
feature's own design.

**Advances Closing Bell:** critical tasks 2 and 3 (the personal site + `/blog`
and the trips site render through the Istio Gateway) and the `curl -k`
TLS-tolerant probing the gestalt fix (Feature 9) needs.

## Feature 4: Storage (Postgres + Valkey)

**Depends on: Feature 1, Feature 2** — needs a cluster and the GitOps spine to
reconcile the storage layer's Helm releases.

Scope: Postgres and Valkey Helm charts. Adopt k3s `local-path` as the dev
storage class (`research.md` decision 1 — Longhorn cannot run on stock k3d
without `open-iscsi`); keep Longhorn declared in the app-of-apps but scoped out
of `overlays/dev`. Off-cluster DR (pg_dump, Longhorn backups to S3) deferred;
local DR is GitOps-only (RPO 0 for declarative state).

**Defines shared contract:** storage class + per-app DB/role naming (see Shared
Contracts above), consumed by Features 5-8.

**Advances Closing Bell:** unblocks Auth, Git hosting, Feature flags, and
Observability — none of the Closing Bell's remaining critical tasks can be
exercised without a datastore in place.

## Feature 5: Auth (Keycloak)

**Depends on: Feature 4. Parallel with: Feature 6, Feature 7, Feature 8; shared
contract: storage class + DB naming.**

Scope: Keycloak (Tier-2 OIDC), Postgres-backed. Cloudflare Access (Tier-1) has
no local equivalent; local workloads are public or Keycloak-gated (the design's
resolved item 3 keeps trips itself at plain reachability, not Keycloak-gated).

**Advances Closing Bell:** feeds Feature 9 (Workloads), which depends on it
directly; no standalone Closing Bell task names Auth on its own.

## Feature 6: Git hosting (Forgejo)

**Depends on: Feature 4. Parallel with: Feature 5, Feature 7, Feature 8; shared
contract: storage class + DB naming.**

Scope: Forgejo + forgejo-runner, Postgres-backed. GitHub push-mirror is
optional locally (works only if outbound is available).

**Advances Closing Bell:** rounds out the platform-services tier the Purpose
section commits to as part of the unified whole; no standalone Closing Bell
task names Git hosting directly.

## Feature 7: Feature flags (Flagsmith)

**Depends on: Feature 4. Parallel with: Feature 5, Feature 6, Feature 8; shared
contract: storage class + DB naming.**

Scope: OpenFeature + Flagsmith, Postgres-backed.

**Advances Closing Bell:** feeds Feature 9 (Workloads) only where a workload
actually reads a flag — Feature 9 is not blocked on this feature otherwise; also
backs the project's own release flag mechanism (design.md § Release Flag).

## Feature 8: Observability (LGTM + Alloy)

**Depends on: Feature 4 (signal stores need PVCs). Parallel with: Feature 5,
Feature 6, Feature 7; shared contract: storage class.**

Scope: Loki, Grafana, Tempo, Mimir + an Alloy DaemonSet, reduced replicas,
signal stores on `local-path`. Rook-Ceph deferred.

**Advances Closing Bell:** critical task 4 directly (Grafana authenticates
locally and renders) — this is what that probe exercises.

## Feature 9: Workloads (resume + trips)

**Depends on: Feature 3 (Networking), Feature 5 (Auth) — and Feature 7 (Feature
flags) only where a workload reads a flag.**

Scope (concretized in `design.md`, not a placeholder): pulls in the two real
repositories (`github.com/davidsouther/resume`, `github.com/davidsouther/trips`)
that serve production today via GitHub Pages, and deploys both into the local
k3d cluster. Both are pure static `@davidsouther/jiffies` sites on Node 24 with
no Dockerfile, Helm chart, or K8s manifest today; this feature authors that
packaging from scratch:

1. **A build+serve container image per workload**, produced by one imperative
   `mise` task (e.g. `workloads:build`): stage 1 `node:24` runs `npm ci && npm
   run build` to produce `docs/`; stage 2 a static server (`nginx:alpine` or
   equivalent) serves it. `k3d image import` loads the tag the chart pins — no
   external registry needed locally. This is the one deliberate non-GitOps step
   in this feature, the same shape as Feature 2's `bootstrap` task. Upstream
   source arrives as a git submodule under a `workloads/` build context (the
   design's resolved item 2); the source repos themselves stay untouched.
2. **A minimal Helm chart per workload** in `charts/resume/` and `charts/trips/`
   (reduced-replica in `overlays/dev`): a Deployment, a Service, a Gateway API
   `HTTPRoute` against the Feature 3 Gateway contract at the workload's dev
   hostname, and a cert-manager `Certificate` from the local CA issuer.
3. **An ArgoCD Application** in the `workloads` layer (Feature 2's contract)
   pointing at each chart.
4. **The personal site's `/healthz` liveness endpoint**, served via an nginx
   `location /healthz { return 200; }` in the chart (the design's resolved item
   4) — not a file added to the resume repo.
5. **The `tests/agrippa.bats` gestalt fix** (three edits, `research.md`
   decision 5): (a) collapse the environment switch onto the single `ENV`
   variable `setup()` already sets, retiring the dead `GESTALT_ENV` branch; (b)
   give the trips test a **dev branch** asserting plain local reachability (the
   design's resolved item 3 — no Keycloak/OIDC gating) instead of the absent
   Cloudflare Access 302; (c) make the `ENV=dev` probes tolerate the local CA
   with `curl -k`. Run with `PUBLIC_HOST`, `TRIPS_HOST`, `DASHBOARD_HOST`
   pointed at the local `nip.io` ingress and `ENV=dev`.

`agathon` and `ailly.dev` are explicitly out of this feature's build (the
design's resolved item 1) — roadmap seams for a later cycle only, once their
repos are inspected.

**Advances Closing Bell:** critical tasks 2 and 3 directly (personal site +
`/blog` and trips render through the Gateway) and critical task 6 directly
(`ENV=dev bats tests/agrippa.bats` passes).

## Dependency graph

Topological layering (a feature can start once every feature in an earlier
layer is done; features in the same layer with no arrow between them run in
parallel):

```text
Layer 0   Feature 0  Prerequisites
             |
Layer 1   Feature 1  Cluster core
             |
Layer 2   Feature 2  GitOps            Feature 3  Networking
             |        (needs Feature 1; Feature 3 needs Feature 1,
             |         applied via Feature 2's sync-waves once GitOps exists)
             v
Layer 3   Feature 4  Storage  <----------------- (needs Feature 1 + Feature 2)
             |
Layer 4   Feature 5  Auth          --+
          Feature 6  Git hosting    |- parallel, shared contract: storage class
          Feature 7  Feature flags  |  (+ DB naming for 5/6/7)
          Feature 8  Observability --+
             |
Layer 5   Feature 9  Workloads  (needs Feature 3 + Feature 5, and Feature 7
                                  where a workload reads a flag)
```

Features 5-8 are the project's one parallel band: four different sessions (or
people) can build Auth, Git hosting, Feature flags, and Observability
concurrently once Feature 4 has settled the storage-class and DB-naming
contract — not just designed it, but landed and reconcilable by ArgoCD, since a
design draft is not the same as a merged chart. Feature 9 (Workloads) is the
closing sequential step: it cannot start until Networking (hostnames/TLS) and
Auth (the gating decision) exist, and it is where the Closing Bell's remaining
critical tasks (2, 3, 6) and the project release flag's promotion (design.md §
Release Flag) land.

## Notes for each feature-step's own design phase

- Per-component SLOs (Prometheus queries / Grafana alert thresholds, per
  `TASKS.md`) are defined inside each feature-step's own `design.md`, not in
  this project plan (design.md § User Journey and Metrics).
- Each feature still runs its own `research:public` / `research:codebase` pass
  and writes its own executable feature test — this project plan fixes scope
  and order, not per-feature implementation detail.
- The Release Flag (design.md § Specification § Release Flag): one
  project-level flag gates the unified whole. Deploy continuously — each
  feature above lands and is testable in isolation on an integration branch —
  but do not promote that branch to `main` until the Closing Bell passes. A
  half-built layer ships dark (excluded from the `overlays/dev` app-of-apps
  root until its feature lands). No feature-step above needs its own flag.

## Stop Condition

Do not begin any feature-step's own design or build from this document. Each
feature-step above still owes its own `research:public` / `research:codebase`
pass and its own design→plan→build→cleanup cycle (project-cycle.md, "Plan Steps
Are Features"). This plan only fixes the checklist and the dependency graph.

## Resolved by the long-loop reviewer (2026-07-07)

This plan transcribes the already-cleared `design.md` Specification into a
feature-step checklist; it poses no per-component decisions of its own (those are
deferred to each feature-step's own design gate by the Stop Condition and the
"Notes for each feature-step's own design phase" section). The reviewer verified
the transcription against `design.md`, `research.md`, `closing-bell.md`,
`ARCHITECTURE.html`, and the working tree, then decided each item to the
conservative default. No escalation trigger (irreversible, out of recorded scope,
or underdetermined) fired, so this draft gate is cleared.

**1. Closing Bell task numbering for the gestalt suite. Decided: correct
"critical task 5" to "critical task 6" everywhere the plan attributes
`ENV=dev bats tests/agrippa.bats` to Feature 9 (the Feature 9 "Advances Closing
Bell" line and the dependency-graph "remaining critical tasks" note).**
`closing-bell.md`'s Acceptance Criteria table numbers the `ENV=dev bats` gestalt
as critical task **6**; task **5** is the *secondary* ArgoCD/GitOps task, which
Feature 2 (not Feature 9) advances. `design.md`'s Workloads step already cites
"critical task 6" for this same probe, so the correction aligns the plan with both
its own design and the Closing Bell. A cross-reference fix to a stable source
table: reversible, in scope (the plan's own citation accuracy), and determined by
the table.

**2. No other open items; transcription verified faithful. Decided: clear the
gate.** Every research-decision citation (`research.md` decisions 1, 2, 3, 4, 5,
6, 8) and every design resolved-item citation (`design.md` resolved items 1-6) in
the plan was checked against its source and is accurate. The dependency markers
and the Layer 0-5 graph match `design.md`'s feature-step dependencies exactly and
contain no cycle. The five app-of-apps layer names (`core`, `storage`,
`platform`, `observability`, `workloads`) and the `overlays/dev`/`overlays/prod`
split are confirmed present in `ARCHITECTURE.html` and already realized in the
working tree's `apps/`. The one dependency a careful reader might question —
Feature 9 (Workloads) depending on Feature 5 (Auth) even though `design.md`
resolved item 3 serves local trips publicly and neither concretized workload
(resume, trips) is Keycloak-gated — is kept as transcribed: it is the design's own
recorded ordering, re-deciding it would re-litigate scope (this plan "does not
re-litigate scope, only sequences it"), and keeping the edge is the conservative
default since Auth completes well before the closing Workloads step regardless and
the edge preserves the design's stated option to layer OIDC gating later.

Plan saved to `ailly/developer/2026-07-06-A-agrippa-local-k3d/plan.md`. A
separately dispatched long-loop reviewer has cleared this draft gate (the `Draft`
marker is now `Reviewed`), the same way one already cleared `design.md`'s; its
decisions are recorded in the *Resolved by the long-loop reviewer* block above.
Remaining human review happens at the project's merge gate, not here.
