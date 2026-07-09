# Implementation Plan: Workloads (resume + trips static sites, in-cluster)

*Reviewed 2026-07-09*

> Feature-step plan (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 9: Workloads (resume +
> trips)**, the project's **last** feature-step. Its `design.md` (and
> `research.md`) are already Reviewed by a separately dispatched long-loop
> reviewer; this plan is a paper plan against that cleared design and has not
> been built. This is a **long-loop** run: the draft gate below is left open
> for a separately dispatched reviewer to clear — this session does not clear
> it itself. The step decomposition follows the two closest-precedent sibling
> plans' shape (`git-hosting-forgejo/plan.md`: a Step 0 layout/stub step, a
> final proof-and-regression step, and per-wave content steps in between;
> `networking-istio/plan.md`, `storage-postgres-valkey/plan.md`: the same
> three-part shape) closely enough that the forward-backward method's map-file
> mechanism was not needed — the six-step shape below was directly evident
> from those precedents plus this feature's own two-symmetric-workloads shape
> (resume then trips, each a repeat of one wiring unit) and its one genuinely
> new mechanic (the imperative git-submodule + Docker + `k3d image import`
> pipeline, which has no wave number at all — it runs entirely outside
> ArgoCD, ahead of any GitOps content).

**Feature test:** `tests/workloads.bats`
**User story:** Given the bootstrapped `agrippa-dev` cluster (Features 0-8,
all live) with this Workloads content committed, the `resume:dev`/`trips:dev`
images built and `k3d image import`-ed by `mise run workloads:build`, and
ArgoCD reconciling the two plain-`resources:` overlays into the `workloads`
layer — each workload a Namespace, an `imagePullPolicy: Never` Deployment, a
Service, and an `HTTPRoute` on the shared Istio Gateway — when an operator
reaches each site through the Gateway at its dev host, then the `workloads`
Application is Synced/Healthy, the personal-site host serves `200` with real
rendered content at `/` and (following the jiffies build's directory-index
redirect) at `/blog`, its `/healthz` returns exactly `200`, and the trips host
serves `200` with real rendered content at `/` — proving both of David's real
sites run in-cluster and are reachable end-to-end through the Gateway over the
local-CA cert. This advances the project's remaining Closing Bell critical
tasks 2, 3, and 6; the human study, not this test, is the authoritative judge
of those tasks' full depth.

**Steps:**
- [x] Step 0: API surface area (file layout, the `apps/workloads.yaml` sync
  seam, GitOps-consumed stubs)
- [x] Step 1: The git submodules and the imperative `mise run workloads:build`
  image pipeline
- [x] Step 2: Wave 0 — the `resume` workload wired live, plus its Gateway-cert
  SAN append
- [x] Step 3: Wave 0 — the `trips` workload wired live, plus its Gateway-cert
  SAN append
- [x] Step 4: The packaging Helm charts (`charts/resume/`, `charts/trips/`),
  real and helm-unittest-tested
- [x] Step 5: Full GREEN — `tests/workloads.bats`, `tests/agrippa.bats`
  verification, and the regression sweep

**Libraries & Skills (carried forward from `design.md`/`research.md`; load
before each build step):**

- `developer:initialize` — carried forward per convention, but this
  feature-step exercises no residual `mise`-managed CLI-tool pin. `git`,
  `docker`, and `k3d` are every tool `workloads:build` needs, all already
  ambient or pinned (`k3d` `5.9.0`); Node runs only inside the Docker build
  stage, so it earns no `[tools]` entry, exactly as Docker itself is the
  repo's established non-`mise` ambient dependency. Nothing in the `[tools]`
  table of `mise.toml` changes across any step below — only a new
  `[tasks."workloads:build"]` entry (Step 1).
- `research:public` and `research:codebase` — for the per-tool detail each
  step below explicitly defers to build time: the exact `node:24` base-image
  digest, the real jiffies `/blog` output shape (directory index vs. flat
  file) and the nginx clean-URL rule it needs, the exact `k3d image import
  --mode direct` invocation and flags, and the two upstream repos' pinned
  submodule commits. The ArgoCD submodule-fetch prerequisite
  (`reposerver.enable.git.submodule: "false"` on `argocd-cmd-params-cm`) is
  already satisfied — applied and live-verified by the coordinator before
  this feature-step's build began (see § Resolved by the long-loop reviewer,
  item 3) — so no research or build-time decision remains on that front.
- No library-shipped agentic skill exists for git submodules, Docker
  multi-stage builds, `k3d`, nginx, helm-unittest, or `@davidsouther/jiffies`
  (reconfirmed by this feature's own cleared `research.md`). Build to
  `DEVELOPMENT.md` (§ Testing, § repo layout), `ROUTING.md` (the
  apex-path-vs-subdomain placement already fixed for these two hosts), and
  the two most load-bearing sibling designs/plans directly —
  `networking-istio` for the Gateway/HTTPRoute/hostname/TLS contract and the
  shared append-only `dnsNames` list, and `git-hosting-forgejo` for the
  per-component-subdirectory plain-`resources:` composition shape appended to
  a shared layer `kustomization.yaml`, and for the precedent that real
  chart/config surprises surface only under a live `kustomize
  build`/`docker build`/ArgoCD apply, not by inspection.

**Patterns beat (`patterns:using-patterns` consulted).** Same conclusion as
every completed sibling, re-verified for this feature-step's own pressures
rather than assumed. This feature-step has no typed application code — only
GitOps infrastructure config (Kustomize `resources:` composition, one
authored `Namespace`/`Deployment`/`Service`/`HTTPRoute` per workload, two
Dockerfiles, one bash build script, two hand-authored Helm charts with their
own `tests/*.yaml`, and one bats feature test) — so `newtype`,
`domain-objects`, `builder`, `visibility`, `parse-dont-validate`,
`type-states`, `repository`, `aggregate`, and `unit-of-work` all require a
typed domain model that does not exist here, and none is invoked. Two
patterns shape *how* the surface and its one test are written:
**`arrange-act-assert`**, for the single bats `@test` (the existing
`run`/assert shape `tests/workloads.bats` already follows: `wait_for_...`
arrange/act helper, then a sequence of `run curl` acts each paired with its
own assert block) and for the helm-unittest `tests/*.yaml` files Step 4
authors (each a values-in/rendered-manifest-out assertion with no
interleaving); and **`errors-typed-untyped`**, resolved to the untyped side —
a `kubectl`/`curl`/`docker`/`k3d` exit code and an ArgoCD `Application`'s
`sync`/`health` status are the correct, sufficient failure signals here,
consumed only by an operator's shell, `bats`, and ArgoCD's own reconcile
loop; no in-process caller needs to match distinct typed failure modes. No
other pattern's discriminator fires: nothing here is a many-field
constructor (`builder`), a persisted aggregate (`repository`/`aggregate`/
`unit-of-work`), or a lifecycle-phased object (`type-states`) — the closest
tempting fit, "the `workloads:build` pipeline has ordered stages" (init
submodule, build, import), is a linear imperative script, not a domain type
whose *illegal states* need making unrepresentable, so `type-states` does not
apply either.

## Step 0: API surface area

Fix every file path, directory layout, and object name across the whole
feature-step before any of it has real content, mirroring both completed
siblings' Step 0 convention (fixed identifiers, honest inert stubs, no logic
or spec). Two kinds of change land here:

