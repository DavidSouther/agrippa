# Implementation Plan: Git hosting (Forgejo server, Postgres-backed)

*Draft 2026-07-08*

> Feature-step plan (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 6: Git hosting
> (Forgejo)**. Its `design.md` (and `research.md`) are already Reviewed by a
> separately dispatched long-loop reviewer; this plan is a paper plan against
> that cleared design and has not been built. This is a **long-loop** run: the
> draft gate below is left open for a separately dispatched reviewer to clear
> — this session does not clear it itself. The step decomposition follows the
> forward path fixed by the two most-recently-completed sibling plans,
> `storage-postgres-valkey/plan.md` and `networking-istio/plan.md`, closely
> enough (four intra-component sync-waves + a Step 0 layout step + a final
> proof-and-regression step) that the forward-backward method's map-file
> mechanism was not needed — the six-step shape was directly evident from
> those two precedents plus the cleared design's own intra-`forgejo`
> sync-wave scheme.

**Feature test:** `tests/git-hosting.bats`
**User story:** Given the bootstrapped `agrippa-dev` cluster with this
Forgejo content committed and reconciled by ArgoCD into the `platform`
layer — the Forgejo server backed by the shared `postgres` Cluster's
`forgejo` database/role, its sealed admin credential, and its `HTTPRoute` at
`git.davidsouther.com.127.0.0.1.nip.io` — when an operator reaches Forgejo's
API through the shared Gateway, authenticates with the sealed admin
credential, and creates and pushes to a repository, then the `platform`
Application is Synced/Healthy, Forgejo's API answers through the Gateway
over a local-CA-issued cert, the authenticated admin call succeeds (proving
the sealed credential plus the Postgres-backed user store), and a newly
created repository accepts a `git push` and serves the pushed commit back —
proving Git hosting is live and usable end-to-end, with **no
runner/Actions/CI assertion** (deferred).

**Steps:**
- [ ] Step 0: API surface area (file layout, `apps/platform.yaml` sync seam)
- [ ] Step 1: Wave `-10` — the `forgejo` Namespace, wired into the shared `platform` overlay
- [ ] Step 2: Wave `-5` — sealing the admin + DB credentials, and the storage `managed.roles[]` append
- [ ] Step 3: Wave `0` — the Forgejo chart, its `HTTPRoute`, and the Gateway-cert SAN append
- [ ] Step 4: Wave `5` — the `forgejo` `Database` CR
- [ ] Step 5: Full GREEN — the authenticated admin + push proof, and the regression sweep

**Libraries & Skills (carried forward from `design.md`/`research.md`; load before each build step):**

- `developer:initialize` — carried forward per convention, but this
  feature-step exercises no residual `mise` work: it adds **no** new
  mise-managed CLI. The Forgejo chart is an in-cluster resource ArgoCD
  reconciles via Helm, not a local tool; every CLI this plan's steps need
  (`sops`, `age`, `kustomize`, `helm`, `kubectl`, `k3d`, `openssl`, `jq`,
  `yq`, `bitwarden`) is already pinned in `mise.toml`. Nothing in
  `mise.toml` changes across any step below.
- `research:public` and `research:codebase` — for the per-tool detail each
  step below explicitly defers to build time: the exact current Forgejo
  chart `version:` (`code.forgejo.org/forgejo-helm/forgejo-helm`, OCI), the
  exact `gitea.config.database`/`additionalConfigFromEnvs`/
  `admin.existingSecret`/`admin.passwordMode` key spellings and the
  `FORGEJO__DATABASE__PASSWD` env-var name against that pinned chart, the
  chart's default HTTP Service name/port the `HTTPRoute` targets, and
  whether the chart's `helmCharts:` inflation needs the same
  kustomize-namespace-stamp or `skipTests:` workarounds Valkey's own
  inflation needed.
- No library-shipped agentic skill exists for Forgejo, CloudNativePG, the
  official Valkey chart, sops, age, or KSOPS (reconfirmed by both
  `research.md` and `design.md`). Build to `ARCHITECTURE.html` (§ Platform
  layer / Git Hosting view), `DEVELOPMENT.md` (§ Secrets), and the two
  completed sibling designs/plans directly — `storage-postgres-valkey` (the
  DB/role naming contract, the credential-sealing shell recipes, the
  self-contained-KSOPS-sub-kustomization wiring, the per-component-subdir
  layout with wave-scoped nested kustomizations) and `networking-istio` (the
  Gateway/HTTPRoute/hostname/TLS contract, the explicit-`matches:` trap, and
  the shared append-only `dnsNames` list).

**Patterns beat (`patterns:using-patterns` consulted):** Same conclusion as
both completed siblings, re-verified for this feature-step's own pressures
rather than assumed. This feature-step has no typed application code — only
GitOps infrastructure config (Kustomize kustomizations, `helmCharts:`
inflation, one authored CNPG `Database` CR, one authored `HTTPRoute`,
sops-encrypted Secret manifests, one bats suite) — so `newtype`,
`domain-objects`, `builder`, `visibility`, `parse-dont-validate`,
`type-states`, `repository`, `aggregate`, and `unit-of-work` all require a
typed domain model that does not exist here, and none is invoked. The
`forgejo` database=role=slug naming and the two-copies-of-one-password
cross-namespace credential shape are naming/data conventions expressed in
YAML string fields and ciphertext, not a wrapped primitive or an object
carrying behavior — no code constructs or compares these values, only
kustomize/Helm rendering and CNPG's/Forgejo's own controllers. Two patterns
shape *how* the surface and its one test are written: **`arrange-act-assert`**
for the single bats `@test` (the existing `run`/assert shape
`tests/git-hosting.bats` already follows), and **`errors-typed-untyped`**,
resolved to the untyped side — a `kubectl`/`curl`/`git` exit code, an ArgoCD
`Application`'s `sync`/`health` status, and a `sops`/KSOPS decrypt
success-or-failure are the correct, sufficient failure signals here, consumed
only by an operator's shell, `bats`, and ArgoCD's own reconcile loop; no
in-process caller needs to match distinct typed failure modes.

## Step 0: API surface area

Land the shared `apps/platform.yaml` sync seam and fix every file path,
directory layout, and object name before any has real content, mirroring
both completed siblings' Step 0 convention (fixed identifiers, honest inert
stubs, no logic/spec). Two changes land here:

**1. The `apps/platform.yaml` sync seam** (shared with Auth and Flagsmith;
lands once, idempotent if a sibling adds it first — verify current content
before writing). `apps/platform.yaml` today carries `syncPolicy.automated`
only, no `syncOptions` and no `compare-options` annotation (confirmed live
this session). Add the identical pair `apps/core.yaml` and
`apps/storage.yaml` both already carry, pre-empting the same
controller-defaulted-field permanent-`OutOfSync` symptom (argoproj/argo-cd
#22151) both siblings hit live once their own Helm/CRD content synced:

```diff
 metadata:
   name: platform
   namespace: argocd
   annotations:
     argocd.argoproj.io/sync-wave: "2"
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

**2. The `platform/overlays/dev/forgejo/` and `secrets/dev/platform/forgejo/`
directory layout**, fixing every file and object name the cleared `design.md`
Specification already resolved (including its reviewer-resolved Open
Artifact Decisions 1-5). **One plan-level refinement on the design's proposed
flat layout:** the design's `forgejo/` listing mixes four different
sync-waves (namespace `-10`, secrets `-5` via a referenced sub-kustomization,
chart+`HTTPRoute` `0`, `Database` `5`) inside one component subdirectory —
under-specified in the design as "normal artifact authoring" (research item
4). Mirroring how Storage resolved the identical shape (`cnpg-operator/` and
`valkey/` are each their own nested kustomization scoped to *one* wave via
`commonAnnotations`, because Helm-emitted output cannot be annotated
directly, while standalone authored CRs — `postgres-cluster.yaml`,
`smoke-database.yaml` — carry their own inline `metadata.annotations`
instead of a wrapping kustomization): the Forgejo `helmCharts:` release gets
its own nested `chart/` subdirectory (`commonAnnotations` wave `0`,
mirroring `valkey/kustomization.yaml`), while `namespace.yaml`,
`httproute.yaml`, and `forgejo-database.yaml` — standalone authored CRs this
step controls directly — each carry their own inline sync-wave annotation,
exactly `postgres-cluster.yaml`/`smoke-database.yaml`/`gateway-cert.yaml`/
`argocd-httproute.yaml`'s precedent. **The top-level `platform/overlays/dev/
kustomization.yaml` stays the existing `resources: [argocd.yaml]`** — none of
these new files are referenced yet, so `platform` stays trivially
Synced/Healthy on `argocd.yaml`-only content (preserving the RED baseline's
THEN 0 pass) and nothing new reaches the live cluster this step:

```text
platform/overlays/dev/forgejo/
├── kustomization.yaml        # this step: resources: [namespace.yaml] only
├── namespace.yaml            # Namespace forgejo (full content now; wave -10)
├── httproute.yaml            # wave 0; HTTPRoute forgejo name-only stub (ns forgejo; spec lands Step 3)
├── forgejo-database.yaml     # wave 5; Database forgejo name-only stub (ns storage; spec lands Step 4)
└── chart/
    └── kustomization.yaml    # wave 0; helmCharts: [] (Forgejo chart lands Step 3)

secrets/dev/platform/forgejo/
└── kustomization.yaml        # wave -5; generators: [] (secret-generator.yaml + the three
                               #   encrypted files land Step 2)
```

Representative stubs (every other authored-CR file follows the same shape):

```yaml
# platform/overlays/dev/forgejo/namespace.yaml -- full content now (a Namespace has no spec)
apiVersion: v1
kind: Namespace
metadata:
  name: forgejo
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
```

```yaml
# platform/overlays/dev/forgejo/httproute.yaml -- Step 0 skeleton (name-only stub, no spec)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: forgejo
  namespace: forgejo
  annotations:
    argocd.argoproj.io/sync-wave: "0"
```

```yaml
# platform/overlays/dev/forgejo/forgejo-database.yaml -- Step 0 skeleton (name-only stub, no spec)
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: forgejo
  namespace: storage
  annotations:
    argocd.argoproj.io/sync-wave: "5"
```

```yaml
# platform/overlays/dev/forgejo/chart/kustomization.yaml -- Step 0 skeleton
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: "0"
helmCharts: []   # code.forgejo.org/forgejo-helm/forgejo-helm lands Step 3
```

```yaml
# secrets/dev/platform/forgejo/kustomization.yaml -- Step 0 skeleton
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: "-5"
generators: []   # secret-generator.yaml (kind: ksops) lands Step 2
```

This fixes: the `apps/platform.yaml` sync seam, the directory layout, every
shared-contract object name (`forgejo`, `forgejo-admin`, `forgejo-db`), and
the four-tier sync-wave scheme (`-10`/`-5`/`0`/`5`) as constants every
remaining step reuses. `tests/git-hosting.bats` is a `design.md` artifact and
already exists (RED baseline: `platform` trivially Synced/Healthy on
`argocd.yaml`-only content, failing from THEN 1 onward). Step 0 does not
touch it and does not change that RED state: `platform/overlays/dev/
kustomization.yaml`'s top-level `resources:` list is unchanged, so nothing
new reaches the live cluster yet — but every name and file the remaining
steps fill in now exists and is fixed.

**Tests**

```bash
test "the apps/platform.yaml seam is real; platform stays Synced/Healthy on unchanged content":
  run bash -c "yq '.spec.syncPolicy.syncOptions' apps/platform.yaml"
  assert output contains "ServerSideApply=true"
  assert output contains "SkipDryRunOnMissingResource=true"
  run bash -c "yq '.metadata.annotations[\"argocd.argoproj.io/compare-options\"]' apps/platform.yaml"
  assert output == "ServerSideDiff=true"
  run kubectl --context k3d-agrippa-dev -n argocd get application platform \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"               # unchanged -- still argocd.yaml-only
```

- Edge case: if Auth or Flagsmith already landed the identical `apps/platform.yaml` pair before this step runs, the edit must be a no-op check-then-skip, not a duplicate append that produces two `syncOptions` lists.
- Edge case: confirm `platform/overlays/dev/kustomization.yaml` is unchanged (still `resources: [argocd.yaml]`) after this step — nothing new is fed to the live cluster yet.
- Edge case: re-running `mise run test:push`/`test:static` after this step must still pass (nothing new is fed to kubeconform/conftest yet — `secrets/dev/platform/forgejo/kustomization.yaml`'s `generators: []` has no `kind` to inspect, matching Storage's own Step 0 precedent).

**Implementation Outline**

```text
apps/platform.yaml:
  metadata.annotations["argocd.argoproj.io/compare-options"] <- "ServerSideDiff=true"
  spec.syncPolicy.syncOptions <- [ServerSideApply=true, SkipDryRunOnMissingResource=true]

platform/overlays/dev/kustomization.yaml:
  resources: [argocd.yaml]   # unchanged

platform/overlays/dev/forgejo/{kustomization.yaml, namespace.yaml, httproute.yaml,
  forgejo-database.yaml, chart/kustomization.yaml}: stubs, as above

secrets/dev/platform/forgejo/kustomization.yaml: generators: [] stub
```

## Step 1: Wave `-10` — the `forgejo` Namespace, wired into the shared `platform` overlay

**Enables:** no feature-test assertion flips yet (`platform` was already
trivially Synced/Healthy on `argocd.yaml`-only content, and stays
Synced/Healthy once the inert Namespace lands — THEN 1 onward still fails, no
`HTTPRoute` routes the git host yet). Substrate-only: this step wires the
shared top-level resource list for the first time this feature-step, the
same append-only-list edit Networking's Gateway `dnsNames` and Storage's
`managed.roles[]` already established, this time on `platform/overlays/dev/
kustomization.yaml`'s `resources:` list — the design's own flagged "many
independent consumers append to one shared, mutable list" shape.

Append `forgejo` to `platform/overlays/dev/kustomization.yaml`'s `resources:`
list (`resources: [argocd.yaml, forgejo]`) — the first real content this
feature-step applies to the live cluster. Verify the current list first
(Auth/Flagsmith may have already appended their own entries alongside
`argocd.yaml`); append `forgejo` alongside whatever is already there rather
than assuming a fixed starting shape.

**Tests**

```bash
test "the forgejo namespace lands, platform stays Synced/Healthy":
  run kubectl --context k3d-agrippa-dev -n argocd get application platform \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"
  run kubectl --context k3d-agrippa-dev get namespace forgejo
  assert status == 0
```

- Edge case: confirm Step 0's `ServerSideApply=true`/`SkipDryRunOnMissingResource=true` on `apps/platform.yaml` has already rolled out before this commit syncs (the same sequencing caveat both siblings' own Step 1 carried).
- Edge case: `forgejo` must not collide with any namespace already live (`istio-system`, `istio-ingress`, `cert-manager`, `metallb-system`, `cnpg-system`, `storage`, `argocd`).
- Edge case: if a sibling (Auth/Flagsmith) already appended its own entry to `platform/overlays/dev/kustomization.yaml`'s `resources:` list, append `forgejo` alongside it, preserving the existing entries.

**Implementation Outline**

```text
platform/overlays/dev/kustomization.yaml:
  resources:
    - argocd.yaml
    - forgejo

platform/overlays/dev/forgejo/kustomization.yaml:
  resources:
    - namespace.yaml
```

## Step 2: Wave `-5` — sealing the admin + DB credentials, and the storage `managed.roles[]` append

**Enables:** no feature-test assertion flips directly yet (nothing consumes
these Secrets until Step 3's chart references them), but this is the
load-bearing prerequisite for THEN 3 (the authenticated admin call) and THEN
4 (the repo push, which needs the Postgres-backed user store) — and it is the
storage-side half of the design's cross-namespace DB credential wrinkle.

Seal three credentials using the identical discipline Storage's `smoke-db`/
`smoke-valkey` fixtures already proved (generate in memory, encrypt
immediately, never write plaintext to disk, never put a secret in argv):

- **`forgejo-admin`** (ns `forgejo`, keys `username`, `password`) — the
  multi-value case, `admin.enc.yaml`.
- **`forgejo-db`** (`kubernetes.io/basic-auth`, keys `username: forgejo`,
  `password`), sealed **twice from one generated password** — once `-n
  storage` (`db-storage.enc.yaml`, for CNPG's `managed.roles[]`) and once `-n
  forgejo` (`db-forgejo.enc.yaml`, for the chart's `additionalConfigFromEnvs`)
  — the single-value pure-stdin case, run twice against the same in-memory
  value.

Fill `secrets/dev/platform/forgejo/kustomization.yaml`'s `generators:` with
`secret-generator.yaml` (`apiVersion: viaduct.ai/v1`, `kind: ksops`, `files:
[admin.enc.yaml, db-storage.enc.yaml, db-forgejo.enc.yaml]`). Wire
`platform/overlays/dev/forgejo/kustomization.yaml`'s `resources:` to add
`../../../../secrets/dev/platform/forgejo` — the self-contained
sub-kustomization reference Storage's `../../../secrets/dev/storage` pattern
established (one path segment deeper here, since `forgejo/` nests one level
further than `storage/overlays/dev/` itself).

Append one entry to `storage/overlays/dev/postgres-cluster.yaml`'s
`managed.roles[]`: `{name: forgejo, login: true, passwordSecret: {name:
forgejo-db}}` — the shared, sibling-owned append-only list, changing only the
slug from the live `smoke` entry. This is a `storage`-layer touch (a
different ArgoCD Application than `platform`), landing here because it is
tightly coupled to sealing `db-storage.enc.yaml` in the same step.

**Tests**

```bash
test "the forgejo credentials round-trip through KSOPS; the storage role append lands":
  run kubectl --context k3d-agrippa-dev -n forgejo get secret forgejo-admin \
    -o jsonpath='{.data.username} {.data.password}'
  assert status == 0                              # both keys present, non-empty
  run kubectl --context k3d-agrippa-dev -n forgejo get secret forgejo-db \
    -o jsonpath='{.type} {.data.username} {.data.password}'
  assert status == 0
  assert output contains "kubernetes.io/basic-auth"
  run kubectl --context k3d-agrippa-dev -n storage get secret forgejo-db \
    -o jsonpath='{.type} {.data.username} {.data.password}'
  assert status == 0
  run kubectl --context k3d-agrippa-dev -n storage get cluster.postgresql.cnpg.io postgres \
    -o jsonpath='{.spec.managed.roles[?(@.name=="forgejo")].passwordSecret.name}'
  assert output == "forgejo-db"
  run mise run test:static
  assert status == 0                               # conftest sees secrets/, still passes
```

- Edge case: both `db-storage.enc.yaml` and `db-forgejo.enc.yaml` must be
  sealed from the **same** in-memory password (generate once, reuse the
  value for both `sops --encrypt` calls in the same shell session) — never
  regenerated independently, or CNPG's role password and the pod's
  configured password diverge and auth fails.
- Edge case: each `sops --encrypt` call needs its own `--filename-override
  secrets/dev/platform/forgejo/<file>.enc.yaml` so the `^secrets/dev/.*$`
  creation rule applies to stdin input (Storage's Step 2 edge case, reused
  verbatim — omitting it makes `sops` see the filename as `/dev/stdin`,
  matching no rule).
- Edge case: the admin Secret's multi-value case passes `username`/
  `password` through shell variables, not `--from-literal=password=...` on
  the command line — verify with `ps`/history that no plaintext password
  ever appears in argv (Storage's `smoke-valkey` precedent).
- Edge case (design's own flagged Challenge): confirm at build whether the
  chart's `existingSecret` expects the admin username as a Secret key
  (`stringData: {username: ...}`) or a plain `gitea.admin.username` chart
  value — correct `admin.enc.yaml`'s shape here if the pinned chart's schema
  differs.
- Edge case: verify `kustomize build platform/overlays/dev/forgejo` does not
  trip the default `LoadRestrictionsRootOnly` restrictor — the
  sub-kustomization reference must stay genuinely self-contained (Storage's
  Step 2 edge case, reused).
- Edge case: appending to `storage/overlays/dev/postgres-cluster.yaml`'s
  `managed.roles[]` must not disturb the live `smoke` entry — a pure list
  append, not a replace.

**Implementation Outline**

```bash
# db password -- generated once, sealed twice into two namespaces
DB_PW="$(openssl rand -base64 24 | tr -d '\n')"

printf '%s' "$DB_PW" | kubectl create secret generic forgejo-db -n storage \
    --type kubernetes.io/basic-auth --from-literal=username=forgejo \
    --from-file=password=/dev/stdin --dry-run=client -o yaml \
  | sops --encrypt --filename-override secrets/dev/platform/forgejo/db-storage.enc.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > secrets/dev/platform/forgejo/db-storage.enc.yaml

printf '%s' "$DB_PW" | kubectl create secret generic forgejo-db -n forgejo \
    --type kubernetes.io/basic-auth --from-literal=username=forgejo \
    --from-file=password=/dev/stdin --dry-run=client -o yaml \
  | sops --encrypt --filename-override secrets/dev/platform/forgejo/db-forgejo.enc.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > secrets/dev/platform/forgejo/db-forgejo.enc.yaml

# admin credential -- multi-value case, env-passed (never argv)
ADMIN_PW="$(openssl rand -base64 24 | tr -d '\n')"
kubectl create secret generic forgejo-admin -n forgejo \
    --from-literal=username=agrippa-admin --from-literal=password="$ADMIN_PW" \
    --dry-run=client -o yaml \
  | sops --encrypt --filename-override secrets/dev/platform/forgejo/admin.enc.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > secrets/dev/platform/forgejo/admin.enc.yaml
```

```yaml
# secrets/dev/platform/forgejo/secret-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: forgejo-secret-generator
files:
  - admin.enc.yaml
  - db-storage.enc.yaml
  - db-forgejo.enc.yaml
```

```text
secrets/dev/platform/forgejo/kustomization.yaml:
  generators: [secret-generator.yaml]

platform/overlays/dev/forgejo/kustomization.yaml:
  resources:
    - namespace.yaml
    - ../../../../secrets/dev/platform/forgejo

storage/overlays/dev/postgres-cluster.yaml:
  spec.managed.roles:
    - {name: smoke, login: true, passwordSecret: {name: smoke-db}}   # unchanged
    - name: forgejo
      login: true
      passwordSecret: {name: forgejo-db}
```

## Step 3: Wave `0` — the Forgejo chart, its `HTTPRoute`, and the Gateway-cert SAN append

**Enables:** THEN 1 (`curl .../api/v1/version` returns a `"version"` payload
through the Gateway) and THEN 2 (the served certificate is issued by the
local CA) — the reachability half of the feature test.

Fill `chart/kustomization.yaml`'s `helmCharts:` with
`code.forgejo.org/forgejo-helm/forgejo-helm` (OCI, pinned `version:` —
`research:public` at build time), `releaseName: forgejo`, namespace
`forgejo`, `valuesInline`: `gitea.config.database` (`DB_TYPE: postgres`,
`HOST: postgres-rw.storage.svc:5432`, `NAME: forgejo`, `USER: forgejo`),
`gitea.additionalConfigFromEnvs` mapping `FORGEJO__DATABASE__PASSWD` (exact
env-var spelling confirmed at build) to a `secretKeyRef` on `forgejo-db`'s
`password` key, `gitea.admin.existingSecret: forgejo-admin`,
`gitea.admin.email` (a plain, non-secret value), `gitea.admin.passwordMode:
keepUpdated` (design's resolved Open Artifact Decision 4), `persistence.
enabled: true` on `local-path` with a small size. Fill `httproute.yaml`'s
spec: `parentRefs: [{name: agrippa-gateway, namespace: istio-ingress,
sectionName: https}]`, `hostnames: [git.davidsouther.com.127.0.0.1.nip.io]`,
an **explicit** `matches: [{path: {type: PathPrefix, value: /}}]` rule
(Networking's own live-hit trap — an omitted `matches:` left `core`
permanently OutOfSync — avoided here by design fiat), `backendRefs:` the
chart's default HTTP Service (exact name/port confirmed at build). Append
`git.davidsouther.com.127.0.0.1.nip.io` to `core/overlays/dev/
gateway-cert.yaml`'s `dnsNames` — a `core`-layer, sibling-owned append-only
list (the one-line SAN edit, never a `Gateway`/`Certificate` object change).
Wire `chart/` and `httproute.yaml` into `platform/overlays/dev/forgejo/
kustomization.yaml`'s `resources:` list.

**Tests**

```bash
test "the Forgejo chart and HTTPRoute reconcile; the API is reachable over local-CA TLS":
  run kubectl --context k3d-agrippa-dev -n argocd get application platform \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"
  run kubectl --context k3d-agrippa-dev -n forgejo get pods -l app.kubernetes.io/name=forgejo \
    -o jsonpath='{.items[0].status.phase}'
  assert output == "Running"
  run curl -k -sS --max-time 10 "https://git.davidsouther.com.127.0.0.1.nip.io/api/v1/version"
  assert output contains '"version"'
  run bash -c "openssl s_client -connect 127.0.0.1:443 -servername git.davidsouther.com.127.0.0.1.nip.io </dev/null 2>/dev/null | openssl x509 -noout -issuer"
  assert output contains "Agrippa Local Dev CA"
```

- Edge case (design's flagged risk): the `helmCharts:` namespace-stamp
  regression (kustomize#6058) may hit the Forgejo chart the same way it hit
  Valkey — verify at build whether the chart's templates hardcode `{{
  .Release.Namespace }}`; if not, mirror Valkey's scoped `patches:`
  namespace-stamp for exactly the kinds this chart emits.
- Edge case (design's flagged risk): confirm the chart's default
  `server.PROTOCOL` is `http` before trusting the plain-HTTP `HTTPRoute`
  shape — an HTTPS default would need a backend `DestinationRule` (the
  `argocd`-style re-origination Networking already proved), not the plain
  route this step authors.
- Edge case: confirm `chart/`'s `helmCharts:` inflation emits no literal
  `helm.sh/hook` test Pod the way Valkey's did (design's own flagged
  Challenge) — add `skipTests: true` if it does.
- Edge case: the `forgejo` pod must not start (or must crash-loop cleanly,
  not silently misconfigure) before `forgejo-db`/`forgejo-admin` exist —
  Step 2's wave `-5` ordering should guarantee this; verify live rather than
  trust the wave annotation alone.
- Edge case: verify `git.davidsouther.com.127.0.0.1.nip.io` is the only new
  entry appended to `gateway-cert.yaml`'s `dnsNames` — the existing
  `argocd.127.0.0.1.nip.io` entry must be undisturbed.
- Edge case: if `platform` goes permanently OutOfSync on a
  controller-defaulted chart field (the symptom Storage hit with CNPG's
  `Cluster` and Networking hit with istiod's webhooks), Step 0's
  `ServerSideDiff=true` annotation should pre-empt it — verify live, and
  fall back to a narrowly-scoped `ignoreDifferences` only if it still
  surfaces.

**Implementation Outline**

```yaml
# platform/overlays/dev/forgejo/chart/kustomization.yaml (filled)
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: "0"
helmCharts:
  - name: forgejo
    repo: oci://code.forgejo.org/forgejo-helm
    version: <pinned; research:public at build>
    releaseName: forgejo
    namespace: forgejo
    valuesInline:
      gitea:
        config:
          database:
            DB_TYPE: postgres
            HOST: postgres-rw.storage.svc:5432
            NAME: forgejo
            USER: forgejo
        additionalConfigFromEnvs:
          - envName: FORGEJO__DATABASE__PASSWD    # exact spelling confirmed at build
            secretKeyRef: {name: forgejo-db, key: password}
        admin:
          existingSecret: forgejo-admin
          email: admin@git.davidsouther.com.127.0.0.1.nip.io
          passwordMode: keepUpdated
      persistence:
        enabled: true
        storageClass: local-path
        size: 2Gi
```

```yaml
# platform/overlays/dev/forgejo/httproute.yaml (filled)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: forgejo
  namespace: forgejo
  annotations: {argocd.argoproj.io/sync-wave: "0"}
spec:
  parentRefs:
    - {name: agrippa-gateway, namespace: istio-ingress, sectionName: https}
  hostnames: [git.davidsouther.com.127.0.0.1.nip.io]
  rules:
    - matches: [{path: {type: PathPrefix, value: /}}]
      backendRefs: [{name: forgejo-http, port: 3000}]   # exact chart Service name/port confirmed at build
```

```text
core/overlays/dev/gateway-cert.yaml:
  spec.dnsNames:
    - argocd.127.0.0.1.nip.io          # unchanged
    - git.davidsouther.com.127.0.0.1.nip.io

platform/overlays/dev/forgejo/kustomization.yaml:
  resources:
    - namespace.yaml
    - ../../../../secrets/dev/platform/forgejo
    - chart/
    - httproute.yaml
```

## Step 4: Wave `5` — the `forgejo` `Database` CR

**Enables:** the storage-provisioning half of THEN 3/THEN 4 (a real
Postgres-backed user store and repo-metadata store) — the declarative
per-app database the shared `postgres` Cluster's `forgejo` role (Step 2)
needs before Forgejo's user/repo tables can be created.

Fill `forgejo-database.yaml`'s spec: `name: forgejo`, `owner: forgejo`,
`cluster: {name: postgres}` — the exact live `smoke-database.yaml` shape,
slug changed (including the required `spec.name` literal DB name, Storage's
own build-discovered CRD field, already reflected here). Wire it into
`platform/overlays/dev/forgejo/kustomization.yaml`'s `resources:` list at
wave `5`, after the chart (wave `0`) and the `forgejo` role (Step 2, already
live on the shared Cluster) exist.

**Tests**

```bash
test "the forgejo Database CR reconciles":
  run kubectl --context k3d-agrippa-dev -n storage get database.postgresql.cnpg.io forgejo \
    -o jsonpath='{.status.applied}'
  assert output == "true"
```

- Edge case: `owner: forgejo` must resolve to a role that already exists
  (Step 2's `managed.roles[]` entry) — CNPG errors on `CREATE DATABASE ...
  OWNER forgejo` if the role isn't there yet; sync-wave ordering should
  prevent this, but verify live rather than trust the wave annotation alone.
- Edge case: confirm the exact CRD field spellings (`spec.name`,
  `spec.owner`, `spec.cluster.name`) against the pinned CNPG version at
  build — Storage's own build-time correction (the live CRD requires
  `spec.name` in addition to `owner`/`cluster.name`) is already reflected
  here, but re-verify against whatever CNPG version is live by this build.
- Edge case: this `Database` CR lives in `platform/overlays/dev/forgejo/`
  (the `platform` Application's own subtree) but targets `metadata.
  namespace: storage` — confirm the `platform` Application can create a
  resource into a namespace outside its own `destination.namespace` default
  (the design's own cited precedent: the `storage` Application already
  creates resources into both `cnpg-system` and `storage`).

**Implementation Outline**

```yaml
# platform/overlays/dev/forgejo/forgejo-database.yaml (filled)
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: forgejo
  namespace: storage
  annotations: {argocd.argoproj.io/sync-wave: "5"}
spec:
  name: forgejo
  owner: forgejo
  cluster: {name: postgres}
```

```text
platform/overlays/dev/forgejo/kustomization.yaml:
  resources:
    - namespace.yaml
    - ../../../../secrets/dev/platform/forgejo
    - chart/
    - httproute.yaml
    - forgejo-database.yaml
```

## Step 5: Full GREEN — the authenticated admin + push proof, and the regression sweep

**Enables:** THEN 3 (an authenticated `GET /api/v1/user` call with the
sealed admin credential succeeds) and THEN 4 (create → clone → push →
serve-back a repository) — the two assertions that prove the whole path
end-to-end. No new manifests: Steps 1-4 already wired the chart, its
DB-backed user store, and the `HTTPRoute`, so this step is proof-and-
regression, not new substrate — mirroring both siblings' final step.

Run `bats tests/git-hosting.bats` against the fully reconciled `platform`
layer. If build-time verification (Steps 2-4's own recorded edge cases)
found any Forgejo API path, admin-Secret key name, or chart Service/port
spelling diverges from what the suite assumes, correct the test's constants
here — a test-definition correction inherited from build-time
re-verification, not new test authorship (mirroring both siblings' own
final-step corrections). Then re-run the full harness the design's Metrics
section names as no-regression evidence.

**Tests**

```bash
test "tests/git-hosting.bats passes end-to-end":
  run bats tests/git-hosting.bats
  assert status == 0

test "no regression to earlier harness":
  run mise run test:push
  assert status == 0
  run mise run test:feature
  assert status == 0
  run bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats tests/storage.bats tests/rotate-keys.bats
  assert status == 0
```

- Edge case: `scripts/test-feature.sh` already excludes `git-hosting.bats`
  from its throwaway-cluster auto-discovery (verified committed this
  session, landed with the feature test at design time) — this step only
  needs to confirm that exclusion still holds, not add it.
- Edge case: the `git push` over HTTPS needs `http.sslVerify=false` and the
  `Authorization` header (not a URL-embedded credential) — confirm the
  operator's `git` CLI honors both `-c` overrides against the local-CA-signed
  Gateway.
- Edge case: re-running `bats tests/git-hosting.bats` a second time
  back-to-back must not error — the probe repository is deleted first
  (idempotent create) and cleaned up in `teardown()`; confirm this holds
  against the live server, not just the test's own logic.
- Edge case: `mise run test:static`'s kubeconform/conftest pass does not
  walk `platform/` (only `apps/`, `charts/*/rendered/`, and `secrets/`) — do
  not assume `test:push` exercises Steps 1-4's Forgejo/CNPG/HTTPRoute YAML;
  ArgoCD's own live reconcile and this bats suite are the only validators of
  that content (both siblings' own final-step note, reused).
- Edge case: `tests/rotate-keys.bats` is recorded as pre-existing-failing,
  unrelated to Storage's own commits (Storage's Step 5 finding) — confirm it
  is still failing for the same pre-existing reason, not a new regression
  this feature-step introduced.

**Implementation Outline**

```text
# no new manifests; this step is verification-only plus any build-time-discovered
# corrections to tests/git-hosting.bats' API-path/Secret-key/Service-port
# assumptions, surfaced by actually running the suite against the live
# reconciled platform layer
run bats tests/git-hosting.bats
run mise run test:push && mise run test:feature
run bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats tests/storage.bats tests/rotate-keys.bats
```
