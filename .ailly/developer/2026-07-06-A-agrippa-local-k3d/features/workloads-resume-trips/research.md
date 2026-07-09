# Research: Workloads (resume + trips)

*Reviewed 2026-07-09*

> Feature-step research (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 9: Workloads (resume +
> trips)** of that project's plan — the last feature-step, sequentially
> dependent on Feature 3 (Networking) and Feature 5 (Auth), landing after
> Features 0-8 are already built and (mostly) committed live on this cluster.
> Long-loop session: per the dispatching coordinator, this draft does not stop
> to resolve every open item with a human — a separately dispatched reviewer
> clears the draft gate in a later pass, the same way `design.md`'s and
> `plan.md`'s own long-loop reviewers already did for the parent artifacts.
> This document only gathers and narrows; it resolves what research alone can
> determine and leaves the rest explicitly open below.

## Topic and Intent

Original request, verbatim (from the dispatching coordinator's task framing
for this feature-step):

> "Feature 9: **Workloads (resume + trips)**. This is NOT a placeholder —
> read the parent project design's own 'Workloads feature-step (concretized —
> new requirement)' section IN FULL, it already did substantial investigation
> ... Also read § Resolved by the long-loop reviewer items 1-6 (agathon/
> ailly.dev deferral, image/chart location + git-submodule mechanism, local
> trips gating, healthz mechanism, app-of-apps names, hostname shape). ...
> **Real upstream source code arrives via git submodule** —
> `github.com/davidsouther/resume` (public) and `github.com/davidsouther/
> trips` (public) under a `workloads/` build context ... research the exact
> `git submodule add`/`.gitmodules` mechanics, and how a Dockerfile build
> context interacts with a submodule directory (does the image build need the
> submodule already checked out locally, i.e. is `git submodule update
> --init` a `mise` task prerequisite?). **One deliberate imperative step
> outside GitOps** — a `mise workloads:build`-style task that builds the
> multi-stage container image ... and `k3d image import`s it ... Research
> exact `k3d image import` mechanics and how a locally-built, unregistried
> image tag is referenced in a Kubernetes Deployment spec (`imagePullPolicy:
> Never` or `IfNotPresent` ...). **The `tests/agrippa.bats` fix is
> BUILD-PHASE work on an EXISTING committed file**, not this feature-step's
> own new bats file — but this feature-step's OWN feature test still needs to
> be a fresh, separate proof ... **This feature-step directly targets Closing
> Bell critical tasks 2, 3, and 6** ... whether `mise workloads:build`'s Node
> 24 runs INSIDE the Docker build stage only (no local Node needed) or also
> needs a local `mise`-pinned Node for anything outside the container."

Loosely stated goal, in the project's own framing (`design.md` §
"Workloads feature-step" and `plan.md` § "Feature 9"): take the two real,
already-production repositories that serve `davidsouther.com`(`/blog`) and
`trips.davidsouther.com` today via GitHub Pages, and actually run both inside
the local k3d cluster — behind the shared Istio Gateway, GitOps-managed like
every other component — so that the platform's parity claim ("the same
charts and manifests locally and in production") extends to David's real
workloads, not just infrastructure. This is the step that makes the Closing
Bell's remaining critical tasks (2, 3, 6) passable.

## Search/Expand

General lens: what does established practice say about each of this
feature-step's genuinely new mechanics (none used by any prior feature-step
in this session)?

- **Vendoring an external app's source into an infra repo for a container
  build.** Git submodules are the standard, git-native mechanism for
  "reference another repo at a pinned commit, materialize its files locally
  on demand" — confirmed against git-scm.com's own reference chapter (see
  `research/public.md`). The alternative (a periodic vendored copy/mirror,
  or a git subtree) was not separately researched in depth: the parent
  design's own resolved decision 2 already selected the submodule mechanism
  specifically because it "reads real, current upstream source rather than a
  vendored copy," and this feature-step's job is to nail the mechanics of
  that already-made choice, not re-litigate it.
- **Multi-stage container builds for a Node-built static site.** A `node:
  <version>[-alpine]` build stage producing static output, discarded in favor
  of a minimal serving image (nginx, or a Node-based static server) in stage
  2, is the dominant, widely-corroborated community pattern (see
  `research/public.md` [15]-[17]) — no exotic alternative surfaced (no
  Buildpacks/Nixpacks precedent exists anywhere else in this repo, and
  introducing one here would be a bigger, unrelated tooling decision).
