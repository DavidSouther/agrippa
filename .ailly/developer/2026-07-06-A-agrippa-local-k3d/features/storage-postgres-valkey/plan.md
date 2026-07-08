# Implementation Plan: Storage (Postgres via CloudNativePG + Valkey)

*Reviewed 2026-07-08*

> A separately dispatched long-loop reviewer cleared this feature plan's draft
> gate on 2026-07-08. This plan is a paper plan against the already-cleared
> feature `design.md` (and its `Resolved by the long-loop reviewer` block); it
> has not been built. Per the three completed siblings' precedent
> (`cluster-core-k3d/plan.md`, `gitops-argocd/plan.md`, `networking-istio/plan.md`)
> the review's job was three-fold: verify the plan's step decomposition faithfully
> transcribes the cleared `design.md` (no re-litigating design decisions), verify
> the plan's claims about current repo state against the actually-committed files,
> and live-verify the load-bearing Step 0 `.sops.yaml` mechanism every later step
> depends on. Unlike the Networking plan, this plan surfaced **no** net-new
> mechanism decision of its own to decide — the cleared `design.md` had already
> resolved all five of its Open Artifact Decisions, which this plan transcribes.
> The load-bearing finding: Step 0's `.sops.yaml` fix was verified end-to-end
> against the live vault and cluster (vault unlocked via the `.env` `BW_SESSION`;
> `bw get notes agrippa-age-dev` yields the expected `# public key: age1…` shape;
> the plan's `grep`/`sed`/`yq` mechanism derives and writes the recipient exactly;
> and that recipient matches the in-cluster `sops-age` trust root's own public
> half, so the `sops -e` → commit → KSOPS-decrypt round-trip Steps 2-3 depend on
> will work). No escalation trigger (irreversible, out of recorded scope,
> underdetermined) fired; the gate is cleared. The live cluster was **read only**
> and left exactly as found — `storage` remains Synced/Healthy on its empty
> `resources: []` placeholder, and `.sops.yaml` on disk still carries the
> placeholder recipient (the fix is Build-phase work, not done here). Full detail
> in the *Resolved by the long-loop reviewer* block at the end.

**Feature test:** `tests/storage.bats`
**User story:** Given the bootstrapped `agrippa-dev` cluster with this Storage content committed and reconciled by ArgoCD into the `storage` layer — the CNPG operator, the shared Postgres `Cluster` `postgres` on `local-path`, the shared standalone Valkey instance, and the permanent `smoke` fixture — when an operator connects to database `smoke` as role `smoke` using the sops-encrypted, KSOPS-decrypted credential and authenticates to Valkey as ACL user `smoke`, then the shared Postgres instance is Healthy on a `local-path` PVC, the `smoke` database is owned by role `smoke` with the committed credential working, and the Valkey `smoke` user can write within `~smoke:*` but is denied outside it — proving the storage-class + per-app DB/role naming shared contract Features 5-8 each bind to.

**Steps:**
- [ ] Step 0: API surface area (file layout, `.sops.yaml` fix, `apps/storage.yaml` SSA seam)
- [ ] Step 1: Wave `-10` — namespaces + the CNPG operator
- [ ] Step 2: Wave `-5` — sealing and wiring the `smoke` KSOPS credentials
- [ ] Step 3: Wave `0` — the shared `postgres` Cluster and the Valkey instance
- [ ] Step 4: Wave `5` — the `smoke` `Database` CR
- [ ] Step 5: Full GREEN — the credential + ACL proof, and the regression sweep

**Libraries & Skills (carried forward from `design.md`/`research.md`; load before each build step):**

- `developer:initialize` — carried forward per convention, but (as `design.md`/`research.md` both record) this feature-step exercises no residual `mise` work: it adds **no** new mise-managed CLI. The CNPG operator and the Valkey chart are both in-cluster resources ArgoCD reconciles via Helm, not local tools; every CLI this plan's steps need (`sops`, `age`, `kustomize`, `helm`, `kubectl`, `k3d`, `yq`, `jq`, `bitwarden`) is already pinned in `mise.toml`. An optional `kubectl cnpg` plugin may aid operator debugging at build time — stays unpinned, exactly as `istioctl` stayed optional/unpinned for Networking. Nothing in `mise.toml` changes across any step below.
- `research:public` and `research:codebase` — for the per-tool detail each step below explicitly defers to build time: the CNPG operator chart version, the CNPG operand PostgreSQL major/image (≥17.6 if on the 17 line), the Valkey chart version (`0.9.0`/appVersion `9.0.1` as the research-date reference), and the exact CNPG `Cluster`/`Database` CRD field spellings and Valkey chart value keys (`auth.aclUsers`, `auth.usersExistingSecret`, `dataStorage.*`) against the pinned versions.
- No library-shipped agentic skill exists for CloudNativePG, the official Valkey chart, sops, age, or KSOPS (reconfirmed by both `research.md` and `design.md`). Build to `ARCHITECTURE.html` (§ S4 Storage, § S5 Platform), `DEVELOPMENT.md` (§ Testing, § Secrets), and the two completed sibling designs/plans directly — `gitops-argocd` (the KSOPS/`sops-age` convention, the `secrets/dev/<component>.enc.yaml` path) and `networking-istio` (the shared append-only-list precedent, and the `helmCharts:`-inflation-plus-authored-CRs composition under one layer Application, realized one-for-one in the committed `core/overlays/dev/` tree this plan mirrors file-for-file).