**1. The `apps/workloads.yaml` sync seam** (real, not a stub — idempotent and
low-risk, so it lands now exactly as every sibling's own Step 0 landed its own
seam immediately). `apps/workloads.yaml` today carries `syncPolicy.automated`
only, no `syncOptions` and no `compare-options` annotation (confirmed live
this session). Add the identical pair `apps/core.yaml`, `apps/storage.yaml`,
`apps/platform.yaml`, and `apps/observability.yaml` all already carry,
pre-empting the controller-defaulted-field permanent-`OutOfSync` symptom
(argoproj/argo-cd#22151) the `workloads` layer's own first `HTTPRoute`s (Steps
2-3) would otherwise be the first Gateway-API resources in this layer to hit:

```diff
 metadata:
   name: workloads
   namespace: argocd
   annotations:
     argocd.argoproj.io/sync-wave: "4"
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

**2. The `workloads/overlays/dev/{resume,trips}/` directory layout**, fixing
every file and object name the cleared `design.md` Specification already
resolved (its reviewer-resolved Resolved-by-the-long-loop-reviewer items 1-7).
**The top-level `workloads/overlays/dev/kustomization.yaml` stays the
existing `resources: []`** — none of these new files are referenced yet, so
`workloads` stays trivially Synced/Healthy on empty content (preserving the
RED baseline's THEN 0 pass) and nothing new reaches the live cluster this
step, exactly mirroring both siblings' own Step 0 discipline:

```text
workloads/overlays/dev/
├── kustomization.yaml            # UNCHANGED this step: resources: []
├── resume/
│   ├── kustomization.yaml        # this step: resources: [namespace.yaml] only
│   ├── namespace.yaml            # wave -10; Namespace resume (full content now)
│   ├── deployment.yaml           # wave 0; name-only stub (spec lands Step 2)
│   ├── service.yaml              # wave 0; name-only stub (spec lands Step 2)
│   └── httproute.yaml            # wave 0; name-only stub (spec lands Step 2)
└── trips/
    ├── kustomization.yaml        # this step: resources: [namespace.yaml] only
    ├── namespace.yaml            # wave -10; Namespace trips (full content now)
    ├── deployment.yaml           # wave 0; name-only stub (spec lands Step 3)
    ├── service.yaml              # wave 0; name-only stub (spec lands Step 3)
    └── httproute.yaml            # wave 0; name-only stub (spec lands Step 3)
```

This step also **names** (fixes the path of, without yet creating) the
files Steps 1 and 4 author with real content — `workloads/resume.Dockerfile`,
`workloads/trips.Dockerfile`, `scripts/workloads-build.sh`, the
`[tasks."workloads:build"]` `mise.toml` entry, `.gitmodules`, and
`charts/resume/`, `charts/trips/` — matching the design's own proposed
layout. Unlike the GitOps-consumed stubs above, these do not need to exist as
inert placeholders yet: nothing composes or reconciles them until the step
that gives them real content, so an empty Dockerfile or a no-op build task
would be misleading busywork, not a genuine stub.

Representative stubs (the other name-only files follow the same shape as the
`httproute.yaml` stub below, substituting kind/name):

```yaml
# workloads/overlays/dev/resume/namespace.yaml -- full content now (a Namespace has no spec)
apiVersion: v1
kind: Namespace
metadata:
  name: resume
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
```

```yaml
# workloads/overlays/dev/resume/httproute.yaml -- Step 0 skeleton (name-only stub, no spec)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: resume
  namespace: resume
  annotations:
    argocd.argoproj.io/sync-wave: "0"
```

This fixes: the `apps/workloads.yaml` sync seam, the directory layout, every
shared-contract object name (`resume`, `trips`, and their Namespace/
Deployment/Service/HTTPRoute names, all matching their namespace), and the
two-tier sync-wave scheme (`-10`/`0` — no `-5` tier here, unlike forgejo,
because neither workload has a database or a sealed credential to sequence
ahead of its Deployment). `tests/workloads.bats` is a `design.md` artifact and
already exists (RED baseline: `workloads` trivially Synced/Healthy on
`resources: []`, failing from the first resume `/` status assertion onward).
Step 0 does not touch it and does not change that RED state — the top-level
`workloads/overlays/dev/kustomization.yaml` `resources:` list is unchanged,
so nothing new reaches the live cluster yet, but every name and file the
remaining steps fill in now exists and is fixed.

**Tests**

```text
test "the apps/workloads.yaml seam is real; workloads stays Synced/Healthy on unchanged content":
  run bash -c "yq '.spec.syncPolicy.syncOptions' apps/workloads.yaml"
  assert output contains "ServerSideApply=true"
  assert output contains "SkipDryRunOnMissingResource=true"
  run bash -c "yq '.metadata.annotations[\"argocd.argoproj.io/compare-options\"]' apps/workloads.yaml"
  assert output == "ServerSideDiff=true"
  run kubectl --context k3d-agrippa-dev -n argocd get application workloads \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"               # unchanged -- still resources: []
```

- Edge case: confirm `workloads/overlays/dev/kustomization.yaml` is unchanged
  (still `resources: []`) after this step — nothing new is fed to the live
  cluster yet.
- Edge case: `resume`/`trips` namespace names must not collide with any
  namespace already live (`istio-system`, `istio-ingress`, `cert-manager`,
  `metallb-system`, `cnpg-system`, `storage`, `argocd`, `forgejo`, `keycloak`,
  `flagsmith`, `observability`).
- Edge case: re-running `mise run test:push`/`test:static` after this step
  must still pass — nothing new is fed to kubeconform/conftest yet (the two
  `resume/trips` `kustomization.yaml`s reference only a bare `Namespace`, and
  the top-level overlay is unchanged).

**Implementation Outline**

```text
apps/workloads.yaml:
  metadata.annotations["argocd.argoproj.io/compare-options"] <- "ServerSideDiff=true"
  spec.syncPolicy.syncOptions <- [ServerSideApply=true, SkipDryRunOnMissingResource=true]

