# Feature Design: Workloads (resume + trips static sites, in-cluster)

*Draft 2026-07-09*

> Feature-step design (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 9: Workloads (resume +
> trips)**, the project's **last** feature-step. It lands in the `workloads`
> layer (sync-wave 4, the last layer), sequentially after Networking (Feature 3,
> the Gateway/HTTPRoute/hostname/TLS contract) and Auth (Feature 5), both live.
> It has its own feature test (recorded below). The project as a whole is
> measured by `closing-bell.md`, not by this test. This step advances that
> project-level definition of done at its remaining Critical tasks **2, 3, and
> 6**; the human Closing Bell study, not this one automated test, is the
> authoritative judge of those tasks.
>
> Its research (`research.md`, `research/public.md`, `research/codebase.md`) is
> Reviewed. The reviewer block there (`Resolved by the long-loop reviewer`,
> 2026-07-09) settled the load-bearing open items. The decisive one: the live
> path is plain kustomize `resources:` YAML, not local `helmCharts:` inflation
> (decision h), and the charts stay as real helm-unittest artifacts. Those
> decisions are carried in as settled inputs below, not re-litigated. This is a
> **long-loop** run, so the draft gate is left open for a separately dispatched
> reviewer to clear.
>
> **Decision-reference convention (this doc).** Lettered `decision a`..`decision
> k` always cite *this feature-step's* `research.md`. Numbered `parent design
> decision N` cites the project `design.md` (§ Resolved by the long-loop
> reviewer). Numbered `research decision N` cites the *project* `research.md`
> (the `curl -k` / local-CA item is `research decision 3`).

## Libraries & Skills (carry forward to plan and build)

Per the project's cleared `research.md` (§ Libraries & Skills), this
feature-step's own cleared `research.md` (§ Libraries & Skills), and the project
`design.md`, the plan and build phases MUST load these skills via the harness's
skill-loading mechanism before working:

- **`developer:initialize`**, for the residual `mise` task work (the new
  `workloads:build` task entry). This feature adds **no** new `mise`-managed CLI
  tool pin. Every step of the build task runs on `git`, `docker`, and `k3d`,
  already present or already pinned (`k3d` `5.9.0`). `node`/`npm` run **only
  inside** the Docker build stage, so Node earns **no** `[tools]` entry in
  `mise.toml`, exactly as Docker is the repo's established ambient non-`mise`
  dependency (`GETTING_STARTED.md`, `tests/preflight.bats`). This is cleared
  research decision d.
- **`research:public`** and **`research:codebase`**, for the per-tool detail the
  build defers to build time: the exact `node:24` base-image tag, the nginx
  clean-URL config that makes `/blog` render, the exact `k3d image import --mode
  direct` invocation, and the two upstream repos' pinned submodule commits.

**No library-shipped agentic skill exists** for git submodules, Docker
multi-stage builds, `k3d`, nginx, helm-unittest, or `@davidsouther/jiffies` (the
SSG both workloads build with). This feature's cleared research reconfirmed the
absence at the per-mechanism level. Build to the in-repo contracts. `DEVELOPMENT.md`
fixes testing and the `charts/<chart>/tests/` repo layout. `ROUTING.md` fixes the
domain-vs-path policy that places resume at the apex and trips at a subdomain. The
two most load-bearing sibling designs are the authoritative contracts this step
builds to: `networking-istio` (Feature 3) for the Gateway/HTTPRoute/hostname/TLS
contract and the shared append-only `dnsNames` list, and `git-hosting-forgejo`
(Feature 6) for the per-component-subdirectory plain-`resources:` composition
shape appended to a shared layer `kustomization.yaml`. The forgejo sibling also
sets the precedent that real chart/config surprises surface only under a live
`kustomize build`/ArgoCD apply, which is why this step's build phase re-verifies
the nginx serving config and the image import against a live render.

## Purpose

Take the two real, already-in-production repositories that serve
`davidsouther.com` (with `/blog`) and `trips.davidsouther.com` today via GitHub
Pages, and **actually run both inside the local k3d cluster**. Each is built into
a container image, GitOps-reconciled behind the shared Istio Gateway at its dev
hostname. This extends the platform's parity claim ("the same charts and
manifests locally and in production") to David's real workloads, not just
infrastructure.

Both upstream repos are pure `@davidsouther/jiffies` static-site generators on
Node 24. `npm ci && npm run build` emits a fully static, self-contained site into
`docs/`, which is gitignored in both repos (confirmed). The image build must run
that build, because there is no committed static output to copy. Neither repo
ships a Dockerfile, Helm chart, or Kubernetes manifest. This step authors that
packaging from scratch, per workload, entirely inside the `agrippa` repo, leaving
both upstream repos untouched.

The deliverable is:

1. **A git submodule per workload** (`workloads/resume/`, `workloads/trips/`)
   pinning `github.com/davidsouther/resume` and `.../trips` at a commit. Each is
   the Docker build context's real, current upstream source.
2. **One imperative build task** (`mise run workloads:build`, running
   `scripts/workloads-build.sh`, the same shape as the `bootstrap` task): init
   the submodules, `docker build` a multi-stage image per workload (Node build
   stage, then nginx serve stage), and `k3d image import` each tag into the
   single-node `agrippa-dev` cluster. This is the one deliberate step outside
   GitOps, exactly as `bootstrap` is.
3. **Plain kustomize `resources:` YAML** per workload under
   `workloads/overlays/dev/<workload>/` (a Namespace, a Deployment pinning the
   locally-built image with `imagePullPolicy: Never`, a Service, and an
   `HTTPRoute` on the shared Gateway), composed by the **existing, unchanged**
   `apps/workloads.yaml` Application. TLS for the two dev hosts comes from two
   appended SANs on the shared `agrippa-gateway-tls` certificate, not a
   per-workload cert. This is not local `helmCharts:` inflation (decision h).
4. **A real, helm-unittest-tested Helm chart per workload** (`charts/resume/`,
   `charts/trips/`), the first real content in this repo's `charts/` directory,
   kept as the packaging artifact for the deferred prod/registry-push path and to
   satisfy `DEVELOPMENT.md`'s `charts/<chart>/tests/` convention. It is not the
   live GitOps render path.
5. **A `/healthz` liveness endpoint** for the personal site, served by nginx
   `location = /healthz { return 200; }` in the resume image's serving config
   (parent design decision 4), not a file added to the resume repo.

The value is narrow but real, and it is what the Closing Bell measures. An
operator gets David's real personal site (with `/blog`) and trips site running
in-cluster, reachable in a browser through the same Istio Gateway everything else
uses, and `ENV=dev bats tests/agrippa.bats` finally passes green against real
Deployments.

## Prior Art

- **`git-hosting-forgejo` (Feature 6), live.** The authoritative in-repo shape
  this step's live path imitates. A per-component subdirectory
  (`platform/overlays/dev/forgejo/`) whose own `kustomization.yaml` composes a
  Namespace plus authored CRs, appended as **one `resources:` entry** to the
  shared layer `kustomization.yaml`. Its `httproute.yaml` is the exact `HTTPRoute`
  template this step copies: explicit `parentRefs` to `agrippa-gateway`
  (`sectionName: https`), an explicit `matches: [{path: {type: PathPrefix, value:
  /}}]`, and same-namespace `backendRefs`.
- **`networking-istio` (Feature 3), live.** Defines the contract this step
  consumes. `agrippa-gateway` in `istio-ingress` terminates TLS on `:443` with
  `certificateRefs: [agrippa-gateway-tls]` and `allowedRoutes.namespaces.from:
  All`. There is one shared `agrippa-gateway-tls` `Certificate` (in
  `core/overlays/dev/gateway-cert.yaml`) with an explicit-SAN `dnsNames` list
  that every UI feature appends one line to. It carries five SANs live today
  (`argocd`, `dashboard.davidsouther.com`, `auth`, `git.davidsouther.com`,
  `flagsmith`), with neither `davidsouther.com` nor `trips.davidsouther.com`
  present yet. The `<prod-host>.127.0.0.1.nip.io` hostname scheme is reached
  through the k3d `:443` port-map, and the local-CA cert is probed with `curl -k`.
- **`observability` (Feature 8), live, the closest analog for the sync seam.**
  Its `grafana-httproute.yaml` is a plain-`resources:` `HTTPRoute` in an overlay,
  the identical shape this step authors, and `apps/observability.yaml` carries
  **both** the `ServerSideApply=true`/`SkipDryRunOnMissingResource=true`
  `syncOptions` **and** the `argocd.argoproj.io/compare-options:
  ServerSideDiff=true` annotation. `apps/core.yaml`'s own comment names the
  reason: an `HTTPRoute` reproduced a permanent OutOfSync (spec matched
  byte-for-byte, three `ignoreDifferences` forms all failed) until
  `ServerSideDiff=true` forced a real dry-run apply (argoproj/argo-cd#22151). The
  `workloads` layer introduces its first `HTTPRoute`s, so it needs the same seam
  (see § The `apps/workloads.yaml` sync seam).
- **`ROUTING.md`.** Fixes the placement this step realizes. `davidsouther.com`
  with `/blog` is a **path at the apex root** (same source, same identity, so one
  image and one route cover both), and `trips.davidsouther.com` is a **subdomain**
  (deploy-isolation and edge-session-isolation triggers in prod). Locally both
  are public static sites, and the placement is preserved as two separate hosts.
- **The `charts/` directory, absent until now.** Every `Chart.yaml` in the tree
  today is a Helm dependency-cache artifact under a `<layer>/overlays/dev/
  <component>/charts/<chart>-<version>/` path from `helmCharts:` inflating an
  **upstream** chart. No hand-authored in-repo chart exists yet, and no top-level
  `charts/` directory exists at all (`scripts/test-chart.sh` guards on exactly
  that, printing "no charts/ directory yet" and passing green). This step creates
  it. There is therefore **no in-repo precedent** for a hand-authored chart's
  internals (values schema, `templates/`, `tests/*.yaml`), so the design looks
  outward to helm-unittest's own docs (see § Open Artifact Decisions).
- **External worked examples** (full IEEE citations in `research/public.md`): the
  two upstream repos' `package.json`/`.gitignore`/CI read via `gh api` [1][2];
  git-submodule-vs-Docker-build-context mechanics [6]-[9]; `k3d image import`
  modes and `imagePullPolicy` defaults [10]-[14]; the Node-build-to-nginx-serve
  multi-stage pattern and nginx's `return` directive [15]-[19]; and the kustomize
  local-`helmCharts:` load-restrictor limitation that disqualified the
  chart-as-live-render path [20][21].

## User Journey and Metrics

**The operator's flow, from the bootstrapped `agrippa-dev` cluster (Features 0-8,
all live) with this Workloads content committed:**

1. The operator runs **`git submodule update --init`** (or a fresh
   `git clone --recurse-submodules`), then **`mise run workloads:build`**. The
   task initializes the two submodules, `docker build`s `resume:dev` and
   `trips:dev` (each: a `node:24` stage runs `npm ci && npm run build` to produce
   `docs/`, then an nginx stage serves it), and `k3d image import --mode direct`s
   both tags into the cluster node's containerd. This is the one imperative,
   non-GitOps step. The operator runs it once, and again whenever they want a
   fresh build, exactly as they run `bootstrap` once.
2. ArgoCD reconciles the `workloads` layer. The `resume` and `trips` Namespaces,
   Deployments (each running its locally-imported image with `imagePullPolicy:
   Never`), Services, and `HTTPRoute`s come up. The operator runs `kubectl -n
   argocd get application workloads` and sees it **Synced/Healthy**.
3. The operator opens `https://davidsouther.com.127.0.0.1.nip.io/` in a browser
   (or `curl -k`). The request path is host `:443`, then k3d port-map, then node
   IP (Gateway `externalIPs`), then gateway pods, then the `resume` `HTTPRoute`,
   then the resume Service, then the nginx pod. David's real resume renders,
   `/blog` renders the blog index, and `/healthz` returns `200`. TLS is
   terminated at the Gateway with the local-CA cert (a by-design untrusted-CA
   warning in a browser, which `curl -k` accepts).
4. The operator opens `https://trips.davidsouther.com.127.0.0.1.nip.io/`. The
   trips site renders a real trip itinerary, served publicly with no gating
   (parent design decision 3: production's Cloudflare Access edge has no local
   equivalent, so local trips is plainly reachable).
5. The operator runs `ENV=dev PUBLIC_HOST=davidsouther.com.127.0.0.1.nip.io
   TRIPS_HOST=trips.davidsouther.com.127.0.0.1.nip.io
   DASHBOARD_HOST=dashboard.davidsouther.com.127.0.0.1.nip.io bats
   tests/agrippa.bats` and sees it pass green. The gestalt's already-landed dev
   branch (`a9cdfbc`, Feature 0) now runs against real Deployments.

**Metrics / measures of done for this feature-step:**

- The feature test (`tests/workloads.bats`) is green. `workloads` is
  Synced/Healthy; the resume dev host serves `200` at `/` (with a personal-site
  content token) and `/blog`, and `200` at `/healthz`; the trips dev host serves
  `200` at `/` (with a trips content token). The test proves both sites render
  and are reachable end-to-end through the Gateway. The **depth** the Closing Bell
  names (Task 2's full "real resume/blog content", Task 3's "at least one real
  trip detail page") is judged by the human study; the feature test is the
  reachability-and-render backstop, discriminating a real rendered site from the
  empty-404 baseline and from the other workload's content (see § Feature Test).
- **Verification (not authoring) of `tests/agrippa.bats`.** Its three-edit dev
  branch is already committed (`a9cdfbc`, Feature 0; `git diff HEAD` empty,
  confirmed by cleared research). The build phase confirms `ENV=dev bats
  tests/agrippa.bats` passes green against these real Deployments with the
  documented host overrides. This step authors **no** new edits to that file.
- Adding this step does not regress earlier harness. `mise run test:push`
  (`test:static` + `test:policy` + `test:chart`, the last now actually exercising
  `helm unittest` against the new `charts/resume/` + `charts/trips/` suites for
  the first time), `mise run test:feature`, and the other component `bats` suites
  stay green (the `workloads.bats` `test:feature` exclusion lands with the test).

**Per-component SLO (defined here, watched in Grafana on the already-live
Observability stack; not a CI step, per `DEVELOPMENT.md`).** These are David's
real user-facing sites and the platform's outermost contract, so their budget is
tight, but they are trivially cheap static content. Target over a rolling 28-day
window: each workload's HTTP endpoint returns non-5xx at least 99.9% of the time
(from Istio gateway telemetry `istio_requests_total` for the `davidsouther.com.*`
and `trips.davidsouther.com.*` hosts), and `davidsouther.com.*/healthz` returns
2xx at least 99.9%. Burn-rate alert at 2% budget consumed in 1h. Recorded here,
instrumented against the live Prometheus/Grafana, not asserted by the feature
test.

**Failure modes to design against.**

- **`ErrImageNeverPull`, or the Deployment never becoming Ready**, because
  `workloads:build` was not run (or was run against a different cluster) before
  ArgoCD scheduled the pod. This is inherent to the deliberate imperative-step
  boundary and to `imagePullPolicy: Never`, which fails fast and honestly rather
  than attempting a doomed registry pull (cleared research decision c). Mitigated
  by documenting `workloads:build` as a required prerequisite in the operator
  flow (like `bootstrap`), and by the feature test asserting **real rendered
  content**, not merely that a pod exists.
- **The Docker build context containing an empty submodule directory**, so the
  build stage's `COPY` copies nothing (or the build produces an empty site). A
  plain local build context never auto-populates a submodule (cleared research
  decision a). Mitigated by `git submodule update --init` as **step 1** of
  `workloads:build`, and by the build failing loudly if `package.json` is absent.
- **The `workloads` `HTTPRoute`s leaving the layer permanently OutOfSync**, the
  Gateway-API/SMD symptom `apps/core.yaml` documents (argoproj/argo-cd#22151).
  Mitigated by adding the `ServerSideApply`/`SkipDryRunOnMissingResource`
  `syncOptions` **and** the `ServerSideDiff=true` compare-options annotation to
  `apps/workloads.yaml` (see § The `apps/workloads.yaml` sync seam), and by
  authoring `matches:` explicitly (the `core`/forgejo omitted-`matches` trap).
- **The two dev hosts served by a certificate that does not cover them**, if the
  `dnsNames` SAN append is missed. `curl -k` and the feature test tolerate this,
  but a strict client or a real browser lock would not, and the gestalt's parity
  intent wants it. Mitigated by appending **both** SANs to `agrippa-gateway-tls`
  (append-only, the accepted precedent).
- **`/blog` returning `301` instead of `200`**, if the serving config does not
  resolve the blog directory index. This depends on the exact shape of the
  jiffies build output at `/blog` (see the build-verify note in § Challenges).
  Mitigated by an nginx clean-URL config in the serving stage, and by the feature
  test following redirects (`curl -kL`) so it asserts the rendered blog index
  regardless of a trailing-slash bounce.
- **ArgoCD fetching the submodules over the network at reconcile time.** ArgoCD's
  repo-server fetches submodules by default when cloning, but the live path (the
  plain-YAML overlays) references **none** of the submodule content, and the
  images are already imported locally. The fetch is therefore harmless if it
  succeeds and unnecessary either way. If it ever slows or fails the `workloads`
  sync (a github reachability blip), disable submodule fetch for that
  Application. Watch at build, do not pre-optimize.
- **Cumulative single-node resource pressure** (the Flagsmith OOMKill, `db93c91`,
  is live evidence). Two static-nginx pods are cheap, but sized conservatively
  (see § The Deployments). If either will not schedule, check `kubectl describe
  node` / `kubectl top nodes` before raising requests.

## Specification

### Composition: two more `resources:` entries under the unchanged `workloads` Application

Following the realized `platform/overlays/dev/forgejo/` layout, each workload
composes as a **per-component subdirectory** whose own `kustomization.yaml` lists
plain authored YAML, appended as **one `resources:` entry** to the shared
`workloads/overlays/dev/kustomization.yaml` (today the literal `resources: []`
placeholder). `apps/workloads.yaml` (sync-wave 4) already points
`source.path: workloads/overlays/dev`, so its `source`/`destination` do not
change; only its `syncPolicy` seam and its target's composed content do. Proposed
layout (object/file names are Open Artifact Decisions where noted):

```text
workloads/overlays/dev/
├── kustomization.yaml            # resources: [resume, trips]   (was resources: [])
├── resume/
│   ├── kustomization.yaml        # resources: the four YAMLs below
│   ├── namespace.yaml            # wave -10; Namespace `resume`
│   ├── deployment.yaml           # wave 0; Deployment (image resume:dev, pullPolicy Never)
│   ├── service.yaml              # wave 0; ClusterIP Service :80 -> nginx :80
│   └── httproute.yaml            # wave 0; HTTPRoute `resume` -> the resume Service
└── trips/
    ├── kustomization.yaml        # resources: the four YAMLs below
    ├── namespace.yaml            # wave -10; Namespace `trips`
    ├── deployment.yaml           # wave 0; Deployment (image trips:dev, pullPolicy Never)
    ├── service.yaml              # wave 0; ClusterIP Service :80 -> nginx :80
    └── httproute.yaml            # wave 0; HTTPRoute `trips` -> the trips Service

workloads/                        # the git-submodule build context (NOT under overlays/)
├── resume/                       # git submodule -> github.com/davidsouther/resume
├── trips/                        # git submodule -> github.com/davidsouther/trips
├── resume.Dockerfile            # authored; multi-stage; nginx /healthz inline (Open Artifact Decision)
└── trips.Dockerfile             # authored; multi-stage (Open Artifact Decision)

charts/                           # the deferred-prod packaging artifact (NOT the live render path)
├── resume/                       # Chart.yaml + values.yaml + templates/{deployment,service,httproute}.yaml + tests/
└── trips/                        # same shape
```

There are **no secrets and no database** in either subtree. Both workloads are
pure static sites with no runtime datastore and no credential of any kind
(cleared research § Scope; no `secrets/dev/workloads/` is needed). This is
materially simpler than the forgejo sibling, with no KSOPS generator, no
cross-namespace credential, no `Database` CR, and no `managed.roles[]` append.

### The git submodules

`git submodule add https://github.com/davidsouther/resume.git workloads/resume`
and the equivalent for `trips`, producing a committed `.gitmodules` (two
`[submodule "workloads/<name>"]` entries) plus two gitlink entries pinning each
upstream at a commit. Both upstream repos are **public** and stay **untouched**.
The submodule directories are the Docker build context's source. They are **not**
referenced by any kustomize overlay, so ArgoCD's plain-YAML render never depends
on them being initialized. `git submodule update --init` is a real prerequisite
of `workloads:build` (step 1), because a plain local build context never
auto-populates a submodule (cleared research decision a).

### The image build and import (`mise run workloads:build`)

One imperative task, `[tasks."workloads:build"] file =
"scripts/workloads-build.sh"`, matching the `bootstrap` task's shape (a plain
idempotent bash script with `set -euo pipefail`, staged with comments). Its
stages:

1. **`git submodule update --init`**, to materialize `workloads/resume/` and
   `workloads/trips/`. Fail loud if a submodule is still empty afterward.
2. **`docker build` per workload**, a multi-stage image:
   - **Stage 1 (`FROM node:24 ... AS build`):** `npm ci && npm run build` inside
     the workload's submodule, emitting the static site to `docs/`. Node 24
     matches both repos' own `mise.toml`/CI pin (`engines.node >= 24`). The
     `prebuild` (typecheck plus lint) that runs automatically is expected to pass
     at build time, as it does in each repo's GitHub Actions today, subject to the
     libc/offline build-verify in § Challenges.
   - **Stage 2 (`FROM nginx:alpine`):** `COPY --from=build .../docs
     /usr/share/nginx/html`, plus the serving config (the clean-URL rule for
     `/blog`, and, resume only, `location = /healthz { return 200; }`). The Node
     runtime and `node_modules` are discarded from the shipped image.
   - Tagged explicitly **`resume:dev`** / **`trips:dev`** (never `:latest`, which
     would default `imagePullPolicy` to `Always`, and an explicit tag also avoids
     `k3d image import`'s `:latest` name-normalization, cleared research decision
     c and [10]).
   - **Build context and the authored files' location.** The submodule cannot
     hold authored files (it is the untouched upstream repo), so the Dockerfile
     lives **outside** the submodule and is passed with `-f`, and the nginx
     `/healthz` plus clean-URL config is written **inside the Dockerfile serving
     stage** (a `RUN` heredoc), needing nothing extra in the build context. The
     exact `-f`/context/heredoc spelling is an Open Artifact Decision resolved at
     build against a live `docker build`.