- **Loading a locally-built image into a local Kubernetes cluster with no
  registry.** `k3d image import` is k3d's own purpose-built answer to
  exactly this gap (a `docker build`-ed image lives only in the host Docker
  daemon; the k3s nodes' containerd has no access to it) — no alternative
  tool competes here; the open questions are its exact modes and how the
  consuming Deployment's `imagePullPolicy` should read (see
  `research/public.md` [10]-[14]).
- **Hand-authoring a minimal Helm chart from scratch for a simple stateless
  web app** (as opposed to consuming someone else's chart, which is the only
  pattern this repo has used so far). Well-trodden in the broader Helm
  ecosystem (a `Deployment` + `Service` + ingress-shaped route +
  values-driven image tag is the textbook minimal chart), but genuinely
  un-precedented *inside this repo* — see Falsification below for why the
  chart-composition mechanism specifically (not the chart's internal
  content) is a real open question.
- **A liveness/health endpoint on a static site with no application server.**
  The nginx `return 200;` location-block pattern the parent design's resolved
  decision 4 already committed to is confirmed as valid, minimal, primary-
  source syntax (`research/public.md` [19]).

## Libraries & Skills

**Before doing any work in this feature, load these skills via the active
harness's skill-loading mechanism:** none new — carried forward unchanged
from the project's `research.md` and `design.md` § Libraries & Skills:
`developer:initialize` (this feature-step adds **no** new `mise`-managed CLI
tool pin — see Resolved Decisions on the local-Node question), `research:
public` and `research:codebase` (already exercised by this document and
`research/public.md`/`research/codebase.md`), and the `developer:ailly`
project-shape references.

**No library-shipped agentic skill exists for git submodules, Docker
multi-stage builds, k3d, nginx, or helm-unittest** — this reconfirms, at the
per-mechanism level, the project's already-recorded top-level finding. It
also extends explicitly to `@davidsouther/jiffies`, the SSG both workload
repos depend on: it is a plain published npm package with no `repository`
field and no discoverable `SKILL.md`/MCP manifest (`research/public.md` [5])
— unlike the cautionary Astrolabe/Jiffies-skill-miss `research.md`'s own
phase reference cites as the reason this check exists, there genuinely is no
skill to miss here, confirmed by direct inspection rather than assumed.

**Per-library docs review**, closest worked examples included, full
citations in `research/public.md`:

- **git submodules.** Getting-started: git-scm.com's own "Git Tools -
  Submodules" chapter. Closest worked example: `git submodule add <url>
  <path>` plus the exact `.gitmodules` shape it produces. No skill.
- **k3d (image import specifically — the cluster/GitOps mechanics were
  already covered by `cluster-core-k3d`'s and `gitops-argocd`'s own
  research).** Getting-started: k3d.io's `usage/commands/k3d_image_import/`
  and `usage/importing_images/` pages. Closest worked example: the `direct`
  vs `tools` mode distinction, directly relevant to this single-node
  cluster's choice. No skill.
- **Docker multi-stage builds (Node build → static serve).** No single
  canonical getting-started page; triangulated across several worked
  examples (`research/public.md` [15]-[17]) plus Docker Hub's own `node`
  image tag listing for the exact base-image pin. No skill.
- **nginx (the `return` directive for `/healthz`).** Getting-started:
  nginx.org's own `ngx_http_rewrite_module` reference page — a primary
  source, not a tutorial. No skill.
- **helm-unittest.** Getting-started and closest worked examples: the
  `helm-unittest/helm-unittest` GitHub repo and its `DOCUMENT.md` — the same
  source `DEVELOPMENT.md`'s own testing table points at. No skill; this is
  the first feature-step to actually exercise it against a real, non-empty
  `charts/` directory (see Falsification).
- **ArgoCD's native Helm-from-git support** (a candidate resolution to the
  chart-composition open question below). Getting-started: `argo-cd.
  readthedocs.io`'s "Helm" user guide and "Application Specification
  Reference." No skill.

`ARCHITECTURE.html`, `DEVELOPMENT.md` (§ Testing, § Secrets — though this
feature-step needs no new secret), `ROUTING.md`, and the two most-recently-
completed sibling designs (`networking-istio` for the Gateway/HTTPRoute/
hostname/TLS contract; `git-hosting-forgejo` for the "one component
subdirectory appended to a shared layer `kustomization.yaml`" composition
shape and its own build-time-surprise-found-only-by-live-testing precedent)
remain the authoritative in-repo contracts this feature-step builds to —
confirmed read in full for this research pass, not re-derived from
`ARCHITECTURE.html` alone.

## Falsification/Refine

Specific-lens right-sizing.

**Size: one feature-step, already fixed by the project plan — and now
smaller than the parent design/plan describe.** `plan.md` names this
Feature 9 with five numbered sub-items. Item 5 (`tests/agrippa.bats`'s
three-edit fix) is a *false* remaining scope item: `research/codebase.md`
confirms, by direct `git diff`, that commit `a9cdfbc` (Feature 0) already
landed all three edits. This is exactly the "digested thread contains a
comment that postdates and materially reframes the original scoping" class
of finding the research phase exists to catch, transplanted from a tracker
thread to a git history — recorded under Resolved Decisions below, not
treated as a halt.

**Off-the-shelf: no single tool replaces the whole feature, but every
ingredient is individually off-the-shelf and none needed inventing.** Git
submodules, multi-stage Docker builds, `k3d image import`, and a minimal
Helm chart are each a standard mechanism reached for by name, not designed
from first principles — consistent with every prior feature-step in this
project.

**Smallest version that still meets the intent.** The Closing Bell's
critical tasks 2 and 3 need only: both sites reachable through the Gateway
at their dev hostnames, rendering real content (task 2 also needs `/blog`
and `/healthz`). Task 6 needs the already-landed gestalt suite to pass
against real Deployments. Nothing in the Closing Bell or the parent design
requires forgejo-runner-style CI wiring, a registry push, or any
feature-flag gating for resume/trips (Feature 7/Flagsmith is named in the
plan's dependency line only "where a workload reads a flag" — neither
concretized workload does). This argues for the parent design's own five
items, minus the already-done item 5, as the right-sized slice — no further
narrowing found.

**Claims tested against reality — three corrections and one open risk, not
foreclosed by this research:**

1. **The `tests/agrippa.bats` fix is done, not pending** (above) — narrows
   scope, does not change design.
2. **`docs/` is gitignored in both upstream repos, confirmed by reading the
   actual `.gitignore` files, not assumed.** This positively *confirms*
   (does not falsify) the parent design's plan: the image build's stage 1
   must run a real `npm ci && npm run build` inside the container, because
   there is no committed static output anywhere in the submodule to just
   `COPY`. If either repo instead committed `docs/`, the whole multi-stage
   build could collapse to a single `COPY`+serve stage — it cannot, and this
   is now confirmed rather than inferred from the design's prose.
3. **A genuine, not-yet-evaluated alternative to nginx for stage 2 exists
   and should at least be named for the design phase, even though this
   research does not recommend switching.** Both repos already ship a
   working Node static-file server via `@davidsouther/jiffies`'s
   `server/http` module (`npm start` → `scripts/serve.ts`), with clean-URL
   directory-index resolution built in (the exact behavior `/blog` needs).
   Reusing it would keep serving-stage behavior byte-identical to each
   repo's own local/production expectations, at the cost of a larger runtime
   image (Node instead of nginx) and — critically — **no confirmed
   equivalent to nginx's one-line `return 200;` healthz mechanism** (jiffies'
   server module was not inspected deeply enough in this pass to know if it
   offers one). The parent design's resolved decision 4 already committed to
   nginx specifically *because* of the healthz mechanism; this finding does
   not overturn that decision, it names why revisiting it would reopen a
   settled question rather than being a free upgrade.
4. **Real, unresolved mechanical risk: how does `workloads/overlays/dev/
   kustomization.yaml` actually consume a hand-authored, in-repo
   `charts/resume/`-style chart, given every prior Helm-sourced component in
   this repo pulls a *remote* chart via kustomize's `helmCharts:`
   generator, and that generator's *local*-chart path (`helmGlobals.
   chartHome`) is the subject of a closed-not-planned kustomize bug report
   (`#5818`, plus three corroborating sibling issues)?** This is not a
   hypothetical — it is the single most load-bearing unresolved question
   this research surfaces, because it determines whether `charts/resume/`
   is literally what ArgoCD syncs, or a separate, parallel, helm-unittest-
   only artifact next to plain-YAML manifests that are what actually
   deploys. `research/public.md` lays out three concrete options (local
   `chartHome` inflation accepting the known-flaky risk; per-workload
   ArgoCD `Application`s using ArgoCD's native git-Helm auto-detection,
   deviating from the "one Application per layer" shape; or plain kustomize
   `resources:` YAML for the live path with the chart kept only for
   `test:chart`) with citations for each. Research deliberately does not
   pick one — mise pins a newer kustomize (5.8.1) than the version the bug
   was filed against (5.5.0), so a live `kustomize build --enable-helm`
   smoke test against a real local `charts/resume/` directory, done early in
   the design or plan phase, resolves this cheaply and conclusively before
   any chart internals are written against the wrong assumption.