**Patterns beat (`patterns:using-patterns` consulted):** Same conclusion as both completed siblings, re-verified for this feature-step's own pressures (the DB/role naming contract, the credential-sealing discipline) rather than assumed. This feature-step has no typed application code — only GitOps infrastructure config (Kustomize kustomizations, `helmCharts:` inflation, authored CNPG/Valkey CRs, sops-encrypted manifests, one bats suite) — so `newtype`, `domain-objects`, `builder`, `visibility`, `parse-dont-validate`, `type-states`, `repository`, `aggregate`, and `unit-of-work` all require a typed domain model that does not exist here and none is invoked. The database=role=slug naming contract is a **naming convention expressed in YAML string fields**, not a wrapped primitive or an object carrying behavior, so it does not route to `newtype`/`domain-objects` either — there is no code constructing or comparing these values, only kustomize/Helm rendering and CNPG's own controller reconcile loop. Two patterns shape *how* the surface and its tests are written: **`arrange-act-assert`** for the one bats `@test` (the existing `run`/assert shape `tests/storage.bats` already follows), and **`errors-typed-untyped`**, resolved to the untyped side — a `kubectl`/`psql`/`valkey-cli` exit code, an ArgoCD `Application`'s `sync`/`health` status, and a `sops`/KSOPS decrypt success-or-failure are the correct, sufficient failure signals here, consumed only by an operator's shell, `bats`, and ArgoCD's own reconcile loop; no in-process caller needs to match distinct typed failure modes. One pressure specific to this feature, carried forward from `design.md`'s own framing rather than newly found: the `Cluster.spec.managed.roles[]` append is a **structural** echo of Networking's shared, mutable, append-only `dnsNames` list (not a catalog pattern — no code owns or validates the list beyond CNPG's controller and kustomize's own YAML merge), so it is recorded here for continuity but does not change the "no domain-object pattern" conclusion.

## Step 0: API surface area

Fix every file path, directory layout, and object name before any has real content, mirroring both siblings' Step 0 convention (fixed identifiers, honest inert stubs, no logic/spec). Three changes land here, in order:

**1. The `.sops.yaml` placeholder fix — non-destructive, and explicitly NOT `rotate-keys`.** `.sops.yaml`'s `secrets/dev/.*` rule still carries the literal placeholder `AGE-PLACEHOLDER-REPLACE-WITH-REAL-agrippa-age-dev-PUBLIC-KEY` (live-verified this session). Nothing in Step 2 onward that seals a credential under `secrets/dev/storage/` can run until this is fixed, so it lands first, before any other content:

```bash
recipient="$(bw get notes agrippa-age-dev | grep '^# public key: ' | sed -E 's/^# public key: //')"
SOPS_NEW_AGE="$recipient" \
  yq -i '(.creation_rules[] | select(.path_regex == "^secrets/dev/.*$") | .age) = strenv(SOPS_NEW_AGE)' .sops.yaml
```

> **Do NOT run `mise run rotate-keys` / `scripts/rotate-keys.sh` for this.** `agrippa-age-dev` already exists in Bitwarden, so `rotate-keys.sh`'s item-existence check fires: it prompts for a typed `rotate` confirmation and, if confirmed, **rotates** — archives the working key and mints a new one — desynchronising `.sops.yaml` from the `sops-age` trust root `bootstrap.sh` already seeded into the live cluster, which would then fail to decrypt until `bootstrap` is re-run. `rotate-keys` is the tool for *rotating an existing key*, not for *populating a placeholder*; re-derive the recipient live via the command above (do not hardcode the `age1e8w...` value this session's research recorded — Bitwarden is the source of truth, not this document).

