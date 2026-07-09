# Public: Packaging two Node static-site builds (git submodule, multi-stage
Docker, k3d image import, and a hand-authored Helm chart) for a local k3d/
ArgoCD platform

## Findings

**The two upstream repos, inspected directly via `gh api` (public
repos, current default branch):** `davidsouther/resume`'s and
`davidsouther/trips`' `package.json` are functionally identical:
`"engines": {"node": ">=24"}`, `"build": "npm run css:bundle && node
scripts/sitemap.ts && node node_modules/@davidsouther/jiffies/lib/esm/ssg/
main.js --out docs"`, and a `"prebuild": "npm run check"` npm-lifecycle
script that runs `tsc --noEmit && biome check ...` **automatically before**
`npm run build` executes [1][2]. Both repos' `.gitignore` marks `docs/` as
build output, **not committed** [3][4] — confirmed by reading the actual
`.gitignore` content, not inferred: a git submodule checkout therefore never
carries a pre-built site; the multi-stage image's build stage must run the
real `npm ci && npm run build` to produce one. Both repos' current GitHub
Actions (`deploy.yml`) provision Node via `jdx/mise-action` reading each
repo's own `mise.toml` (`[tools] node = "24"`), not `actions/setup-node` —
confirms `node:24`/`node:24-alpine` is the correct, current pin, and that
`npm run build`'s implicit `prebuild` (typecheck + lint) is expected to pass
cleanly at build time in CI today, so it should also pass inside a fresh
Docker build stage with no special-casing [1][2]. `davidsouther/jiffies`
(the shared SSG package both repos depend on) is not resolvable as a public
GitHub repo via `gh repo view` from this environment, but is a published,
non-private npm package (`@davidsouther/jiffies`, currently `2026.26.1`) with
no `repository` field or discoverable `SKILL.md`/MCP manifest in its
published `package.json` [5] — corroborates the parent `design.md`'s already-
recorded finding that no library in this stack ships an agentic skill; this
extends that finding to jiffies specifically. Its own `package.json` also
reveals a `"start": "node ./src/server/main.ts"` script and both consuming
repos' `scripts/serve.ts` import `@davidsouther/jiffies/server/http/index.ts`
`makeServer` — i.e. jiffies ships its **own** Node static-file server with
clean-URL (`/blog` → `/blog/index.html`) resolution, used today by each
repo's own `npm start` [1][2][5]. This is a genuine, not-yet-evaluated
alternative to nginx for the serving stage (see Falsification note in
`research.md`), surfaced here as a fact, not a recommendation.

**Git submodules: mechanics and the Docker-build-context interaction.**
`git submodule add <url> [<path>]` clones the child repo into `<path>` and
writes a `.gitmodules` entry (`[submodule "<name>"] path = ...  url = ...`)
[6]. Critically: **a plain `git clone` (or an existing clone with a newly-
added submodule) leaves the submodule's working directory *empty*** until
either `git submodule update --init [--recursive]` runs, or the clone itself
used `--recurse-submodules` [6] — confirmed against git-scm.com's own
worked example showing `ls` on a freshly-cloned submodule directory
returning nothing. A `docker build <context-dir>` invoked against an
ordinary local filesystem path (as opposed to Docker's separate "remote git
context" feature, `docker build https://github.com/...git`, which BuildKit
clones itself) does **not** know anything about git or submodules — it simply
tars up whatever is already on disk under that path. **Consequence for this
feature-step: if the submodule directory is uninitialized, the Docker build
context silently contains an empty directory, and any `COPY` from it either
copies nothing or fails** — so `git submodule update --init` (or
`--recursive` for defense against nested submodules, though neither resume
nor trips is known to nest one) **must run on the host before `docker
build`**, i.e. it is a real prerequisite step inside the `workloads:build`
mise task, not something the Dockerfile itself can be made to do for a plain
local build context. Independent, real-world corroboration of exactly this
failure class (files silently missing from a Docker build context that
crosses a submodule boundary) appears in `docker/compose#9517` [7],
`monero-project/monero#5687` [8], and `Azure/dev-spaces#391` [9] — three
unrelated projects hitting the same root cause, which is stronger evidence
than any one of them alone (tier-3 corroboration of the tier-1 git-scm.com
mechanism [6]).