workloads/overlays/dev/kustomization.yaml:
  resources: []   # unchanged

workloads/overlays/dev/{resume,trips}/{kustomization.yaml, namespace.yaml,
  deployment.yaml, service.yaml, httproute.yaml}: stubs, as above
```

## Step 1: The git submodules and the imperative `mise run workloads:build` image pipeline

**Enables:** no feature-test assertion flips yet (this step never touches the
ArgoCD-reconciled `workloads/overlays/dev` tree), but it is the load-bearing
prerequisite for Steps 2-3's Deployments: without a `resume:dev`/`trips:dev`
image already imported into the node's containerd, `imagePullPolicy: Never`
means those Deployments would sit in `ErrImageNeverPull` forever — the
design's own named failure mode.

Run (once, real repo mutation, not a stub) `git submodule add
https://github.com/davidsouther/resume.git workloads/resume` and the
equivalent for `.../trips.git workloads/trips`, producing the committed
`.gitmodules` (two `[submodule "workloads/<name>"]` entries) and two gitlink
entries pinning each upstream at a commit. `resume` is public (no auth);
`trips` is private (the operator's own authenticated git credential helper
resolves it non-interactively — confirmed live by the cleared research; an
unauthenticated third party would `401`, a documented, accepted limitation of
this local, operator-run feature-step).

Author `workloads/resume.Dockerfile` and `workloads/trips.Dockerfile`
(outside the submodules, passed via `-f`, since the submodule directories are
the untouched upstream repos): stage 1 `FROM node:24 AS build` (glibc,
per the design's build-verify note on `biome`'s musl-native optional deps),
running `npm ci && npm run build` inside the submodule's own directory,
emitting the static site to `docs/`; stage 2 `FROM nginx:alpine`, `COPY
--from=build .../docs /usr/share/nginx/html`, plus an inline `RUN` heredoc
serving config carrying the clean-URL rule that resolves `/blog`'s directory
index and, resume only, `location = /healthz { return 200; }`. Both tagged
explicitly non-`:latest` — `resume:dev` / `trips:dev`.

Author `scripts/workloads-build.sh` (matching `bootstrap.sh`'s shape: `set
-euo pipefail`, staged with comments, idempotent). Its stages, per workload:
(1) `git submodule update --init` (materializes the submodule content the
Docker build context needs — a plain local build context never
auto-populates a submodule); (2) `docker build -f workloads/<name>.Dockerfile
-t <name>:dev workloads/<name>`; (3) `k3d image import <name>:dev --mode
direct --cluster agrippa-dev` (copies the image from the host Docker daemon
into the k3s node's containerd; `direct` mode needs no tools-container hop on
this single-node cluster). Add `[tasks."workloads:build"] file =
"scripts/workloads-build.sh"` to `mise.toml`, matching the `bootstrap` task's
own entry shape. No `[tools]` entry for `node` is added.

**Tests**

```text
test "workloads:build materializes both submodules and imports both images":
  run git submodule status workloads/resume workloads/trips
  assert status == 0                              # both initialized, no leading '-'
  run mise run workloads:build
  assert status == 0
  run bash -c "docker image inspect resume:dev trips:dev --format '{{.Id}}'"
  assert status == 0                               # both tags exist in the host daemon
  run bash -c "docker exec k3d-agrippa-dev-server-0 crictl images | grep -c 'resume\|trips'"
  assert output != "0"                             # both imported into node containerd
```

- Edge case: a fresh clone (or a submodule directory left uninitialized)
  must fail loudly at stage 1, not silently `COPY` an empty context — verify
  the build fails with a clear "submodule not initialized" signal, not a
  cryptic `npm ci` "no package.json" error three layers deep.
- Edge case: `npm run build`'s `prebuild` (typecheck + lint via `biome`) must
  actually pass inside a fresh `node:24` container with no cached
  `node_modules` — confirm at build, per the design's own flagged libc/
  offline risk (musl-native optional deps if `-alpine` were used instead;
  `node:24` avoids this).
- Edge case: confirm `resume`'s build needs no network fetch beyond `npm
  ci` (asserted, not yet verified, per the design) — `trips` is confirmed
  offline-buildable (a committed data cache).
- Edge case: re-running `mise run workloads:build` a second time (rebuild +
  re-import) must not error — idempotent, like `bootstrap`.
- Edge case: confirm the real `docs/blog/` output shape (directory index vs.
  a flat file) before finalizing the nginx clean-URL rule — the design's own
  flagged build-verify; adjust the serving config here if the assumed shape
  is wrong.

**Implementation Outline**

```text
scripts/workloads-build.sh:
  for workload in resume trips:
    git submodule update --init workloads/<workload>
    docker build -f workloads/<workload>.Dockerfile -t <workload>:dev workloads/<workload>
    k3d image import <workload>:dev --mode direct --cluster agrippa-dev

workloads/resume.Dockerfile (and trips.Dockerfile, same shape):
  FROM node:24 AS build
    WORKDIR /src
    COPY . .
    RUN npm ci && npm run build   # emits docs/
  FROM nginx:alpine
    COPY --from=build /src/docs /usr/share/nginx/html
    RUN <<EOF > /etc/nginx/conf.d/default.conf
      server { listen 80;
        location / { try_files $uri $uri/ $uri.html =404; }
        location = /healthz { return 200; }   # resume only
      }
    EOF

mise.toml:
  [tasks."workloads:build"]
    file = "scripts/workloads-build.sh"
```

## Step 2: Wave 0 — the `resume` workload wired live, plus its Gateway-cert SAN append

**Enables:** THEN 1 (`curl -k https://davidsouther.com.127.0.0.1.nip.io/`
returns `200` with `<html` and `david` in the body) and THEN 2 (`/blog`
returns `200`, following any redirect, with `<html` in the body) and THEN 3
(`/healthz` returns exactly `200`) — the entire personal-site half of the
feature test.