## Scope

### In scope (this feature-step)

- **A `git submodule` under a `workloads/` build context** for each of
  `github.com/davidsouther/resume` and `github.com/davidsouther/trips`
  (public repos; `.gitmodules` entries + pinned commits), leaving both
  upstream repos themselves untouched (parent design's resolved decision 2).
- **A `mise workloads:build`-shaped imperative task** (matching the
  `bootstrap` task's shape: `[tasks."workloads:build"] file =
  "scripts/workloads-build.sh"` or similar), whose steps are, per this
  research: (1) `git submodule update --init` to materialize the submodule
  content the Docker build context needs; (2) `docker build` a multi-stage
  image per workload (stage 1 `node:24-alpine`, stage 2 a static server);
  (3) `k3d image import` the built tag into the `agrippa-dev` cluster. No
  host-side Node needed for any of these three steps (see Resolved
  Decisions).
- **A hand-authored, minimal Helm chart per workload** (`charts/resume/`,
  `charts/trips/`) — the first real content in this repo's `charts/`
  directory, with a `tests/` suite `scripts/test-chart.sh` already knows how
  to discover and run. **The mechanism by which `workloads/overlays/dev`
  actually consumes it is an open question for design** (see Falsification
  item 4), not settled here.
- **One `HTTPRoute` per workload** attached to `agrippa-gateway`
  (`sectionName: https`), matching `platform/overlays/dev/forgejo/
  httproute.yaml`'s exact shape (explicit `matches:`, same-namespace
  `backendRefs`) — and **one append of both dev hostnames**
  (`davidsouther.com.127.0.0.1.nip.io`, `trips.davidsouther.com.
  127.0.0.1.nip.io`) to the single shared `core/overlays/dev/
  gateway-cert.yaml` `dnsNames:` list, which does not yet contain either
  (confirmed live, `research/codebase.md`).
- **An ArgoCD-visible landing point for both workloads inside the existing
  `workloads` layer Application** (`apps/workloads.yaml`, already correctly
  pointed at `workloads/overlays/dev`, sync-wave 4, no change needed to the
  `Application` object itself — only to what its target path composes).
- **`nginx`'s `location = /healthz { return 200; }`** in the resume chart's
  serving-layer config (parent design's resolved decision 4), confirmed
  valid minimal syntax against nginx's own primary docs.
- **`imagePullPolicy: Never`** (recommended over `IfNotPresent`, see
  Resolved Decisions) on both Deployments, since neither image will ever
  exist in any registry.
- **Verification, not authoring, of `tests/agrippa.bats`** — confirm the
  already-landed three-edit fix passes green once real Deployments/
  HTTPRoutes/healthz exist, with `PUBLIC_HOST`/`TRIPS_HOST`/`DASHBOARD_HOST`
  pointed at the local `nip.io` ingress and `ENV=dev`.
- **This feature-step's own feature test** — per every sibling's convention
  (`networking.bats`, `git-hosting.bats`, `feature-flags.bats`, …), a fresh
  `tests/workloads.bats` (name to confirm in design) targeting the
  long-lived `k3d-agrippa-dev` cluster: the `workloads` Application stays
  Synced/Healthy, both dev hosts render real content, and `/healthz`
  responds — the same proof shape `networking.bats` and `git-hosting.bats`
  already established, distinct from `tests/agrippa.bats`'s cross-cutting
  gestalt role.

### Out of scope (deferred, per already-cleared parent artifacts)

- **`agathon` and `ailly.dev`** — parent design's resolved decision 1;
  neither repo was inspected, neither is named in the Closing Bell's
  critical tasks.
- **Trips' Cloudflare Access → Terraform port and CI → Forgejo Actions
  port** — prod/post-git-hosting concerns, parent design's own deferral.
  forgejo-runner does not even exist yet in this build (`git-hosting-
  forgejo`'s own deferred-decisions entry), so a CI port has nothing to land
  on regardless.
- **Any Postgres/CNPG usage** — both workloads are pure static builds; the
  cross-cutting "`Database` CR must precede its Deployment's wave" pattern
  from Features 5-7 does not apply here (confirmed, not just assumed, by
  `.ailly/developer/TASKS.md`'s own note plus this research's confirmation
  that neither repo's build touches a database).
- **Any new sops-sealed secret** — no credential of any kind is needed by
  either workload's build or serving path.
- **Publishing the built image to a real registry** (Forgejo's own or GHCR)
  — explicitly a cloud-cycle/parity-seam concern per the parent design; the
  local build stays registry-less by design.
- **Feature-flag gating of either workload** — Flagsmith is a dependency
  only "where a workload reads a flag," and neither concretized workload
  does.

## Resolved Decisions

Answered by this research:

- **(a) Is `git submodule update --init` a real prerequisite before `docker
  build`, or can the Dockerfile fetch the submodule itself?** It is a real,
  necessary host-side (or `workloads:build`-task-side) prerequisite. A plain
  local-filesystem Docker build context never auto-populates a submodule —
  the directory is present but empty until `git submodule update --init`
  runs — confirmed against git-scm.com's own worked example and
  corroborated by three independent real-world GitHub issues hitting exactly
  this failure class. `git submodule update --init` (no `--recursive`
  needed unless a nested submodule is later discovered) is step 1 of the
  `workloads:build` task.
- **(b) `k3d image import` mechanics and mode choice.** It copies an image
  already present in the local Docker daemon into the k3s node containers'
  containerd store (the node has no access to the host Docker daemon
  otherwise). For this project's single-node `agrippa-dev` cluster, `--mode
  direct` is the simplest and cheapest of the three documented modes (no
  intermediate tools-container hop needed for a single node) — a concrete,
  research-backed recommendation for the design phase to adopt or override.
- **(c) `imagePullPolicy: Never` or `IfNotPresent`?** `Never` is recommended.
  Kubernetes' own default-policy rule already makes a non-`:latest`-tagged
  image default to `IfNotPresent` with no explicit setting needed at all —
  but `IfNotPresent` still attempts a registry pull on any future cache miss
  (a node restart, a `k3d cluster stop`/`start` cycle), which would fail
  against a registry these images were never pushed to. `Never` fails the
  same way without ever trying a network call first — the more honest
  statement of "this image only ever comes from a local build," matching the
  design's own framing ("no external registry needed for the local build").
- **(d) Does `workloads:build` need a local, `mise`-pinned Node outside the
  container?** No. Every step of the task (`git submodule update --init`,
  `docker build`, `k3d image import`) needs only `git`, `docker`, and `k3d`
  on the host — all either already present (git, per every other step in
  this project) or already `mise`-pinned (`k3d` `5.9.0`). `npm ci && npm run
  build` runs entirely inside the `node:24-alpine` build stage. This mirrors
  the repo's own already-established convention that Docker itself is a
  deliberate non-`mise`-managed "ambient dependency" (`GETTING_STARTED.md`)
  — Node earns the identical treatment for the identical reason: it is
  needed only inside a container, never on the operator's host. **No
  `[tools]` entry for `node` should be added to this repo's `mise.toml`.**
- **(e) Is the `tests/agrippa.bats` three-edit fix still this feature-step's
  work?** No — confirmed already committed in `a9cdfbc` (Feature 0). This
  feature-step's remaining obligation against that file is to verify it
  passes once real Deployments/HTTPRoutes/healthz exist, and to correct the
  parent `plan.md`'s Feature 9 item 5 framing at the next opportunity that
  touches it (a documentation accuracy fix, not a design-phase blocker).
- **(f) Which two dev hostnames, and where do they get wired in?** Per the
  parent design's already-fixed `<prod-host>.127.0.0.1.nip.io` scheme and
  confirmed against the live `core/overlays/dev/gateway-cert.yaml`:
  `davidsouther.com.127.0.0.1.nip.io` and `trips.davidsouther.com.
  127.0.0.1.nip.io`, neither yet present in the shared `dnsNames:` list —
  this feature-step appends both, following the identical append-only
  discipline (and the same latent merge-contention watch-item) every prior
  UI-exposing feature-step already used.
- **(g) `/healthz` mechanism.** Confirmed valid, primary-source syntax:
  `location = /healthz { return 200; }` inside the resume chart's nginx
  config (parent design's resolved decision 4) — no change needed to the
  resume repo itself.

### Resolved by the long-loop reviewer (2026-07-09)

Items (h)-(k) below were the "left open, for this feature-step's own design
phase to settle" slot. A separately dispatched research-and-decide reviewer
read this artifact cold and resolved them at the research draft gate. For the
one flagged highest-leverage item (h) it ran the live `kustomize build
--enable-helm` smoke test this research itself recommended (§ Falsification
item 4), against the pinned kustomize `5.8.1` and the live `k3d-agrippa-dev`
cluster (`workloads` Application `Synced/Healthy`, overlay still the
`resources: []` placeholder; single-node `1/1` server, `0` agents), and
checked each item against the repo conventions (`DEVELOPMENT.md`, parent
`design.md`/`plan.md`, the `forgejo` sibling's `chart/`+plain-YAML
composition, and ArgoCD's live `argocd-cm` `kustomize.buildOptions`). The
"Answered by this research" items (a)-(g) above were re-verified and stand;
(e) was re-confirmed live (`git show a9cdfbc -- tests/agrippa.bats`; current
tree carries no `GESTALT_ENV`, the trips `dev` branch, and the `-k` flags;
`git diff HEAD` empty). Each item was decided to the conservative, reversible
default. No escalation trigger (irreversible, out of recorded scope, or
underdetermined) fired, so this research draft gate is cleared (marker now
`*Reviewed 2026-07-09*`).

**(h) The chart-composition mechanism. Decided: consume both workloads as
plain kustomize `resources:` YAML (Deployment / Service / HTTPRoute /
Certificate) under `workloads/overlays/dev/<workload>/`, composed by the
existing single `apps/workloads.yaml` Application — NOT via `helmCharts:`
inflation — and keep `charts/resume/` and `charts/trips/` as real,
`helm-unittest`-tested charts at the repo root, as the packaging artifact for
the deferred prod/registry-push path rather than the local GitOps render
path.** Live smoke-test findings against pinned kustomize 5.8.1: (1) local
`helmCharts:` inflation of an in-repo chart *does* work — the `#5818`
"`chartHome` silently ignored when `repo` omitted" bug this research flagged
does **not** reproduce in 5.8.1: a `helmGlobals.chartHome` +
`helmCharts:[{name, releaseName}]` render (no `repo`, no `version`) succeeds,
honors a non-default `chartHome`, and applies `valuesInline` overrides (the
`overlays/dev` replica-reduction path), so the research's stated primary risk
is retired. (2) But a second, decisive constraint the research did not surface
blocks the convention-correct layout: kustomize's default load restrictor
(`LoadRestrictionsRootOnly`, which ArgoCD uses) **refuses a `chartHome` that
points above the kustomization directory**. With `charts/<chart>/` at the repo
root (the `DEVELOPMENT.md` convention) and ArgoCD building from the deep
`workloads/overlays/dev`, the render fails hard: `Error: security; file
'.../charts/resume/values.yaml' is not in or below
'.../workloads/overlays/dev/...'`. The only ways to make repo-root-chart +
deep-overlay `helmCharts:` work are (a1) add `--load-restrictor
LoadRestrictionsNone` to ArgoCD's cluster-wide `kustomize.buildOptions`
(today `--enable-alpha-plugins --enable-exec --enable-helm`,
`apps/platform/argocd/kustomization.yaml`) — a security-posture change to the
ArgoCD/`core` layer this feature-step does not own, weakening every
Application's kustomize sandbox — or (a2) relocate the chart to
`workloads/overlays/dev/<workload>/chart/charts/<workload>/` (at-or-below the
overlay, which does render with no flag), violating `DEVELOPMENT.md`'s
`charts/<chart>/` convention and colliding with the `./charts` dir kustomize
itself writes fetched charts into. Both disqualify local `helmCharts:` as the
conservative default. Option (b) native ArgoCD Helm-from-git respects the
repo-root chart and is single-source-of-truth, but forces the `workloads`
layer off the "single `apps/workloads.yaml` composes `workloads/overlays/dev`
via kustomize" shape (`research/codebase.md` confirmed that Application needs
*no* change) onto per-workload Applications — more new structure than the
conservative default warrants. Plain `resources:` YAML (option c) is strictly
lowest-blast-radius: it reuses the exact composition shape
`platform/overlays/dev/forgejo/` already uses for its non-Helm resources
(`namespace.yaml`, `forgejo-database.yaml`, `httproute.yaml` in a bare
`resources:` list), leaves `apps/workloads.yaml` untouched, and needs zero
ArgoCD/kustomize config change. On the convention question the task raises:
`DEVELOPMENT.md`'s `charts/<chart>/` + `charts/<chart>/tests/` describes
*where a Helm chart lives if one exists*; it does not mandate that every
workload *be* a chart, and two thin static sites (four objects, no runtime
config surface beyond an image tag) do not earn Helm's templating machinery
for the local path. Keeping the charts as real repo-root artifacts still
satisfies the parent design's "minimal Helm chart in `charts/`" commitment
(`design.md` § Workloads item 2) and `test:chart`. To avoid the "two
representations kept in sync by discipline" drift, the design phase may either
hand-author the live plain YAML with the chart as a parallel
`helm-unittest`-only artifact (this research's stated option c, accepting
minor duplication) or render the live YAML from the chart via `helm template`
in the `workloads:build` task (single-source-of-truth, at the cost of a
render/commit step) — a smaller sub-decision that does not gate design. The
decision is reversible, stays within the scope this research explicitly
re-opened (§ Falsification item 4 named plain-YAML `resources:` as a
candidate), and deliberately avoids the one out-of-scope, higher-blast-radius
path (a1's cluster-wide load-restrictor relaxation); no escalation fires.

**(i) nginx vs `@davidsouther/jiffies`' own Node static server for serving
stage 2. Decided: keep nginx.** Parent design resolved decision 4 committed to
nginx specifically for its one-line `location = /healthz { return 200; }`
liveness mechanism (Closing Bell task 6; the gestalt probes
`davidsouther.com/healthz`), and this research found no confirmed jiffies
equivalent. Switching would reopen a settled decision for a larger runtime
image and an unconfirmed healthz path with no offsetting upside — the
conservative default is the already-settled choice.

**(j) Serving-container `resources` requests/limits. Decided: set explicit,
modest values proactively; do not ship request-less containers.** The cluster
has evidenced scheduling pressure (`db93c91`, the Flagsmith OOMKill), and the
forgejo chart's own comments flag request-less containers as a noisy-neighbor
risk even with node headroom. A static server is cheap, so values well below
forgejo's (`requests: cpu 100m/memory 256Mi`) suffice — e.g. `requests: cpu
25m/memory 32Mi`, `limits: memory 64-128Mi`. The exact numbers are a
design-phase artifact detail, but the direction (explicit + modest) is
decided.

**(k) Naming (test file, build task/script, submodule paths). Decided: follow
the established sibling conventions.** `tests/workloads.bats` (matching
`networking.bats` / `git-hosting.bats`); `[tasks."workloads:build"]` →
`scripts/workloads-build.sh` (matching the `bootstrap` task shape
`research/codebase.md` cites); submodule checkouts at `workloads/resume/` and
`workloads/trips/`. Low-risk, convention-matching defaults; with (h) settled
on plain `resources:` these are unconstrained by any chartHome-relative build
context, so design may adjust freely but has a working starting point.

## Sources

Full citations with inline references are in `research/public.md` (external:
git submodules, Docker multi-stage builds, k3d image import, imagePullPolicy,
nginx, helm-unittest, kustomize local-chart limitations, ArgoCD native Helm
support, and the two upstream workload repos' actual `package.json`/
`.gitignore`/CI as read via `gh api`) and `research/codebase.md` (internal:
the already-landed `tests/agrippa.bats` fix, the never-yet-populated
`charts/` directory, the live Gateway/Certificate/HTTPRoute contract, the
ambient-Docker/no-mise-pin precedent, and the `bootstrap`-task shape
precedent). Both are IEEE-style within their own files; this top-level
document does not duplicate their numbering.