**`k3d image import`: mechanics and imagePullPolicy.** The command "imports
image(s) from docker into k3d cluster(s)" [10][11]; conceptually it copies an
image already present in the *local Docker daemon's* image store into the
k3s nodes' containerd image store, since a freshly `docker build`-ed image
exists only in the host Docker daemon and containerd inside the k3d
node-containers has no access to it by default [12]. Three `--mode` values:
`direct` (loads straight into the k3s node containers, no intermediate
container or files — the cheapest option, and adequate for this project's
single-node `agrippa-dev` cluster), `tools` (spins up a `k3d-tools`
container to relay the image, useful when the runtime is remote), and `auto`
(picks between them) [10][11]. Image names are normalized (`docker.io/`
prefix stripped, missing tag defaults to `:latest`) [10] — a second,
independent reason (beyond registry-pull risk) to tag the built image
explicitly (e.g. `resume:dev`), not leave it tag-less. **`imagePullPolicy`
default rule** (general Kubernetes behavior, not k3d-specific): if unset, the
policy defaults to `Always` when the tag is `:latest` and to `IfNotPresent`
otherwise [13][14]; `IfNotPresent` still *attempts* a registry pull on a
cache miss (node restart, `k3d cluster start` after a stop, a second node in
a future multi-node config), which would fail loudly against a registry that
was never pushed to (these images have no registry home at all in the local
build) [13][14]. `imagePullPolicy: Never` is the more semantically correct
choice for an image that will *never* exist anywhere but the node's own
local containerd store — it fails the same way `IfNotPresent` would on a
true cache miss, but without ever attempting an outbound registry call
first.

**Multi-stage Docker build shape (Node build → static serve).** The
standard, widely-corroborated pattern is stage 1 `FROM node:<version>[-
alpine] AS build` running `npm ci` then the project's own build script, and
stage 2 `FROM nginx:alpine` (or `nginx:<version>-alpine`) copying only the
build output (here, `docs/`) into `/usr/share/nginx/html`, discarding
`node_modules` and the Node runtime entirely from the shipped image [15][16][17].
`node:24-alpine` and `node:24.18-alpine`-style tags are published and current
on Docker Hub as of this research [18]. **`nginx`'s `return` directive**
(context: `http`, `server`, `location`, `if`; syntax `return code [text];`)
accepts a bare status code with no body — `return 200;` inside `location =
/healthz { return 200; }` is valid, minimal, primary-source-confirmed syntax
for the liveness endpoint the parent design's resolved decision 4 already
committed to [19].

**Composing a hand-authored, in-repo Helm chart into this project's existing
kustomize/ArgoCD pipeline is a genuinely open mechanical question, not a
foregone detail — a load-bearing finding for the design phase.** Every prior
Helm-sourced component in this repo (Forgejo, Flagsmith, Keycloak-operator,
Istio, cert-manager, CNPG, the LGTM stack) uses kustomize's `helmCharts:`
generator pointed at a **remote** OCI/https chart repo — none renders a
**local, in-repo** chart this way. Kustomize's documented mechanism for a
local chart is `helmGlobals.chartHome` with `helmCharts[].repo` omitted
[20], but this exact combination is the subject of an open-then-closed
kustomize issue: `kubernetes-sigs/kustomize#5818` (affecting 5.5.0, closed
"not planned") reports `chartHome` being silently ignored when `repo` is
omitted, erroring `"no repo specified for pull, no chart found at ''"` —
with only a reported, layout-fragile workaround (pointing `chartHome` one
directory *inside* the expected root) [21]; sibling issues `#5775` (no
per-chart `chartHome`), `#5163` (a 5.0.2 regression), and `#4378` (no direct
local-path option at all) corroborate that local-chart inflation is a known
soft spot, not a one-off report. `mise.toml` pins kustomize `5.8.1`, a later
version than the one the closed issue was filed against, so this project's
own live build is the only way to know whether the bug still reproduces —
research surfaces the risk, it does not resolve it. Two alternative
mechanisms exist and should be weighed by design, each independently
well-supported: **(a)** ArgoCD's own native Helm-from-git support — pointing
an `Application`'s `spec.source.path` directly at a chart directory
containing a `Chart.yaml` in the same git repo auto-detects it as a Helm
source with no Kustomize involvement at all [22][23], at the cost of one
`Application` per workload rather than the "one Application composes the
whole layer via kustomize" shape every other layer in this repo uses; **(b)**
skip Helm-as-the-GitOps-render-path for the *live* manifests entirely — plain
Kustomize `resources:` (a Deployment/Service/HTTPRoute/Certificate as
ordinary YAML, exactly like every non-Helm-sourced resource already in this
repo: `namespace.yaml`, `httproute.yaml`, `forgejo-database.yaml`) — while
keeping `charts/resume/`/`charts/trips/` as a real, separately
`helm-unittest`-tested artifact satisfying `DEVELOPMENT.md`'s repo-layout
promise and this project's own stated intent to reuse the chart for a future
registry push, accepting that the chart and the live manifests are two
representations kept in sync by discipline rather than a single generator.