Fill `workloads/overlays/dev/resume/deployment.yaml`,
`service.yaml`, and `httproute.yaml` per the design's Specification:
**Deployment** — 1 replica, one container from `resume:dev`,
`imagePullPolicy: Never`, `containerPort: 80`, `resources: {requests: {cpu:
25m, memory: 32Mi}, limits: {memory: 128Mi}}`, a readiness/liveness probe
`httpGet: {path: /healthz, port: 80}`. **Service** — `ClusterIP`, port `80`
to the container's `80`. **HTTPRoute** — `parentRefs: [{name:
agrippa-gateway, namespace: istio-ingress, sectionName: https}]`,
`hostnames: [davidsouther.com.127.0.0.1.nip.io]`, an explicit `matches:
[{path: {type: PathPrefix, value: /}}]` (the omitted-`matches` OutOfSync trap
every prior HTTPRoute in this repo avoids by fiat), `backendRefs:` the
`resume` Service on port `80`. Append `namespace.yaml` (already present),
`deployment.yaml`, `service.yaml`, `httproute.yaml` to
`workloads/overlays/dev/resume/kustomization.yaml`'s `resources:` list
(already stubbed with `namespace.yaml` alone in Step 0). Append `resume` to
the **top-level** `workloads/overlays/dev/kustomization.yaml`'s `resources:`
list (`resources: [resume]`) — the first real content this feature-step
applies to the live cluster, mirroring forgejo Step 1's own "first real
content" framing. Append `davidsouther.com.127.0.0.1.nip.io` to
`core/overlays/dev/gateway-cert.yaml`'s `dnsNames` — re-check the live list
first (it carries 5 SANs as of this design; a concurrent feature could have
appended since), append-only.

**Tests**

```text
test "the resume workload lands live; the personal site renders through the Gateway":
  run kubectl --context k3d-agrippa-dev -n argocd get application workloads \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"
  run kubectl --context k3d-agrippa-dev -n resume get pods \
    -o jsonpath='{.items[0].status.phase}'
  assert output == "Running"
  run curl -k -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    "https://davidsouther.com.127.0.0.1.nip.io/"
  assert output == "200"
  run bash -c "curl -k -sS https://davidsouther.com.127.0.0.1.nip.io/ | grep -qi david"
  assert status == 0
  run curl -k -L -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    "https://davidsouther.com.127.0.0.1.nip.io/blog"
  assert output == "200"
  run curl -k -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    "https://davidsouther.com.127.0.0.1.nip.io/healthz"
  assert output == "200"
```

- Edge case: `ErrImageNeverPull` if Step 1's `workloads:build` was not (re-)run
  against this exact cluster before this commit syncs — verify live, do not
  assume the image is already imported.
- Edge case: the real `/blog` serving shape (Step 1's own flagged
  build-verify) determines whether this HTTPRoute's plain `PathPrefix: /`
  match is sufficient on its own, or whether the nginx-side redirect needs a
  `-L` follow in the probe (already reflected in the test above and in
  `tests/workloads.bats` itself).
- Edge case: confirm `davidsouther.com.127.0.0.1.nip.io` is the only new
  entry appended to `gateway-cert.yaml`'s `dnsNames` — the existing 5 SANs
  must be undisturbed.
- Edge case: if `workloads` goes permanently OutOfSync on a
  controller-defaulted field (the Gateway-API symptom `core`/forgejo both
  hit), Step 0's `ServerSideDiff=true` annotation should pre-empt it —
  verify live.
- Edge case: cumulative cluster resource pressure — check `kubectl describe
  node` / `kubectl top nodes` if the resume pod does not schedule.

**Implementation Outline**

```text
workloads/overlays/dev/resume/deployment.yaml:
  spec.template.spec.containers[0]:
    image: resume:dev
    imagePullPolicy: Never
    ports: [{containerPort: 80}]
    resources: {requests: {cpu: 25m, memory: 32Mi}, limits: {memory: 128Mi}}
    readinessProbe/livenessProbe: {httpGet: {path: /healthz, port: 80}}

workloads/overlays/dev/resume/service.yaml:
  spec: {ports: [{port: 80, targetPort: 80}], selector: <matches Deployment>}

workloads/overlays/dev/resume/httproute.yaml:
  spec:
    parentRefs: [{name: agrippa-gateway, namespace: istio-ingress, sectionName: https}]
    hostnames: [davidsouther.com.127.0.0.1.nip.io]
    rules: [{matches: [{path: {type: PathPrefix, value: /}}], backendRefs: [{name: resume, port: 80}]}]

workloads/overlays/dev/resume/kustomization.yaml:
  resources: [namespace.yaml, deployment.yaml, service.yaml, httproute.yaml]

workloads/overlays/dev/kustomization.yaml:
  resources: [resume]

core/overlays/dev/gateway-cert.yaml:
  spec.dnsNames: [..., davidsouther.com.127.0.0.1.nip.io]
```

## Step 3: Wave 0 — the `trips` workload wired live, plus its Gateway-cert SAN append

**Enables:** THEN 4 (`curl -k https://trips.davidsouther.com.127.0.0.1.nip.io/`
returns `200` with `<html` and `trip` in the body) — the last remaining
assertion. With Step 2 done, this closes out `tests/workloads.bats` entirely.

Repeat Step 2's shape for `trips`, with two differences: no `/healthz` (the
gestalt probes only the personal site, per parent design decision 4), so the
probe target is `httpGet: {path: /, port: 80}`; and no `/blog`-style
clean-URL concern (trips' probe is a plain `/`). Fill
`workloads/overlays/dev/trips/{deployment.yaml, service.yaml,
httproute.yaml}` (image `trips:dev`, hostname
`trips.davidsouther.com.127.0.0.1.nip.io`, same resource shape and explicit
`matches:`). Append `deployment.yaml`/`service.yaml`/`httproute.yaml` to
`workloads/overlays/dev/trips/kustomization.yaml`'s `resources:`. Append
`trips` to the top-level `workloads/overlays/dev/kustomization.yaml`'s
`resources:` list (`resources: [resume, trips]`). Append
`trips.davidsouther.com.127.0.0.1.nip.io` to `core/overlays/dev/
gateway-cert.yaml`'s `dnsNames` (re-check the live list again — Step 2's own
append should already be there; add alongside it, not instead of it).

