# Feature Design: GitOps (ArgoCD app-of-apps, KSOPS/age, local bootstrap)

*Reviewed 2026-07-07*

> Feature-step design (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 2: GitOps (ArgoCD)** of that
> project's plan: the GitOps spine that reconciles every later layer (Networking,
> Storage, the platform services, Observability, Workloads) from git. It has its
> own feature test (recorded below). The project as a whole is measured by
> `closing-bell.md`, not by this test.
>
> A separately dispatched long-loop reviewer cleared this feature design's draft
> gate on 2026-07-07. Items 1-5 in the *Resolved by the long-loop reviewer* block
> under Summary are resolved to the conservative default. Item 6 was escalated (it
> turned on a project-altitude `closing-bell.md` edit outside this feature design's
> recorded scope) and has since been decided by the human project owner;
> `closing-bell.md` and this design now agree, so no escalation remains open and the
> gate is cleared.

## Libraries & Skills (carry forward to plan and build)

Per the project's cleared `research.md` (§ Libraries & Skills) and `design.md`, the
plan and build phases MUST load these skills via the harness's skill-loading
mechanism before working:

- **`developer:initialize`** — this feature adds the `bootstrap` task and new tool
  pins (`sops`, `age`, `kustomize`; the `argocd` CLI is optional) to the Step 0
  `mise.toml`.
- **`research:public`** and **`research:codebase`** — for any per-tool detail the
  build hits (a KSOPS repo-server plugin flag, an ArgoCD `Application` field, a
  `sync-wave` edge case).

