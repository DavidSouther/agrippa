# Implementation Plan: Feature flags (Flagsmith)

*Draft 2026-07-08*

**Feature test:** `tests/feature-flags.bats`
**User story:** Given the bootstrapped `agrippa-dev` cluster (Features 1-6) with this Flagsmith content committed and reconciled by ArgoCD into the `platform` layer — the Flagsmith Helm release (`api` + `frontend`) in the `flagsmith` namespace, wired via `databaseExternal` to the shared CNPG `postgres` Cluster's own `flagsmith` database/role, its three KSOPS-sealed credentials, its `Database` CR, and its hand-authored `HTTPRoute` at `flagsmith.127.0.0.1.nip.io` — when an operator requests `https://flagsmith.127.0.0.1.nip.io/` and `.../health` through the k3d `:443` host port-map, then the admin UI is served through the shared Istio Gateway with a local-CA TLS cert, and the API `/health` endpoint returns 200, transitively proving the Django app is up and its connection to the shared Postgres database works.

**Steps:**
- [ ] Step 0: API surface area (file layout, `apps/platform.yaml` SSA seam)
- [ ] Step 1: Wave `-10` — the `flagsmith` namespace
- [ ] Step 2: Wave `-5` — the three sealed credentials and the `flagsmith` `Database` CR
- [ ] Step 3: Wave `0` — the Flagsmith Helm release
- [ ] Step 4: Wave `5` — the `HTTPRoute` and the Gateway certificate append
- [ ] Step 5: Full GREEN — the feature test and the regression sweep

**Libraries & Skills (carried forward from `design.md`/`research.md`; load before each build step):**

- `developer:initialize` — carried forward per convention, but (as `design.md`/`research.md` both record) this feature-step exercises no residual `mise` work: it adds **no** new mise-managed CLI. Flagsmith is an in-cluster Helm release ArgoCD reconciles, not a local tool; every CLI this plan's steps need (`sops`, `age`, `kustomize`, `helm`, `kubectl`, `k3d`, `yq`, `jq`, `bitwarden`, `openssl`) is already pinned in `mise.toml`, unchanged since `storage-postgres-valkey` landed. Nothing in `mise.toml` changes across any step below.
- `research:public` and `research:codebase` — for the per-tool detail each step below explicitly defers to build time: the exact pinned `flagsmith-charts` chart version (`0.82.0`/app `2.238.0` is the research-date reference — re-verify, pin explicitly, do not float), the API/frontend Service names and ports (expected `flagsmith-api`/`flagsmith-frontend`, ~8000/~8080), the exact health-endpoint path (`/health` vs `/health/readiness/`), the exact `databaseExternal`/`secretKeyFromExistingSecret`/`bootstrap`/allowed-hosts value-key spellings, and whether the chart's templates hardcode `{{ .Release.Namespace }}` (governs whether Step 3 needs `valkey/`'s `patches:` namespace workaround).
- No library-shipped agentic skill exists for Flagsmith, OpenFeature, or the official `flagsmith-charts` Helm chart (reconfirmed by both `research.md` and `design.md`). Build to `ARCHITECTURE.html` § S5 Platform, `DEVELOPMENT.md` § Secrets, and the two completed sibling designs/plans directly — `storage-postgres-valkey` (the CNPG `Database`/`managed.roles[]` pattern, the two-Secrets-from-one-password precedent, the `secrets/dev/<layer>/<component>/<slug>.enc.yaml` path convention, the `helmCharts:`-in-a-subdir + `patches:` namespace-workaround precedent) and `networking-istio` (the shared `agrippa-gateway` contract, the `HTTPRoute`-per-consumer + append-to-`dnsNames` contract, the explicit `matches:` authoring that avoids the Gateway-API-default `OutOfSync` symptom) — as the authoritative contracts this plan's steps build to.

**Patterns beat (`patterns:using-patterns` consulted):** Same conclusion as both completed siblings, re-verified for this feature-step's own pressures rather than assumed. This feature-step has no typed application code — only GitOps infrastructure config (Kustomize kustomizations, `helmCharts:` inflation, three authored CRs, three sops-encrypted manifests, one bats suite) — so `newtype`, `domain-objects`, `builder`, `visibility`, `parse-dont-validate`, `type-states`, `repository`, `aggregate`, `unit-of-work`, and `bootstrap-and-service` all require a typed domain model that does not exist here, and none is invoked. Two patterns shape *how* the surface and its tests are written, not the surface itself: **`arrange-act-assert`** for the one bats `@test` (the existing `run`/assert shape `tests/feature-flags.bats` already follows), and **`errors-typed-untyped`**, resolved to the untyped side — a `kubectl`/`curl`/`openssl` exit code and an ArgoCD `Application`'s `sync`/`health` status are the correct, sufficient failure signals here, consumed only by an operator's shell, `bats`, and ArgoCD's own reconcile loop; no in-process caller needs to match distinct typed failure modes. One pressure specific to this feature, carried forward from `design.md`'s own framing: the `Cluster.spec.managed.roles[]` append is the same structural append-only-list mechanic Networking's `dnsNames` and Storage's own `managed.roles[]` already established (not a catalog pattern — no code owns or validates the list beyond CNPG's controller and kustomize's own YAML merge), recorded here for continuity, not a new conclusion.