3. **`k3d image import <tag> --mode direct --cluster agrippa-dev`** per tag, which
   copies the freshly-built image from the host Docker daemon into the k3s node's
   containerd store (the node has no access to the host daemon otherwise).
   `--mode direct` is the simplest and cheapest mode for this **single-node**
   cluster, with no tools-container hop (cleared research decision b).

No host-side Node or npm is needed for any stage (decision d). The task is
idempotent (re-running rebuilds and re-imports), and, like `bootstrap`, it is
deliberately **outside GitOps**. The GitOps-managed Deployments pin the tag this
task produces.

### The Deployments, Services, and the nginx serving layer

Per workload, plain authored YAML in the overlay subdirectory:

- **Deployment** (wave 0): 1 replica (dev), one container from `resume:dev` /
  `trips:dev`, **`imagePullPolicy: Never`** (the image only ever exists in the
  node's local containerd, cleared research decision c), `containerPort: 80`.
  **`resources`** set explicitly and modestly (cleared research decision j; the
  live cluster is under cumulative pressure): `requests: {cpu: 25m, memory:
  32Mi}`, `limits: {memory: 128Mi}`, well below forgejo's `100m`/`256Mi` since a
  static-file nginx pod is far cheaper. A **readiness/liveness probe** so ArgoCD's
  Healthy gate means the site actually serves (the probe target and timing are an
  Open Artifact Decision, proposed `httpGet /healthz` for resume and `httpGet /`
  for trips).
- **Service** (wave 0): `ClusterIP`, port `80` to the container's `80`, the
  target of the `HTTPRoute`'s same-namespace `backendRefs`.
- **The nginx serving config** carries the two behaviors above: clean-URL
  resolution so `/blog` renders the blog index, and, resume only, the `location =
  /healthz { return 200; }` block (parent design decision 4; valid minimal
  primary-source nginx syntax [19]). trips needs no `/healthz` (the gestalt probes
  only the personal site). Whether resume and trips share one base nginx config or
  carry two is an Open Artifact Decision (a shared config with the `/healthz` block
  is harmless on trips). The config lives in the **image** (the Dockerfile serving
  stage), not a Kubernetes ConfigMap and not a file added to the resume repo,
  keeping both the live overlay and the chart to exactly Deployment plus Service
  plus HTTPRoute.

### The shared Gateway routes and the certificate SAN append (consuming Networking's contract)

- **`HTTPRoute` per workload** in its own namespace (wave 0), the forgejo/grafana
  template exactly. `parentRefs: [{name: agrippa-gateway, namespace:
  istio-ingress, sectionName: https}]`; `hostnames:
  [davidsouther.com.127.0.0.1.nip.io]` / `[trips.davidsouther.com.127.0.0.1.
  nip.io]`; an **explicit** `matches: [{path: {type: PathPrefix, value: /}}]`
  (the omitted-`matches` OutOfSync trap, avoided by fiat); `backendRefs:` the
  same-namespace Service on port `80`. The backend is plain HTTP (nginx serves
  plain HTTP and the Gateway terminates the only TLS on the path), so **no**
  backend `DestinationRule` (unlike ArgoCD's HTTPS re-origination). No
  `ReferenceGrant` is needed (same-namespace backend, and the Gateway's
  `allowedRoutes.namespaces.from: All` admits both routes).
- **Append two SANs** to the shared `agrippa-gateway-tls` `Certificate`'s
  `dnsNames` in `core/overlays/dev/gateway-cert.yaml`:
  `davidsouther.com.127.0.0.1.nip.io` and `trips.davidsouther.com.127.0.0.1.
  nip.io`. This is a **`core`-layer**, append-only edit to one shared, mutable
  list (the accepted precedent; the cert carries five SANs today; re-check live
  before editing, since a concurrent feature could have appended). It is the
  **only** TLS object this step touches. **There is no per-workload
  `Certificate`.** The shared Gateway's single `https` listener references only
  `agrippa-gateway-tls`, so a per-workload cert would be unreferenced and unused,
  and every prior UI feature (forgejo, keycloak, grafana, flagsmith) consumed TLS
  the same way, by appending a SAN, never by minting its own cert. In prod, TLS is
  the Cloudflare edge's concern, not a per-workload local cert, so the charts
  template no `Certificate` either. (Ratification note: cleared decision h and
  parent design item 2 both list "Certificate" among the workload's objects. That
  wording predates the realized five-SAN shared-cert model; this design discharges
  it as the shared-cert SAN append. See § Open Artifact Decisions.)

### The `apps/workloads.yaml` sync seam

`apps/workloads.yaml` today carries only `syncPolicy.automated: {prune,
selfHeal}`, with **no** `ServerSideApply`/`ServerSideDiff` seam (verified live).
It has not needed one because its target is the empty `resources: []`
placeholder. This step introduces the layer's first `HTTPRoute`s, which are
exactly the Gateway-API resource class that reproduced a permanent OutOfSync
(spec-byte-identical, unfixable by `ignoreDifferences`) on `core` until
`ServerSideDiff=true` forced a real dry-run apply (argoproj/argo-cd#22151,
documented verbatim in `apps/core.yaml`). Add the same seam every other
resource-bearing layer carries:

- `syncPolicy.syncOptions: [ServerSideApply=true, SkipDryRunOnMissingResource=true]`
- `metadata.annotations: {argocd.argoproj.io/compare-options: ServerSideDiff=true}`

This is the conservative, convention-matching default (`core`, `storage`,
`platform`, `observability` all carry it, and `observability`, a plain-`HTTPRoute`
plus Deployments layer with no CRD-defining content of its own, is the direct
precedent). It is idempotent and low-risk. The build phase verifies that
`workloads` reaches Synced/Healthy after the resources land. If a plain apply
happened to reconcile cleanly without the seam, the seam is harmless; the
HTTPRoute precedent says add it.

### Intra-workload sync-wave scheme

Simple, with no cross-resource ordering dependency (no DB-before-Deployment,
unlike Features 5-7). The **Namespace is at wave `-10`** (matching
forgejo/keycloak), and the **Deployment/Service/HTTPRoute are at wave `0`** (via
`commonAnnotations` on each workload `kustomization.yaml`, or inline). ArgoCD
creates the Namespace before its contents regardless, so the explicit `-10`
matches the established convention and is defensive, not load-bearing. The
Namespace objects are bare (name plus the sync-wave annotation), matching the
forgejo/keycloak namespaces exactly, which carry no ambient/injection label
(verified live: no app namespace in `platform`/`observability`/`core` carries an
`istio.io/dataplane-mode` or `istio-injection` label; the meshed Gateway routes
to the Service without requiring backend mesh membership, and the gateway emits
the `istio_requests_total` telemetry the SLO reads).

### The Helm charts (`charts/resume/`, `charts/trips/`), the deferred-prod artifact

`charts/resume/` and `charts/trips/` are authored as real, minimal,
helm-unittest-tested charts: a `Chart.yaml`, a `values.yaml` (image
repository/tag/pullPolicy, replica count, resources, hostname), a `templates/`
directory rendering the **same three objects** the live overlay hand-authors
(Deployment plus Service plus HTTPRoute, and **no** `Certificate`, matching the
live path's shared-cert model and prod's edge-TLS model), and a `tests/` suite of
helm-unittest `*.yaml` assertions (that the Deployment pins the values-driven
image and `imagePullPolicy`, that the Service targets the right port, and that the
HTTPRoute carries explicit `matches:` and the values-driven hostname). These
charts are the packaging artifact for the deferred prod/registry-push path, not
the live GitOps render path (decision h: local `helmCharts:` inflation of a
repo-root chart collides with kustomize's `LoadRestrictionsRootOnly` across the
deep `overlays/dev` tree, and relaxing it cluster-wide is out of this step's
scope). They also make `mise run test:chart` (green-on-empty until now) actually
exercise `helm unittest` for the first time.

On the "two representations kept in sync by discipline" cost (cleared research
decision h names this as a smaller sub-decision that does not gate design):
**decided, hand-author both the live plain YAML and the chart** (research's
option c), rather than rendering the live YAML from the chart via `helm template`
in `workloads:build`. Rationale: the objects are thin (three per workload, no
runtime config surface beyond an image tag and a hostname), the duplication is
small, and rendering-from-chart would add a render/commit step that muddies
`workloads:build`'s single, clean responsibility (build and import images,
nothing else). The two representations stay aligned **by discipline**, not by a
generator: helm-unittest asserts the chart against author-written expectations,
and it never compares the chart's output to the hand-authored live overlay, so it
cannot by itself detect the two drifting apart. A build-phase or plan-phase check
that renders `helm template` and diffs it against the live overlay is the way to
catch drift if that risk grows; the accepted cost here is that alignment is
maintained deliberately.

### Cross-step touches (summary)

- **`workloads/overlays/dev/kustomization.yaml`**: replace `resources: []` with
  `resources: [resume, trips]`. This step owns this file entirely (it is the
  `workloads` layer's own root, not a shared multi-sibling list).
- **`core/overlays/dev/gateway-cert.yaml`** (the shared `agrippa-gateway-tls`
  `Certificate`, `core` layer): append **two** `dnsNames` entries. Shared,
  append-only list (Networking's contract); re-check live before editing.
- **`apps/workloads.yaml`**: add the `ServerSideApply`/
  `SkipDryRunOnMissingResource` `syncOptions` **and** the `ServerSideDiff=true`
  compare-options annotation. This step owns `apps/workloads.yaml` (it is the last
  layer, with no parallel sibling contending for it).
- **`mise.toml`**: add one `[tasks."workloads:build"]` entry. No new `[tools]`
  pin.
- **`.gitmodules`** (new) plus two gitlink entries, the two submodules.
- **`scripts/test-feature.sh`**: add `workloads.bats` to the probe-suite
  exclusion `case` list (it drives the long-lived `agrippa-dev` cluster and the
  GitOps-reconciled `workloads` layer, not the throwaway `agrippa-feature`
  cluster), the same one-line edit every sibling suite made. **Lands with the
  feature test in this design phase.**

### Challenges (deferred to build, shapes fixed here)

- **The exact nginx serving config and the shape of the jiffies build output at
  `/blog`.** The design assumes jiffies emits a directory index at
  `docs/blog/index.html`, so `/blog` trailing-slash-redirects to `/blog/`, and an
  nginx clean-URL rule (`try_files`/`index`) plus the `-L` follow in the test
  handle it. This shape is inferred from the repos' `package.json`/`posts/`
  layout, not from a built site. **Build-verify** by rendering the site and
  serving it: if jiffies instead emits a flat `docs/blog.html` (or the index at
  another path), the failure-mode framing changes (no trailing-slash redirect) and
  the nginx rule takes a different shape. Resolve the exact serving config, and
  the `/blog` failure-mode's real cause, against a live `docker build` plus a real
  request.
- **The build stage's libc and network posture.** Stage 1's base is pinned at
  build; `node:24-alpine` (musl) is the smaller default, but `npm run build`'s
  `prebuild` runs `biome`, which resolves platform-native binaries
  (`@biomejs/cli-linux-*-musl`) at `npm ci`, and musl-native optional-dep
  resolution is a common fresh-container build failure. Prefer `node:24` (glibc)
  unless the alpine variant is confirmed to build both repos cleanly. Separately,
  research confirmed trips builds fully offline (committed Wikipedia cache); resume
  being network-free after `npm ci` is asserted, not verified, so confirm the
  resume build needs no network fetch (a restricted Docker build would fail one).
- **The pinned `node:24`/`nginx:alpine` tags and the exact `npm run build` output
  path** (`docs/` per both repos' `package.json`, re-confirmed against the pinned
  submodule commit).
- **ArgoCD submodule-fetch behavior** on the `workloads` Application (see § Failure
  modes), verified at build, disabled only if it bites.
- **helm-unittest `tests/*.yaml` shape**, following helm-unittest's own
  `DOCUMENT.md` (no in-repo precedent; see § Open Artifact Decisions).

## Alternatives

- **Consume the local chart via kustomize `helmCharts:` inflation (chart as the
  live render path).** Rejected (decision h), proven by a live `kustomize build
  --enable-helm` smoke test: a repo-root `charts/<chart>/` (the `DEVELOPMENT.md`
  convention) plus ArgoCD building from the deep `workloads/overlays/dev` fails
  kustomize's default `LoadRestrictionsRootOnly` (`security; file
  '.../charts/resume/values.yaml' is not in or below '.../workloads/overlays/
  dev/...'`). The only fixes, relaxing the load restrictor cluster-wide (a
  security-posture change to the `core`/ArgoCD layer this step does not own) or
  relocating the chart below the overlay (violating the `charts/<chart>/`
  convention and colliding with kustomize's own `./charts` fetch dir), both
  disqualify it. Plain `resources:` YAML is strictly lowest-blast-radius.
- **A per-workload ArgoCD `Application` using native Helm-from-git.** Rejected.
  It respects the repo-root chart and is single-source-of-truth, but forces the
  `workloads` layer off the "one `apps/workloads.yaml` composes the whole layer
  via kustomize" shape (which needs **no** change) onto per-workload Applications,
  more new structure than the conservative default warrants (decision h).
- **A per-workload cert-manager `Certificate`.** Rejected. The shared Gateway's
  single `https` listener references only `agrippa-gateway-tls`, so a per-workload
  cert would be unreferenced. Append two SANs to the shared cert instead, exactly
  as every prior UI feature did.
- **Serve stage 2 with `@davidsouther/jiffies`' own Node static server** (both
  repos already ship one via `npm start`). Rejected (decision i). It would keep
  serving byte-identical to each repo's own expectation, but at a larger runtime
  image and with **no** confirmed one-line `/healthz` equivalent to nginx's
  `return 200;` (the parent design chose nginx precisely for that). Reopening a
  settled decision for a larger image and an unconfirmed healthz path is no free
  upgrade.
- **A committed `public/healthz` static file in the resume repo.** Rejected
  (parent design decision 4). Keep the change inside `agrippa`'s serving config
  and leave the upstream repo untouched, consistent with the "author packaging in
  `agrippa`" posture.
- **Vendor upstream source as a subtree or a periodic copy instead of a
  submodule.** Rejected (parent design decision 2 / cleared research). A submodule
  reads real, current upstream source at a pinned commit, git-natively, without a
  drifting vendored copy.
- **Build the sites to GitHub Pages and point the cluster at them externally.**
  Rejected by the parent design. It would not exercise the in-cluster request
  path (Gateway, HTTPRoute, pod) that is the platform's whole contract.
- **`imagePullPolicy: IfNotPresent`.** Rejected in favor of `Never` (decision c).
  `IfNotPresent` still attempts a registry pull on any cache miss (a node
  restart, a `k3d cluster stop`/`start`), which fails against a registry these
  images were never pushed to. `Never` states "local build only" honestly and
  fails without a doomed network call.
- **A single shared `workloads` namespace** instead of per-workload `resume` and
  `trips` namespaces. A real option (simpler: one Namespace, two workload
  subdirs), surfaced as an Open Artifact Decision. The proposed default is
  per-workload namespaces, matching the per-component-owns-its-namespace pattern
  every sibling used and keeping blast radius minimal for two genuinely distinct
  deploy identities (`ROUTING.md` isolates trips onto its own subdomain).

## Summary

This last feature-step runs David's two real static sites inside the local k3d
cluster. It vendors each upstream repo as a **git submodule** under `workloads/`,
adds one imperative **`mise run workloads:build`** task (init submodules,
multi-stage `docker build` per workload, `k3d image import --mode direct`), and
composes each workload as **plain kustomize `resources:` YAML** (Namespace,
`imagePullPolicy: Never` Deployment, Service, shared-Gateway `HTTPRoute`) under
`workloads/overlays/dev/<workload>/`, appended to the unchanged
`apps/workloads.yaml` Application, not local `helmCharts:` inflation (decision h).
It appends two SANs to the shared `agrippa-gateway-tls` cert, adds the
`ServerSideApply`/`ServerSideDiff` sync seam to `apps/workloads.yaml` (the layer's
first `HTTPRoute`s need it), serves `/healthz` from nginx in the resume image
(parent decision 4), and keeps `charts/resume/` plus `charts/trips/` as real
helm-unittest artifacts for the deferred prod/registry path. No secret, no
database, and no Flagsmith gating apply to two static sites. The one feature test
proves both sites render real content through the Gateway with a working
`/healthz`. `tests/agrippa.bats` is verified, not re-authored, because its fix is
already committed.

This Design-phase run does **not** deploy the workloads. Initializing the
submodules, building and importing the images, committing the overlays, charts,
and appends, and letting ArgoCD reconcile are all build-phase work. The feature
test is left **RED** (baseline recorded below), and the build phase turns it
green.

### Deferred decisions (park to `TASKS.md` at cleanup)

- **`agathon` and `ailly.dev`** (parent design decision 1). Neither repo is
  inspected, neither is in the Closing Bell's critical tasks; roadmap seams only.
- **Trips' Cloudflare Access to Terraform port, and CI to Forgejo Actions port.**
  Prod/post-git-hosting concerns; forgejo-runner does not exist in this build.
- **Publishing the built images to a real registry** (Forgejo's own or GHCR), the
  cloud-cycle parity seam the charts preserve. The local build stays
  registry-less by design.
- **Correcting the parent `plan.md`'s Feature 9 item 5 framing** (it still
  describes the already-committed `tests/agrippa.bats` fix as pending), a
  documentation-accuracy fix for the next opportunity that touches it, not a
  blocker (cleared research decision e).
- **Relaxing kustomize's load restrictor to enable local `helmCharts:` chart
  inflation** as the single-source-of-truth live path, deferred with the
  prod/registry cycle that would also want the chart pushed (decision h keeps it
  out of this step's scope).

### Open Artifact Decisions

Concrete artifact choices this design invents that are **not** fixed by a skill
template, an existing project convention, or the cleared `research.md` (which
already settled the composition mechanism, the nginx-vs-jiffies choice, the
`resources` direction, the `imagePullPolicy`, the submodule mechanism, and the
`tests/workloads.bats` / `scripts/workloads-build.sh` / `workloads/{resume,trips}`
names). Confirm these fit intent before clearing the draft.

**`workloads/resume.Dockerfile` and `workloads/trips.Dockerfile` (vs one shared
`workloads/Dockerfile` plus a `--build-arg WORKLOAD=…`), where the nginx
`/healthz` plus clean-URL config lives (inline `RUN` heredoc in the serving stage
vs a `COPY`-ed `workloads/nginx.conf`), and whether resume and trips share one
nginx config or carry two.**
Proposed: two per-workload Dockerfiles with the nginx config written inline in
the serving stage (needs nothing extra in the build context), and a shared base
nginx config carrying the `/healthz` block (harmless on trips).

**The built image tags (`resume:dev`, `trips:dev`).**
Proposed: `resume:dev` / `trips:dev`, an explicit non-`:latest` tag (research
requires non-`:latest`; the exact string is invented here). The Deployments and
the charts' `values.yaml` pin these.

**The readiness/liveness probe target per workload** (`httpGet /healthz` for
resume, `httpGet /` for trips).
Proposed: as stated. This determines whether ArgoCD reports the Deployment
Healthy, so it is surfaced rather than left implicit; the exact timing is
build-tuned.

**The Helm charts' internal shape**: the `values.yaml` schema (image
`repository`/`tag`/`pullPolicy`, `replicaCount`, `resources`, `hostname`, and a
`healthz` toggle), the `templates/` helper layout, and the helm-unittest
`tests/*.yaml` assertion shape. No in-repo precedent (first hand-authored chart).
Proposed: a minimal three-template chart (`deployment.yaml`, `service.yaml`,
`httproute.yaml`) with a flat `values.yaml`, and a `tests/` suite asserting the
image pin, `imagePullPolicy: Never`, the Service port, and the HTTPRoute's
explicit `matches:` plus hostname, following helm-unittest's own `DOCUMENT.md`.

**Ratifying that "Certificate" is discharged by the shared-cert SAN append, not a
per-workload `Certificate` object.** Cleared decision h and parent design item 2
both list "Certificate" among the workload's objects, but the realized networking
contract is one shared cert with per-host SANs. This design appends two SANs and
mints no per-workload cert (see § The shared Gateway routes). Confirm this matches
intent; a per-workload cert is unreferenced under the single-listener Gateway.

**The workload namespaces (`resume`, `trips`, vs one shared `workloads`).**
This is closer to confirming an already-prescribed convention than a live choice:
every sibling uses per-component namespaces, and `ROUTING.md` plus the parent
design isolate trips, so per-workload namespaces are the strong default. A single
`workloads` namespace remains the reasonable alternative if preferred.

## Feature Test

**Path:** `tests/workloads.bats` (following `DEVELOPMENT.md`'s
`tests/<feature>.bats` convention, feature = "workloads"; the tool qualifier is
dropped just as `cluster-core.bats` dropped `-k3d`, `networking.bats` dropped
`-istio`, and `git-hosting.bats` dropped `-forgejo`; cleared research decision k).
It is distinct from the cross-cutting `tests/agrippa.bats` gestalt, whose own dev
branch is already committed and is verified, not authored, by this step.

**User story (Given / When / Then).** *Given* the bootstrapped long-lived
`agrippa-dev` cluster (Features 0-8) with this Workloads content committed, the
`resume:dev`/`trips:dev` images built and `k3d image import`-ed by `mise run
workloads:build`, and ArgoCD reconciling the two plain-`resources:` overlays into
the `workloads` layer, *When* an operator reaches each site through the shared
Istio Gateway at its dev host, *Then* the `workloads` Application is
Synced/Healthy, the personal-site host serves `200` with real rendered content at
`/` and (following the trailing-slash redirect) at `/blog`, its `/healthz`
returns exactly `200`, and the trips host serves `200` with real rendered content
at `/`. This proves both of David's real sites run in-cluster and are reachable
end-to-end through the Gateway over the local-CA cert. `curl -k`/`-kL` tolerate
the deliberately-untrusted local CA (research decision 3).

The test proves reachability and render (a real site, not the empty-404 baseline,
and not the *other* workload's content) via a per-host content token grep. It
deliberately scopes to the primary user story ("both sites run in-cluster and are
reachable"). The **deeper** Closing Bell assertions (Task 2's full resume/blog
content, Task 3's "at least one real trip detail page") are judged by the human
Closing Bell study, which is that project-level artifact's role; the design does
not claim this one test discharges them. The content tokens (`david` on the resume
`/`, `trip` on the trips `/`) are deliberately loose reachability-and-render
proofs; the build phase confirms and may tighten them against the live-rendered
site (a specific resume section header, a specific trip title). The suite
deliberately does **not** tear the cluster or the workloads down (long-lived,
GitOps-managed), and it performs static GETs only, so it has nothing to clean up.

**Current state: RED (baseline captured live this run).** With
`workloads/overlays/dev` still the `resources: []` placeholder, the `workloads`
Application is already `Synced/Healthy` on empty content (live-confirmed: `kubectl
-n argocd get application workloads` returns `Synced Healthy`), so the suite's
precondition (THEN 0, `workloads` Synced/Healthy) passes even now, exactly as
`git-hosting.bats`' THEN 0 passed on the argocd-only `platform`. The RED lands at
the **first render assertion**: `curl -k` to
`https://davidsouther.com.127.0.0.1.nip.io/` returns **`404`** today
(live-confirmed; the Gateway answers the TLS handshake for any SNI but no
`HTTPRoute` routes the host, so an empty 404), not `200`, so the `[ "$output" =
"200" ]` assertion fails there. `/blog`, `/healthz`, and the trips host likewise
return `404`. **Verified live this run: `bats tests/workloads.bats` fails at that
first resume `/` status assertion (`[ "$output" = "200" ]`), exit 1.** That red
state defines "done."
This Design-phase run does **not** turn it green. Building and importing the
images, committing the overlays and the shared-list appends, wiring the sync seam,
and the ArgoCD reconcile are all build-phase work outside this phase's
write-only-the-test gate.
