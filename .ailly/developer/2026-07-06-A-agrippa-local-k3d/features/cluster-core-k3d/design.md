# Feature Design: Cluster core (local k3d substrate)

*Reviewed 2026-07-06*

> A separately dispatched long-loop reviewer cleared this feature design's draft
> gate on 2026-07-06. Its four Open Artifact Decisions are resolved to the
> conservative default in the *Resolved by the long-loop reviewer* block under
> Summary; no escalation trigger fired.
>
> Feature-step design (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is Feature 1 of that project's plan:
> the local k3d substrate every later feature-step (GitOps, Networking, Storage,
> the platform services, and Workloads) builds on. It has its own feature test
> (recorded below). The project as a whole is measured by `closing-bell.md`, not
> by this test.

## Libraries & Skills (carry forward to plan and build)

Per the project's cleared `research.md` (Libraries & Skills) and `design.md`, the
plan and build phases MUST load these skills via the harness's skill-loading
mechanism before working:

- **`developer:initialize`** for any residual tool or `mise` question (this feature
  adds `cluster:up`/`cluster:down` tasks to the Step 0 `mise.toml`).
- **`research:public`** and **`research:codebase`** for any per-tool detail the
  build hits (a k3d config field, a metallb-vs-ServiceLB nuance).

**No library-shipped agentic skill exists for k3d, k3s, or metallb.** The project
research recorded a deliberate check. Build to the in-repo contracts instead:
`ARCHITECTURE.html` (Cluster Core layer, Environments table) and `README.md` fix
that dev uses metallb in place of cloudflared and that local is the same Helm charts
and manifests as production. `DEVELOPMENT.md` fixes the test tooling and repo layout.

## Purpose

Stand up the local k3d cluster that is the k3d-only equivalent of roadmap item 1
(Cluster core). It replaces the production cloud-init / Terraform / DigitalOcean node
provisioning, which is cloud-only and out of scope for this project, with a single
k3s node running as Docker containers on the operator's laptop. The deliverable is a
committed k3d cluster definition plus `mise` create and destroy tasks, so an operator
gets the same working substrate on any machine with one command, and every later
feature-step has a real cluster to reconcile into.

The value here is narrow but load-bearing: a cluster on its own serves no user, but
nothing else in the project can exist without it. What this step must get right is the
substrate shape the rest of the platform assumes: a single node sized for a laptop, no
GPU pool, and the two default k3s components that would fight this platform's own
choices (ServiceLB and Traefik) turned off, plus a host port-map so `https://<host>`
can reach the Istio Gateway once Networking lands.

Out of scope, kept as seams for the deferred cloud cycle: cloud-init, Terraform, the
DigitalOcean node pools, the `elastic-node-pool` autoscaling seam, and the scale-to-zero
GPU pool. metallb is logically part of this Cluster Core concern but is delivered by the
GitOps bootstrap at a sync-wave, not by this step's cluster-create (see Specification).

## Prior Art

- **`tests/preflight.bats`.** The committed preflight check already stands up and tears
  down a throwaway k3d cluster (`agrippa-preflight`) on this machine and gates Docker
  sizing (4 CPU / 8GB). Its `wait_for_node_ready` helper and its k3d up/down shape are
  the direct model for this step's `cluster:up` task and feature test. This step turns
  that throwaway one-off into a named, committed, long-lived cluster definition.
- **Step 0 `mise.toml` (Feature 0).** Pins k3d 5.9.0, kubectl 1.36.2, helm 4.2.2, bats
  1.13.0, and defines the `test:*` task family and the empty-safe conventions this step
  extends. The `test:feature` task already creates its own throwaway `agrippa-feature`
  cluster; this step's cluster is a separate, persistent one.
- **`ARCHITECTURE.html` (Cluster Core layer) and `README.md` (Environments).** Fix that
  the Cluster Core layer is `k3s` + `cloud-init` + `istio` + `cloudflared` + `metallb`
  in production, and that Development (K3d) is "the same Helm charts and manifests;
  metallb replaces cloudflared for local LoadBalancer IPs; no GPU pool; reduced-replica
  overlay." This step realizes the k3s substrate and the ServiceLB-off seam metallb needs.
- **The project `research.md` (§ k3d substrate and load balancing; Resolved decisions 2
  and 8).** k3d ships Traefik + ServiceLB by default; metallb and ServiceLB conflict, so
  ServiceLB is disabled; on macOS the in-Docker metallb IP is not host-routable, so a k3d
  loadbalancer host port-map carries host `:443` to the gateway; and the manual bootstrap
  boundary keeps the imperative surface minimal (decision 8), with metallb moving under
  GitOps at a sync-wave.
- **k3d's own config schema (`k3d.io/v1alpha5`, kind `Simple`).** The declarative form for
  server/agent counts, port mappings, and k3s `extraArgs` with node filters, used verbatim.

## User Journey and Metrics

**The operator's flow, from a clean checkout on macOS with Docker running and the Step 0
toolchain installed:**

1. `mise run cluster:up` reads `k3d/agrippa-dev.yaml` and creates the `agrippa-dev`
   cluster: one server node, no agents, ServiceLB and Traefik disabled, host ports 80 and
   443 published through the k3d loadbalancer. It is idempotent: re-running against an
   existing cluster just ensures it is started, and points `kubectl` at the
   `k3d-agrippa-dev` context.
2. The operator (and every later feature-step) now has a Ready single node to install
   ArgoCD, Istio, storage, and workloads into. `kubectl --context k3d-agrippa-dev get
   nodes` shows `Ready`.
3. `mise run cluster:down` deletes the cluster cleanly when the operator is finished for
   the day, reclaiming the Docker resources.

**Metrics / measures of done for this feature-step:**

- The feature test (`tests/cluster-core.bats`) is green: `mise run cluster:up` yields a
  Ready `agrippa-dev` node with ServiceLB and Traefik disabled and host `:443` published.
- `cluster:up` is idempotent: a second run does not error and does not recreate the
  cluster (verified during design).
- The cluster comes up inside the 120s k3d wait timeout on a laptop meeting the preflight
  bar (4 CPU / 8GB). On this machine it created in about 14s.
- Adding this step does not regress the Step 0 harness: `mise run test:push` and
  `bats tests/harness.bats` stay green (verified during design).

**Failure modes to design against.** A host process already holding `:80` or `:443` makes
`cluster:up` fail to publish the port-map (checked free during design; report as blocked,
do not silently drop the mapping). ServiceLB left enabled would race metallb for
LoadBalancer IPs; Traefik left enabled would compete with the Istio Gateway for `:80`/`:443`;
both are disabled at the k3s layer so neither can. A non-idempotent `cluster:up` that
errors on re-run, or that recreates and wipes a running cluster, would break the "leave it
running" contract later steps rely on; the task guards existence before creating.

## Specification

### `k3d/agrippa-dev.yaml`, the cluster definition

A `k3d.io/v1alpha5` `Simple` config, `metadata.name: agrippa-dev`:

- **`servers: 1`, `agents: 0`.** A single node sized for a laptop dev box. k3s schedules
  workloads on the server node, so no separate agent is needed for the reduced-replica dev
  overlay. **No GPU pool** (production-only).
- **`options.k3s.extraArgs`: `--disable=servicelb` and `--disable=traefik`,** each with
  `nodeFilters: ["server:*"]`. ServiceLB off so metallb owns LoadBalancer IPs with no
  conflict; Traefik off so the Istio Gateway is the sole ingress. Verified at runtime: the
  server container command carries both `--disable=` args, and kube-system comes up with
  coredns, local-path-provisioner, and metrics-server only (no traefik, no svclb).
- **`ports`: `80:80` and `443:443`, `nodeFilters: ["loadbalancer"]`.** Published through
  the k3d loadbalancer proxy, which is a separate proxy from the disabled ServiceLB. On
  macOS the in-Docker metallb IP is not host-routable, so this port-map is how host `:443`
  reaches the Istio Gateway once Networking lands. Port 80 is mapped alongside 443 for the
  conventional HTTP-to-HTTPS redirect; the project design named 443 explicitly and left 80
  implicit (recorded under Open Artifact Decisions).
- **`image: rancher/k3s:v1.35.5-k3s1`.** The k3s image pinned to the k3d 5.9.0 default, so
  the cluster is reproducible across k3d binary upgrades. Derived from the pinned k3d
  version; revisable when the pin moves.

### `mise` tasks (added to the Step 0 `mise.toml`)

- **`cluster:up`.** If `agrippa-dev` already exists, ensure it is started (idempotent
  re-run, no recreate); otherwise `k3d cluster create --config k3d/agrippa-dev.yaml`. Then
  point `kubectl` at the `k3d-agrippa-dev` context. This is the operator's one command to
  get the substrate, and the one the feature test drives.
- **`cluster:down`.** `k3d cluster delete agrippa-dev`.

These are namespaced (`cluster:*`) like `test:*`, and are deliberately distinct from the
project-level `bootstrap` task (Feature 2, GitOps: creates the `sops-age` Secret and applies
the root app-of-apps) and the eventual `mise run up` full-platform path named in the project
design's Release Flag. This step owns only the substrate, not what runs on it.

### metallb boundary (deferred to GitOps, not built here)

Per `research.md` decision 8 and the project design's Cluster core nuance, the hand-created
surface is kept minimal: this step creates only the k3d cluster with ServiceLB and Traefik
disabled and the port-map. metallb and its `IPAddressPool` (scoped to the k3d Docker-network
subnet) are declared part of the Cluster Core concern but are reconciled by ArgoCD at a
sync-wave in the GitOps feature-step. If a chicken-and-egg surfaces during the GitOps build,
metallb moves into the manual `bootstrap` task with no rework here. Consequently the feature
test asserts only what `cluster:up` delivers and does not assert metallb.

### Cross-step touch (Feature 0 `test:feature`)

`test:feature` auto-discovers `tests/*.bats` component probes, excluding the cross-cutting
suites (`agrippa.bats`, `harness.bats`, `preflight.bats`). This step adds `cluster-core.bats`
to that exclusion list, for the same reason `preflight.bats` is excluded: it drives
`cluster:up`/`cluster:down` against the long-lived `agrippa-dev` cluster, not the throwaway
`agrippa-feature` cluster `test:feature` stands up. This is a one-line, convention-consistent
edit to the Step 0 task.

### Challenges

- **Idempotency without data loss.** `cluster:up` must be safe to re-run (later steps and the
  feature test call it repeatedly), so it guards `k3d cluster list agrippa-dev` before
  creating and never recreates an existing cluster.
- **Host port binding.** `:80`/`:443` must be free on the host for the port-map to publish.
  Checked free during design; a bound port is a report-as-blocked condition, not a silent
  fallback.
- **Substrate parity, not identity.** Local pins k3s to the k3d default image for
  reproducibility rather than to production's exact k3s version, which is a separate
  cloud-cycle concern. The seam (an overlay/config value) is preserved.

## Alternatives

- **A throwaway cluster per session (reuse `test:feature`'s `agrippa-feature` pattern)
  instead of a named persistent cluster.** Rejected. Later feature-steps are dispatched in
  isolation and each needs the same running cluster; a per-invocation throwaway would force
  every step to rebuild the whole platform from scratch. A named, committed definition is
  what "leave it running" requires.
- **A multi-node k3d cluster (extra agents) to mirror production's multiple nodes.**
  Rejected for the laptop dev box. The dev overlay is reduced-replica and single-node is the
  lightest footprint that still runs the full platform; multi-node parity is a cloud-cycle
  concern. Adding agents later is a two-line config change.
- **Raw `k3d cluster create` flags in the mise task instead of a config file.** Rejected.
  A committed `k3d.io/v1alpha5` config is declarative, reviewable, diffable, and the k3d-native
  way to pin server/agent counts, port-maps, and k3s args; a long flag string in a shell task
  is harder to read and to keep in sync with production's config shape.
- **Leaving ServiceLB or Traefik enabled and working around the conflict.** Rejected on the
  research: metallb and ServiceLB both try to own external IPs and conflict, and Traefik is
  redundant to the Istio Gateway. Disabling both at cluster-create is the clean substrate.

## Summary

This feature-step lands `k3d/agrippa-dev.yaml` (a single-node, GPU-free, ServiceLB-and-
Traefik-disabled k3d cluster with host `:80`/`:443` published through the k3d loadbalancer),
the `cluster:up` and `cluster:down` mise tasks, and a one-line exclusion of the new feature
test from Feature 0's `test:feature` auto-discovery. metallb is deferred to the GitOps
bootstrap per research decision 8. The one feature test asserts the operator's `cluster:up`
experience end-to-end.

Because later feature-steps are dispatched in isolation and depend on the cluster existing,
this Design-phase run also stood the cluster up and left it running. The feature test's RED
baseline was captured first (before the config and tasks existed, `mise run cluster:up`
errored with "no such task"); after this step's substrate landed, the test is GREEN and the
`agrippa-dev` cluster is left running.

### Resolved by the long-loop reviewer (2026-07-06)

Each Open Artifact Decision below was researched against the repo working tree, the in-repo
contracts (`DEVELOPMENT.md`'s repo-layout list, the `ARCHITECTURE.html`/`README.md`
Environments table), the project's already-cleared `research.md` (decisions 2 and 8) and
`design.md` (the Cluster core step, the Release Flag, and decisions 5-6), the committed k3d
naming family in `tests/preflight.bats` and the Step 0 `mise.toml`, and the artifacts this
Design-phase run already materialized (`k3d/agrippa-dev.yaml`, the `cluster:*` tasks in
`mise.toml`, `tests/cluster-core.bats`), then decided to the conservative default. No
escalation trigger (irreversible, out of recorded scope, or underdetermined) fired for any
item, so this feature design's draft gate is cleared. Each decision matches what the
Design-phase run already built, so none required an edit to the materialized artifacts.

**1. `k3d/agrippa-dev.yaml` (the k3d config file path). Decided: a top-level `k3d/` directory,
`k3d/agrippa-dev.yaml`.** `DEVELOPMENT.md`'s repo-layout list is authoritative for the dirs it
names (`apps/`, `charts/`, `tests/`, `terraform/`, `mise.toml`) but is silent on k3d configs,
so no existing convention is contradicted. A top-level `k3d/` is the k3d-native, discoverable
home for a `k3d.io/v1alpha5` config; it reads better than a hidden `.k3d/`, which would obscure
the reviewable, diffable declarative artifact the Alternatives section deliberately chose over a
flag string, and it avoids overloading an unclaimed `deploy/` that would imply a broader deploy
tree this step does not own. Fully reversible: relocating the file is a one-line edit to the
`cluster:up` task's `CONFIG` variable. In scope and determined by convention, so no trigger
fired.

**2. Cluster name `agrippa-dev`. Decided: `agrippa-dev`.** The step prompt said "`agrippa-dev`
or similar," making the exact name the reviewer's to settle within a recorded range. It matches
the committed k3d naming family (`agrippa-preflight` in `tests/preflight.bats`, `agrippa-feature`
in the Step 0 `test:feature` task) and the `<project>-<env>` shape, where "dev" is exactly how
`README.md` and `ARCHITECTURE.html` label the local environment ("Development (K3d)"). The
derived kube-context `k3d-agrippa-dev` that the tasks and feature test key on follows from it.
Reversible (a rename touches the config, both tasks, and the test in lockstep), in scope, and
determined, so no trigger fired.

**3. mise task names `cluster:up` / `cluster:down`. Decided: `cluster:up` / `cluster:down`.**
Three repo facts pick this over the alternatives. (i) The Step 0 `mise.toml` namespaces every
task family (`test:*`), so a `cluster:*` namespace is the house style; bare `up`/`down` breaks
it. (ii) Bare `up` is already reserved: the project `design.md` Release Flag names `mise run up`
for the eventual full-platform path, so a bare `up`/`down` here would collide. (iii) `up`/`down`
describes the idempotent start-or-create / delete lifecycle better than `create`/`delete`, which
imply the one-shot semantics the `cluster:up` task deliberately is not (it guards existence and
starts an existing cluster rather than recreating). It stays distinct from Feature 2's
`bootstrap` task (project decision 5). Reversible, in scope, and determined, so no trigger fired.

**4. Host port 80 mapped alongside 443. Decided: map both `80:80` and `443:443` through the k3d
loadbalancer.** The cleared project `research.md` (decision 2) and `design.md` named
`443:443@loadbalancer` explicitly and left 80 *implicit*, not excluded, and both defer the exact
port/hostname spelling to the Networking feature-step (project decision 6), so the port set is
within this feature's recorded scope to settle. Two facts make "include 80 now" the conservative,
lowest-future-rework default rather than scope creep. (a) k3d port-maps are fixed at
cluster-create time: k3d has no command to publish an additional host port on a running cluster
(verified against k3d's exposing-services docs and issue tracker — the only options are recreate
or `kubectl port-forward`), so retrofitting `:80` later would force a `cluster:down`/`cluster:up`
that destroys the long-lived `agrippa-dev` cluster every intermediate feature-step builds state
into, directly violating this design's "leave it running" contract. (b) A `:80`-to-`:443`
HTTP-to-HTTPS redirect is the near-universal ingress convention the Networking step will want, and
the Istio Gateway conventionally listens on both. The only added cost of mapping 80 — a
`cluster:up` failure when a host process already holds `:80` — is already a recorded, checked,
report-as-blocked precondition in this design's Failure Modes, so it introduces no unhandled
surface. Provisioning the seam once, up front, is strictly lower blast radius than a future
recreate of the shared cluster, and dropping the mapping while the cluster is still fresh (it
creates in about 14s) stays cheap. In scope and reversible, so no trigger fired.

### Deferred decisions (park to `TASKS.md` at cleanup)

- **Production substrate:** cloud-init, Terraform, DigitalOcean node pools, the
  `elastic-node-pool` autoscaling seam, and the scale-to-zero GPU pool. Deferred to the
  cloud cycle; the single-node dev config is the local form and the overlay seam is preserved.
- **metallb + `IPAddressPool`:** logically Cluster Core, but delivered by the GitOps
  bootstrap at a sync-wave (research decision 8). Settled in the GitOps feature-step; may move
  into the manual `bootstrap` task if a chicken-and-egg surfaces, with no rework here.
- **k3s version parity with production:** local pins the k3d default image for reproducibility;
  matching production's exact k3s version is a cloud-cycle concern.

## Feature Test

**Path:** `tests/cluster-core.bats` (following DEVELOPMENT.md's `tests/<feature>.bats`
convention, where the feature is "cluster-core").

**User story (Given / When / Then):** *Given* a clean checkout with the Step 0 toolchain
(k3d, kubectl, docker) and a running Docker daemon, *When* an operator runs `mise run
cluster:up`, *Then* a single-node local k3d cluster named `agrippa-dev` is running with a
Ready node, with ServiceLB (Klipper) and Traefik both disabled so neither races metallb for
LoadBalancer IPs nor competes with the Istio Gateway for ingress, and with host port 443
published through the k3d loadbalancer so `https://<host>` reaches the in-cluster gateway once
Networking lands. It is one test, driving `cluster:up` and asserting the substrate end-to-end;
it deliberately does not tear the cluster down, because `agrippa-dev` is the long-lived cluster
later feature-steps build on.

**Current state: GREEN (after this step's substrate landed).** The RED baseline was captured
first: with no `k3d/agrippa-dev.yaml` and no `cluster:up` task, `mise run cluster:up` errored
with "no task cluster:up found" and the test failed at its first assertion. This is the one
feature-step where the Design-phase run also stood up the substrate, because the orchestration
requires the cluster running for the isolated feature-steps that follow; the test now passes
and the cluster is left running.