## Step 0: API surface area

Fix every file path, directory layout, and object name before any has real content, mirroring both completed siblings' Step 0 convention (fixed identifiers, honest inert stubs, no logic/spec). Two changes land here:

**1. The `apps/platform.yaml` server-side-apply seam** (must land before Step 1 syncs any content into the shared `platform` layer — the same "roll out before the next step's content" sequencing both siblings' Step 0 used):

```diff
# apps/platform.yaml
   metadata:
     name: platform
     namespace: argocd
     annotations:
       argocd.argoproj.io/sync-wave: "2"
+      argocd.argoproj.io/compare-options: ServerSideDiff=true
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

Additive only, mirroring `apps/storage.yaml`/`apps/core.yaml`'s identical seam verbatim (live-confirmed this session: `apps/platform.yaml` today carries neither `syncOptions` nor the `compare-options` annotation — a clean pre-image). This is the **shared seam all three concurrent platform siblings need** (Keycloak/Forgejo/Flagsmith); whichever lands first adds it, and it is idempotent for the other two (git will merge cleanly — the whole diff is additive to a currently-bare `syncPolicy`/`metadata.annotations`, not a rewrite). Re-check the file live immediately before committing this step in case a sibling has already landed it; if so, this step becomes a no-op confirmation, not a duplicate edit.

**2. The `platform/overlays/dev/flagsmith/` and `secrets/dev/platform/flagsmith/` directory layout**, fixing every file and object name the cleared `design.md` Specification (and its reviewer-resolved Open Artifact Decisions 1-2) already resolved. Each nested kustomization gets its sync-wave fixed now via `commonAnnotations`; each authored CR gets an apiVersion/kind/metadata-only stub (no `spec:`, mirroring both siblings' stub convention) — except `namespace.yaml`, whose entire content *is* `metadata.name`, so it is written in full now, exactly as `storage/overlays/dev/namespace.yaml` was. **The top-level `platform/overlays/dev/kustomization.yaml` stays the existing `resources: [argocd.yaml]`** — the new `flagsmith/` subdir is not referenced yet, so `platform` stays trivially Synced/Healthy exactly as today and nothing new is applied to the live cluster this step:

```text
platform/overlays/dev/flagsmith/
├── kustomization.yaml     # Step 0 skeleton; resources: [] (namespace.yaml/the
│                          #   secrets ref/helm//httproute.yaml/database.yaml
│                          #   land Steps 1-4)
├── namespace.yaml         # Namespace flagsmith (full content now; wave -10)
├── helm/
│   └── kustomization.yaml # wave 0; helmCharts: [] (the flagsmith chart lands Step 3)
├── httproute.yaml         # wave 5; HTTPRoute `flagsmith` name-only stub (Step 4)
└── database.yaml          # wave -5 (**not** the design's literal wave-5 grouping —
                            #   see Step 2's note); Database `flagsmith` name-only
                            #   stub, namespace `storage` (Step 2)

secrets/dev/platform/flagsmith/
└── kustomization.yaml     # wave -5; generators: [] (secret-generator.yaml + the
                            #   two encrypted files land Step 2)
```

Representative stubs (every other authored-CR file follows the same shape):

```yaml
# platform/overlays/dev/flagsmith/namespace.yaml -- full content now (a Namespace has no spec)
apiVersion: v1
kind: Namespace
metadata:
  name: flagsmith
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
```

```yaml
# platform/overlays/dev/flagsmith/kustomization.yaml -- Step 0 skeleton
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []   # namespace.yaml (Step 1), ../../../../secrets/dev/platform/flagsmith
                 # + database.yaml (Step 2), helm/ (Step 3), httproute.yaml (Step 4)
```

```yaml
# platform/overlays/dev/flagsmith/helm/kustomization.yaml -- Step 0 skeleton
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: "0"
helmCharts: []   # the flagsmith chart lands Step 3
```

```yaml
# platform/overlays/dev/flagsmith/database.yaml -- Step 0 skeleton (name-only stub, no spec)
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: flagsmith
  namespace: storage
  annotations:
    argocd.argoproj.io/sync-wave: "-5"
```

```yaml
# platform/overlays/dev/flagsmith/httproute.yaml -- Step 0 skeleton (name-only stub, no spec)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: flagsmith
  namespace: flagsmith
  annotations:
    argocd.argoproj.io/sync-wave: "5"
```

```yaml
# secrets/dev/platform/flagsmith/kustomization.yaml -- Step 0 skeleton
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: "-5"
generators: []   # secret-generator.yaml (kind: ksops) lands Step 2
```

This fixes: the `apps/platform.yaml` SSA seam, the directory layout, every shared-contract object name (`flagsmith` namespace/Secrets/Database/HTTPRoute), and the sync-wave scheme every remaining step reuses — with **one deliberate deviation from `design.md`'s literal wave-scheme text**, flagged inline above and explained in full in Step 2: `database.yaml` is stubbed at wave `-5`, not the design's stated wave `5`. `tests/feature-flags.bats` is a `design.md` artifact and already exists (RED baseline, THEN 1 aborting on a 404). Step 0 does not touch it and does not change that RED state: `platform/overlays/dev/kustomization.yaml`'s top-level `resources:` list is unchanged, so nothing new reaches the live cluster yet — but every name and file the remaining steps fill in now exists and is fixed.

**Tests**

```bash
test "the apps/platform.yaml seam is real and non-destructive; platform stays Synced/Healthy":
  run bash -c "yq '.spec.syncPolicy.syncOptions' apps/platform.yaml"
  assert output contains "ServerSideApply=true"
  assert output contains "SkipDryRunOnMissingResource=true"
  run bash -c "yq '.metadata.annotations.\"argocd.argoproj.io/compare-options\"' apps/platform.yaml"
  assert output == "ServerSideDiff=true"
  run kubectl --context k3d-agrippa-dev -n argocd get application platform \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"               # unchanged -- still argocd.yaml only
```

- Edge case: re-check `apps/platform.yaml` and `platform/overlays/dev/kustomization.yaml` live (not just this plan's recorded pre-image) immediately before committing — a concurrently-landing Keycloak or Forgejo commit may have already added the seam or its own subdir entry; merge/rebase rather than overwrite.
- Edge case: the new `flagsmith/` subdir must not collide with a `keycloak/`/`forgejo/` subdir name a sibling adds independently — confirmed no collision risk (distinct directory names), but worth a `git status`/`ls platform/overlays/dev/` check before committing.
- Edge case: re-running `mise run test:push`/`test:static` after this step must still pass — nothing new is fed to kubeconform/conftest (`test:static` does not walk `platform/`; `secrets/dev/platform/flagsmith/kustomization.yaml`'s `generators: []` has no `kind` conftest would inspect, matching the existing `kustomization.yaml`-exclusion convention).

**Implementation Outline**

```text
apps/platform.yaml:
  metadata.annotations."argocd.argoproj.io/compare-options" <- "ServerSideDiff=true"
  spec.syncPolicy.syncOptions <- [ServerSideApply=true, SkipDryRunOnMissingResource=true]

platform/overlays/dev/kustomization.yaml:
  resources: [argocd.yaml]   # unchanged

platform/overlays/dev/flagsmith/{kustomization.yaml, namespace.yaml, helm/kustomization.yaml,
  httproute.yaml, database.yaml}: name-only stubs, as above

secrets/dev/platform/flagsmith/kustomization.yaml: generators: [] stub
```

## Step 1: Wave `-10` — the `flagsmith` namespace

**Enables:** no feature-test assertion flips yet (`platform` was already trivially Synced/Healthy on `resources: [argocd.yaml]`, and stays Synced/Healthy once a bare Namespace lands — THEN 1 onward still fails, no `HTTPRoute` exists). Substrate-only: this is the first real content this feature-step applies to the live cluster, and the first live edit to the `platform/overlays/dev/kustomization.yaml` file the three concurrent platform siblings all append to.

Wire `platform/overlays/dev/flagsmith/kustomization.yaml`'s `resources:` to `[namespace.yaml]`, and append `- flagsmith/` to the top-level `platform/overlays/dev/kustomization.yaml`'s `resources:` list — re-verified live first per Step 0's edge case, since Keycloak/Forgejo may already have appended their own entries.

**Tests**

```bash
test "the flagsmith namespace lands, platform stays Synced/Healthy":
  run kubectl --context k3d-agrippa-dev -n argocd get application platform \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"
  run kubectl --context k3d-agrippa-dev get namespace flagsmith
  assert status == 0
```

- Edge case: `platform/overlays/dev/kustomization.yaml`'s `resources:` list is a genuinely shared, concurrently-edited file — append (`- flagsmith/`), never replace the list; if the live file already differs from this plan's Step 0 pre-image (`[argocd.yaml]`), merge onto whatever is there.
- Edge case: `flagsmith`'s Namespace must not collide with any namespace already created by `core`/`storage` (`istio-system`, `istio-ingress`, `cert-manager`, `metallb-system`, `cnpg-system`, `storage`) or a sibling's own namespace (`keycloak`, `forgejo`, if already landed) — confirm no name clash.

**Implementation Outline**

```text
platform/overlays/dev/kustomization.yaml:
  resources:
    - argocd.yaml
    - flagsmith/

platform/overlays/dev/flagsmith/kustomization.yaml:
  resources:
    - namespace.yaml
```

## Step 2: Wave `-5` — the three sealed credentials and the `flagsmith` `Database` CR

**Enables:** no feature-test assertion flips yet directly (nothing consumes these Secrets/this Database until Step 3's Helm release references them), but this is the load-bearing prerequisite for THEN 3 (the API `/health` 200) — the credential path and the database the API pod's Postgres connection needs to exist before the release ever starts.

**A note on the `database.yaml` wave placement (a plan-level sequencing correction, not a design change).** `design.md`'s Specification groups the `flagsmith` `Database` CR at wave `5`, alongside the `HTTPRoute`, reasoning that it "needs the operator + Cluster + owner role, all live from the storage layer." That's true, but incomplete: unlike the `HTTPRoute` (which genuinely needs the Helm release's Services, wave `0`, to exist first), the `Database` CR has **no** dependency on anything inside this component's own wave `-10`/`-5`/`0` — it lives in the `storage` namespace and only needs the CNPG operator, the shared `Cluster`, and the `flagsmith` role, all already live from the `storage` layer's own Application (sync-wave 1) before `platform` (sync-wave 2) starts at all. Sequencing it at wave `5` — *after* the wave-`0` Helm release — creates a real risk: if the Flagsmith API Deployment's own Kubernetes readiness probe queries the same DB-backed `/health` endpoint the feature test asserts on (plausible, and the conservative assumption — Django apps commonly gate readiness on DB connectivity precisely so broken pods don't receive traffic), the Deployment would never report Healthy, and ArgoCD's sync-wave gate would then never let the wave-`5` `Database` CR that *creates* the database it's waiting on actually apply — a genuine deadlock, not a transient retry, since no later git commit can break the cycle (ArgoCD will not advance past an unhealthy wave `0` regardless of what wave `5` already contains). Working backward from the passing test (the DB must exist before the API pod can become Ready) and forward from what's already live (the `Database` CR needs nothing this component hasn't already built by wave `-5`), the two connect cleanly by moving `database.yaml` to wave `-5`, alongside the two Secrets — before the Helm release ever starts, regardless of whether the chart's readiness probe turns out to be DB-gated. This is flagged here explicitly for the dispatched reviewer: it is a sequencing (not artifact-shape) deviation from the design's literal text, reversible with a one-line annotation edit, and does not change any object's name, namespace, or spec the design fixed.

Seal the three credentials using the discipline `design.md` § Specification and `storage-postgres-valkey`'s own precedent fix exactly (reused, not reinvented): the single-value case for both the CNPG basic-auth Secret and the composed-DSN Secret (password/DSN piped via `--from-file=.../dev/stdin`, never argv), and a second single-value case for the Django key. Two of the three are sealed from the **same** in-memory-generated password (the two-Secrets-from-one-password precedent `smoke-db`/`smoke-valkey` established):

1. `flagsmith-db` — `kubernetes.io/basic-auth`, `storage` namespace, sealed at `secrets/dev/storage/postgres/flagsmith.enc.yaml`, appended to `secrets/dev/storage/secret-generator.yaml`'s `files:`.
2. `flagsmith-database-url` — Opaque, key `DATABASE_URL`, `flagsmith` namespace, sealed at `secrets/dev/platform/flagsmith/database-url.enc.yaml` (same password as #1).
3. `flagsmith-secret-key` — Opaque, key `SECRET_KEY`, `flagsmith` namespace, sealed at `secrets/dev/platform/flagsmith/secret-key.enc.yaml` (a separate `openssl rand` value).

Append one `managed.roles[]` entry to `storage/overlays/dev/postgres-cluster.yaml` (`{name: flagsmith, login: true, passwordSecret: {name: flagsmith-db}}`) — the storage layer's own Application (sync-wave 1) reconciles this independently of `platform`, so the role exists well before `platform` (sync-wave 2) starts. Fill `secrets/dev/platform/flagsmith/secret-generator.yaml` (`kind: ksops`, `files: [database-url.enc.yaml, secret-key.enc.yaml]`) and wire its `kustomization.yaml`'s `generators:` to reference it. Wire `platform/overlays/dev/flagsmith/kustomization.yaml`'s `resources:` to add `../../../../secrets/dev/platform/flagsmith` and `database.yaml` (now filled with a real spec, wave `-5`).

**Tests**

```bash
test "the three credentials round-trip through KSOPS, the flagsmith role/database exist":
  run kubectl --context k3d-agrippa-dev -n storage get secret flagsmith-db \
    -o jsonpath='{.type} {.data.username} {.data.password}'
  assert status == 0
  assert output contains "kubernetes.io/basic-auth"
  run kubectl --context k3d-agrippa-dev -n flagsmith get secret flagsmith-database-url \
    -o jsonpath='{.data.DATABASE_URL}'
  assert status == 0                              # non-empty
  run kubectl --context k3d-agrippa-dev -n flagsmith get secret flagsmith-secret-key \
    -o jsonpath='{.data.SECRET_KEY}'
  assert status == 0                              # non-empty
  run kubectl --context k3d-agrippa-dev -n storage get cluster.postgresql.cnpg.io postgres \
    -o jsonpath='{.spec.managed.roles[?(@.name=="flagsmith")].name}'
  assert output == "flagsmith"
  run kubectl --context k3d-agrippa-dev -n storage get database.postgresql.cnpg.io flagsmith \
    -o jsonpath='{.status.applied}'
  assert output == "true"
  run mise run test:static
  assert status == 0                               # conftest sees secrets/, still passes (ciphertext + sops: block)
```

- Edge case: the Postgres and Django-key pipes must use `--filename-override secrets/dev/....enc.yaml` so `sops` applies the `^secrets/dev/.*$` creation rule to stdin input, matching `storage`'s own established discipline.
- Edge case: the composed `DATABASE_URL` value embeds the same generated password as `flagsmith-db` — compose it in memory (`printf 'postgres://flagsmith:%s@postgres-rw.storage.svc:5432/flagsmith' "$pw"`) and pipe it to `--from-file=DATABASE_URL=/dev/stdin`, never through `--from-literal` on a `kubectl` command line, so the composed DSN never appears in `ps`/shell history either.
- Edge case: the `Database` CR's `spec` needs **`spec.name: flagsmith`** in addition to `spec.owner`/`spec.cluster.name` — `storage-postgres-valkey`'s own Step 4 build-time finding (the live CNPG CRD requires the actual PostgreSQL database name explicitly; `owner` alone is not enough), carried forward here rather than re-discovered.
- Edge case: `spec.owner: flagsmith` must resolve to a role that already exists — the `managed.roles[]` append above, reconciled by `storage`'s own Application before `platform` starts; verify live (`kubectl -n storage get cluster postgres -o jsonpath='{.spec.managed.roles}'`) rather than trust the commit alone.
- Edge case: verify the three Secrets actually decrypt using the **live cluster's** `sops-age` trust root (real base64 `data`, not a KSOPS error at `kustomize build` time), proving the existing `.sops.yaml` recipient (already fixed by `storage-postgres-valkey`'s Step 0 — no further `.sops.yaml` change needed here) still matches the in-cluster private key.
- Edge case: `secrets/dev/platform/flagsmith/` must be a genuinely self-contained kustomization — verify `kustomize build platform/overlays/dev/flagsmith` does not trip the default `LoadRestrictionsRootOnly` restrictor.

**Implementation Outline**

```bash
# postgres/flagsmith.enc.yaml -- single-value case, storage namespace
FLAGSMITH_PW="$(openssl rand -base64 24 | tr -d '\n')"
printf '%s' "$FLAGSMITH_PW" \
  | kubectl create secret generic flagsmith-db -n storage \
      --type kubernetes.io/basic-auth \
      --from-literal=username=flagsmith \
      --from-file=password=/dev/stdin \
      --dry-run=client -o yaml \
  | sops --encrypt --filename-override secrets/dev/storage/postgres/flagsmith.enc.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > secrets/dev/storage/postgres/flagsmith.enc.yaml

# secrets/dev/platform/flagsmith/database-url.enc.yaml -- same $FLAGSMITH_PW, composed DSN
printf 'postgres://flagsmith:%s@postgres-rw.storage.svc:5432/flagsmith' "$FLAGSMITH_PW" \
  | kubectl create secret generic flagsmith-database-url -n flagsmith \
      --from-file=DATABASE_URL=/dev/stdin \
      --dry-run=client -o yaml \
  | sops --encrypt --filename-override secrets/dev/platform/flagsmith/database-url.enc.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > secrets/dev/platform/flagsmith/database-url.enc.yaml

# secrets/dev/platform/flagsmith/secret-key.enc.yaml -- separate value
openssl rand -base64 48 | tr -d '\n' \
  | kubectl create secret generic flagsmith-secret-key -n flagsmith \
      --from-file=SECRET_KEY=/dev/stdin \
      --dry-run=client -o yaml \
  | sops --encrypt --filename-override secrets/dev/platform/flagsmith/secret-key.enc.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > secrets/dev/platform/flagsmith/secret-key.enc.yaml
```

```yaml
# secrets/dev/platform/flagsmith/secret-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: flagsmith-secret-generator
files:
  - database-url.enc.yaml
  - secret-key.enc.yaml
```

```text
secrets/dev/storage/secret-generator.yaml:
  files:
    - postgres/smoke.enc.yaml
    - postgres/flagsmith.enc.yaml   # appended
    - valkey/smoke.enc.yaml

secrets/dev/platform/flagsmith/kustomization.yaml:
  generators: [secret-generator.yaml]

storage/overlays/dev/postgres-cluster.yaml:
  spec.managed.roles:
    - name: smoke
      login: true
      passwordSecret: {name: smoke-db}
    - name: flagsmith        # appended
      login: true
      passwordSecret: {name: flagsmith-db}

platform/overlays/dev/flagsmith/database.yaml (filled):
  apiVersion: postgresql.cnpg.io/v1
  kind: Database
  metadata: {name: flagsmith, namespace: storage, annotations: {argocd.argoproj.io/sync-wave: "-5"}}
  spec: {name: flagsmith, owner: flagsmith, cluster: {name: postgres}}

platform/overlays/dev/flagsmith/kustomization.yaml:
  resources:
    - namespace.yaml
    - ../../../../secrets/dev/platform/flagsmith
    - database.yaml
```

## Step 3: Wave `0` — the Flagsmith Helm release

**Enables:** no feature-test assertion flips yet (no `HTTPRoute` exists until Step 4, so `curl` to the flagsmith host still 404s), but this is the step where the `api`/`frontend` Deployments actually come up and the API pod's readiness probe passes against a real, already-existing shared-Postgres `flagsmith` database (Step 2 landed the `Database` CR and both DB-facing Secrets ahead of this release specifically to avoid the wave-ordering deadlock Step 2's note above explains).

Fill `platform/overlays/dev/flagsmith/helm/kustomization.yaml`'s `helmCharts:` with the official chart (`repo: https://flagsmith.github.io/flagsmith-charts/`, `name: flagsmith`, pinned `version:` — `research:public` at build time, `0.82.0`/app `2.238.0` is the research-date reference), `releaseName: flagsmith`, target namespace `flagsmith`, and the `valuesInline` block `design.md` § Specification fixes verbatim: `postgresql.enabled: false`; `databaseExternal.enabled: true` + `urlFromExistingSecret: {enabled: true, name: flagsmith-database-url, key: DATABASE_URL}`; `api.secretKeyFromExistingSecret: {enabled: true, name: flagsmith-secret-key, key: SECRET_KEY}`; `api.bootstrap: {enabled: true, adminEmail: admin@agrippa.local, organisationName: agrippa, projectName: agrippa}`; `frontend.enabled: true`; `sse.enabled: false`; the chart's own `gateway.*` block left at its disabled default (Step 4 hand-authors the route). Wire `platform/overlays/dev/flagsmith/kustomization.yaml`'s `resources:` to add `helm/`.

**Tests**

```bash
test "the Flagsmith api/frontend Deployments come up and reach Ready against the shared Postgres":
  run kubectl --context k3d-agrippa-dev -n argocd get application platform \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"
  run kubectl --context k3d-agrippa-dev -n flagsmith get deployments -o name
  assert output contains "api"
  assert output contains "frontend"
  run kubectl --context k3d-agrippa-dev -n flagsmith get pods -l app.kubernetes.io/component=api \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}'
  assert output == "true"
```

- Edge case (design's flagged near-certain-relevant risk): if the chart's templates don't hardcode `{{ .Release.Namespace }}`, the kustomize 5.8.0+ `helmCharts:` inflation regression (`kubernetes-sigs/kustomize#6058`) drops `metadata.namespace`, and objects land in `platform`'s fallback namespace (`argocd`) instead of `flagsmith` — apply `storage/overlays/dev/valkey/kustomization.yaml`'s exact `patches:` `op: add /metadata/namespace` workaround, scoped to this `helm/` sub-kustomization alone, if live-confirmed.
- Edge case: `helm template` semantics (no hooks, no cluster `lookup`) — confirm at build that the chart's bootstrap/migration runs as a normal Deployment/init flow the templated path keeps, not a Helm hook ArgoCD would mishandle; `skipTests: true` if the chart ships a `helm.sh/hook: test` Pod (as the Valkey chart did).
- Edge case (design's flagged failure mode): Django `ALLOWED_HOSTS` rejecting the `flagsmith.127.0.0.1.nip.io` host — if `/health` or the UI returns a 400 through the Gateway once Step 4 lands, set the chart's allowed-hosts value to include the host (or `*` for dev); build-verify against the pinned chart's default before assuming this is needed.
- Edge case: if, despite Step 2's resequencing, the API Deployment's readiness still never reaches `Ready` (e.g., a startup migration race, or a value spelling this step got wrong), diagnose with `kubectl -n flagsmith logs deploy/api` before assuming the wave-ordering fix was insufficient — the `Database`/Secrets are confirmed live from Step 2, so a stuck readiness here points at a value/spelling bug, not the ordering risk Step 2 already resolved.
- Edge case: confirm no bundled `influxdb`/analytics subchart is enabled by the chart's own defaults (design's own flagged watch-item); disable explicitly if it is.

**Implementation Outline**

```yaml
# platform/overlays/dev/flagsmith/helm/kustomization.yaml (filled)
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: "0"
helmCharts:
  - name: flagsmith
    repo: https://flagsmith.github.io/flagsmith-charts/
    version: <pinned; research:public at build, 0.82.0 research-date reference>
    releaseName: flagsmith
    namespace: flagsmith
    valuesInline:
      postgresql:
        enabled: false
      databaseExternal:
        enabled: true
        urlFromExistingSecret:
          enabled: true
          name: flagsmith-database-url
          key: DATABASE_URL
      api:
        secretKeyFromExistingSecret:
          enabled: true
          name: flagsmith-secret-key
          key: SECRET_KEY
        bootstrap:
          enabled: true
          adminEmail: admin@agrippa.local
          organisationName: agrippa
          projectName: agrippa
      frontend:
        enabled: true
      sse:
        enabled: false
```

```text
platform/overlays/dev/flagsmith/kustomization.yaml:
  resources:
    - namespace.yaml
    - ../../../../secrets/dev/platform/flagsmith
    - database.yaml
    - helm/
```

## Step 4: Wave `5` — the `HTTPRoute` and the Gateway certificate append

**Enables:** THEN 1 (`curl -k https://flagsmith.127.0.0.1.nip.io/` returns `2xx`/`3xx`, not the RED-baseline `404`), THEN 2 (the served cert is issued by the local CA — already true of the shared Gateway cert once its SAN covers this host), and THEN 3 (`.../health` returns `200`, transitively proving the Django app plus its already-live Postgres connection) — the three assertions that actually exercise the request path end-to-end.

Fill `platform/overlays/dev/flagsmith/httproute.yaml` with the hand-authored `HTTPRoute` **`flagsmith`** in the `flagsmith` namespace: `parentRefs: [{name: agrippa-gateway, namespace: istio-ingress, sectionName: https}]`, `hostnames: [flagsmith.127.0.0.1.nip.io]`, and two rules with `matches` authored explicitly (mirroring `core/overlays/dev/argocd-httproute.yaml`'s own explicit-`matches` fix for the Gateway-API-schema-default `OutOfSync` symptom) — `/health` (`PathPrefix`) routed first to the Flagsmith **API** Service, then `/` (`PathPrefix`) to the **frontend** Service. Append `flagsmith.127.0.0.1.nip.io` to `core/overlays/dev/gateway-cert.yaml`'s `dnsNames` (the one shared-list edit the Networking contract's consumption mechanic is — the `Gateway` object itself is never touched). Wire `platform/overlays/dev/flagsmith/kustomization.yaml`'s `resources:` to add `httproute.yaml`.

**Tests**

```bash
test "the flagsmith HTTPRoute is Accepted and the Gateway cert covers the host":
  run kubectl --context k3d-agrippa-dev -n flagsmith get httproute flagsmith \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
  assert output == "True"
  run kubectl --context k3d-agrippa-dev -n istio-ingress get certificate agrippa-gateway-tls \
    -o jsonpath='{.spec.dnsNames}'
  assert output contains "flagsmith.127.0.0.1.nip.io"
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 15 https://flagsmith.127.0.0.1.nip.io/
  assert status == 0
  assert output matches ^(2[0-9][0-9]|3[0-9][0-9])$
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 15 https://flagsmith.127.0.0.1.nip.io/health
  assert output == "200"
```

- Edge case: the exact API/frontend Service **names and ports** are build-verified against the pinned chart (expected `flagsmith-api`/`flagsmith-frontend`, ~8000/~8080) — confirm with `kubectl -n flagsmith get svc` before authoring `backendRefs`, and correct this file (not the test) if the spelling differs.
- Edge case: the exact **health path** is build-verified (`/health` vs `/health/readiness/`, whichever the chart's own readiness probe uses) — if it differs from `/health`, correct both `httproute.yaml`'s first rule and `tests/feature-flags.bats`' `HEALTH_PATH` default together (the test already supports an override via `FLAGSMITH_HEALTH_PATH`, so this is a test-definition correction inherited from build-time re-verification, not new test authorship, mirroring `networking.bats`'s own Q6 correction).
- Edge case: Gateway API's longest-prefix-wins precedence routes `/health` ahead of `/` regardless of list order, but author `/health` first anyway for readability; verify live that a request to `/health` actually reaches the API backend, not the frontend's own internal `/api` proxy.
- Edge case: `agrippa-gateway-tls`'s `dnsNames` append must not disturb the existing `argocd.127.0.0.1.nip.io` entry (append-only, mirroring the `managed.roles[]` precedent) — verify the `Certificate` reissues (its own controller re-signs on a `dnsNames` change) and reaches `Ready` again before the TLS assertion is expected to pass.
- Edge case: re-derive live whether a sibling (Keycloac/Forgejo) has already appended its own host to `gateway-cert.yaml`'s `dnsNames` — append onto whatever is there, never replace the list.
- Edge case: if THEN 1 passes but THEN 3 doesn't (a 404/5xx on `/health` specifically), suspect the Service-name/health-path build-time spellings above before suspecting the DB/credential path — Step 2/3 already live-verified the database and the Deployment's own readiness independently of the Gateway.

**Implementation Outline**

```yaml
# platform/overlays/dev/flagsmith/httproute.yaml (filled)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: flagsmith
  namespace: flagsmith
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  parentRefs:
    - name: agrippa-gateway
      namespace: istio-ingress
      sectionName: https
  hostnames:
    - flagsmith.127.0.0.1.nip.io
  rules:
    - matches:
        - path: {type: PathPrefix, value: /health}
      backendRefs:
        - name: <flagsmith-api Service; build-verified>
          port: <API port; build-verified>
    - matches:
        - path: {type: PathPrefix, value: /}
      backendRefs:
        - name: <flagsmith-frontend Service; build-verified>
          port: <frontend port; build-verified>
```

```diff
# core/overlays/dev/gateway-cert.yaml
   spec:
     secretName: agrippa-gateway-tls
     dnsNames:
       - argocd.127.0.0.1.nip.io
+      - flagsmith.127.0.0.1.nip.io
```

```text
platform/overlays/dev/flagsmith/kustomization.yaml:
  resources:
    - namespace.yaml
    - ../../../../secrets/dev/platform/flagsmith
    - database.yaml
    - helm/
    - httproute.yaml
```

## Step 5: Full GREEN — the feature test and the regression sweep

**Enables:** no new substrate — the request path already works after Step 4 — but this step closes the two remaining items `design.md`'s Metrics section names as measures of done: the feature test passing end-to-end, and no regression to earlier harness.

Run `bats tests/feature-flags.bats` against the fully reconciled `platform` layer. If build-time verification (Steps 3-4's own recorded edge cases) found any Service name, port, or health-path spelling diverging from the test's `FLAGSMITH_HOST`/`HEALTH_PATH` defaults, correct the test's environment-variable defaults here — a test-definition correction inherited from build-time re-verification, not new test authorship (mirroring both siblings' final-step corrections). Then re-run the full harness `design.md`'s Metrics section names as no-regression evidence.

**Tests**

```bash
test "tests/feature-flags.bats passes end-to-end":
  run bats tests/feature-flags.bats
  assert status == 0

test "no regression to earlier harness":
  run mise run test:push
  assert status == 0
  run mise run test:feature
  assert status == 0
  run bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats tests/storage.bats tests/rotate-keys.bats
  assert status == 0
```

- Edge case: `scripts/test-feature.sh` already excludes `feature-flags.bats` from its throwaway-cluster auto-discovery (live-confirmed this session, landed with the feature test at design time) — this step only needs to confirm that exclusion still holds, not add it.
- Edge case: re-running `bats tests/feature-flags.bats` a second time back-to-back must not error or disrupt the long-lived `platform` layer — `platform`'s own `syncPolicy.automated.selfHeal` should leave an already-Synced/Healthy state alone, mirroring both siblings' own idempotency edge case.
- Edge case: `mise run test:static`'s kubeconform/conftest pass does not walk `platform/` (only `apps/`, `charts/*/rendered/`, and `secrets/`) — do not assume `test:push` exercises any of Steps 1-4's new YAML; ArgoCD's own live reconcile and this bats suite are the only validators of that content, exactly as both siblings' final steps recorded for their own layers.
- Edge case: `tests/rotate-keys.bats` has a pre-existing, unrelated failure recorded in `storage-postgres-valkey/plan.md`'s own Step 5 results (a `sops updatekeys` behavior-drift issue, confirmed unrelated to any feature-step's own content) — if it still fails here, treat that as the known pre-existing condition, not a regression this feature-step introduced, unless a fresh reproduction against a clean baseline says otherwise.

**Implementation Outline**

```text
# no new manifests; this step is verification-only plus any build-time-discovered
# corrections to tests/feature-flags.bats' FLAGSMITH_HOST/HEALTH_PATH defaults,
# surfaced by actually running the suite against the live reconciled cluster
run bats tests/feature-flags.bats
run mise run test:push && mise run test:feature
run bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats tests/storage.bats tests/rotate-keys.bats
```