## Sources

- [1] `davidsouther/resume` — `package.json`, `.gitignore`, `.github/
  workflows/deploy.yml`, `mise.toml` (fetched via `gh api repos/davidsouther/
  resume/contents/...`, 2026-07-09).
- [2] `davidsouther/trips` — `package.json`, `.gitignore`, `.github/
  workflows/deploy.yml` (fetched via `gh api repos/davidsouther/trips/
  contents/...`, 2026-07-09).
- [3] `davidsouther/resume/.gitignore` — `docs/` build-output comment block.
- [4] `davidsouther/trips/.gitignore` — `docs/` build-output comment block.
- [5] `@davidsouther/jiffies` — npm registry metadata (`registry.npmjs.org/
  @davidsouther/jiffies`), version `2026.26.1`, 2026-07-09; `gh repo view
  davidsouther/jiffies` returns "Could not resolve to a Repository."
- [6] Git — [Git Tools - Submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules)
  (`git submodule add` syntax, `.gitmodules` format, `init`/`update --init`
  semantics, empty-directory-after-plain-clone behavior).
- [7] [docker/compose#9517](https://github.com/docker/compose/issues/9517) —
  git-submodule failure surfaced through a Docker build context.
- [8] [monero-project/monero#5687](https://github.com/monero-project/monero/issues/5687)
  — Dockerfile + `git submodule init` failure.
- [9] [Azure/dev-spaces#391](https://github.com/Azure/dev-spaces/issues/391)
  — submodule files excluded from the Docker build context.
- [10] [k3d — `k3d image import`](https://k3d.io/v5.7.2/usage/commands/k3d_image_import/)
  (command syntax, flags, name-normalization rules).
- [11] [k3d — Importing Images](https://k3d.io/v5.9.0/usage/importing_images/)
  (mode descriptions: direct / tools-node / auto).
- [12] Corroborating community summary of k3d image-import mechanics
  (docker-daemon-to-containerd copy step), consulted as a lead, not
  authoritative on its own: oneuptime.com, "How to Use Docker Images with
  k3d."
- [13] [Kubernetes — Images: updating images](https://kubernetes.io/docs/concepts/containers/images/)
  (default `imagePullPolicy` rule: `Always` for `:latest`, `IfNotPresent`
  otherwise).
- [14] Groundcover — "imagePullPolicy in Kubernetes: Best Practices &
  Pitfalls" (practitioner corroboration of the same default rule and the
  `Never`-for-local-only-images recommendation).
- [15] Baeldung-class and DEV Community multi-stage Node+nginx examples
  (`dev.to/lovestaco/...`, `dev.to/bahachammakhi/...`) — treated as leads
  corroborating a widely-documented pattern, not as an authoritative source
  on their own.
- [16] Maxime Rouiller — "How to build a multistage Dockerfile for SPA and
  static sites."
- [17] `ppdeassis/docker-node-nginx-alpine` (GitHub) — a concrete worked
  example of the same node-build/nginx-serve shape.
- [18] Docker Hub — `library/node` tags listing (`24-alpine`,
  `24.18-alpine`, etc.), consulted 2026-07-09.
- [19] [nginx — `ngx_http_rewrite_module`, the `return` directive](https://nginx.org/en/docs/http/ngx_http_rewrite_module.html#return)
  (primary source: syntax, valid contexts, bare-status-code form).
- [20] `kubernetes-sigs/kustomize` — `examples/chart.md` and `helmGlobals.
  chartHome` documentation (local-chart-loading intent).
- [21] [kubernetes-sigs/kustomize#5818](https://github.com/kubernetes-sigs/kustomize/issues/5818)
  (closed, not planned) — `chartHome` silently ignored when `repo` is
  omitted; sibling reports `#5775`, `#5163`, `#4378` corroborate the same
  soft spot.
- [22] [Argo CD — Helm user guide](https://argo-cd.readthedocs.io/en/latest/user-guide/helm/).
- [23] [Argo CD — Application Specification Reference](https://argo-cd.readthedocs.io/en/latest/user-guide/application-specification/)
  (Helm auto-detection via `Chart.yaml` at `source.path` for a git-repo
  source).