The ArgoCD submodule-fetch prerequisite this step's design once flagged is
**already satisfied** — the coordinator applied and live-verified
`reposerver.enable.git.submodule: "false"` on `argocd-cmd-params-cm` as its
own prerequisite commit on `main`, before this feature-step's build began
(see § Resolved by the long-loop reviewer, item 3, and `design.md` §
Failure modes / § Cross-step touches). That fix is global (every
Application's shared `agrippa` repoURL checkout, not just `workloads`), so
there is no ArgoCD-side action for this step to take. This step proceeds
directly to wiring `trips` live.

**Tests**

```text
test "the trips workload lands live; tests/workloads.bats passes in full":
  run kubectl --context k3d-agrippa-dev -n argocd get application workloads \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"
  run kubectl --context k3d-agrippa-dev -n trips get pods \
    -o jsonpath='{.items[0].status.phase}'
  assert output == "Running"
  run curl -k -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    "https://trips.davidsouther.com.127.0.0.1.nip.io/"
  assert output == "200"
  run bash -c "curl -k -sS https://trips.davidsouther.com.127.0.0.1.nip.io/ | grep -qi trip"
  assert status == 0
  run bats tests/workloads.bats
  assert status == 0
```

- Edge case: confirm the shared cert now carries 7 SANs total (5 original +
  Step 2's + this step's), all previous ones undisturbed — a `grep -c`
  count, not just a presence check.
- Edge case: confirm the `workloads` Application still reconciles cleanly
  now that `.gitmodules` references the private `trips` submodule live — the
  global `reposerver.enable.git.submodule: "false"` prerequisite (already
  applied and live-verified by the coordinator before this feature-step's
  build began) should make this a non-event; verify rather than assume.
- Edge case: `trips`'s namespace must not collide with any already-live
  namespace (same list as Step 0's edge case, plus `resume` itself now).
- Edge case: cumulative resource pressure again — two static-nginx pods are
  cheap individually, but check node headroom now that both are scheduled.

**Implementation Outline**

```text
workloads/overlays/dev/trips/deployment.yaml:
  spec.template.spec.containers[0]:
    image: trips:dev
    imagePullPolicy: Never
    ports: [{containerPort: 80}]
    resources: {requests: {cpu: 25m, memory: 32Mi}, limits: {memory: 128Mi}}
    readinessProbe/livenessProbe: {httpGet: {path: /, port: 80}}

workloads/overlays/dev/trips/httproute.yaml:
  spec:
    hostnames: [trips.davidsouther.com.127.0.0.1.nip.io]
    rules: [{matches: [{path: {type: PathPrefix, value: /}}], backendRefs: [{name: trips, port: 80}]}]

workloads/overlays/dev/kustomization.yaml:
  resources: [resume, trips]

core/overlays/dev/gateway-cert.yaml:
  spec.dnsNames: [..., davidsouther.com.127.0.0.1.nip.io, trips.davidsouther.com.127.0.0.1.nip.io]
```

## Step 4: The packaging Helm charts (`charts/resume/`, `charts/trips/`), real and helm-unittest-tested

**Enables:** no `tests/workloads.bats` assertion directly (the charts are the
deferred prod/registry-push packaging artifact, not the live GitOps render
path — decision h), but this is a required deliverable of this feature-step
(design item 4) and turns `mise run test:chart` from green-on-empty into a
real, exercised check for the first time — part of the "no regression to
earlier harness" metric Step 5 verifies, and the first real content under
this repo's `charts/` directory.

Author, per workload, a minimal chart: `Chart.yaml` (name, version,
`apiVersion: v2`); `values.yaml` (`image: {repository, tag, pullPolicy}`,
`replicaCount`, `resources`, `hostname`, and — resume only — a `healthz`
toggle); `templates/{deployment.yaml, service.yaml, httproute.yaml}`
rendering the **same three objects** the live overlay hand-authors (image/
`imagePullPolicy` from values, the Service port, the HTTPRoute's hostname and
explicit `matches:` from values), and deliberately **no** `Certificate`
template (matching the live path's shared-cert model and prod's edge-TLS
model — the design's ratified decision 1). Author `tests/*.yaml`
helm-unittest suites per chart, following helm-unittest's own `DOCUMENT.md`
conventions, asserting: the Deployment pins the values-driven image and
`imagePullPolicy: Never`; the Service targets the values-driven/default port;
the HTTPRoute carries an explicit `matches:` and the values-driven hostname.
The two representations (this chart and Steps 2-3's hand-authored live YAML)
are kept aligned **by discipline**, not generated from one another (the
design's accepted, explicitly named cost) — helm-unittest tests the chart
against its own author-written expectations and never diffs it against the
live overlay.

**Tests**

```text
test "both charts render and pass their own helm-unittest suites":
  run helm unittest charts/resume
  assert status == 0
  run helm unittest charts/trips
  assert status == 0
  run mise run test:chart
  assert status == 0                    # no longer the green-on-empty path
  run bash -c "helm template charts/resume | grep -c 'kind: Certificate'"
  assert output == "0"
```

- Edge case: the chart's `values.yaml` defaults must not silently diverge
  from the live overlay's hand-authored values (image tag, resource
  requests, hostname) — a manual cross-check against Steps 2-3's committed
  YAML, not an automated diff (the design's named, accepted drift risk).
- Edge case: confirm no chart template accidentally reintroduces a
  `Certificate` object — the design's ratified decision (item 1, resolved by
  the long-loop reviewer) that the shared-cert SAN append discharges it.
- Edge case: `scripts/test-chart.sh`'s discovery loop (`for chart in
  charts/*/`, requiring a `tests/` subdirectory) must actually find and run
  both new charts — verify `mise run test:chart`'s output no longer prints
  its green-on-empty message.

**Implementation Outline**

```text
charts/resume/Chart.yaml:        {apiVersion: v2, name: resume, version: 0.1.0}
charts/resume/values.yaml:       {image: {repository: resume, tag: dev, pullPolicy: Never},
                                   replicaCount: 1, resources: {...}, hostname: davidsouther.com.127.0.0.1.nip.io,
                                   healthz: true}
charts/resume/templates/deployment.yaml:  <Deployment, values-templated, mirrors Step 2>
charts/resume/templates/service.yaml:     <Service, values-templated>
charts/resume/templates/httproute.yaml:   <HTTPRoute, values-templated, explicit matches:>
charts/resume/tests/deployment_test.yaml: <helm-unittest: image/pullPolicy assertions>
charts/resume/tests/service_test.yaml:    <helm-unittest: port assertion>
charts/resume/tests/httproute_test.yaml:  <helm-unittest: matches/hostname assertions>

charts/trips/...: same shape, no healthz toggle
```

## Step 5: Full GREEN — `tests/workloads.bats`, `tests/agrippa.bats` verification, and the regression sweep

**Enables:** the feature test's own full pass (already true at the end of
Step 3, re-confirmed here) plus the two project-level obligations this
feature-step carries: verifying (not authoring) `tests/agrippa.bats`, and
proving no regression to the seven other live components' own suites. No new
manifests land in this step — Steps 0-4 already wired every object this
feature needs, so this is proof-and-regression, not new substrate, mirroring
both completed siblings' own final step.

Run `bats tests/workloads.bats` against the fully reconciled `workloads`
layer (already exercised at the end of Step 3; re-run here as the definitive
gate). Run `ENV=dev PUBLIC_HOST=davidsouther.com.127.0.0.1.nip.io
TRIPS_HOST=trips.davidsouther.com.127.0.0.1.nip.io
DASHBOARD_HOST=dashboard.davidsouther.com.127.0.0.1.nip.io bats
tests/agrippa.bats` and confirm it passes green — verification only, per the
cleared research: its three-edit dev-branch fix is already committed
(`a9cdfbc`, Feature 0; `git diff HEAD` empty), so this step authors no new
edits to that file, and this run is Closing Bell critical task 6's
automated backstop. If build-time verification (Steps 1-3's own recorded
edge cases) found any hostname, path, or content-token assumption in either
suite diverges from what the real built sites serve, correct the suite's
constants here — a test-definition correction inherited from build-time
re-verification, not new test authorship (mirroring both siblings' own
final-step corrections). Then re-run the full harness the design's Metrics
section names as no-regression evidence.

**Tests**

```text
test "tests/workloads.bats and tests/agrippa.bats both pass end-to-end":
  run bats tests/workloads.bats
  assert status == 0
  run bash -c "ENV=dev PUBLIC_HOST=davidsouther.com.127.0.0.1.nip.io \
    TRIPS_HOST=trips.davidsouther.com.127.0.0.1.nip.io \
    DASHBOARD_HOST=dashboard.davidsouther.com.127.0.0.1.nip.io \
    bats tests/agrippa.bats"
  assert status == 0

test "no regression to earlier harness":
  run mise run test:push
  assert status == 0
  run mise run test:feature
  assert status == 0
  run bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats \
    tests/storage.bats tests/git-hosting.bats tests/auth.bats \
    tests/observability.bats tests/feature-flags.bats tests/rotate-keys.bats
  assert status == 0
```

- Edge case: `scripts/test-feature.sh` already excludes `workloads.bats` from
  its throwaway-cluster auto-discovery (verified committed this session,
  landed with the feature test at design time) — this step only needs to
  confirm that exclusion still holds, not add it.
- Edge case: `tests/rotate-keys.bats` is recorded (by the `git-hosting`
  sibling's own final step) as pre-existing-failing, unrelated to any of
  this project's own commits — confirm it is still failing for the same
  pre-existing reason, not a new regression this feature-step introduced.
- Edge case: `mise run test:static`'s kubeconform/conftest pass does not walk
  `workloads/` the same way it now walks `charts/*/` — confirm what it does
  and does not cover, so a false sense of "test:static caught it" is not
  assumed for the live overlay content (ArgoCD's own live reconcile and
  `tests/workloads.bats` are the validators of that content, matching every
  sibling's own final-step note).
- Edge case: cumulative resource pressure one more time, now with every
  component in the project live simultaneously — `kubectl top nodes` before
  declaring done, per the design's own named failure mode.
- Edge case: confirm `reposerver.enable.git.submodule: "false"` is live on
  the repo-server (already verified by the coordinator before this
  feature-step's build began; re-check here as a regression guard, not new
  work) and that it does not itself break the `workloads` Application's
  ordinary reconcile of non-submodule content.

**Implementation Outline**

```text
# no new manifests; this step is verification-only plus any build-time-discovered
# corrections to tests/workloads.bats' or tests/agrippa.bats' hostname/content-token
# assumptions, surfaced by actually running both suites against the live,
# fully-reconciled workloads layer
run bats tests/workloads.bats
run bash -c "ENV=dev PUBLIC_HOST=... TRIPS_HOST=... DASHBOARD_HOST=... bats tests/agrippa.bats"
run mise run test:push && mise run test:feature
run bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats \
  tests/storage.bats tests/git-hosting.bats tests/auth.bats \
  tests/observability.bats tests/feature-flags.bats tests/rotate-keys.bats
```

## Resolved by the long-loop reviewer (2026-07-09)

This is a paper plan against the cleared feature `design.md`; it has not been
built. A separately dispatched long-loop reviewer read it cold and, per the
completed siblings' precedent (`git-hosting-forgejo/plan.md` § Resolved by the
long-loop reviewer), checked: (1) transcription fidelity against the cleared
`design.md`, including the shared-cert-SAN-append ratification and the
private-`trips` correction; (2) the plan's repo-state claims against the
actually-committed files and the live `k3d-agrippa-dev` cluster (read-only);
(3) the design's flagged ArgoCD private-submodule-fetch risk that Step 3 was
originally meant to resolve; (4) the six-step decomposition for the "consumer
lands before its prerequisite" defect class the Features 5-7 Database-CR
deadlock was; and (5) Step 4's charts (no `Certificate` template) plus
`test:chart`'s green-on-empty-to-real transition. Items 1, 2, 4, and 5 cleared
to their conservative defaults at review time. **Item 3 was escalated** at
review time — the design's then-stated mitigation mechanism did not exist at
the granularity claimed, the real mechanism was a whole-cluster ArgoCD-install
change the feature-step's design explicitly scoped out, and the risk was
build-breaking for the entire app-of-apps tree, not just `workloads` — exactly
the same escalation class as the forgejo sibling's own item 4 (a
build-breaking, out-of-recorded-scope prerequisite defect a plan-gate reviewer
correctly declines to decide unilaterally). **The coordinator has since
resolved item 3 directly (2026-07-09)**: the design was corrected and the
global `reposerver.enable.git.submodule: "false"` prerequisite was applied and
live-verified on `main`, before this feature-step's own build begins — see
item 3 below for the full record. With item 3 resolved, all five items are
Decided and **the draft gate clears below**. The working tree and cluster were
left exactly as found by the original read-only review; the coordinator's fix
landed separately, as its own prerequisite commit, and this edit brings the
plan's text in line with that already-applied, already-verified state.

**1. Transcription fidelity against the cleared `design.md` (shared-cert-SAN
ratification; private-`trips` correction). Decided: faithful.** Every step
transcribes the design's § Specification: the two-`resources:`-entry composition
under the unchanged `apps/workloads.yaml` (Steps 0, 2, 3), the `apps/workloads.yaml`
`ServerSideApply`/`ServerSideDiff` sync seam (Step 0), the `-10`/`0` two-tier
wave scheme with no `-5` tier (Steps 0, 2, 3), the imperative git-submodule +
`node:24` Docker + `k3d image import --mode direct` pipeline outside GitOps
(Step 1), `imagePullPolicy: Never` with modest explicit `resources` and the
explicit-`matches:` HTTPRoute (Steps 2, 3), and the proof-and-regression sweep
(Step 5). The **shared-cert-SAN-append ratification** (design's Resolved item 1)
is carried correctly: Steps 2 and 3 each append **one** SAN to the single shared
`core/overlays/dev/gateway-cert.yaml` (`davidsouther.com.127.0.0.1.nip.io`,
`trips.davidsouther.com.127.0.0.1.nip.io`), Step 4's charts template a
Deployment/Service/HTTPRoute and **no** `Certificate`, and no per-workload cert
appears anywhere. The **private-`trips` correction** (design's Resolved item 7)
is carried correctly: Step 1 states `resume` public / `trips` private and relies
on the operator's authenticated credential helper for `trips`, and `.gitmodules`
is accounted for as a new committed file. The ArgoCD submodule-fetch
prerequisite (design's § Failure modes / § Cross-step touches) is also carried
correctly now: the design was corrected and the global
`reposerver.enable.git.submodule: "false"` fix is already applied and
live-verified as a prerequisite commit ahead of this feature-step's own build
— see item 3.

**2. Repo-state claims verified live (read-only). Decided: accurate — no change
needed.** `apps/workloads.yaml` carries `syncPolicy.automated` only (no
`syncOptions`, no `compare-options`), so Step 0's seam has not landed. The
top-level `workloads/overlays/dev/kustomization.yaml` is exactly `resources: []`
with no `resume/`/`trips/` subdir yet. `core/overlays/dev/gateway-cert.yaml`'s
`dnsNames` carries exactly the five SANs the design names (`argocd`,
`dashboard.davidsouther.com`, `auth`, `git.davidsouther.com`, `flagsmith`),
neither workload host present, so Steps 2-3's one-line appends are specified
correctly. `mise.toml`'s `[tools]` has no `node`/`npm` (only `k3d = "5.9.0"`
among the relevant pins) and no `[tasks."workloads:build"]` entry — both as
claimed. `scripts/test-feature.sh` already carries `workloads.bats` in its
probe-suite exclusion `case` list. No top-level `charts/` directory and no
`.gitmodules` exist yet; `workloads/` holds only `overlays/dev/kustomization.yaml`.
`scripts/test-chart.sh` is green-on-empty (no `charts/` → skip). `tests/workloads.bats`
exists as a committed RED-baseline artifact, and the live `workloads` Application
is `Synced/Healthy` on the empty overlay (all seven Applications Synced/Healthy).
Every repo-state claim the plan makes holds.

**3. The ArgoCD private-submodule-fetch risk (Step 3's stated mitigation).
Decided: resolved by the coordinator — the design was corrected and the global
prerequisite is already applied and live-verified, so this feature-step's own
Steps need no ArgoCD-side action.** At review time this was escalated, not
decided: the mitigation as then specified did not exist, and the correct
mitigation was a whole-cluster ArgoCD-install change the feature-step's design
then explicitly scoped out — with a blast radius (the entire app-of-apps tree)
and a trigger point (Step 1's `.gitmodules` commit) both larger and earlier
than the plan framed. That escalation was not unnecessary caution: it
identified real, build-breaking infrastructure work, mis-located and
mis-scoped in both the design and the plan as they then stood. Findings from
that review, all verified at the time and still accurate as history:

- **The fetch failure is fatal, and certain.** ArgoCD's repo-server runs `git
  submodule update --init --recursive` on every checkout when submodules are
  enabled; a private submodule it cannot fetch fails that command, and the
  failure aborts manifest generation for the Application (argoproj/argo-cd#10174,
  a still-open request to make inaccessible submodules non-fatal — today they are
  fatal). Live: the `argocd` namespace holds **no** `repository` or `repo-creds`
  secret, so the public `agrippa` repo is fetched anonymously and there is **no**
  credential that could authenticate the private `github.com/davidsouther/trips`
  submodule. The `401` is determined, not a reachability blip (the design already
  says this; it is confirmed here).
- **The blast radius is the whole tree, not just `workloads`.** All seven
  Applications (`argocd`, `core`, `observability`, `platform`, `root`, `storage`,
  `workloads`) share `repoURL: https://github.com/DavidSouther/agrippa.git`
  (verified live). The repo-server's submodule fetch happens on the shared
  per-`repoURL` checkout, so a `.gitmodules` referencing the private `trips` repo
  breaks manifest generation for **every** layer's Application, not only the
  `workloads` one whose overlay references no submodule content. And it breaks at
  the moment `.gitmodules` is committed — **Step 1** — which is two steps *before*
  Step 3, where the plan proposes to address it. In the interim the entire GitOps
  tree would be un-renderable.
- **No per-Application disable exists.** The design (§ Failure modes) and the plan
  (Step 3) both frame the fix as "disable submodule fetch for the `workloads`
  Application," via "an ArgoCD repository-connection or Application-source
  setting." No such per-Application or per-repository setting exists
  (argoproj/argo-cd#3799 is an open feature request to add `source.fetch_submodules:
  false` per-Application; it is not implemented). The only mechanism is the
  **global** repo-server toggle `ARGOCD_GIT_MODULES_ENABLED=false`, set
  declaratively via the `reposerver.enable.git.submodule: "false"` key in the
  `argocd-cmd-params-cm` ConfigMap (verified live: the repo-server env sources
  `ARGOCD_GIT_MODULES_ENABLED` `valueFrom` that optional key, which is absent, so
  fetching is enabled by default). That ConfigMap lives in the ArgoCD install
  layer `apps/platform/argocd/`, which the design's § Cross-step touches does
  **not** list among this step's owned files — the same ArgoCD/`core`-layer the
  cleared research decision (h) deliberately refused to modify (its option a1,
  the cluster-wide load-restrictor relaxation) for being out of scope and
  higher-blast-radius. Disabling submodules globally is harmless in effect (no
  Application anywhere references submodule content, and the local images are
  already imported), but it is a whole-cluster ArgoCD-config change, and choosing
  to make it — and to sequence it *ahead of* Step 1's `.gitmodules` commit rather
  than at Step 3 — re-assigns ownership and ordering the cleared design fixed.

Per the long-loop escalation rule this fired trigger **(b) out of recorded
scope**: the only real fix changed a system (`apps/platform/argocd/`'s
`argocd-cmd-params-cm`) the design's Scope/Cross-step-touches then excluded, and
it needed to be re-sequenced ahead of the build to avoid bricking every layer.
This was the same class as the forgejo sibling's escalated item 4 (a
build-breaking prerequisite-ordering defect whose fix required revisiting
cleared design scope): correcting it was outside a plan-gate reviewer's
transcribe-faithfully remit, so the reviewer correctly declined to decide it
unilaterally and escalated for the coordinator to resolve.

**Resolved by the coordinator (2026-07-09).** The coordinator resolved item 3
directly, matching the exact pattern used for a prior sibling's own
Database-CR-wave-ordering escalation: `design.md` § Failure modes and §
Cross-step touches were corrected from the non-existent "per-Application"
mechanism to the real global one, and `reposerver.enable.git.submodule:
"false"` was added to `argocd-cmd-params-cm` via a new patch in
`apps/platform/argocd/kustomization.yaml` — this key was already wired to the
repo-server's `ARGOCD_GIT_MODULES_ENABLED` env var in the pinned v3.4.4
install manifest (confirmed live). Applied, the `argocd` Application
self-reconciled, the repo-server was restarted to pick up the env change
(ConfigMap-sourced env vars are not live-reloaded), and all seven Applications
were reconfirmed Synced/Healthy afterward. This landed as its own prerequisite
commit on `main`, already pushed, **before** this feature-step's own Step 1.
With the prerequisite already satisfied, Step 1's `.gitmodules` commit is safe
to land as originally planned — no ArgoCD-side mitigation is needed from this
feature-step's own Steps at all — and Step 3 now proceeds directly to wiring
`trips` live with no ArgoCD-config content of its own (see the corrected Step
3 body above, and Step 5's regression-guard edge case). Because item 3 is now
resolved, it is no longer a prerequisite blocking any subsequent step, and the
gate clears.

**4. The six-step decomposition and the Step 2/3 image-build sequencing (the
Features 5-7 Database-CR deadlock class). Decided: sound — the step ORDER, not
just wave annotations, guarantees Step 1 completes before Step 2/3 apply
anything.** Unlike the forgejo deadlock (a wave-ordering defect *inside* ArgoCD,
where a wave-`0` consumer health-gated a wave-`5` producer), the image build here
is an imperative pre-step **entirely outside** ArgoCD with no wave number at all.
Step 1 runs `mise run workloads:build` (submodule init → `docker build` →
`k3d image import`), materializing `resume:dev`/`trips:dev` in the node's
containerd; only then do Steps 2 and 3 commit the overlays that ArgoCD reconciles
into the `imagePullPolicy: Never` Deployments. The plan's linear Step 1 → Step 2
→ Step 3 order enforces build-before-apply, and within ArgoCD the two Deployments
sit at wave `0` behind their wave-`-10` Namespaces with no intra-tree producer/
consumer ordering to deadlock. The residual `ErrImageNeverPull` case (Deployment
scheduled against a cluster where `workloads:build` was not re-run) is not a
deadlock but a self-healing, documented operational precondition: it fails fast
and honestly, and the pod schedules on the next kubelet retry once the image is
imported — the plan's Step 2 edge case ("verify live, do not assume the image is
already imported") already names it. No consumer-before-prerequisite defect
exists.

**5. Step 4's charts (no `Certificate` template) and `test:chart`'s
green-on-empty-to-real transition. Decided: correct — no change needed.** The
charts genuinely need no `Certificate` template: the shared Gateway's single
`https` listener references only `agrippa-gateway-tls`, so a per-workload cert
would be unreferenced and inert, and prod terminates TLS at the Cloudflare edge —
matching design Resolved item 1. Step 4's own edge case asserts this by fiat
(`helm template charts/resume | grep -c 'kind: Certificate'` == `0`). And
`scripts/test-chart.sh` will exercise the charts for the first time exactly as
the plan claims: verified live, it short-circuits green today because no `charts/`
directory exists; once Step 4 authors `charts/resume/tests/` and
`charts/trips/tests/`, its discovery loop (`for chart in charts/*/`, gated on a
`${chart}tests` subdirectory) finds both and runs `helm unittest` per chart,
setting `found=1` so the green-on-empty message no longer prints. The transition
from green-on-empty to a real exercised check is genuine.

**Reviewer verification (2026-07-09).** Checked live, read-only, against the
committed tree and the `k3d-agrippa-dev` cluster context: `apps/workloads.yaml`
(no seam), `workloads/overlays/dev/kustomization.yaml` (`resources: []`),
`core/overlays/dev/gateway-cert.yaml` (five SANs, neither workload host),
`mise.toml` (no `node`/`npm` pin, no `workloads:build` task), `scripts/test-feature.sh`
(`workloads.bats` excluded), `scripts/test-chart.sh` (green-on-empty on absent
`charts/`), absent `charts/` and `.gitmodules`, and `tests/workloads.bats`
(committed RED baseline). The submodule finding was confirmed from ArgoCD's
documented fatal-submodule-fetch behavior and global-only toggle
(argoproj/argo-cd#10174, #3799), the live repo-server env (`ARGOCD_GIT_MODULES_ENABLED`
sourced from the absent `argocd-cmd-params-cm` key → enabled), the absence of any
`repository`/`repo-creds` secret in `argocd`, and the shared `repoURL` across all
seven Applications. No live cluster state was mutated by that read-only pass;
item 3's fix was applied and live-verified separately by the coordinator, as
its own prerequisite commit on `main`, ahead of this feature-step's own build
(recorded in item 3 above).

**Gate status: CLEARED.** Items 1, 2, 4, and 5 decided to their conservative
defaults; item 3, originally escalated as a build-breaking,
out-of-recorded-scope prerequisite defect (the ArgoCD private-submodule fetch
would have broken the whole app-of-apps tree at Step 1's `.gitmodules`
commit), is now resolved — the coordinator added the global
`reposerver.enable.git.submodule: "false"` toggle to the `apps/platform/argocd/`
install layer as a pre-Step-1 prerequisite, applied and live-verified it, and
corrected the design's § Failure modes and § Cross-step touches from the
non-existent per-Application mechanism to the real global one. This plan's
Step 3 and Step 5 have been reworded to match: no ArgoCD-side action remains
for this feature-step's own Steps. With all five items Decided, the draft
marker moves to `*Reviewed 2026-07-09*` and the plan is cleared to build.