**No library-shipped agentic skill exists for ArgoCD, KSOPS, SOPS, or age.** The
project research recorded a deliberate check. Build to the in-repo contracts:
`DEVELOPMENT.md` (## Secrets fixes the SOPS+age wiring and the KSOPS repo-server
init-container; ## Testing fixes the test tooling and repo layout),
`ARCHITECTURE.html` (the *Cluster Infrastructure · ArgoCD app-of-apps* view fixes
`apps/` = ArgoCD Application CRDs, "core applied manually once — then ArgoCD
reconciles all overlays", and the five layers and their components), and
`README.md` (the Cluster Infrastructure table names the five layers; ArgoCD sits in
the **Platform** layer).

## Purpose

Stand up the GitOps spine that is the k3d-only equivalent of roadmap item 4
(GitOps). It is the load-bearing local pattern: after this step, every other
layer is reconciled from git by ArgoCD, not applied by hand. Production injects the
in-cluster secrets trust root and installs ArgoCD through Terraform / cloud-init;
both are cloud-only and out of scope here, so this step replaces them with a single
`mise run bootstrap` task an operator runs once on their laptop.

The deliverable is three things working together:

1. **A minimal, hand-applied bootstrap** — the smallest imperative surface that gets
   a *decrypting* ArgoCD running (research decision 8): the `sops-age` Secret, ArgoCD
   with its KSOPS-enabled repo-server, then the root app-of-apps applied once.
   Everything after is ArgoCD-reconciled.
2. **The KSOPS/age trust root for the dev environment** — a `mise run bootstrap` task
   that creates the `sops-age` Secret in the `argocd` namespace from the Bitwarden
   item `agrippa-age-dev`, in place of Terraform's injection (research decision 4),
   plus the repo-server init-container that lets KSOPS decrypt sops-encrypted
   manifests during `kustomize build`.
3. **The app-of-apps skeleton** — a self-managing root `Application` and one child
   `Application` per layer (`core`, `storage`, `platform`, `observability`,
   `workloads`), carrying the `sync-wave` ordering contract, **ready to receive**
   each later feature-step's manifests and charts.

The value is narrow but load-bearing: no user visits a URL because ArgoCD exists, but
nothing else in the project reaches a cluster without it, and the whole parity claim
(the same charts and manifests as production, driven by the same GitOps spine) is
what this step proves locally.

Out of scope, kept as seams for the deferred cloud cycle: Terraform / cloud-init
injection of `sops-age`, the `overlays/prod` environment, ExternalDNS and
cloudflared (declared in the `core` layer but scoped out of `overlays/dev`), and the
public-DNS ingress for the ArgoCD UI (reached locally by `kubectl port-forward`
until Networking lands).

## Prior Art

- **`DEVELOPMENT.md` § Secrets** is the authoritative contract for this step. It
  fixes: `.sops.yaml` at the repo root, path-scoped per environment
  (`secrets/prod/.*` vs `secrets/dev/.*`); the `age` private key custody in Bitwarden
  as `agrippa-age-<env>`, pulled with `bw unlock` then `bw get notes`, never a
  standing local file and never committed; the injected `sops-age` Secret in the
  `argocd` namespace as "the whole in-cluster trust root"; and the repo-server
  init-container installing `sops`/`kustomize`/`ksops` with the `sops-age` volume
  mount so KSOPS decrypts during `kustomize build`, transparently to every downstream
  Application. This step realizes that wiring for `dev`, with the `mise` task standing
  in for the Terraform injection the doc describes for production.
- **`ARCHITECTURE.html`, the app-of-apps view.** States verbatim: `apps/` = ArgoCD
  Application CRDs; "🚀 ArgoCD root app-of-apps · manages itself ▼ syncs each layer to
  the cluster"; "🥾 core applied manually once — then ArgoCD reconciles all overlays:
  dev (metallb, reduced replicas) · prod"; and the five layers with their components
  (core: cert-manager/external-dns/cloudflared/istio; storage: longhorn/postgres/
  valkey; platform: keycloak/flagsmith/forgejo/argocd/…; observability: loki/grafana/
  tempo/mimir; workloads). This step builds exactly that skeleton.
- **`README.md` Cluster Infrastructure table.** Names the five layers (Workloads,
  Platform, Observability, Storage, Cluster Core) and places **ArgoCD in the Platform
  layer** — which fixes where ArgoCD's own install is reconciled from once it is
  self-managed.
- **The project `research.md` (decisions 4 and 8).** Decision 4: the `mise` bootstrap
  task creates `sops-age` from `agrippa-age-dev` before ArgoCD's first sync. Decision
  8: the manual bootstrap boundary is "k3d cluster create, the `sops-age` Secret,
  ArgoCD itself with its KSOPS-enabled repo-server, then the root app-of-apps applied
  once"; `ServerSideApply=true` and `SkipDryRunOnMissingResource=true` for large CRD
  sets; metallb and the Gateway API CRDs move under ArgoCD at a sync-wave (metallb may
  move into the manual step if a chicken-and-egg surfaces, with no rework elsewhere).
- **Feature 1 (`cluster-core-k3d`).** Left the long-lived `agrippa-dev` k3d cluster
  running (context `k3d-agrippa-dev`) with ServiceLB and Traefik disabled and host
  `:443` published — the substrate this step installs ArgoCD into. This step's feature
  test, like `cluster-core.bats`, drives the long-lived cluster and does **not** tear
  it down.
- **Feature 0 (`step0-mise-testing-harness`) `mise.toml`.** Provides the `test:*`
  task family, the `cluster:up`/`cluster:down` tasks (added by Feature 1), the
  namespaced `<group>:<verb>` house style, the plaintext-`Secret` conftest guard
  (`tests/policy/secrets.rego`, which already allows a sops-encrypted Secret and denies
  a plaintext one), and the `test:feature` auto-discovery this step extends.

## User Journey and Metrics

**The operator's flow, from the running `agrippa-dev` cluster (Feature 1) with the
Step 0 toolchain installed and an unlocked Bitwarden session:**

1. `mise run bootstrap` (a) reads the `agrippa-age-dev` `age` private key from
   Bitwarden (`bw get notes agrippa-age-dev`) and creates the `sops-age` Secret in a
   freshly-created `argocd` namespace; (b) installs ArgoCD with the KSOPS-enabled
   repo-server (init-container + `sops-age` volume); (c) applies the root app-of-apps
   once. It is idempotent: re-running against an already-bootstrapped cluster
   re-asserts the same state without error.
2. ArgoCD reconciles itself and the five layer skeleton. The operator runs
   `kubectl -n argocd get applications` and sees the root app **Synced/Healthy** and
   the five layer Applications registered, ready to receive later steps' manifests.
3. Until Networking lands ingress, the operator reaches the ArgoCD UI with
   `kubectl -n argocd port-forward svc/argocd-server 8080:443` and the initial admin
   password from the `argocd-initial-admin-secret`.
4. Every later feature-step now delivers its layer by committing manifests/charts
   under that layer's source path; nothing else is applied by hand.

**Metrics / measures of done for this feature-step:**

- The feature test (`tests/gitops.bats`) is green: `mise run bootstrap` yields a
  `sops-age` Secret, a KSOPS-wired repo-server, a Synced/Healthy root app-of-apps, and
  the five registered layer Applications.
- `bootstrap` is idempotent: a second run does not error and does not duplicate or
  wipe ArgoCD (the crux of "one command, safe to re-run").
- The bootstrap decrypts: a committed sops-encrypted Secret in a layer path renders
  to plaintext at sync time via KSOPS, and the plaintext-`Secret` conftest guard stays
  green because nothing plaintext is committed.
- Adding this step does not regress earlier harness: `mise run test:push`,
  `bats tests/harness.bats`, and `bats tests/cluster-core.bats` stay green.

**Failure modes to design against.**

- **Bitwarden locked or unavailable.** The `age` key lives only in Bitwarden
  (`agrippa-age-dev`), never as a committed or standing local file. If `bw` is not
  installed, not logged in, or the vault is locked, `bootstrap` **fails loudly with a
  clear message and a non-zero exit** — it does **not** invent a plaintext key, write
  a key into git, or fake success. This is a report-as-blocked condition for a human
  to resolve (`bw unlock`), mirroring the "Docker sizing / Bitwarden unlock is a human
  grant" boundary the session operates under.
- **`agrippa-age-dev` does not yet exist in Bitwarden.** The dev `age` keypair is a
  one-time custody artifact (`age-keygen`, private key stored as `agrippa-age-dev`,
  public recipient committed to `.sops.yaml`). If the item is absent, that generation
  is a **human prerequisite** the build phase surfaces as a blocker, not something the
  task fabricates.
- **A CR syncing before its CRD.** cert-manager, Gateway API, and Istio ship CRDs that
  later resources reference. The sync-wave contract (below) orders CRDs before the
  resources that use them; `SkipDryRunOnMissingResource=true` and
  `ServerSideApply=true` keep large CRD applies from failing the first dry run.
- **A half-built layer reachable on the release path.** Handled by the project
  Release Flag's ship-dark rule: a layer whose content would be operator-reachable
  before its step lands is excluded from the `overlays/dev` root; the empty skeleton
  Application (which deploys nothing) is not reachable and may register Synced/Healthy.

## Specification

### The manual bootstrap boundary (research decision 8)

The hand-applied surface is kept to the minimum that gets a *decrypting* ArgoCD
running, and no more:

1. **The `argocd` namespace and the `sops-age` Secret** (the trust root).
2. **ArgoCD itself, with its KSOPS-enabled repo-server** (init-container installing
   `sops`/`kustomize`/`ksops` + the `sops-age` volume mount, per `DEVELOPMENT.md`).
3. **The root app-of-apps, applied once.**

metallb, the Gateway API CRDs, cert-manager, Istio, storage, the platform services,
observability, and workloads all move under ArgoCD at their sync-waves. If a
chicken-and-egg surfaces at build (metallb needed before ArgoCD can pull an image on a
LoadBalancer IP), metallb moves into the manual step with no rework elsewhere — the
port-map from Feature 1 makes this unlikely locally, since image pulls use the
node's own network, not a LoadBalancer IP.

### The `bootstrap` mise task

Added to the Step 0 `mise.toml`, namespaced consistently with the house style, and
kept distinct from Feature 1's `cluster:up`/`cluster:down` and from the eventual
`mise run up` full-platform path named in the project Release Flag. Its shape:

```text
mise run bootstrap   # once, after `mise run cluster:up`, with Bitwarden unlocked
```

Steps, all idempotent and fail-loud:

1. Require `bw` present and unlocked; read `agrippa-age-dev` (`bw get notes
   agrippa-age-dev`) into memory only. On any failure, exit non-zero with a message
   naming the missing prerequisite. **No plaintext fallback, no committed key.**
2. `kubectl create namespace argocd` (idempotent), then create/replace the `sops-age`
   Secret in it from the key read in step 1. The key is never written to disk.
3. Install ArgoCD (pinned version) with the KSOPS repo-server patch applied — from the
   ArgoCD install kustomization at its GitOps home (see below), so the same source
   later self-manages. `--wait` for ArgoCD to become ready.
4. Apply the root app-of-apps once (`kubectl apply -k apps` — the target the Step 0
   `test:feature` already assumes). ArgoCD takes over from there.

### KSOPS / age wiring for `dev`

- **`.sops.yaml`** at the repo root (introduced by this step, per `DEVELOPMENT.md`
  § Secrets): a path rule scoping `secrets/dev/.*` to the dev `age` recipient (the
  public key, committed). The `secrets/prod/.*` rule and prod recipient are a seam,
  added with the cloud cycle.
- **The `sops-age` Secret** in `argocd`, holding the dev `age` **private** key, is the
  only decryption root in-cluster. Created by `bootstrap` from Bitwarden; never in git.
- **The repo-server** carries the KSOPS init-container (installing `sops`, `kustomize`,
  `ksops`) and mounts `sops-age`, so any layer's sops-encrypted manifest (e.g. a future
  `secrets/dev/postgres.enc.yaml` referenced by a kustomization) decrypts at
  `kustomize build` time, transparently to every Application. The committed
  plaintext-`Secret` conftest guard (`tests/policy/secrets.rego`) already permits the
  sops-encrypted form and denies plaintext, so this wiring and the guard agree.

### The app-of-apps skeleton (the shared contract this step defines)

Fixed by `ARCHITECTURE.html` (`apps/` = ArgoCD Application CRDs) and the Step 0
`mise.toml` (which globs `apps/` in `test:static` and applies `kubectl apply -k apps`
in `test:feature`). Concretely:

```text
apps/
  kustomization.yaml       # lists the root + layer Applications; `bootstrap` applies this once
  root.yaml                # the root app-of-apps Application: source = apps/, manages itself + children
  core.yaml                # layer Application, sync-wave 0   (metallb, Gateway API CRDs, cert-manager, istio)
  storage.yaml             # layer Application, sync-wave 1   (postgres, valkey; longhorn declared, dev-excluded)
  platform.yaml            # layer Application, sync-wave 2   (argocd self-mgmt, keycloak, forgejo, flagsmith)
  observability.yaml       # layer Application, sync-wave 3   (loki, grafana, tempo, mimir, alloy)
  workloads.yaml           # layer Application, sync-wave 4   (resume, trips)
```

Each layer `Application` is an empty-but-valid skeleton now (its `source.path` starts
empty or placeholder-only) and is **ready to receive** its feature-step's content.
Helm charts live in `charts/<component>/` (per `DEVELOPMENT.md` repo layout);
kustomize sources live under each layer's path; the `Application` in `apps/` references
one or the other. This resolves the project design's deferred "`apps/core` vs `core`,
chart vs app directories" spelling: **Applications in `apps/<layer>.yaml`; charts in
`charts/`; the two are referenced, not conflated.**

**Overlay selection and ship-dark.** `overlays/dev` is the environment this project
targets; `overlays/prod` is a seam. The dev-vs-prod choice is carried by each
Application's `source.path` (a `<layer>/overlays/dev` overlay the later step provides).
The five layer-group Applications are the **skeleton** and exist from this step, each
pointing at an empty-but-valid kustomization (zero resources → Synced/Healthy, which
keeps the root app Healthy). Ship-dark (project Release Flag) operates one level down:
a component whose half-built content would be operator-reachable is left out of its
layer's kustomization until its step lands, so the empty layer Application deploys
nothing reachable in the meantime. This resolves the apparent tension between "the
five-group skeleton exists now" and the Release Flag's "ships dark" — the skeleton is
the layer Applications; ship-dark governs their reachable *content*.

**Sync-wave contract** (the ordering every GitOps-managed step consumes, per research
decision 8 and ArgoCD's sync-waves): layers sync in ascending `sync-wave` order
`core(0) → storage(1) → platform(2) → observability(3) → workloads(4)`; **within** a
layer, its own feature-step assigns finer waves so CRDs (low/negative) precede
controllers precede custom resources. `ServerSideApply=true` and
`SkipDryRunOnMissingResource=true` are set on Applications carrying large CRD sets. The
exact integers are a starting scheme, refinable as layers land (Open Artifact
Decisions).

### ArgoCD self-management

ArgoCD is a **Platform-layer** component (`README.md`). Its install kustomization lives
at its GitOps home (proposed `apps/platform/argocd/`, an Open Artifact Decision): the
`bootstrap` task applies it once, and a thin argocd `Application` (shipped by this step,
inside the platform layer) reconciles that same path thereafter — giving the "manages
itself" property `ARCHITECTURE.html` names. The rest of the platform layer
(Keycloak/Forgejo/Flagsmith) is filled by the later Platform feature-steps; ArgoCD is
special because it is the GitOps engine itself.

### Cross-step touches

- **`mise.toml` tool pins.** This step adds `sops`, `age`, and `kustomize` pins (and
  optionally the `argocd` CLI) to the Step 0 `[tools]` table. `bw` (Bitwarden CLI) is
  operator-provided per `DEVELOPMENT.md` custody, its unlock is human-gated, and it is
  documented as a bootstrap prerequisite rather than silently pinned.
- **`test:feature` exclusion.** `tests/gitops.bats` drives `mise run bootstrap`
  against the long-lived `agrippa-dev` cluster (not the throwaway `agrippa-feature`
  cluster `test:feature` stands up), so it is added to the same auto-discovery
  exclusion list as `cluster-core.bats` — a one-line, convention-consistent edit.

### Challenges

- **The secret never touches disk or git.** The `age` key flows Bitwarden → task
  memory → `kubectl` → the in-cluster `sops-age` Secret, and nowhere else. The task
  must avoid temp files and command-line exposure of the key.
- **Idempotency for a repeatable bootstrap.** Namespace create, Secret create, ArgoCD
  install, and root-app apply must each be safe to re-run so the operator (and the
  feature test) can bootstrap repeatedly without wiping ArgoCD's state.
- **CRD-before-CR ordering under a single sync.** The sync-wave scheme plus
  `SkipDryRunOnMissingResource`/`ServerSideApply` are what keep a first, all-at-once
  reconcile from failing on not-yet-existing CRDs.

## Alternatives

- **Bake the `age` key into a committed file or add a plaintext fallback so bootstrap
  never needs Bitwarden.** Rejected outright, and explicitly out of bounds for this
  session. `DEVELOPMENT.md` custody says the private key never lives in git and never
  as a standing local copy; a plaintext fallback would defeat the entire SOPS+age
  trust model and is the exact failure the plaintext-`Secret` conftest guard exists to
  catch. Bitwarden-locked is a human-resolved blocker, not a reason to weaken the model.
- **Install ArgoCD by hand (helm/kubectl) and never make it self-manage.** Rejected.
  `ARCHITECTURE.html` requires the root app-of-apps to "manage itself"; a hand-only
  install would drift and break the parity claim. The bootstrap applies the same
  kustomization ArgoCD then reconciles.
- **A separate top-level `bootstrap/` tree for the ArgoCD install instead of its
  Platform-layer GitOps home.** A reasonable option (it makes the imperative surface
  visibly separate), recorded as an Open Artifact Decision. Rejected as the default
  because a single source of truth that both the manual apply and the self-management
  Application point at is cleaner than two copies of the install to keep in sync.
- **Argo CD Vault Plugin or sealed-secrets instead of KSOPS/age.** Rejected:
  `DEVELOPMENT.md` fixes SOPS+age with KSOPS in the repo-server as the platform's one
  trust model, per-environment. Introducing a second secrets mechanism locally would
  break parity with the production wiring this step mirrors.

## Summary

This feature-step lands the GitOps spine for the local build: a `mise run bootstrap`
task that creates the `sops-age` trust root in `argocd` from Bitwarden's
`agrippa-age-dev` (no plaintext fallback; a locked/absent vault is a loud, human-
resolved blocker), installs a KSOPS-enabled ArgoCD, and applies a self-managing root
app-of-apps; the `.sops.yaml` dev path rule and repo-server KSOPS wiring;
and the five-layer app-of-apps skeleton (`core`/`storage`/`platform`/`observability`/
`workloads`) carrying the sync-wave ordering contract, ready to receive every later
feature-step's Applications. It also adds `sops`/`age`/`kustomize` pins and one
`test:feature` exclusion line to the Step 0 `mise.toml`. The one feature test asserts
the operator's `bootstrap` experience end-to-end. This Design-phase run does **not**
perform the bootstrap: the actual install requires an unlocked Bitwarden session (a
human grant) and is build-phase work, so the feature test is left RED (its RED baseline
is recorded below).

### Resolved by the long-loop reviewer (2026-07-06)

These are the concrete artifact choices this design invents that are not fixed by a
skill template, an existing project convention, or the cleared `research.md`/project
`design.md`. (The `bootstrap` task name, the `sops-age` Secret name and `argocd`
namespace, the five layer names, and `apps/` = Application CRDs are all *derived* and
stated as conclusions in the body above, not decided here.) Each open item below was
researched against the committed `mise.toml` and `tests/gitops.bats`, the in-repo
contracts (`DEVELOPMENT.md`, `ARCHITECTURE.html`, `README.md`), and the cleared
`research.md`/project `design.md`, then decided to the conservative default. **One item
(6) was escalated**: it turned on a project-altitude `closing-bell.md` edit outside this
feature design's recorded scope, and has since been decided by the human project owner
via the coordinator (recorded below). A subsequent long-loop reviewer (2026-07-07)
re-verified all six items cold against the committed artifacts: item 3's `root` name
at `tests/gitops.bats` line 100; item 6's dropped fallback at `closing-bell.md` line
45 (now "Read access to the Bitwarden item `agrippa-age-dev` for the dev `age` key,"
with no local-key parenthetical); and items 1/2/4/5 against `mise.toml`,
`tests/policy/secrets.rego`, `DEVELOPMENT.md` (§ Secrets lines 61 and 96), `README.md`,
and the project `design.md`/`research.md`. Item 6's escalation is resolved and both
artifacts are consistent, so the draft gate is cleared (marker above now
`*Reviewed 2026-07-07*`).

**1. `apps/` file layout: flat `apps/<layer>.yaml` versus a directory per layer.
Decided: flat — `apps/root.yaml` plus one `apps/<layer>.yaml` per layer, listed by
`apps/kustomization.yaml`.** The tooling does not force either shape: the committed
`mise.toml` runs `kubectl apply -k apps` when `apps/kustomization.yaml` exists
(`test:feature`) and walks `apps/` recursively for kubeconform/conftest
(`test:static`), and `tests/gitops.bats` keys only on Application *names*, never on
file paths — so the tie-break is simplicity. Flat is diffable, matches
`kubectl apply -k apps`, and adds no nesting the skeleton needs; a directory-per-layer
stays available without rework once a layer's content grows. Reversible and inside the
artifact's scope (the design proposes it).

**2. ArgoCD install kustomization home: `apps/platform/argocd/` versus a separate
top-level `bootstrap/` tree. Decided: `apps/platform/argocd/`**, applied once by
`bootstrap` and reconciled thereafter by a thin platform-layer `argocd` Application.
`README.md` places ArgoCD in the Platform layer and `ARCHITECTURE.html` requires the
root app to "manage itself"; a single source that both the manual apply and the
self-management Application point at avoids two copies of the install drifting — the
Alternatives section already weighs and rejects the `bootstrap/` tree on exactly this
ground. Consistent with decision 1: the layer *Application manifests* stay flat at
`apps/<layer>.yaml`, while the ArgoCD install *content* lives under
`apps/platform/argocd/` and is referenced by the platform Application, not conflated
with it. Reversible and in scope.

**3. Root Application name: `root` versus `app-of-apps` or `agrippa`. Decided:
`root`.** Not a judgment call — the committed feature test fixes it: `tests/gitops.bats`
line 100 asserts `wait_for_synced_healthy root`, and the design's recorded RED baseline
is defined against that name, so any other spelling would fail the very test that
defines "done." Fixed by an existing committed artifact.

**4. Sync-wave integers. Decided: `core=0, storage=1, platform=2, observability=3,
workloads=4`, with finer sub-waves assigned inside each layer's own step.** Matches the
layer dependency order the project `design.md` fixes (core → storage →
platform/observability → workloads) and `research.md` decision 8's "CRDs low,
controllers next, custom resources last." ArgoCD sync-waves are relative-ordering
integers, fully refinable and reversible as layers land (the design itself calls them
"a starting scheme"). Placing observability at 3 rather than sharing 2 with platform is
harmless: the two carry no hard cross-dependency, so a later wave only defers, never
breaks. In scope.

**5. `secrets/dev/` encrypted-manifest sub-layout. Decided:
`secrets/dev/<component>.enc.yaml`, referenced by each layer's kustomization, with the
exact per-component paths settling in each layer's own feature-step.** Directly
satisfies the `.sops.yaml` `secrets/dev/.*` path rule this step introduces
(`DEVELOPMENT.md` § Secrets, line 61), which is the governing rule for where
dev-encrypted manifests may sit; `.sops.yaml` and `secrets/` do not yet exist, so this
step commits the rule and only the rule now. `DEVELOPMENT.md`'s other example spelling
(`storage/postgres/secret.enc.yaml`, line 96) is a reference-*site* example, not a
conflicting contract — the two coexist and the concrete per-component location is
deferred to the owning step. Conservative (commits the path-scoping rule, defers the
paths), reversible, and in scope.

**6. Bitwarden-vs-local-key reconciliation. Decided: drop the local-key-fallback
parenthetical from `closing-bell.md` rather than build a local-key-file override.**
The *bootstrap behavior* itself needed no escalation and was already decided —
Bitwarden-only, no plaintext fallback, fail loud when `bw` is missing/locked — fixed by
this session's explicit directive, `DEVELOPMENT.md` custody ("never kept as a standing
local copy," never in git), and the plaintext-`Secret` conftest guard. What this design
could not decide conservatively was the residual cross-artifact contradiction it
surfaced: the project `closing-bell.md` (Setup and Materials, line 46) offered
participants "the documented local-key fallback the bootstrap task provides," but this
bootstrap provides none, and resolving it meant either editing a project-altitude
artifact outside this feature design's recorded scope, or building an
`SOPS_AGE_KEY_FILE`-style override that would contradict the Bitwarden-only directive.
That is why this item was genuinely escalated rather than defaulted, unlike items 1–5.
**This is a human decision, not the reviewer's conservative default**: the human
project owner reviewed the escalation (via the coordinator) and decided to drop the
`closing-bell.md` parenthetical — `closing-bell.md` now reads "Read access to the
Bitwarden item `agrippa-age-dev` for the dev `age` key," with no fallback — rather than
add a local-key override, since any local-key fallback would contradict
`DEVELOPMENT.md`'s committed Bitwarden-only custody policy and the whole purpose of the
plaintext-`Secret` conftest guard.

### Deferred decisions (park to `TASKS.md` at cleanup)

- **Terraform / cloud-init injection of `sops-age`** and the **`overlays/prod`
  environment** — deferred to the cloud cycle; the `mise run bootstrap` task and the
  `secrets/prod/.*` / prod-recipient seam are the local stand-ins, seams preserved.
- **ArgoCD UI ingress and Tier-1 gating** — reached by `kubectl port-forward` locally;
  the Istio-Gateway HTTPRoute and (production) Cloudflare Access on the ArgoCD UI are
  Networking / cloud concerns.
- **metallb placement** — declared in `core`, reconciled at a sync-wave; may move into
  the manual `bootstrap` step if a chicken-and-egg surfaces, with no rework here
  (research decision 8).

## Feature Test

**Path:** `tests/gitops.bats` (following `DEVELOPMENT.md`'s `tests/<feature>.bats`
convention, feature = "gitops"; the `-argocd` tool qualifier is dropped just as
`cluster-core.bats` dropped `-k3d`).

**User story (Given / When / Then):** *Given* the running `agrippa-dev` cluster
(Feature 1), the Step 0 toolchain, and an unlocked Bitwarden session holding
`agrippa-age-dev`, *When* an operator runs `mise run bootstrap`, *Then* the `sops-age`
trust root exists in the `argocd` namespace, the ArgoCD repo-server is KSOPS-enabled
(mounts `sops-age` and carries the ksops decrypt init-container), the root app-of-apps
manages itself and reports **Synced/Healthy**, and the five-layer skeleton (`core`,
`storage`, `platform`, `observability`, `workloads`) is registered and ready to receive
later feature-steps' Applications. It is one test, driving `bootstrap` and asserting the
GitOps spine end-to-end; like `cluster-core.bats` it deliberately does **not** tear
ArgoCD or the cluster down, because both are long-lived and every later feature-step
builds on them.

**Current state: RED (baseline captured this run).** With no `bootstrap` task,
`mise run bootstrap` errors (`mise ERROR no task bootstrap found`) and the test fails
at its first assertion. That red state defines "done" for this feature-step. Unlike
Feature 1, this Design-phase run does **not** turn the test green: the actual bootstrap
requires an unlocked Bitwarden vault (a human grant) and installs cluster software,
which is build-phase work outside this phase's write-only-the-test gate. The build
phase turns it green after `bw unlock` and lands the `bootstrap` task, the KSOPS
wiring, and the `apps/` skeleton.
