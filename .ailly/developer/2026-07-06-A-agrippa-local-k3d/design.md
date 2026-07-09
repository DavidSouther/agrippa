# Project Design: Agrippa Local (k3d, no cloud)

*Reviewed 2026-07-06*

**Project Shape.** This is the umbrella design doc for a multi-feature project, not
a single-feature design. Its exit criterion is a Closing Bell usability study, not
one executable feature test.

**Phase: Review.** The project design doc moves through Review → Implement →
Completed (project-cycle.md). This document, its feature-step plan, and the Closing
Bell are in the Review (draft-gate) period now. A separately dispatched long-loop
reviewer has cleared this design's draft; its open items are resolved in the
*Resolved by the long-loop reviewer* block under Summary. The feature-step plan and
the Closing Bell remain their own artifacts with their own gates.

**Closing Bell:** `ailly/developer/2026-07-06-A-agrippa-local-k3d/closing-bell.md`
(the project's definition of done, in place of a feature test).

**Project release flag:** see *Release Flag* under Specification.

## Libraries & Skills (carry forward to plan and build)

Per the cleared `research.md` (§ Libraries & Skills), the plan and build phases MUST
load these skills via the harness's skill-loading mechanism before working:

- **`developer:initialize`** — for the "Initialize mise" prerequisite (Step 0).
- **`developer:ailly` project-shape references** (`shapes/project/project-cycle.md`,
  `closing-bell.md`, `release-flags.md`) — this is a project, not a feature.
- **`research:public`** and **`research:codebase`** — each feature-step still needs
  its own per-component design research.

**No library-shipped agentic skill exists for this infrastructure.** `research.md`
recorded a deliberate check: none of k3d, k3s, Helm, ArgoCD, Istio, Gateway API,
metallb, cert-manager, Longhorn, Postgres, Valkey, Keycloak, Forgejo, Flagsmith, the
Grafana LGTM stack, SOPS/KSOPS, kubeconform, helm-unittest, conftest, chainsaw,
bats, or mise ships a `SKILL.md` or MCP server. The authoritative in-repo contracts
stand in: `DEVELOPMENT.md` (## Testing, ## Secrets) fixes the test tooling and the
SOPS+age wiring; `ROUTING.md` fixes the domain-vs-path policy; `ARCHITECTURE.html`
fixes the component topology and overlays. Design and build to those, not to a
from-scratch reinvention.

## Purpose

Stand up a from-scratch, working copy of the Agrippa self-hosted Kubernetes platform
on a local **k3d** cluster, so an operator can develop against a real cluster on a
laptop. The value is delivered only as a whole: a single component (a lone Postgres,
a lone Istio Gateway) proves nothing about the platform. What must work is the
**parity model** — the same Helm charts and manifests that production runs, driven by
the same GitOps spine, standing up locally on k3d and serving David's real workloads
through the Istio Gateway. That end-to-end whole is why this is a project and not a
feature: the GitOps spine, ingress, storage, the platform services, and the workloads
each warrant their own design→build cycle, and none is useful alone.

Scope is the local k3d substrate only. Production (Terraform, cloud-init, DigitalOcean
node pools, the GPU pool), the Cloudflare edge (Tunnel, Access, public DNS, public
ACME certs), off-cluster S3 disaster recovery, Rook-Ceph, the home-lab substrate, and
the Platform LLM tier (roadmap item 10, DavidBot) are all out of scope for this
project. The seams that let production slot in later — `overlays/dev` vs
`overlays/prod`, the Terraform `elastic-node-pool` seam, the S3 "one Terraform var" —
are preserved, not built.

## Prior Art

- **The 2026-06-10 architecture cycle** is the authoritative Prior Art. Its
  `design.md` was deleted by feature-loop cleanup convention; `ARCHITECTURE.html`
  (the eight-view deck), `README.md`, `ROUTING.md`, `DEVELOPMENT.md`,
  `GETTING_STARTED.md`, and `docs/developer/TASKS.md` are its durable residue and fix
  the component topology, the layer/overlay model, the request path, the routing
  policy, and the test and secrets conventions this project builds to.
- **The committed test suites.** `tests/preflight.bats` already gates the local
  toolchain and a throwaway k3d up/down. `tests/agrippa.bats` is the committed
  gestalt and the nearest existing statement of "done"; it is the Closing Bell's
  automated backstop (and needs the dev-mode fix recorded below).
- **The parity precedents already in the docs.** The architecture already replaces
  production-only pieces with local equivalents (metallb replaces cloudflared;
  reduced replicas; Rook-Ceph deferred behind block volumes). This project extends
  that same pattern to storage (local-path replaces Longhorn) and TLS (a local CA
  replaces the Cloudflare edge).
- **External worked examples**, cited in full in `research.md` § Sources: Istio's own
  k3d platform-setup and ambient install pages; the k3d/k3s issues documenting the
  Longhorn/open-iscsi limitation; the metallb-vs-ServiceLB conflict guidance;
  cert-manager's SelfSigned→CA issuer docs; ArgoCD sync-waves; and KSOPS-with-age in
  ArgoCD.
- **The real workload repositories** (new, inspected for this design):
  `github.com/davidsouther/resume` and `github.com/davidsouther/trips`. Both are
  `@davidsouther/jiffies` static-site generators on Node 24 that build a fully static
  site into `docs/` and deploy to GitHub Pages today. Neither ships a Dockerfile,
  Helm chart, or Kubernetes manifest. Details in the Workloads feature-step.

## User Journey and Metrics

**The end-to-end journey.** An operator clones the repo on a macOS laptop, runs the
`mise` bootstrap, and gets a running local platform: a k3d cluster with metallb, an
ArgoCD app-of-apps that reconciles every layer from git, Istio ambient + Gateway API
ingress with locally-valid TLS, local-path-backed Postgres and Valkey, the platform
services (Keycloak, Forgejo, Flagsmith), the LGTM observability stack, and David's
real personal site and trips site running in-cluster and reachable in a browser at
dev hostnames. They open the sites, open Grafana with local dev credentials, see
ArgoCD reporting everything Synced, and run `ENV=dev bats tests/agrippa.bats` green
against the local ingress.

**Metrics / measures of done.** The Closing Bell
(`closing-bell.md`) is the measure. Its critical tasks: the platform comes up from a
clean checkout; the personal site + `/blog` and the trips site render through the
Istio Gateway; Grafana authenticates locally and renders; and
`ENV=dev bats tests/agrippa.bats` passes against the local cluster. Its secondary task probes the GitOps/parity intent.
Per-component SLOs (Prometheus queries / Grafana alert thresholds, per `TASKS.md`)
are defined inside each feature-step's own design, not here.

**Failure modes to design against.** ServiceLB/metallb IP contention; the Istio CNI
and ztunnel rejecting k3d's containerized nodes without `global.platform=k3d`;
Longhorn's manager failing its `open-iscsi` environment check; ArgoCD syncing a CR
before its CRD exists; the `sops-age` trust root being absent at first sync (no
Terraform locally); and the committed gestalt asserting a Cloudflare Access redirect
that cannot exist on k3d.

## Specification

The project decomposes into a bounded set of feature-steps. Each is its own
design→plan→build→cleanup cycle with its own session folder, `design.md`, feature
test, and plan (project-cycle.md, "Plan Steps Are Features"). Sequential/parallel
relationships and the shared contracts to settle first are stated explicitly.

### Shared contracts (settle before the parallel work — the project-altitude Step 0)

Parallel feature-steps integrate only if these are agreed first:

- **App-of-apps layout and sync-waves.** The layer directories (`core`, `storage`,
  `platform`, `observability`, `workloads`), the `overlays/dev` vs `overlays/prod`
  split, and the sync-wave numbering (CRDs low, controllers next, custom resources
  last). Settled in the GitOps step; every GitOps-managed step consumes it.
- **Storage class + per-app DB naming.** The dev storage class (`local-path`) and the
  per-app Postgres DB/role naming that Auth, Git hosting, Feature flags, and
  Observability all bind to. Settled in the Storage step.
- **Gateway + HTTPRoute + local hostname + TLS scheme.** The shared Istio Gateway
  listener(s), the HTTPRoute conventions, the `*.nip.io` loopback hostname scheme
  reached through a k3d gateway port-map, and the local CA `Certificate` pattern.
  Settled in the Networking step; every UI-exposed service and every workload
  consumes it.

### Feature-steps

Marked with dependency relationships per project-cycle.md.

- **Step 0 — Prerequisites (land first, no dependencies).** `mise` init
  (`developer:initialize`): `mise.toml` pinning kubeconform, helm, kubectl, k3d,
  chainsaw, conftest, bats; a `setup` task installing the helm-unittest Helm plugin;
  the `test:*` tasks (`test:static`, `test:chart`, `test:policy`, `test:feature`, and
  the `test:push` umbrella). The plaintext-`Secret` conftest guard from
  `DEVELOPMENT.md` § Secrets lands here. Per `research.md` decision 6, **omit** the
  terraform/tflint pins and the `test:tf` lane (they ship with the deferred cloud
  cycle). This step is the shared contract for every later step's tooling and tests.

- **Cluster core.** *Depends on: Step 0.* A `k3d` cluster definition (config file +
  `mise` task) in place of Terraform/cloud-init/DigitalOcean: single node, ServiceLB
  **and** Traefik disabled (`--k3s-arg --disable=servicelb`, and disable Traefik),
  metallb installed with an `IPAddressPool` inside the k3d Docker-network subnet, and
  a gateway host **port-map** (e.g. `-p "443:443@loadbalancer"`) so host `:443`
  reaches the Istio Gateway (the metallb IP is not host-routable on macOS). No GPU
  pool. *Nuance:* metallb is logically part of this step but is GitOps-managed at a
  sync-wave; if a chicken-and-egg surfaces at build, metallb moves into the manual
  bootstrap with no rework elsewhere (`research.md` decision 8).

- **GitOps (ArgoCD).** *Depends on: Cluster core.* ArgoCD app-of-apps; the **manual
  bootstrap boundary** (`research.md` decision 8) is the minimum that gets a
  decrypting ArgoCD running: k3d cluster create, the `sops-age` Secret, ArgoCD with
  its KSOPS-enabled repo-server, then the root app-of-apps applied once. Everything
  after is ArgoCD-reconciled via sync-waves. A `mise` **bootstrap** task creates the
  `sops-age` Secret in the `argocd` namespace from Bitwarden item `agrippa-age-dev`
  before first sync, in place of Terraform's injection (`research.md` decision 4).
  ArgoCD is reached by `kubectl port-forward` until ingress exists. Defines the
  app-of-apps layout / sync-wave shared contract above.

- **Networking.** *Depends on: Cluster core; applied by GitOps.* Istio ambient +
  Gateway API with `global.platform=k3d` (Gateway API CRDs installed first);
  cert-manager with a SelfSigned→CA local `ClusterIssuer` chain. cloudflared and
  ExternalDNS excluded. Local name resolution via `*.nip.io` loopback + the k3d
  port-map; local TLS is real-but-not-publicly-trusted, probed with `curl -k`
  (`research.md` decisions 2, 3). Defines the Gateway/HTTPRoute/hostname/TLS shared
  contract.

- **Storage.** *Depends on: Cluster core, GitOps.* Postgres and Valkey Helm charts.
  **Adopt k3s `local-path` as the dev storage class**; keep Longhorn declared in the
  app-of-apps but scoped out of `overlays/dev` (`research.md` decision 1 — Longhorn
  cannot run on stock k3d without `open-iscsi`). Off-cluster DR (pg_dump, Longhorn
  backups to S3) deferred; local DR is GitOps-only (RPO 0 for declarative state).
  Defines the storage-class + DB-naming shared contract.

- **Auth (Keycloak).** *Depends on: Storage. Parallel with: Git hosting, Feature
  flags, Observability; shared contract: storage class + DB naming.* Keycloak
  (Tier-2 OIDC), Postgres-backed. Cloudflare Access (Tier-1) has no local equivalent;
  local workloads are public or Keycloak-gated.

- **Git hosting (Forgejo).** *Depends on: Storage. Parallel with: Auth, Feature flags,
  Observability; shared contract: storage class + DB naming.* Forgejo +
  forgejo-runner, Postgres-backed. GitHub push-mirror is optional locally (works only
  if outbound is available).

- **Feature flags (Flagsmith).** *Depends on: Storage. Parallel with: Auth, Git
  hosting, Observability; shared contract: storage class + DB naming.* OpenFeature +
  Flagsmith, Postgres-backed.

- **Observability (LGTM + Alloy).** *Depends on: Storage (signal stores need PVCs).
  Parallel with: Auth, Git hosting, Feature flags; shared contract: storage class.*
  Loki, Grafana, Tempo, Mimir + an Alloy DaemonSet, reduced replicas, signal stores
  on `local-path`. Rook-Ceph deferred. This is what the dev gestalt's Grafana probe
  exercises.

- **Workloads.** *Depends on: Networking and Auth (and Feature flags where used).*
  Concretized below. This is where the committed `tests/agrippa.bats` gestalt fix
  lands.

### Workloads feature-step (concretized — new requirement)

This step is **not** a placeholder. It pulls in the two real, already-existing
repositories that serve production and **actually deploys both into the local k3d
cluster** as part of this project's build.

**What the two repos actually are (inspected 2026-07-06 via `gh`):**

- **`github.com/davidsouther/resume`** → serves `davidsouther.com` and its `/blog`.
  A `@davidsouther/jiffies` static-site generator on **Node 24**. `npm ci && npm run
  build` (which runs `check` → `css:bundle` → `sitemap` → the jiffies SSG) emits a
  **fully static, self-contained site into `docs/`**. Blog posts live in `posts/`,
  so a single build/deployment covers both `davidsouther.com` **and**
  `davidsouther.com/blog`. **No Dockerfile, Helm chart, or K8s manifest.** Today it
  deploys to GitHub Pages (`.github/workflows/deploy.yml`).
- **`github.com/davidsouther/trips`** → serves `trips.davidsouther.com`. The same
  jiffies SSG on Node 24, same `npm run build` → static `docs/`. **No runtime
  database or external service** (the Wikipedia cache is committed; the build is
  fully offline). Its `infra/` directory is Terraform for the **Cloudflare Access**
  app only — production edge gating, out of local scope (`research.md` decision 5).
  **No Dockerfile, Helm chart, or K8s manifest.** Today it deploys to GitHub Pages,
  edge-gated by Cloudflare Access.

**Consequence:** both are pure static sites, and **neither ships any container or
Kubernetes packaging.** This project must author it from scratch, per workload. The
source of each real repo arrives into this repo's build context (git submodule under
a `workloads/` build context is the proposed mechanism — resolved in the *Resolved
by the long-loop reviewer* block below), so the build reads real, current upstream source rather than a vendored
copy. From that source:

1. **A build+serve container image, produced by one imperative step.** A multi-stage
   image: stage 1 `node:24` runs `npm ci && npm run build` to produce `docs/`; stage
   2 a static server (`nginx:alpine` or equivalent) serves `docs/`. A `mise` task
   (e.g. `workloads:build`) builds the image and runs `k3d image import` to load the
   tag the chart pins — no external registry needed for the local build (production
   would push to the Forgejo registry or GHCR). This image build+import is the **one
   imperative step in the workload path**, deliberately outside GitOps the way the
   `bootstrap` task is: the chart and Application (below) stay GitOps-managed and pin
   the tag this step produces. The static build is offline for trips; the resume
   build is likewise offline once dependencies are installed.
2. **A minimal Helm chart** (in this repo's `charts/`, reduced-replica in
   `overlays/dev`): a Deployment (the image above), a Service, a Gateway API
   `HTTPRoute` attaching to the shared Istio Gateway at the workload's dev hostname
   (`davidsouther.com.<loopback>.nip.io` and `trips.davidsouther.com.<loopback>.nip.io`
   or equivalent per the Networking contract), and a cert-manager `Certificate` from
   the local CA issuer.
3. **GitOps management via the existing `workloads` layer Application.** So the
   sites reconcile like everything else. (Corrected 2026-07-09, per the
   Workloads feature-step's own cleared research: `charts/resume/`/`charts/trips/`
   stay real, helm-unittest-tested charts for the deferred prod/registry path, but
   the live `workloads/overlays/dev/` content the shared `apps/workloads.yaml`
   Application reconciles is plain kustomize `resources:` YAML, not a
   chart-pointed Application — kustomize's local-`helmCharts:` load-restrictor
   collides with the `charts/<chart>/` convention across the deep `overlays/dev`
   tree, and a one-off cluster-wide load-restrictor relaxation is out of this
   step's scope. Reversible, in scope, determined by a live `kustomize build`
   test — not a re-litigation of the chart-authoring decision itself.)
4. **A `/healthz` liveness endpoint for the personal site.** The committed gestalt
   probes `davidsouther.com/healthz`, but a jiffies static export serves 404 there
   by default. Resolve in the serving layer: either an nginx `location /healthz {
   return 200; }` in the chart, or a committed `public/healthz` static file. The
   nginx-config approach keeps the change inside this repo's chart and is preferred.

**Gestalt / Closing-bell backstop fix (build-phase work, `research.md` decision 5):**
fix and extend `tests/agrippa.bats` in place, with three edits. (a) Collapse the
environment switch onto the single `ENV` variable `setup()` already sets (retire the
dead `GESTALT_ENV` branch on line 51). (b) Give the trips test a **dev branch**
asserting local reachability/gating appropriate to k3d (plain reachability, or
Keycloak/OIDC if the local trips is gated) instead of the absent Cloudflare Access
302 redirect (lines 69-76). (c) Make the `ENV=dev` probes tolerate the local CA with
`curl -k` (`research.md` decision 3): the dev hostnames present real certs from the
local CA that is deliberately not in the host trust store, so the existing plain
`curl` HTTPS probes (lines 43, 54, 70) would fail TLS verification on the dev path
without it — and Closing Bell critical task 6 would fail even after edits (a) and (b).
Run with `PUBLIC_HOST`, `TRIPS_HOST`, `DASHBOARD_HOST` pointed at the local `nip.io`
ingress and `ENV=dev`.

**The other named workloads (`davidsouther.com/agathon`, `ailly.dev`)** follow the
same chart + Application pattern but are **not** simply another pure-static clone of
resume/trips. Per `ROUTING.md` and `TASKS.md`, `agathon` ships as a **path** under
`davidsouther.com` from the **already-inspected resume repo**, and it gains "its own
per-user DB" — so it is a dynamic app with a runtime datastore, not a static export;
`ROUTING.md` itself flags its GitOps source/secret profile as unverified. `ailly.dev`
is a distinct product on its own apex domain whose source repo was **not** inspected
for this design. The user's explicit requirement concretizes **resume and trips**
only; agathon and ailly.dev are scoped out of this project's build and kept as
Workloads-step roadmap seams (resolved in the *Resolved by the long-loop reviewer*
block below). Trips' Cloudflare Access policy (its `infra/` Terraform) and its CI
port to Forgejo Actions are prod / post-git-hosting concerns and are deferred for the
local build.

### Release Flag

One project-level release flag gates the unified whole (release-flags.md). Deploy
continuously — each feature-step lands and is testable in isolation — but do not
"release" the platform to an operator (make the `main`-branch `GETTING_STARTED.md` /
`mise run up` path advertise a working full platform) until the Closing Bell passes.
Concretely: feature-steps accumulate on a long-lived integration branch, and the
single flag is the promotion of that branch to `main` as the sanctioned local
bootstrap. Where a half-built layer would otherwise be reachable by an operator on
the release path, its ArgoCD Application ships dark (excluded from the `overlays/dev`
app-of-apps root until its step lands). No feature-step needs its own flag: each
ships dark on the branch and none independently changes what a `main`-branch operator
sees on its own. Run the Closing Bell against a build with the flag enabled for the
participant. Retire the flag at project cleanup: fold the integration branch into
`main` and remove any now-dead "not yet released" conditionals (project-cycle.md,
"Cleanup for a Project").

## Alternatives

- **A managed cluster (DOKS/GKE/EKS) or a prebuilt platform (Rancher, OpenShift
  Local).** Rejected on purpose (`research.md` § Falsification). The project's whole
  intent is a self-managed, cloud-portable k3s platform whose local and production
  substrates share Helm charts and manifests. An off-the-shelf platform defeats the
  parity guarantee that is the point. k3d is itself the off-the-shelf choice at the
  substrate layer — the sanctioned local equivalent of production k3s.
- **Longhorn locally via a custom node image or a VM with `open-iscsi`.** Rejected as
  the default in favor of `local-path` (`research.md` decision 1): reversible, needs
  no custom image or VM, and matches the existing parity-seam pattern (production
  keeps Longhorn; only the dev overlay differs). The custom-image/VM path stays
  available for a later cycle that wants Longhorn parity locally.
- **`/etc/hosts` or `*.localhost` for local DNS.** Rejected in favor of `*.nip.io`
  (`research.md` decision 2): no host-file edits, no root, resolves arbitrary
  subdomains, and matches the subdomain-shaped host overrides the committed gestalt
  already assumes.
- **Importing the local CA into the host trust store (or mkcert).** Rejected in favor
  of `curl -k` on probes (`research.md` decision 3): a per-probe flag that leaves the
  host untouched, vs. mutating system trust. CA-import stays an opt-in for an operator
  who wants a green browser lock.
- **A separate local bats suite instead of fixing the committed gestalt.** Rejected
  in favor of fixing `tests/agrippa.bats` in place (`research.md` decision 5):
  `DEVELOPMENT.md` prescribes one suite per feature, the file's own header says its
  targets are overridable "so the same test can run against a local K3d ingress," and
  a parallel suite would duplicate probes and drift.
- **Building the workloads as GitHub Pages statics and pointing the cluster at them
  externally.** Rejected: it would not exercise the in-cluster request path (Istio
  Gateway → HTTPRoute → pod) that is the platform's contract, and the new requirement
  is to actually run the workloads inside k3d.

## Summary

This project builds Agrippa's local k3d development environment: the cross-cutting
prerequisites (mise + test harness) and the GitOps spine first, then storage, then
the platform services and observability in parallel, then the real workloads.
Roadmap items 1-9 are the feature-steps; item 10 (Platform LLM / DavidBot) is out of
scope. The Closing Bell (`closing-bell.md`) fixes "done" as a human usability study;
`tests/agrippa.bats` is its automated backstop. All eight of `research.md`'s
long-loop-reviewer decisions are treated as settled inputs.

### Deferred decisions (park to `TASKS.md` at cleanup)

- **Production substrate** (Terraform, cloud-init, DigitalOcean node pools, GPU
  pool), the **Cloudflare edge** (Tunnel, Access, public DNS, public ACME), the
  **terraform/tflint mise pins and `test:tf` lane**, **off-cluster S3 DR**, and
  **Rook-Ceph** — all deferred to the cloud cycle, seams preserved.
- **Longhorn-on-k3d parity** (custom node image / VM) — deferred; `local-path` is the
  dev default.
- **Testing-harness open items folded in from the orphaned `TASK-NOTES-testing-harness`
  citation** (`research.md` decision 7): the bootstrap-ordering trigger (resolved as
  the manual bootstrap boundary, decision 8) and snapshot-test breadth. The cloud/policy
  items (kyverno, terraform-apply e2e) and the whole synthetic-monitoring note defer
  with the cloud cycle. Recommend repointing or dropping the two dangling `TASKS.md`
  citations (`TASK-NOTES-testing-harness.md`, `prober-synthetic-monitoring.md`) — they
  name files that do not exist.
- **Trips' Cloudflare Access → Terraform port** and **Trips' CI → Forgejo Actions
  port** — prod / post-git-hosting concerns, deferred for the local build.

### Resolved by the long-loop reviewer (2026-07-06)

Each open item below (the former *Open Items* and *Open Artifact Decisions* slots,
merged and de-duplicated) was researched against the repo, the in-repo contracts
(`ARCHITECTURE.html`, `ROUTING.md`, `DEVELOPMENT.md`), the committed
`tests/agrippa.bats` and `closing-bell.md`, the two real workload repositories via
`gh`, and the already-cleared `research.md` decisions, then decided to the
conservative default. No escalation trigger (irreversible, out of recorded scope, or
underdetermined) fired for any item, so this design's draft gate is cleared.

**1. agathon and ailly.dev source repos not inspected. Decided: concretize only
resume and trips now; scope agathon and ailly.dev out of this project's build,
keeping them as Workloads-step roadmap seams for a later cycle.** Inspected both via
`gh`: `davidsouther/agathon` is a **private TypeScript** repo (not the public resume
repo the body assumed, and not a static export), and `ROUTING.md` records it "gains
its own per-user DB" with its GitOps source/secret profile flagged **unverified**;
`davidsouther/ailly` (ailly.dev) is a distinct **public TypeScript product** ("Your AI
Writing Ally") on its own apex domain whose build/runtime shape was not inspected.
Neither is named in the Closing Bell's critical workload tasks (tasks 2 and 3 cover
only the personal site + `/blog` and trips), so deferring them does not move the
project's definition of done. agathon in particular is a dynamic, DB-backed,
privately-sourced app whose local deployment cannot be responsibly designed without
its own per-component research (the `research:` step each feature-step still owes) —
designing it now would be underdetermined, whereas deferring it is a determined,
reversible narrowing the design itself offers as a sanctioned resolution ("scope them
out of this project explicitly"). The roadmap seam is preserved: a later cycle, or the
Workloads step's own design, can add them once their repos are inspected. Reversible,
and inside the artifact's recorded scope (the design already flags them open).

**2. Where the workload container image + Helm chart live (and how upstream source
arrives). Decided: author each workload's image build and Helm chart in the `agrippa`
repo (`charts/resume/`, `charts/trips/`), build the image locally and `k3d image
import` the tag the chart pins, and bring upstream source in as a git submodule under
a `workloads/` build context; leave the resume and trips repos untouched.** This
accepts the design's own proposal and matches `DEVELOPMENT.md`'s repo layout
(`charts/<chart>/`, with `charts/<chart>/tests/` for helm-unittest). Authoring in
`agrippa` lets this project own the deployment end-to-end for the local build with no
external registry, keeps the two workload repos (one public, one private) unchanged,
and preserves the parity seam: the cloud cycle can later push the same image to the
Forgejo registry or GHCR, or upstream a shared `Dockerfile`/chart, without reworking
the local path. A git submodule reads real, current upstream source rather than a
vendored copy (the design's stated intent); the exact source-vending mechanism
(submodule vs pinned checkout) settles in the Workloads feature-step. Reversible
(upstreaming stays available) and in scope.

**3. Local trips gating (gestalt dev branch). Decided: serve local trips publicly and
assert plain reachability in the `ENV=dev` gestalt branch; do not gate it behind
Keycloak/OIDC.** Production gates trips at the **Cloudflare Access edge (Tier-1)**,
which has no local equivalent (`research.md` and this design both state edge auth
happens before traffic reaches the cluster). Keycloak/OIDC is **not** what production
uses for trips, so gating local trips behind Keycloak would invent a scheme that
exists nowhere rather than preserve parity, and it would add a hard Workloads→Auth
dependency for trips. Plain reachability is the minimal, conservative default: it keeps
Closing Bell critical task 3 (a trip itinerary renders in a browser, with no auth step
in the human study) unblocked, and lets the gestalt's trips dev branch assert local
reachability with `curl -k` (`research.md` decision 3) in place of the absent
Cloudflare Access 302. The Workloads feature-step may layer OIDC gating later if it
wants a local auth demonstration; nothing here forecloses it. Reversible, and in scope
(this is the exact dev-mode assertion `research.md` decision 5 left to the Design
phase).

**4. Personal-site `/healthz` mechanism. Decided: serve `/healthz` from an nginx
`location /healthz { return 200; }` in the `agrippa` chart's serving layer; do not add
a `public/healthz` file to the resume repo.** The committed gestalt probes
`davidsouther.com/healthz` for a 2xx within 1s (`tests/agrippa.bats` lines 42-48), but
a jiffies static export serves 404 there by default. An nginx `return 200` satisfies
the probe, keeps the change inside this project's chart, and leaves the resume repo
untouched — consistent with decision 2's "author packaging in `agrippa`, leave the
workload repos unchanged." Reversible (swap to a committed static file later if the
serving layer changes) and in scope.

**5. App-of-apps directory names and the `mise` bootstrap task name. Decided: use the
five `ARCHITECTURE.html` layer names verbatim (`core`, `storage`, `platform`,
`observability`, `workloads`) with the `overlays/dev` vs `overlays/prod` split, name
the bootstrap task `bootstrap` (`research.md` decision 8), and settle the exact path
spelling (`apps/core` vs `core`, chart vs app directories) in the GitOps feature-step's
own design.** Confirmed against `ARCHITECTURE.html`, which uses exactly those five
layer names and references `overlays/dev`/`overlays/prod`. Following the authoritative
Prior Art verbatim is the conservative default; the app-of-apps layout is itself a
shared contract the Specification assigns to the GitOps step to settle, so fixing the
names here and deferring the exact directory paths there matches the design's own
decomposition. Reversible and in scope.

**6. Local dev hostname shape. Decided: mirror each production hostname as
`<prod-host>.127.0.0.1.nip.io` (for example `davidsouther.com.127.0.0.1.nip.io`,
`trips.davidsouther.com.127.0.0.1.nip.io`, `dashboard.davidsouther.com.127.0.0.1.nip.io`),
reached through the k3d gateway port-map; settle the exact pattern in the Networking
feature-step.** `research.md` decision 2 already fixed `*.nip.io` + loopback + the k3d
`443:443@loadbalancer` port-map as the local DNS/ingress scheme. Mirroring the
production host as a `.127.0.0.1.nip.io` suffix makes the committed gestalt's
`PUBLIC_HOST`/`TRIPS_HOST`/`DASHBOARD_HOST` overrides read naturally and keeps each dev
host one substitution away from its prod host, aiding parity. The Networking step owns
the Gateway/HTTPRoute/hostname shared contract, so the exact spelling settles there.
Reversible and in scope.

*No new executable feature test is written for this Project-Shape design: the Closing
Bell (`closing-bell.md`) fills that slot, and `tests/agrippa.bats` is its automated
backstop, fixed during the Workloads feature-step.*