**2. The `apps/storage.yaml` server-side-apply seam** (must land before Step 1 syncs any CNPG CRD content — the same "roll out before the next step's content" sequencing Networking's Step 0 used for its repo-server flag):

```diff
# apps/storage.yaml
   syncPolicy:
     automated:
       prune: true
       selfHeal: true
+    syncOptions:
+      - ServerSideApply=true
+      - SkipDryRunOnMissingResource=true
```

Additive only, mirroring `apps/core.yaml`'s identical seam: CNPG's `Cluster` CRD is large enough to overflow client-side apply's last-applied-configuration annotation, and `SkipDryRunOnMissingResource` lets the wave-0 `Cluster`/wave-5 `Database` CRs sync before their own CRDs are dry-run-validatable on the very first apply.

**3. The `storage/overlays/dev/` and `secrets/dev/storage/` directory layout**, fixing every file and object name the cleared `design.md` Specification already resolved (including its reviewer-resolved Open Artifact Decisions 1-3). Each nested kustomization gets its sync-wave fixed now via `commonAnnotations`; each authored CR gets an apiVersion/kind/metadata-only stub (no `spec:`, mirroring both siblings' stub convention) — except `namespace.yaml` files, whose entire content *is* `metadata.name`, so those are written in full now, exactly as `core/overlays/dev/istio-base/namespace.yaml` was. **The top-level `storage/overlays/dev/kustomization.yaml` stays the existing `resources: []`** — none of these new files are referenced yet, so `storage` stays trivially Synced/Healthy exactly as today and nothing new is applied to the live cluster this step:

```text
storage/overlays/dev/
├── kustomization.yaml            # UNCHANGED this step: resources: []
├── namespace.yaml                # Namespace storage (full content now; wave -10)
├── cnpg-operator/
│   ├── kustomization.yaml        # wave -10; helmCharts: [] (chart lands Step 1)
│   └── namespace.yaml            # Namespace cnpg-system (full content now)
├── valkey/
│   └── kustomization.yaml        # wave 0; helmCharts: [] (chart lands Step 3)
├── postgres-cluster.yaml         # wave 0; Cluster `postgres` name-only stub (spec lands Step 3)
└── smoke-database.yaml           # wave 5; Database `smoke` name-only stub (spec lands Step 4)

secrets/dev/storage/
└── kustomization.yaml            # wave -5; generators: [] (secret-generator.yaml + the
                                   #   two encrypted files land Step 2)
```

Representative stubs (every other authored-CR file follows the same shape):

```yaml
# storage/overlays/dev/namespace.yaml -- full content now (a Namespace has no spec)
apiVersion: v1
kind: Namespace
metadata:
  name: storage
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
```

```yaml
# storage/overlays/dev/cnpg-operator/kustomization.yaml -- Step 0 skeleton
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: "-10"
resources:
  - namespace.yaml
helmCharts: []   # cloudnative-pg chart lands Step 1
```

```yaml
# storage/overlays/dev/postgres-cluster.yaml -- Step 0 skeleton (name-only stub, no spec)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  namespace: storage
  annotations:
    argocd.argoproj.io/sync-wave: "0"
```

```yaml
# storage/overlays/dev/smoke-database.yaml -- Step 0 skeleton (name-only stub, no spec)
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: smoke
  namespace: storage
  annotations:
    argocd.argoproj.io/sync-wave: "5"
```

```yaml
# secrets/dev/storage/kustomization.yaml -- Step 0 skeleton
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: "-5"
generators: []   # secret-generator.yaml (kind: ksops) lands Step 2
```

This fixes: the `.sops.yaml` recipient (unblocking every later sealed credential), the `apps/storage.yaml` SSA seam, the directory layout, every shared-contract object name (`postgres`, `smoke`, `storage`, `cnpg-system`), and the four-tier sync-wave scheme (`-10`/`-5`/`0`/`5`) as constants every remaining step reuses. `tests/storage.bats` is a `design.md` artifact and already exists (RED baseline: `storage` trivially Synced/Healthy on the empty placeholder, failing from THEN 1 onward — no CNPG CRDs, no `storage` namespace). Step 0 does not touch it and does not change that RED state: `storage/overlays/dev/kustomization.yaml`'s top-level `resources:` list is unchanged, so nothing new reaches the live cluster yet — but every name and file the remaining steps fill in now exists and is fixed, and the `.sops.yaml` fix unblocks Step 2's sealing.

**Tests**

```bash
test "the .sops.yaml fix is real and non-destructive; storage stays Synced/Healthy on the unchanged placeholder":
  run bash -c 'grep -c AGE-PLACEHOLDER-REPLACE .sops.yaml'
  assert output == "0"                          # placeholder is gone
  run bash -c 'grep -A1 "secrets/dev" .sops.yaml | grep age'
  assert output matches "^age1"                  # a real bech32 age recipient landed
  run kubectl --context k3d-agrippa-dev -n argocd get application storage \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"               # unchanged -- still the empty placeholder
```

- Edge case: if `agrippa-age-dev` is unexpectedly absent from Bitwarden (contradicting this session's live-verified fact), the `grep` for `^# public key: ` returns empty and the `yq -i` would write an empty string into `.sops.yaml` — guard by failing loudly (`[ -n "$recipient" ] || { echo "agrippa-age-dev not found in Bitwarden" >&2; exit 1; }`) rather than writing a blank recipient.
- Edge case: `bw unlock --check` must confirm unlocked before the `bw get notes` call; if the session token in `.env` has expired by build time, that is a real blocker to report (per the task framing), not something to fake around.
- Edge case: the `yq -i` must target only the `secrets/dev/.*` rule's `age` field — verify the `secrets/prod/.*` seam rule (if present) is untouched.
- Edge case: re-running `mise run test:push`/`test:static` after this step must still pass (nothing new is fed to kubeconform/conftest yet — `secrets/dev/storage/kustomization.yaml`'s `generators: []` has no `kind` conftest/kubeconform would inspect, matching the existing `kustomization.yaml`-exclusion convention `scripts/test-static.sh` already applies).

**Implementation Outline**

```text
.sops.yaml:
  creation_rules[path_regex == "^secrets/dev/.*$"].age <- live Bitwarden recipient (yq -i)

apps/storage.yaml:
  spec.syncPolicy.syncOptions <- [ServerSideApply=true, SkipDryRunOnMissingResource=true]

storage/overlays/dev/kustomization.yaml:
  resources: []   # unchanged

storage/overlays/dev/{namespace.yaml, cnpg-operator/*, valkey/kustomization.yaml,
  postgres-cluster.yaml, smoke-database.yaml}: name-only stubs, as above

secrets/dev/storage/kustomization.yaml: generators: [] stub
```

## Step 1: Wave `-10` — namespaces + the CNPG operator

**Enables:** no feature-test assertion flips yet (`storage` was already trivially Synced/Healthy on empty `resources: []`, and stays Synced/Healthy once real-but-inert operator content lands — THEN 1 onward still fails, no `Cluster` exists). Substrate-only: this step exists so wave `0`'s `Cluster` has its CRDs and webhook running before it syncs, per the design's own wave grouping and its first flagged failure mode (a `Cluster`/`Database` CR syncing before the operator's CRDs/webhook exist).

Wire `namespace.yaml` and `cnpg-operator/` into the top-level `storage/overlays/dev/kustomization.yaml`'s `resources:` list — the first real content this feature-step applies to the live cluster. Fill `cnpg-operator/kustomization.yaml`'s `helmCharts:` with the CNPG operator chart (`repo: https://cloudnative-pg.github.io/charts`, `name: cloudnative-pg`, pinned `version:` — `research:public` at build time), `releaseName: cnpg`, target namespace `cnpg-system`, no special `valuesInline` unless build-time research finds one needed (the operator chart bundles its own CRDs, controller, and webhook, the same self-contained shape cert-manager's static manifest already has in `core`). Fill `cnpg-operator/namespace.yaml` with the real (trivial) `Namespace: cnpg-system` object — required because `helmCharts:` inflation runs `helm template`, which never emits a `Namespace` on its own, the same gap `core/overlays/dev/istio-base/namespace.yaml` already fills for Istio.

**Tests**

```bash
test "the CNPG operator's CRDs land, storage stays Synced/Healthy":
  run kubectl --context k3d-agrippa-dev -n argocd get application storage \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"
  run kubectl --context k3d-agrippa-dev get crd
  assert output contains "clusters.postgresql.cnpg.io"
  assert output contains "databases.postgresql.cnpg.io"
  run kubectl --context k3d-agrippa-dev -n cnpg-system get deployment -l app.kubernetes.io/name=cloudnative-pg \
    -o jsonpath='{.items[0].status.readyReplicas}'
  assert output == "1"
  run kubectl --context k3d-agrippa-dev get namespace storage cnpg-system
  assert status == 0
```

- Edge case: `apps/storage.yaml`'s Step 0 `ServerSideApply=true`/`SkipDryRunOnMissingResource=true` must already be live before this commit syncs, or the operator chart's CRD manifests may fail client-side apply's annotation-size limit — verify `kubectl -n argocd get application storage -o jsonpath='{.spec.syncPolicy.syncOptions}'` first.
- Edge case: `helm template` semantics (no hooks, no cluster `lookup`) — confirm at build that the CNPG operator chart does not rely on a post-install hook the templated path would silently drop (design's own flagged Challenge; the chart installs cleanly this way in practice per research, but verify live).
- Edge case: the operator's webhook must actually be Ready (not just the Deployment `Running`) before wave `0`'s `Cluster` is admitted in Step 3 — the wave gate should sequence this, but the webhook's own readiness, not pod status, is what gates admission.
- Edge case: `cnpg-system`'s and `storage`'s two Namespaces must not collide with any namespace `core` already created (`istio-system`, `istio-ingress`, `cert-manager`, `metallb-system`) — confirm no name clash.

**Implementation Outline**

```text
storage/overlays/dev/kustomization.yaml:
  resources:
    - namespace.yaml
    - cnpg-operator/

storage/overlays/dev/cnpg-operator/kustomization.yaml:
  resources:
    - namespace.yaml
  helmCharts:
    - name: cloudnative-pg
      repo: https://cloudnative-pg.github.io/charts
      version: <pinned; research:public at build>
      releaseName: cnpg
      namespace: cnpg-system
```

## Step 2: Wave `-5` — sealing and wiring the `smoke` KSOPS credentials

**Enables:** no feature-test assertion flips yet directly (nothing consumes these Secrets until Step 3's `Cluster`/Valkey release reference them), but this is the load-bearing prerequisite for THEN 3/THEN 4 and the project's **first** committed application-level sops-encrypted Secret — the piece the KSOPS-enabled repo-server (`gitops-argocd`) installed but never exercised.

Seal the two credentials using the discipline `design.md` § Specification § Sealing a per-app credential fixes exactly (reused, not reinvented): the single-value case for the Postgres `smoke-db` basic-auth Secret (password via `--from-file=password=/dev/stdin`, never argv), and the multi-value case for the Valkey `smoke-valkey` users Secret (`default` and `smoke` keys, both required once `auth.enabled: true`). Fill `secrets/dev/storage/kustomization.yaml`'s `generators:` with `secret-generator.yaml` (`apiVersion: viaduct.ai/v1`, `kind: ksops`, `files: [postgres/smoke.enc.yaml, valkey/smoke.enc.yaml]`). Wire `storage/overlays/dev/kustomization.yaml`'s `resources:` to add `../../../secrets/dev/storage` — the self-contained sub-kustomization reference the reviewer-cleared design decided (no repo-server load-restrictor change). Extend `scripts/test-static.sh` to also feed the `secrets/` tree's manifests to **conftest only** (not `kubeconform -strict`, which would flag the `sops:` block against the core `Secret` schema) — closing the plaintext-guard coverage gap `DEVELOPMENT.md` promises and this step is the first to actually need.

**Tests**

```bash
test "the smoke credentials round-trip through KSOPS into real basic-auth/users Secrets":
  run kubectl --context k3d-agrippa-dev -n storage get secret smoke-db \
    -o jsonpath='{.type} {.data.username} {.data.password}'
  assert status == 0
  assert output contains "kubernetes.io/basic-auth"
  run kubectl --context k3d-agrippa-dev -n storage get secret smoke-valkey \
    -o go-template='{{index .data "default"}} {{index .data "smoke"}}'
  assert status == 0                              # both keys present, non-empty
  run mise run test:static
  assert status == 0                               # conftest sees secrets/, still passes (ciphertext + sops: block)
```

- Edge case: the Postgres pipe must use `--filename-override secrets/dev/storage/postgres/smoke.enc.yaml` so `sops` applies the `^secrets/dev/.*$` creation rule to stdin input — omitting it makes `sops` see the filename as `/dev/stdin`, matching no rule, and fail to encrypt.
- Edge case: the Valkey `smoke-valkey` Secret's two password values pass through shell variables/env (the multi-key case design accepts as a minor, same-user-only exposure), not through `--from-literal` on a `kubectl` command line — verify with `ps`/history that no plaintext password ever appears in argv.
- Edge case: `secrets/dev/storage/` must be a genuinely self-contained kustomization — verify `kustomize build storage/overlays/dev` does not trip the default `LoadRestrictionsRootOnly` restrictor (it would, if the encrypted files were referenced directly from `storage/overlays/dev/kustomization.yaml` instead of through this sub-kustomization).
- Edge case: `scripts/test-static.sh`'s new `secrets/` walk must exclude `kustomization.yaml` and non-Secret files the same way its existing `apps/`/`charts/` walks already do, and must never run `kubeconform -strict` over an sops-encrypted manifest.
- Edge case: verify the Secret actually decrypts using the **live cluster's** `sops-age` trust root (`kubectl -n storage get secret smoke-db -o yaml` showing real base64 data, not KSOPS erroring at `kustomize build` time) — proving Step 0's `.sops.yaml` recipient matches the in-cluster private key `bootstrap.sh` seeded, not just a local `age` identity.

**Implementation Outline**

```bash
# postgres/smoke.enc.yaml -- single-value case (design's exact discipline)
openssl rand -base64 24 | tr -d '\n' \
  | kubectl create secret generic smoke-db -n storage \
      --type kubernetes.io/basic-auth \
      --from-literal=username=smoke \
      --from-file=password=/dev/stdin \
      --dry-run=client -o yaml \
  | sops --encrypt --filename-override secrets/dev/storage/postgres/smoke.enc.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > secrets/dev/storage/postgres/smoke.enc.yaml

# valkey/smoke.enc.yaml -- multi-value case (two in-memory values, env-passed)
DEFAULT_PW="$(openssl rand -base64 24 | tr -d '\n')" \
SMOKE_PW="$(openssl rand -base64 24 | tr -d '\n')" \
  bash -c 'kubectl create secret generic smoke-valkey -n storage \
      --from-literal=default="$DEFAULT_PW" --from-literal=smoke="$SMOKE_PW" \
      --dry-run=client -o yaml' \
  | sops --encrypt --filename-override secrets/dev/storage/valkey/smoke.enc.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > secrets/dev/storage/valkey/smoke.enc.yaml
```

```yaml
# secrets/dev/storage/secret-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: storage-secret-generator
files:
  - postgres/smoke.enc.yaml
  - valkey/smoke.enc.yaml
```

```text
secrets/dev/storage/kustomization.yaml:
  generators: [secret-generator.yaml]

storage/overlays/dev/kustomization.yaml:
  resources:
    - namespace.yaml
    - cnpg-operator/
    - ../../../secrets/dev/storage

scripts/test-static.sh:
  + secrets_manifests=$(find secrets -type f \( -name '*.yaml' -o -name '*.yml' \) ! -name 'kustomization.yaml')
  + conftest test --policy tests/policy --all-namespaces "${secrets_manifests[@]}"   # NOT kubeconform
```

## Step 3: Wave `0` — the shared `postgres` Cluster and the Valkey instance

**Enables:** THEN 1 (`kubectl get cluster.postgresql.cnpg.io postgres -o jsonpath='{.status.phase}'` contains `healthy`, and its PVC's `storageClassName` is `local-path`) — the storage-class half of the shared contract, fully exercised.

Fill `postgres-cluster.yaml`'s spec: `instances: 1`, `storage: {storageClass: local-path, size: 1Gi}`, `managed.roles: [{name: smoke, login: true, passwordSecret: {name: smoke-db}}]` — the one shared, append-only list every Feature 5-8 consumer later appends its own entry to, mirroring Networking's Gateway `dnsNames` precedent. The operand PostgreSQL major/image is a build-time `research:public` pin with the recorded guardrail: if on the 17 line, ≥17.6 (avoiding the documented 17.0–17.5 `max_slot_wal_keep_size` upgrade bug); otherwise CNPG's current stable default major. Fill `valkey/kustomization.yaml`'s `helmCharts:` with the official `valkey-io/valkey-helm` chart (pinned `version:`, standalone/default mode), target namespace `storage`, `valuesInline`: `auth.enabled: true`, `auth.usersExistingSecret: smoke-valkey`, `auth.aclUsers.smoke.permissions: "~smoke:* +@all"`, `dataStorage: {enabled: true, className: local-path, requestedSize: <small; build-time>}` — exact value-key spellings are a build-time `research:public` confirmation against the pinned chart README. Wire `postgres-cluster.yaml` and `valkey/` into the top-level `resources:` list.

**Tests**

```bash
test "the shared Postgres Cluster is Healthy on local-path; Valkey is standalone-Ready":
  run kubectl --context k3d-agrippa-dev -n storage get cluster.postgresql.cnpg.io postgres \
    -o jsonpath='{.status.phase}'
  assert status == 0
  assert output contains "healthy"
  run kubectl --context k3d-agrippa-dev -n storage get pvc -l cnpg.io/cluster=postgres \
    -o jsonpath='{.items[0].spec.storageClassName}'
  assert output == "local-path"
  run kubectl --context k3d-agrippa-dev -n storage get pods -l app.kubernetes.io/name=valkey \
    -o jsonpath='{.items[0].status.phase}'
  assert output == "Running"
```

- Edge case: the Valkey chart requires a `default` user be defined once `auth.enabled: true` (else unauthenticated access) — `smoke-valkey`'s `default` key from Step 2 must be present, not just the `smoke` key.
- Edge case: `managed.roles`' `passwordSecret` reference requires `smoke-db` to already exist (Step 2, wave `-5`, before wave `0`) — the sync-wave ordering should guarantee this; verify live rather than trust the annotation alone.
- Edge case (design's flagged failure mode): a CNPG controller-owned status/defaulted field could leave `storage` permanently `OutOfSync` even though every resource applied — the exact symptom Networking hit with istiod's self-patched webhooks. If it surfaces, resolve with a narrowly-scoped `ignoreDifferences` and/or the `compare-options: ServerSideDiff=true` annotation on `apps/storage.yaml`, scoped to the offending field only, mirroring `apps/core.yaml`'s precedent — not a blanket ignore.
- Edge case: both the Cluster's PVC and Valkey's `dataStorage` PVC bind lazily (`WaitForFirstConsumer`) on the single k3d node — confirm both bind without conflict once their respective pods schedule.
- Edge case: confirm the exact CNPG `status.phase` "healthy" string and the Valkey pod's label spelling (`app.kubernetes.io/name=valkey`) against the pinned chart versions at build — `tests/storage.bats`' own helper functions carry the same live-verification caveat.

**Implementation Outline**

```yaml
# storage/overlays/dev/postgres-cluster.yaml (filled)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  namespace: storage
  annotations: {argocd.argoproj.io/sync-wave: "0"}
spec:
  instances: 1
  imageName: <pinned CNPG operand image; >=17.6 if on the 17 line>
  storage: {storageClass: local-path, size: 1Gi}
  managed:
    roles:
      - name: smoke
        login: true
        passwordSecret: {name: smoke-db}
```

```text
storage/overlays/dev/valkey/kustomization.yaml:
  helmCharts:
    - name: valkey
      repo: <official valkey-io/valkey-helm repo>
      version: <pinned; research:public at build>
      releaseName: valkey
      namespace: storage
      valuesInline:
        auth:
          enabled: true
          usersExistingSecret: smoke-valkey
          aclUsers:
            smoke: {permissions: "~smoke:* +@all"}
        dataStorage: {enabled: true, className: local-path, requestedSize: <small>}

storage/overlays/dev/kustomization.yaml:
  resources:
    - namespace.yaml
    - cnpg-operator/
    - ../../../secrets/dev/storage
    - postgres-cluster.yaml
    - valkey/
```

## Step 4: Wave `5` — the `smoke` `Database` CR

**Enables:** THEN 2 (`kubectl get database.postgresql.cnpg.io smoke -o jsonpath='{.status.applied}'` == `true`) — the declarative per-app provisioning mechanism the contract is built on.

Fill `smoke-database.yaml`'s spec: `owner: smoke`, `cluster: {name: postgres}`. Wire it into the top-level `resources:` list at wave `5`, after the Cluster's `smoke` role (wave `0`) exists as its owner.

**Tests**

```bash
test "the smoke Database CR reconciles":
  run kubectl --context k3d-agrippa-dev -n storage get database.postgresql.cnpg.io smoke \
    -o jsonpath='{.status.applied}'
  assert status == 0
  assert output == "true"
```

- Edge case: the `Database` CR's `owner: smoke` must resolve to a role that already exists (Step 3's `managed.roles` entry) — CNPG errors on `CREATE DATABASE ... OWNER smoke` if the role isn't there yet; sync-wave ordering (`0` before `5`) should prevent this, but verify live rather than trust the wave annotation alone.
- Edge case: `status.applied` flips `true` only after CNPG actually runs `CREATE DATABASE`/`ALTER DATABASE` against the live instance, not merely on CR acceptance by the API server — poll rather than assume immediacy.
- Edge case: confirm the exact CRD field spellings (`spec.owner`, `spec.cluster.name`) against the pinned CNPG version at build — the design fixes the shape, build confirms the spelling, and corrects `smoke-database.yaml`/the feature test if either differs.

**Implementation Outline**

```yaml
# storage/overlays/dev/smoke-database.yaml (filled)
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: smoke
  namespace: storage
  annotations: {argocd.argoproj.io/sync-wave: "5"}
spec:
  owner: smoke
  cluster: {name: postgres}
```

```text
storage/overlays/dev/kustomization.yaml:
  resources:
    - namespace.yaml
    - cnpg-operator/
    - ../../../secrets/dev/storage
    - postgres-cluster.yaml
    - valkey/
    - smoke-database.yaml
```

## Step 5: Full GREEN — the credential + ACL proof, and the regression sweep

**Enables:** THEN 3 (a real TCP scram-sha-256 `psql` connection to database `smoke` as role `smoke` using the KSOPS-decrypted `smoke-db` credential) and THEN 4 (Valkey ACL user `smoke` writes within `~smoke:*`, denied outside it) — the two assertions that prove the whole credential path and the recommended per-app ACL isolation end-to-end. No new manifests: Steps 1-4 already wired the role's `passwordSecret` and the Valkey `aclUsers.smoke` entry, so this step is proof-and-regression, not new substrate — mirroring Networking's own final step.

Run `bats tests/storage.bats` against the fully reconciled `storage` layer. If build-time verification (Steps 1-4's own recorded edge cases) found any CNPG label spelling (`cnpg.io/cluster`, `cnpg.io/instanceRole=primary`) or Valkey pod label (`app.kubernetes.io/name=valkey`) diverges from what `tests/storage.bats`' `pg_primary_pod()`/`valkey_pod()` helpers assume, correct the test's selectors here — a test-definition correction inherited from build-time re-verification, not new test authorship (mirroring Networking's Step 5 Q6 correction). Then re-run the full harness `design.md`'s Metrics section names as no-regression evidence.

**Tests**

```bash
test "tests/storage.bats passes end-to-end":
  run bats tests/storage.bats
  assert status == 0

test "no regression to earlier harness":
  run mise run test:push
  assert status == 0
  run mise run test:feature
  assert status == 0
  run bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats tests/rotate-keys.bats
  assert status == 0
```

- Edge case: `scripts/test-feature.sh` already excludes `storage.bats` from its throwaway-cluster auto-discovery (verified committed this session, landed with the feature test at design time) — this step only needs to confirm that exclusion still holds, not add it.
- Edge case: the TCP connection (`psql -h 127.0.0.1 -U smoke -d smoke`) must exercise CNPG's `host ... scram-sha-256` `pg_hba` rule, not a unix-socket `peer`/`trust` rule — confirm CNPG's default `pg_hba` configuration already includes a `host` entry requiring `scram-sha-256` for non-superuser roles; if the pinned CNPG version's default differs, an explicit `postgresql.pg_hba` entry may be needed on `postgres-cluster.yaml` (a Step 3 amendment, discovered here).
- Edge case: `valkey-cli --user smoke -a "$vkpw" set other:probe nope` must return `NOPERM`, not merely a non-zero-looking success — verify the exact denial string the pinned Valkey version emits matches `tests/storage.bats`' `*NOPERM*` match.
- Edge case: re-running `bats tests/storage.bats` a second time back-to-back must not error or disrupt the permanent `smoke` fixture — ArgoCD's `selfHeal` should leave an already-Synced/Healthy `storage` alone, and the test's own `SET`s are idempotent (`smoke:probe`/`other:probe` keys, safely overwritten).
- Edge case: `mise run test:static`'s kubeconform/conftest pass does not walk `storage/` (only `apps/`, `charts/*/rendered/`, and, after Step 2, `secrets/`) — do not assume `test:push` exercises Steps 1-4's CNPG/Valkey YAML; ArgoCD's own live reconcile and this bats suite are the only validators of that content, exactly as Networking's Step 5 recorded for `core/`.

**Implementation Outline**

```text
# no new manifests; this step is verification-only plus any build-time-discovered
# corrections to tests/storage.bats' label selectors or postgres-cluster.yaml's
# pg_hba, surfaced by actually running the suite against the live reconciled cluster
run bats tests/storage.bats
run mise run test:push && mise run test:feature
run bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats tests/rotate-keys.bats
```

## Resolved by the long-loop reviewer (2026-07-08)

This plan is a paper plan against the cleared `design.md`; it has not been built.
The review's job, per the three completed siblings' precedent
(`cluster-core-k3d/plan.md`, `gitops-argocd/plan.md`, `networking-istio/plan.md`),
was three-fold: verify the plan's step decomposition faithfully transcribes the
cleared `design.md` (no re-litigating design decisions), verify the plan's claims
about current repo state against the actually-committed files (`research:codebase`),
and live-verify the load-bearing Step 0 `.sops.yaml` mechanism every later step
depends on. Researched via `research:codebase` (direct inspection of `.sops.yaml`,
`storage/overlays/dev/kustomization.yaml`, `apps/storage.yaml`,
`apps/platform/argocd/kustomization.yaml`, `scripts/test-feature.sh`,
`scripts/test-static.sh`, `tests/storage.bats`, `tests/policy/secrets.rego`) and
live read-only verification against the `k3d-agrippa-dev` cluster and the unlocked
Bitwarden vault. No escalation trigger (irreversible, out of recorded scope,
underdetermined) fired, so this plan's draft gate is cleared (marker now
`*Reviewed 2026-07-08*`). The live cluster and the working tree were left exactly
as found.

**1. Does the plan's step decomposition faithfully transcribe the cleared feature
`design.md`? Decided: yes — no change needed.** The four-tier intra-`storage`
sync-wave scheme (`-10` operator+CRDs+namespaces / `-5` credential Secrets / `0`
shared operands / `5` per-consumer `Database`) maps one-for-one onto the design's
Specification § "Intra-`storage` sync-wave scheme", and Steps 1-4 partition exactly
along those waves. The Step 0 file-layout block (`storage/overlays/dev/` with
`namespace.yaml`, `cnpg-operator/`, `valkey/`, `postgres-cluster.yaml`,
`smoke-database.yaml`; `secrets/dev/storage/` with `kustomization.yaml`,
`secret-generator.yaml`, `postgres/smoke.enc.yaml`, `valkey/smoke.enc.yaml`)
reproduces the design's § Composition layout verbatim, including the
`../../../secrets/dev/storage` self-contained sub-kustomization reference (design
Open Artifact Decision 4). Every shared-contract object name matches the design's
resolved Open Artifact Decisions 1-3: Cluster `postgres`, Database `smoke`, Secrets
`smoke-db`/`smoke-valkey`, generator `secret-generator.yaml` / `kind: ksops`
(`viaduct.ai/v1`), namespaces `storage`/`cnpg-system`, and the
`secrets/dev/storage/<store>/<slug>.enc.yaml` path convention. The Postgres Cluster
spec (`instances: 1`, `storage.storageClass: local-path`, `size: 1Gi`, the
append-only `managed.roles[]` with `passwordSecret: {name: smoke-db}}`), the
`Database` spec (`owner: smoke`, `cluster: {name: postgres}`), the Valkey
`valuesInline` (`auth.enabled/usersExistingSecret/aclUsers.smoke.permissions:
"~smoke:* +@all"`, `dataStorage` on `local-path`), and both sealing cases (the
single-value pure-stdin Postgres pipe and the multi-value env-passed Valkey pipe)
all transcribe the design's § Specification without alteration. The plan's Step 0
`.sops.yaml` fix, its "**Do NOT run `rotate-keys`**" warning, the `apps/storage.yaml`
SSA seam, and the `scripts/test-static.sh` conftest-only `secrets/` extension each
match the design's § Cross-step touches. Faithful.

**2. Are the plan's claims about current repo state accurate? Decided: yes —
verified, no change needed.** All six load-bearing repo-state claims were confirmed
against the committed files: (a) `.sops.yaml`'s `secrets/dev/.*` rule still carries
the literal `AGE-PLACEHOLDER-REPLACE-WITH-REAL-agrippa-age-dev-PUBLIC-KEY` (Step 0's
pre-image). (b) `storage/overlays/dev/kustomization.yaml` is exactly `resources: []`
(Step 0 leaves it so; nothing new reaches the cluster this step). (c)
`apps/storage.yaml`'s `syncPolicy` has `automated.prune/selfHeal` only and **no**
`syncOptions` — so Step 0's additive `ServerSideApply=true` +
`SkipDryRunOnMissingResource=true` is a correct additive change, mirroring
`apps/core.yaml`. (d) `apps/platform/argocd/kustomization.yaml`'s `argocd-cm` patch
already reads `kustomize.buildOptions: "--enable-alpha-plugins --enable-exec
--enable-helm"` (line 85, and live-confirmed identical in the running `argocd-cm`),
so the plan correctly assumes no repo-server change is needed for the two
`helmCharts:` inflations. (e) `scripts/test-feature.sh`'s probe-suite exclusion
`case` list already carries `storage.bats` (line 71), confirming Step 5's "only
needs to confirm that exclusion still holds, not add it". (f) `scripts/test-static.sh`
currently walks only `apps/` and `charts/*/rendered/` — **not** `secrets/` — so
Step 2 is genuinely the step that must close that coverage gap, as the plan states.
Additionally confirmed the plan's binding surface: `tests/storage.bats` reads Secret
`${SLUG}-db` = `smoke-db` (key `password`) and `${SLUG}-valkey` = `smoke-valkey`
(key `smoke`), selects CNPG pods/PVCs on `cnpg.io/cluster=postgres` +
`cnpg.io/instanceRole=primary` and Valkey on `app.kubernetes.io/name=valkey`, and
asserts `status.phase` contains `healthy`, `status.applied == true`, and a `NOPERM`
denial — every string the plan's Steps 3-5 name; and `tests/policy/secrets.rego` is
exactly the plaintext-`Secret` guard (denies `kind: Secret` with non-empty
`data`/`stringData` and no `sops` block, allows the ciphertext-plus-`sops:`-block
form) that Step 2's `secrets/` conftest extension feeds. Every repo-state claim held.

**3. Step 0's load-bearing `.sops.yaml` fix — does the plan's `grep`/`sed`/`yq`
mechanism actually work live, and does it produce a recipient the cluster can use?
Decided: verified end-to-end; the mechanism is correct as written and
non-destructive.** This is the first step every later step depends on, so it was
exercised live, read-only: (a) the `.env`-provided `BW_SESSION` still unlocks the
vault (`bw unlock --check` → "Vault is unlocked!"). (b) `bw get notes agrippa-age-dev`
returns exactly one item carrying one `AGE-SECRET-KEY-` identity and the expected
`# public key: age1…` comment line — the shape the plan's `grep '^# public key: ' |
sed` depends on. (c) that pipeline derives the valid 62-char bech32 recipient
`age1e8wr0f85w0yfqgxc3pc6426ghlu5xt069znn5yuwrtwz30u23quqjcx6vc`, matching the value
recorded in both the cleared `design.md` and `research.md`. (d) the plan's `yq`
expression (`select(.path_regex == "^secrets/dev/.*$") | .age = strenv(...)`), run
read-only without `-i`, correctly rewrites **only** that rule's `age` field (comments
and structure preserved; there is only the one `secrets/dev/.*` rule, so the
"leave `secrets/prod/.*` untouched" edge case is vacuously satisfied), and the file
on disk is unchanged. (e) crucially, the derived recipient **equals the public half
of the in-cluster `sops-age` trust root** (`kubectl -n argocd get secret sops-age`,
`age-keygen -y`) — so what `sops -e` encrypts to in Step 2, the KSOPS repo-server can
decrypt in-cluster, closing the round-trip Steps 2-3 assert on. The plan's own
Step 0 edge-case guards (fail loudly on an empty recipient; require `bw unlock
--check` before `bw get notes`) are the correct conservative handling. Verified,
non-destructive (a git-revertable local edit informed by a read, explicitly **not**
`rotate-keys`), in scope, determined. No escalation.

**4. Build-time-deferred upstream pins and exact spellings (the CNPG operator chart
version, the CNPG operand PostgreSQL major/image ≥17.6-on-the-17-line, the Valkey
chart version `0.9.0`/appVersion `9.0.1`, and the exact CNPG `Cluster`/`Database`
CRD field spellings and Valkey `auth.aclUsers`/`usersExistingSecret`/`dataStorage`
value keys). Decided: correctly deferred to build-time `research:public` — no
change, not a net-new gap.** These are inherited verbatim from the cleared
`design.md` § Challenges ("Version pins deferred to build", "Exact CRD field and
chart-value spellings") and the cleared `research.md` reviewer item 4, which already
recorded the two guardrails the plan carries forward (PostgreSQL ≥17.6 to avoid the
17.0–17.5 `max_slot_wal_keep_size` upgrade bug; pin explicit versions, never float
tags). This matches how the `networking-istio` plan reviewer treated its own
build-time-deferred upstream chart/manifest pins (its item 5): none of these enter
`mise.toml` (the plan correctly states `mise.toml` is unchanged across every step —
the only tools involved, `sops`/`age`/`kustomize`/`helm`/`kubectl`/`k3d`/`yq`/`jq`/
`bitwarden`, are already pinned, and `kubectl cnpg` stays optional/unpinned exactly
as `istioctl` did), so they are not plan-time tool-pin decisions. Trivially bumped,
so neither irreversible nor underdetermined.

**5. Any other net-new open item needing a decision or escalation? Decided: no —
the gate clears.** Unlike the Networking plan (whose Step 4 surfaced two genuinely
net-new mechanism decisions — the DestinationRule-vs-BackendTLSPolicy re-origination
and the gateway selector label — for the reviewer to decide), this plan surfaces
**no** net-new mechanism decision of its own: the cleared `design.md` had already
resolved all five of its Open Artifact Decisions (the Secret/generator names, the
`secrets/dev/storage/<store>/<slug>` path convention, the overlay file names, the
self-contained sub-kustomization wiring, and inline-vs-`mise`-helper sealing), and
this plan only transcribes them. The remaining build-time items the plan's own edge
cases flag — the CNPG `host … scram-sha-256` `pg_hba` default (Step 5, with a
recorded conservative fallback: add an explicit `postgresql.pg_hba` entry to
`postgres-cluster.yaml` if the pinned version's default differs), the CNPG/Valkey
label-spelling re-verification and any resulting `tests/storage.bats` selector
correction (Step 5, a test-definition correction inherited from build-time
re-verification, mirroring Networking's Q6), the exact `NOPERM` denial string, and
the anticipated CNPG-controller-owned-field perma-`OutOfSync` (Step 3, resolved with
a narrowly-scoped `ignoreDifferences`/`ServerSideDiff=true` mirroring
`apps/core.yaml`) — are all contingent live-verifications with conservative
fallbacks already recorded, consistent with the design's "the design fixes the
shapes and names; the build confirms the exact spellings" posture, not open
decisions this gate must resolve. No irreversible, out-of-recorded-scope, or
underdetermined item remains for this artifact. The `*Draft*` marker is removed
(changed to `*Reviewed 2026-07-08*`).
