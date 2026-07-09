# Implementation Plan: Git hosting (Forgejo server, Postgres-backed)

*Reviewed 2026-07-09*

> Feature-step plan (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 6: Git hosting
> (Forgejo)**. Its `design.md` (and `research.md`) are already Reviewed by a
> separately dispatched long-loop reviewer; this plan is a paper plan against
> that cleared design and has not been built. This is a **long-loop** run: the
> draft gate below is left open for a separately dispatched reviewer to clear
> — this session does not clear it itself. The step decomposition follows the
> forward path fixed by the two most-recently-completed sibling plans,
> `storage-postgres-valkey/plan.md` and `networking-istio/plan.md`, closely
> enough (three intra-component sync-waves + a Step 0 layout step + a final
> proof-and-regression step) that the forward-backward method's map-file
> mechanism was not needed — the five-step shape was directly evident from
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
- [x] Step 0: API surface area (file layout, `apps/platform.yaml` sync seam)
- [x] Step 1: Wave `-10` — the `forgejo` Namespace, wired into the shared `platform` overlay
- [x] Step 2: Wave `-5` — sealing the admin + DB credentials, the storage `managed.roles[]` append, and the `forgejo` `Database` CR
- [x] Step 3: Wave `0` — the Forgejo chart, its `HTTPRoute`, and the Gateway-cert SAN append
- [x] Step 4: Full GREEN — the authenticated admin + push proof, and the regression sweep

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
flat layout:** the design's `forgejo/` listing mixes three different
sync-waves (namespace `-10`, secrets and the `Database` CR `-5` — the
secrets via a referenced sub-kustomization, the `Database` CR via its own
inline annotation — and chart+`HTTPRoute` `0`) inside one component
subdirectory —
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
├── forgejo-database.yaml     # wave -5; Database forgejo name-only stub (ns storage; spec lands Step 2)
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
    argocd.argoproj.io/sync-wave: "-5"
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
the three-tier sync-wave scheme (`-10`/`-5`/`0`) as constants every
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

## Step 2: Wave `-5` — sealing the admin + DB credentials, the storage `managed.roles[]` append, and the `forgejo` `Database` CR

**Enables:** no feature-test assertion flips directly yet (nothing consumes
these Secrets or the database until Step 3's chart connects to them), but
this is the load-bearing prerequisite for THEN 3 (the authenticated admin
call) and THEN 4 (the repo push, which needs the Postgres-backed user store)
— the storage-side half of the design's cross-namespace DB credential
wrinkle, plus the declarative `forgejo` `Database` CR itself: the per-app
database the shared `postgres` Cluster's `forgejo` role (sealed and appended
below, in this same step) needs before Forgejo's user/repo tables can be
created.

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

Fill `forgejo-database.yaml`'s spec: `name: forgejo`, `owner: forgejo`,
`cluster: {name: postgres}` — the exact live `smoke-database.yaml` shape,
slug changed (including the required `spec.name` literal DB name, Storage's
own build-discovered CRD field, already reflected here). Wire it into
`platform/overlays/dev/forgejo/kustomization.yaml`'s `resources:` list at
wave `-5`, alongside the sealed Secrets and ahead of the chart (wave `0`,
Step 3) — its only real prerequisites are the CNPG operator and the
`forgejo` role (the `managed.roles[]` append just above, on the already-live
shared Cluster), not the chart or anything later in this component.
**Corrected placement:** the design originally scheduled this CR at wave
`5`, after the chart; a plan-gate reviewer found that deadlocks the ArgoCD
sync (the wave-`0` Forgejo Deployment crash-loops without a database to
connect to, so it never reaches Healthy, which permanently blocks the later
wave that would create that database), and the coordinator corrected
`design.md` to place it here at wave `-5` instead (see `design.md`'s
"Correction by the coordinator (2026-07-09)"; also this plan's own §
Resolved by the long-loop reviewer, item 4, below).

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

test "the forgejo Database CR reconciles":
  run kubectl --context k3d-agrippa-dev -n storage get database.postgresql.cnpg.io forgejo \
    -o jsonpath='{.status.applied}'
  assert output == "true"
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
- Edge case: `owner: forgejo` must resolve to a role that already exists
  (this step's own `managed.roles[]` append, above) — CNPG errors on
  `CREATE DATABASE ... OWNER forgejo` if the role isn't there yet. The role
  append and the `Database` CR both land at wave `-5`, but they are two
  different ArgoCD Applications (`storage` and `platform`) syncing
  independently, so same-wave numbering alone does not guarantee ordering
  between them — verify live rather than trust the wave annotation alone.
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

```yaml
# platform/overlays/dev/forgejo/forgejo-database.yaml (filled)
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: forgejo
  namespace: storage
  annotations: {argocd.argoproj.io/sync-wave: "-5"}
spec:
  name: forgejo
  owner: forgejo
  cluster: {name: postgres}
```

```text
secrets/dev/platform/forgejo/kustomization.yaml:
  generators: [secret-generator.yaml]

platform/overlays/dev/forgejo/kustomization.yaml:
  resources:
    - namespace.yaml
    - ../../../../secrets/dev/platform/forgejo
    - forgejo-database.yaml

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
  not silently misconfigure) before `forgejo-db`/`forgejo-admin` exist and
  the `forgejo` database itself has been created — Step 2's wave `-5`
  ordering (the sealed Secrets and the `Database` CR both land there, ahead
  of this wave-`0` chart) should guarantee this; verify live rather than
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
    - forgejo-database.yaml
    - chart/
    - httproute.yaml
```

## Step 4: Full GREEN — the authenticated admin + push proof, and the regression sweep

**Enables:** THEN 3 (an authenticated `GET /api/v1/user` call with the
sealed admin credential succeeds) and THEN 4 (create → clone → push →
serve-back a repository) — the two assertions that prove the whole path
end-to-end. No new manifests: Steps 1-3 already wired the chart, its
DB-backed user store, and the `HTTPRoute`, so this step is proof-and-
regression, not new substrate — mirroring both siblings' final step.

Run `bats tests/git-hosting.bats` against the fully reconciled `platform`
layer. If build-time verification (Steps 2-3's own recorded edge cases)
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
  not assume `test:push` exercises Steps 1-3's Forgejo/CNPG/HTTPRoute YAML;
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

## Resolved by the long-loop reviewer (2026-07-08)

This is a paper plan against the cleared feature `design.md`; it has not been
built. A separately dispatched long-loop reviewer read it cold and, per the
completed siblings' precedent, checked: (1) transcription fidelity against the
cleared `design.md` (no re-litigating design decisions), (2) the plan's
repo-state claims against the actually-committed files and the live
`k3d-agrippa-dev` cluster (read-only), (3) the plan's own net-new refinement
(the wave-scoped `chart/` sub-kustomization), and (4) the `forgejo` `Database`
CR's wave placement for an ordering-vs-dependency defect. Items 1-3 cleared
outright. **Item 4 was escalated: the originally transcribed wave scheme
deadlocked the ArgoCD sync, and the fix required revisiting a cleared design
decision — outside a plan-gate reviewer's own transcribe-faithfully remit, so
the reviewer correctly declined to decide it unilaterally.** The coordinator
resolved it directly: `design.md` § Intra-`forgejo` sync-wave scheme is
corrected (see its "Correction by the coordinator (2026-07-09)" subsection) to
move the `forgejo` `Database` CR from wave `5` to wave `-5`, and this plan is
updated to match — the `Database` CR's creation now lands in Step 2 (wave
`-5`, alongside the sealed credentials and the storage `managed.roles[]`
append), and the standalone step that used to hold it is removed, with every
downstream step renumbered. Item 4 below is accordingly re-recorded as
**Decided**, not escalated, and **the draft gate clears** — the marker is
updated to `*Reviewed 2026-07-09*`. The working tree and cluster were left
exactly as found by the original review; this edit is paper-only.

**1. Transcription fidelity against the cleared `design.md`; no runner/Actions/CI
component anywhere. Decided: faithful — no change needed.** Every step transcribes
the design's § Specification: the `apps/platform.yaml` sync-seam pair (Step 0),
the `platform/overlays/dev/forgejo/` + `secrets/dev/platform/forgejo/` layout and
the three-tier `-10/-5/0` wave scheme (Steps 0-3), the two sealed credentials
plus the storage `managed.roles[]` append and the `forgejo` `Database` CR
(Step 2), the chart `valuesInline` / `HTTPRoute` / `dnsNames` SAN append
(Step 3), and the proof-and-regression sweep (Step 4). forgejo-runner/Actions
appears only in the carried-forward deferral framing; no step introduces a
runner Deployment, a
registration secret, or any Actions/CI assertion, and the feature test explicitly
asserts "no runner/Actions/CI." (The `mise run test:push` / `test:feature`
regression calls are the project's own CI harness, not a Forgejo Actions runner.)

**2. Repo-state claims verified live (read-only). Decided: accurate — no change
needed.** `apps/platform.yaml` carries `syncPolicy.automated` only (no
`syncOptions`, no `compare-options`), so the shared seam has not landed — and no
sibling has raced it in: `platform/overlays/dev/` is still `resources:
[argocd.yaml]` with no `forgejo/`, `keycloak/`, or `flagsmith/` subdir, and
`secrets/dev/platform/` does not exist yet. `platform/overlays/dev/
kustomization.yaml` is exactly `resources: [argocd.yaml]`.
`storage/overlays/dev/postgres-cluster.yaml`'s `managed.roles[]` holds only
`{name: smoke, login: true, passwordSecret: {name: smoke-db}}`, matching the
append shape Step 2 mirrors. `core/overlays/dev/gateway-cert.yaml`'s `dnsNames` is
`[argocd.127.0.0.1.nip.io]` only, so Step 3's one-line SAN append is specified
correctly. `scripts/test-feature.sh` already carries `git-hosting.bats` in its
probe-suite exclusion `case` list, so Step 4 need only confirm it, as stated.
**`.sops.yaml`'s `^secrets/dev/.*$` recipient is a real, functional key, not a
placeholder:** its value
`age1e8wr0f85w0yfqgxc3pc6426ghlu5xt069znn5yuwrtwz30u23quqjcx6vc` is byte-identical
to the `recipient:` embedded in the already-committed, live-decrypting
`secrets/dev/storage/postgres/smoke.enc.yaml`, so the design's "already a real
recipient, fixed by Storage" holds and this plan's sealing will decrypt
in-cluster. (Caveat, not a plan defect: `.sops.yaml`'s own leading comment still
reads "PLACEHOLDER recipient / Replace the placeholder below … once it exists" —
stale text carried over from Storage's Step 0 pre-image; the value beneath it is
the real key. Worth correcting the comment out-of-band; it does not affect this
plan.)

**3. The plan's refinement splitting the design's flat `forgejo/` into a
wave-scoped `chart/` sub-kustomization (mirroring Storage's `valkey/`). Decided:
internally consistent and faithful — no change needed.** Every authored file's
sync-wave annotation matches the step that lands it: `namespace.yaml` wave `-10`
(Step 1), the `secrets/dev/platform/forgejo` kustomization `commonAnnotations`
wave `-5` (Step 2), `forgejo-database.yaml` inline wave `-5` (Step 2, folded in
alongside the sealed credentials — see item 4), `chart/kustomization.yaml`
`commonAnnotations` wave `0` (Step 3), `httproute.yaml` inline wave `0`
(Step 3) — one-for-one with the Step table. The `chart/`
sub-kustomization (`commonAnnotations: {sync-wave: "0"}` + `helmCharts:`) is a
faithful mirror of Storage's realized `storage/overlays/dev/valkey/
kustomization.yaml`, and the refinement changes structure, not behavior: it
realizes exactly the design's own stated rule ("`commonAnnotations` on the nested
Helm/secrets kustomizations, inline on authored CRs"), and it is strictly safer
than the design's flat-`forgejo/` diagram — a single `commonAnnotations` on one
flat kustomization carrying the wave-`0` chart *alongside* the wave-`-10`/`-5`
authored CRs would have to clobber or collide with those CRs' own inline waves.
A legitimate plan-level improvement, not a silent divergence. (It is orthogonal
to, and unaffected by, the wave-*number* correction recorded in item 4.)

**4. The `forgejo` `Database` CR wave placement versus the Forgejo chart
(Step 3, wave `0`). Decided: corrected — the `Database` CR now lands in
Step 2 at wave `-5`, before the chart, closing the deadlock.** The reviewer
found that the originally transcribed wave scheme (`Database` CR at wave
`5`, after the wave-`0` chart) deadlocked the ArgoCD sync — the Forgejo
Deployment hard-depends on a database that a later, health-gated wave was
responsible for creating, so neither could ever complete. Verified:
Forgejo/Gitea blocks on its database connection at startup — `InitDBEngine`
retries `DB_RETRIES` (default 10) times at `DB_RETRY_BACKOFF` (default 3s)
intervals (≈30s), then `log.Fatal`s and exits (CrashLoopBackOff); it never
binds the HTTP listener or passes its readiness probe until the connection
succeeds (go-gitea/gitea#27079; Gitea config cheat-sheet `[database]`).
Connecting to a database that does not exist is itself a connection failure,
so a Forgejo pod pointed at the not-yet-created `forgejo` database
crash-loops. Meanwhile ArgoCD applies sync-waves in ascending order and
waits for every resource in a wave to be **Healthy** before applying the
next; a crash-looping Deployment stays Progressing/Degraded, so the old wave
`5` — the `Database` CR that alone creates database `forgejo` — would never
have executed. The database was thus permanently gated behind the very
Deployment that requires it: a circular deadlock the sync could not have
converged out of (selfHeal re-attempts always restart at the lowest
incomplete wave, `0`, and stick again). CNPG does not auto-create the
database (its `managed.roles[]` append creates only the *role*; the
`Database` CR is the sole creator, exactly as Storage's `smoke` proved), so
there was no escape path within the original plan. This was not the
graceful-retry exemption the review question hypothesized: Forgejo's ~30s
retry window cannot bridge a database whose creation is strictly wave-gated
behind the pod's own health, and even an unbounded retry would not, because
the old wave `5` would never run. Storage's own `smoke` `Database` (also
wave `5`) is safe only because storage has **no consumer Deployment** that
connects to the smoke database before wave `5`; Forgejo is the first
platform feature with a wave-`0` consumer of its own database, so it was
the first to hit this. The design was *internally contradictory* on exactly
this point: its § Failure modes prescribed "the intra-`forgejo` sync-wave
ordering (secret **and DB** before the Deployment)" as the mitigation, which
its own original § Intra-`forgejo` sync-wave scheme (Database at wave `5`,
after the wave-`0` chart) violated; the plan had faithfully transcribed the
wave-scheme half.

Per the long-loop escalation rule, the reviewer correctly declined to decide
this unilaterally — fixing it meant moving the `forgejo` `Database` CR to a
wave *before* the chart, which re-assigns a wave the cleared `design.md` §
scheme fixed explicitly, outside a plan-gate reviewer's own
transcribe-faithfully remit — and escalated instead of deciding. **The
coordinator has since resolved it.** `design.md` § Intra-`forgejo` sync-wave
scheme is corrected (see its "Correction by the coordinator (2026-07-09)"
subsection) to place the `forgejo` `Database` CR at wave `-5`, alongside the
two sealed Secrets: its only real prerequisites — the CNPG operator and the
`forgejo` role — are both cross-Application in the already-live `storage`
layer, not in this Application's own later waves, so an earlier wave loses
nothing. This plan is updated to match: the `Database` CR's file, spec, and
wave annotation are folded into Step 2 (wave `-5`, alongside the sealed
credentials and the storage `managed.roles[]` append), the standalone step
that used to hold it is removed, and Step 3's own resources list and
build-verification edge case are updated to reflect that the database
already exists by the time the wave-`0` chart lands. With the database
created before the chart's wave-`0` Deployment ever starts, Forgejo's pod
connects to an already-existing database on first boot — no crash-loop, no
deadlock.

**Reviewer verification (2026-07-08).** Checked live, read-only, against the
committed tree and the `k3d-agrippa-dev` cluster context: `apps/platform.yaml`
(no seam), `platform/overlays/dev/kustomization.yaml` (`resources: [argocd.yaml]`),
`platform/overlays/dev/` and `secrets/dev/platform/` (no sibling landing yet),
`storage/overlays/dev/postgres-cluster.yaml` (`smoke` role only),
`core/overlays/dev/gateway-cert.yaml` (`argocd` SAN only),
`scripts/test-feature.sh` (`git-hosting.bats` excluded), and `.sops.yaml`
(recipient equals the committed storage ciphertext's `recipient:` — real key).
The wave-scoped `chart/` refinement was checked against
`storage/overlays/dev/valkey/kustomization.yaml` and `smoke-database.yaml`. The
item-4 deadlock was confirmed from Forgejo/Gitea's documented startup DB-blocking
behavior (go-gitea/gitea#27079; config cheat-sheet `DB_RETRIES=10`,
`DB_RETRY_BACKOFF=3s`) and ArgoCD's documented wave health-gating (Sync Phases and
Waves). No live cluster state was mutated.

**Gate status: CLEARED.** Items 1-3 decided to their conservative defaults;
item 4 — originally escalated as a build-breaking, prerequisite ordering
defect requiring a design revisit — is resolved: the coordinator corrected
`design.md`'s intra-`forgejo` sync-wave scheme (2026-07-09, moving the
`Database` CR from wave `5` to wave `-5`) and this plan was updated to match
(the `Database` CR folded into Step 2, the old standalone step removed, and
every downstream step renumbered). Marker updated to `*Reviewed 2026-07-09*`.
