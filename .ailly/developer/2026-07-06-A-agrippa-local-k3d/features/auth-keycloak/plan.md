# Implementation Plan: Auth (Keycloak via the Keycloak Operator)

*Reviewed 2026-07-09*

**Feature test:** `tests/auth.bats`
**User story:** Given the bootstrapped `agrippa-dev` cluster with this Auth content committed and reconciled by ArgoCD into the `platform` layer — the Keycloak Operator in the `keycloak` namespace, the `Keycloak` CR wired to the shared `postgres` Cluster over its plain-HTTP listener, the `keycloak` `Database` CR in `storage`, and the declaratively-imported `agrippa` realm — when an operator requests the `agrippa` realm's OIDC discovery document at `https://auth.127.0.0.1.nip.io/realms/agrippa/.well-known/openid-configuration` through the k3d `:443` host port-map, then the `platform` Application is Synced/Healthy, the `Keycloak` CR is Ready, the `KeycloakRealmImport` is done, the `keycloak` `Database` CR is applied, the discovery endpoint returns 200 with the correct `issuer`, and the served TLS certificate is issued by the local CA — proving the Operator + external-Postgres + declarative-realm-import + shared-Gateway/HTTPRoute/local-CA-TLS path end-to-end, the substrate a later OIDC integration binds to.

**Steps:**
- [x] Step 0: API surface area (file layout, `apps/platform.yaml` sync seam, `.sops.yaml` recipient check)
- [ ] Step 1: Wave `-10` — the Keycloak Operator + CRDs + namespace
- [ ] Step 2: Wave `-5` — the two-namespace `keycloak-db` credential, `keycloak-admin`, the `managed.roles[]` append, and the `keycloak` `Database` CR
- [ ] Step 3: Wave `0` — the `Keycloak` CR
- [ ] Step 4: Wave `5` — the `KeycloakRealmImport`, the HTTPRoute, and the Gateway cert's `dnsNames` append
- [ ] Step 5: Full GREEN — the discovery-endpoint + local-CA-TLS proof, and the regression sweep

**Libraries & Skills (carried forward from `design.md`/`research.md`; load before each build step):**

- `developer:initialize` — carried forward per convention, but this feature-step exercises no residual `mise` work: it adds **no** new mise-managed CLI. The Keycloak Operator installs from raw pinned-URL manifests ArgoCD reconciles directly (not a local tool, and not Helm-sourced, so it needs neither a new tool pin nor `--enable-helm` repo-server wiring — that already landed for Storage/Networking regardless). Every CLI this plan's steps need (`sops`, `age`, `kubectl`, `openssl`, `k3d`, `yq`, `bitwarden`) is already pinned in `mise.toml`. Nothing in `mise.toml` changes across any step below.
- `research:public` and `research:codebase` — for the per-tool detail each step below explicitly defers to build time: the exact Operator/Keycloak version pin (the three raw-manifest URLs' tag; current stable the 26.6.x line per `research.md`), the exact `Keycloak`/`KeycloakRealmImport` CRD field spellings and `status` condition strings the feature test selects on, the Operator manifest's default RBAC-binding namespace (patch if not `keycloak`), and the exact `spec.hostname.strict`/`spec.proxy.headers` values.
- No library-shipped agentic skill exists for the Keycloak Operator, the `keycloak-k8s-resources` raw manifests, or CNPG's `Database`/`managed.roles` mechanism this feature-step consumes (reconfirmed by both `research.md` and `design.md`). Build to `ARCHITECTURE.html` (§ S5 Platform), `ROUTING.md`, `DEVELOPMENT.md` (§ Secrets), and the two completed sibling designs/plans directly — `storage-postgres-valkey` (the `managed.roles[]`/`Database` CR/`secrets/dev/storage/…` sealing contract this step consumes, and its four-tier sync-wave scheme this step's own intra-`keycloak` scheme mirrors) and `networking-istio` (the Gateway/HTTPRoute/hostname/TLS consumption contract, and the `argocd-httproute.yaml` template this step's own HTTPRoute copies, simplified — no `DestinationRule`, since Keycloak's `spec.http.httpEnabled: true` opens a plain-HTTP backend).

**Patterns beat (`patterns:using-patterns` consulted):** Same conclusion as both completed siblings, re-verified for this feature-step's own pressure (the two-namespace credential materialization) rather than assumed. This feature-step has no typed application code — only GitOps infrastructure config (Kustomize kustomizations, raw pinned-URL `resources:` entries, authored Keycloak-Operator/CNPG CRs, sops-encrypted manifests, one bats suite) — so `newtype`, `domain-objects`, `builder`, `visibility`, `parse-dont-validate`, `type-states`, `repository`, `aggregate`, `unit-of-work`, and `bootstrap-and-service` all require a typed domain model that does not exist here, and none is invoked. The one generated password materialized as two Secret objects is a **namespace-scoping mechanic** (Kubernetes Secrets cannot cross namespaces), not a wrapped primitive or a domain object carrying behavior — there is no code constructing, comparing, or validating these values beyond `sops`/KSOPS decrypt and each controller's own reconcile loop, so it does not route to `newtype`/`domain-objects` either. Two patterns shape *how* the surface and its tests are written: **`arrange-act-assert`** for the one bats `@test` (the existing `run`/assert shape `tests/auth.bats` and its siblings already follow), and **`errors-typed-untyped`**, resolved to the untyped side — a `kubectl`/`curl`/`openssl` exit code, an ArgoCD `Application`'s `sync`/`health` status, and a CR's `status.conditions[]` string are the correct, sufficient failure signals here, consumed only by an operator's shell, `bats`, and ArgoCD's own reconcile loop; no in-process caller needs to match distinct typed failure modes. One structural echo carried forward from `design.md`'s own framing: the `managed.roles[]` and Gateway-cert `dnsNames` appends are the same shared, mutable, append-only-list shape Networking's and Storage's own plans already named (not a catalog pattern) — recorded here for continuity, not a new conclusion.

## Step 0: API surface area

Fix every file path, directory layout, and object name before any has real content, mirroring both completed siblings' Step 0 convention (fixed identifiers, honest inert stubs, no logic/spec). Three changes land here, in order:

**1. The `apps/platform.yaml` sync seam — additive, shared with two concurrent siblings.** Live-verified this session: `apps/platform.yaml`'s `syncPolicy` carries only `automated.prune`/`selfHeal`, no `syncOptions`, no `compare-options` annotation. Keycloak ships two webhook-backed CRDs (`Keycloak`, `KeycloakRealmImport`) plus a controller that defaults spec/status fields the way CNPG's `Cluster` webhook does — the exact symptom that made `apps/core.yaml` and `apps/storage.yaml` need this seam (`argoproj/argo-cd#22151`: `ServerSideApply=true` alone silently auto-enables Structured Merge Diff, which mispredicts webhook-defaulted fields and leaves the Application permanently OutOfSync; `ServerSideDiff=true` forces a real dry-run diff). Add the full two-part seam, copying `apps/storage.yaml`'s pattern verbatim:

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
+      syncOptions:
+        - ServerSideApply=true
+        - SkipDryRunOnMissingResource=true
```

**Build-phase check-first, not a hard requirement only this feature owns:** two concurrent siblings (Forgejo, Flagsmith) independently need this identical seam on this same shared file. Whichever build lands first adds it; if a sibling's build has already landed it by the time this feature-step builds, treat the file as already correct — do not re-add it or fight a merge conflict over identical content.

**2. The `.sops.yaml` recipient — verify live, expect no change.** Storage's build already replaced `.sops.yaml`'s `^secrets/dev/.*$` recipient with the real `agrippa-age-dev` public key; live-verified this session (`cat .sops.yaml` shows a real `age1e8wr0…` value). The file's own comment block still literally says "PLACEHOLDER recipient" — a stale comment from before Storage's build, not a real gap. Confirm live at build time (`cat .sops.yaml`) before Step 2 seals anything — if the placeholder somehow *is* still live (contradicting this session's verification), that is a real blocker to report, not something to route around. **Do not run `mise run rotate-keys`/`scripts/rotate-keys.sh`** to "fix" it: that tool rotates an existing key, it does not populate a placeholder, and running it would desynchronize `.sops.yaml` from the cluster's already-seeded `sops-age` trust root.

**3. The `platform/overlays/dev/keycloak/` and `secrets/dev/platform/keycloak/` directory layout**, fixing every file and object name the cleared `design.md` Specification already resolved (including its reviewer-resolved Open Artifact Decisions 1-3). Each nested kustomization gets its sync-wave fixed now via `commonAnnotations`; each authored CR gets an apiVersion/kind/metadata-only stub (no `spec:`) — except `operator/namespace.yaml`, whose entire content *is* `metadata.name`, so it is written in full now, exactly as `core/overlays/dev/istio-base/namespace.yaml` was. **`platform/overlays/dev/kustomization.yaml` stays the existing `resources: [argocd.yaml]`** — none of these new files are referenced yet, so `platform` stays trivially Synced/Healthy exactly as today and nothing new is applied to the live cluster this step:

```text
platform/overlays/dev/keycloak/
├── kustomization.yaml            # NEW; resources: [] (operator/ lands Step 1; the sealed-credential
│                                 #   sub-kustomization + keycloak-database.yaml land Step 2;
│                                 #   keycloak.yaml lands Step 3;
│                                 #   keycloak-realm.yaml/keycloak-httproute.yaml land Step 4)
├── operator/
│   ├── kustomization.yaml        # wave -10; namespace: keycloak; resources: [namespace.yaml]
│   │                             #   (3 pinned raw-manifest URLs -- 2 CRDs + the operator
│   │                             #   Deployment/RBAC -- land Step 1)
│   └── namespace.yaml            # Namespace keycloak (full content now; a Namespace has no spec)
├── keycloak.yaml                 # wave 0;  Keycloak CR `keycloak` name-only stub (spec lands Step 3)
├── keycloak-database.yaml        # wave -5; CNPG Database `keycloak` name-only stub --
│                                 #   metadata.namespace: storage (spec lands Step 2, ahead of the
│                                 #   Keycloak CR that connects to it -- see Step 2/Step 3)
├── keycloak-realm.yaml           # wave 5;  KeycloakRealmImport `agrippa` name-only stub (spec lands Step 4)
└── keycloak-httproute.yaml       # wave 5;  HTTPRoute `keycloak` name-only stub (spec lands Step 4)

secrets/dev/platform/keycloak/    # first Secret path committed under a platform/ prefix
└── kustomization.yaml            # wave -5; generators: [] (secret-generator.yaml + the two
                                   #   encrypted files land Step 2)
```

Representative stubs:

```yaml
# platform/overlays/dev/keycloak/operator/namespace.yaml -- full content now
apiVersion: v1
kind: Namespace
metadata:
  name: keycloak
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
```

```yaml
# platform/overlays/dev/keycloak/operator/kustomization.yaml -- Step 0 skeleton
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: keycloak   # safe here: only Operator resources live in this sub-kustomization; the
                       # two CRDs and the Namespace itself are cluster-scoped, so the transformer
                       # skips them
commonAnnotations:
  argocd.argoproj.io/sync-wave: "-10"
resources:
  - namespace.yaml   # the 3 pinned raw-manifest URLs (2 CRDs + kubernetes.yml) land Step 1
```

```yaml
# platform/overlays/dev/keycloak/keycloak.yaml -- Step 0 skeleton (name-only stub, no spec)
apiVersion: k8s.keycloak.org/v2beta1
kind: Keycloak
metadata:
  name: keycloak
  namespace: keycloak
  annotations:
    argocd.argoproj.io/sync-wave: "0"
```

```yaml
# platform/overlays/dev/keycloak/keycloak-database.yaml -- Step 0 skeleton
# NOTE metadata.namespace: storage -- CNPG's Database.spec.cluster is a same-namespace-only
# LocalObjectReference (issue #6043); this file lives in this feature's tree but the object
# lands in `storage`, exactly as core's Certificate/Gateway land in istio-ingress.
# NOTE wave -5 (not 5): the keycloak database must exist before the wave-0 Keycloak CR's
# pod connects to it -- see Step 2's placement and the design's "Correction by the
# long-loop reviewer (2026-07-09)".
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: keycloak
  namespace: storage
  annotations:
    argocd.argoproj.io/sync-wave: "-5"
```

```yaml
# platform/overlays/dev/keycloak/keycloak-realm.yaml -- Step 0 skeleton
apiVersion: k8s.keycloak.org/v2beta1
kind: KeycloakRealmImport
metadata:
  name: agrippa
  namespace: keycloak
  annotations:
    argocd.argoproj.io/sync-wave: "5"
```

```yaml
# platform/overlays/dev/keycloak/keycloak-httproute.yaml -- Step 0 skeleton
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: keycloak
  namespace: keycloak
  annotations:
    argocd.argoproj.io/sync-wave: "5"
```

```yaml
# secrets/dev/platform/keycloak/kustomization.yaml -- Step 0 skeleton
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: "-5"
generators: []   # secret-generator.yaml (kind: ksops) + the two encrypted files land Step 2
```

This fixes: the `apps/platform.yaml` sync seam, the directory layout, every shared-contract object name (`keycloak` namespace/CR, `keycloak-db`/`keycloak-admin` Secrets, `agrippa` realm), and the four-tier sync-wave scheme (`-10`/`-5`/`0`/`5`) every remaining step reuses. `tests/auth.bats` is a `design.md` artifact and already exists (RED baseline: `platform` trivially Synced/Healthy on `argocd.yaml`-only content, failing from THEN 1 onward — no `keycloak` namespace, no Keycloak CRDs, no CRs, nothing serving `auth.127.0.0.1.nip.io`). Step 0 does not touch it and does not change that RED state: `platform/overlays/dev/kustomization.yaml`'s top-level `resources:` list is unchanged, so nothing new reaches the live cluster yet — but every name and file the remaining steps fill in now exists and is fixed, and the `apps/platform.yaml` seam is live before Step 1 syncs any CRD content.

**Tests**

```bash
test "the apps/platform.yaml seam is live (or already landed by a sibling); platform stays Synced/Healthy on unchanged content":
  run bash -c 'kubectl --context k3d-agrippa-dev -n argocd get application platform -o jsonpath="{.spec.syncPolicy.syncOptions}"'
  assert output contains "ServerSideApply=true"
  assert output contains "SkipDryRunOnMissingResource=true"
  run bash -c 'kubectl --context k3d-agrippa-dev -n argocd get application platform -o jsonpath="{.metadata.annotations.argocd\.argoproj\.io/compare-options}"'
  assert output == "ServerSideDiff=true"
  run kubectl --context k3d-agrippa-dev -n argocd get application platform \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"    # unchanged -- still argocd.yaml-only content
  run bash -c 'grep -c "age: \"age1e8wr0" .sops.yaml'
  assert output == "1"                 # the real, operative recipient is live (byte-identical to the
                                       # recipient the committed, live-decrypting secrets/dev/storage/postgres/
                                       # smoke.enc.yaml was sealed to). NOTE the leading COMMENT still literally
                                       # reads "PLACEHOLDER recipient" -- stale text, not a gap; do NOT assert
                                       # `grep -c PLACEHOLDER == 0` (it is 1: the comment matches), and do NOT
                                       # run rotate-keys to "fix" it.
```

- Edge case: if a concurrent sibling's build already landed the `apps/platform.yaml` seam first, this step's own edit would be a no-op diff (or a git merge conflict on the same lines if committed concurrently) — check the file's current committed state before editing, and treat "already there, byte-identical" as success, not a surprise (per `design.md`'s explicit instruction).
- Edge case: the seam must land before Step 1's commit syncs, or the Operator's two CRD manifests may hit the client-side apply annotation-size limit on first apply. Unlike Networking's repo-server `--enable-helm` flag, this is an Application-object annotation/syncOptions field, not a repo-server container flag, so it takes effect on the next reconcile, not after a pod restart — no rollout wait needed.
- Edge case: confirm `.sops.yaml`'s `secrets/prod/.*` rule (if present) is untouched — this step makes no `.sops.yaml` edit at all, only a read-only check, so this is vacuously satisfied.
- Edge case: re-running `mise run test:push`/`test:static` after this step must still pass — nothing new is fed to kubeconform/conftest yet (`platform/overlays/dev/keycloak/kustomization.yaml`'s `resources: []` and `secrets/dev/platform/keycloak/kustomization.yaml`'s `generators: []` have no `kind` conftest/kubeconform would inspect, matching the existing `kustomization.yaml`-exclusion convention).

**Implementation Outline**

```text
apps/platform.yaml:
  metadata.annotations["argocd.argoproj.io/compare-options"] <- "ServerSideDiff=true"
  spec.syncPolicy.syncOptions <- [ServerSideApply=true, SkipDryRunOnMissingResource=true]

.sops.yaml: unchanged (read-only live verification only)

platform/overlays/dev/kustomization.yaml:
  resources: [argocd.yaml]   # unchanged

platform/overlays/dev/keycloak/{kustomization.yaml, operator/*, keycloak.yaml,
  keycloak-database.yaml, keycloak-realm.yaml, keycloak-httproute.yaml}: name-only stubs, as above

secrets/dev/platform/keycloak/kustomization.yaml: generators: [] stub
```

## Step 1: Wave `-10` — the Keycloak Operator + CRDs + namespace

**Enables:** no feature-test assertion flips yet (`platform` was already trivially Synced/Healthy on `argocd.yaml`-only content, and stays Synced/Healthy once real-but-inert Operator content lands — THEN 1 onward still fails, no `Keycloak` CR exists). Substrate-only: this step exists so wave `0`'s `Keycloak` CR has its CRDs and controller running before it syncs, per the design's own wave grouping and its first flagged failure mode (a CR syncing before the Operator's CRDs/controller exist).

Append `keycloak/` to `platform/overlays/dev/kustomization.yaml`'s `resources:` list (the first real content this feature-step applies to the live cluster; this is the shared, coordinator-sequenced append the design flags — check the file's current committed state first, since Forgejo/Flagsmith may independently append their own entries around the same time, and append rather than overwrite). Wire `platform/overlays/dev/keycloak/kustomization.yaml`'s `resources:` to `[operator/]`. Fill `operator/kustomization.yaml`'s `resources:` with the three pinned raw-manifest URLs from `keycloak/keycloak-k8s-resources` at a pinned version tag (`research:public` at build time for the exact tag; `research.md`/`design.md` both reference the 26.6.x line as the current-stable starting point) — the two CRDs (`keycloaks.k8s.keycloak.org-v1.yml`, `keycloakrealmimports.k8s.keycloak.org-v1.yml`) and the operator Deployment/RBAC manifest (`kubernetes.yml`), alongside the already-real `namespace.yaml`.

**Tests**

```bash
test "the Keycloak Operator's CRDs land, platform stays Synced/Healthy":
  run kubectl --context k3d-agrippa-dev -n argocd get application platform \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"
  run kubectl --context k3d-agrippa-dev get crd
  assert output contains "keycloaks.k8s.keycloak.org"
  assert output contains "keycloakrealmimports.k8s.keycloak.org"
  run kubectl --context k3d-agrippa-dev -n keycloak get deployment \
    -o jsonpath='{.items[0].status.readyReplicas}'
  assert output == "1"
  run kubectl --context k3d-agrippa-dev get namespace keycloak
  assert status == 0
```

- Edge case: the Step 0 `apps/platform.yaml` seam (`ServerSideApply=true`/`SkipDryRunOnMissingResource=true`) must already be live before this commit syncs, or the Operator's CRD manifests may fail the client-side apply annotation-size limit — verify `kubectl -n argocd get application platform -o jsonpath='{.spec.syncPolicy.syncOptions}'` first.
- Edge case: `platform/overlays/dev/kustomization.yaml`'s `resources:` list is a shared, mutable list under concurrent contention from two sibling feature-steps (Forgejo, Flagsmith) — re-inspect the file's live committed content immediately before appending, so a last-writer-wins overwrite does not silently drop a sibling's already-landed entry.
- Edge case: the exact Operator Deployment label is unconfirmed against the pinned `kubernetes.yml` manifest (`app.kubernetes.io/name=keycloak-operator` is the common Operator-SDK/Kustomize convention, not yet live-verified) — the test above deliberately selects `.items[0]` rather than a label filter to avoid guessing it; tighten to a label selector once confirmed at build, mirroring Storage's own CNPG-operator-label verification.
- Edge case: the Operator's RBAC binding may hardcode a default namespace in its upstream `kubernetes.yml`; if that default is not `keycloak`, the `ClusterRoleBinding` subject needs a build-time patch (`research/public.md` [1] flags this) — verify the Operator pod actually starts and its ServiceAccount can watch/list `Keycloak`/`KeycloakRealmImport` CRs in the `keycloak` namespace, not just that the Deployment is `Running`.
- Edge case: the Operator's admission webhook (both CRDs are webhook-validated) must be genuinely Ready — not just the Deployment `Running` — before wave `0`'s `Keycloak` CR is admitted in Step 3; the wave gate should sequence this, but verify live rather than trust the annotation alone.
- Edge case: the new `keycloak` namespace must not collide with any namespace `core`/`storage` already created (`istio-system`, `istio-ingress`, `cert-manager`, `metallb-system`, `cnpg-system`, `storage`) — confirm no name clash.

**Implementation Outline**

```text
platform/overlays/dev/kustomization.yaml:
  resources:
    - argocd.yaml
    - keycloak/

platform/overlays/dev/keycloak/kustomization.yaml:
  resources:
    - operator/

platform/overlays/dev/keycloak/operator/kustomization.yaml:
  namespace: keycloak
  resources:
    - namespace.yaml
    - https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/<tag>/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
    - https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/<tag>/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml
    - https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/<tag>/kubernetes/kubernetes.yml
```

## Step 2: Wave `-5` — the two-namespace `keycloak-db` credential, `keycloak-admin`, the `managed.roles[]` append, and the `keycloak` `Database` CR

**Enables:** THEN 3 (`kubectl -n storage get database.postgresql.cnpg.io keycloak -o jsonpath='{.status.applied}'` == `true`) — the `keycloak` PostgreSQL database now physically exists, created at wave `-5` **ahead of** the wave-`0` `Keycloak` CR that connects to it. No other feature-test assertion flips yet directly (nothing consumes the Secrets until Step 3's `Keycloak` CR references them), but this step is the load-bearing prerequisite for THEN 1 (the `Keycloak` CR can only reach Ready against an already-existing database) and carries the design's one genuinely novel correctness point — the two-namespace credential materialization.

**Wave placement of the `keycloak` `Database` CR — corrected from the design's original wave `5` to wave `-5` (see `design.md`'s "Correction by the long-loop reviewer (2026-07-09)").** The design originally grouped the `Database` CR at wave `5`, alongside the realm import and HTTPRoute, *after* the wave-`0` `Keycloak` CR. That is a hard ArgoCD sync deadlock: Keycloak (Quarkus/JVM) opens a JDBC connection to `spec.db.database: keycloak` at startup to run its Liquibase migration and **never issues `CREATE DATABASE`**, so a missing `keycloak` database yields `FATAL: database "keycloak" does not exist`, Keycloak's `start` fails, and the pod crash-loops (CrashLoopBackOff) — the Operator's `Keycloak` CR `Ready` condition (gated on the pod's `/health/ready` probe) never goes True, ArgoCD's wave-`0` gate never clears, and the wave-`5` `Database` CR that alone creates the database is never applied. CNPG creates only the *role* from the `managed.roles[]` append, never the database, so nothing else breaks the cycle. This is the identical defect class the two parallel platform siblings hit: `feature-flags-flagsmith` (its api pod blocks in `migrate`/`waitfordb` initContainers) and `git-hosting-forgejo` (Gitea's `log.Fatal` on a missing DB, go-gitea/gitea#27079) both resequenced their own `Database` CR to wave `-5`. The `keycloak` `Database` CR's only real prerequisites — the CNPG operator and the `keycloak` role — are already live from the `storage` layer's own sync (sync-wave 1) before `platform` (sync-wave 2) starts, so folding it into this wave-`-5` step (alongside the sealed Secrets and the `managed.roles[]` append) loses nothing and breaks the deadlock cleanly.

Generate the DB role's password **once**, in memory, then seal it into **two** ciphertext files differing only in `metadata.namespace` (`design.md` § "The credential: one password, two namespaces"): `secrets/dev/storage/postgres/keycloak.enc.yaml` (Secret `keycloak-db`, `namespace: storage`, `type: kubernetes.io/basic-auth`, `username: keycloak`) and `secrets/dev/platform/keycloak/keycloak-db.enc.yaml` (same shape, `namespace: keycloak`, same password). Generate a second, independent password for the admin bootstrap credential and seal it once into `secrets/dev/platform/keycloak/keycloak-admin.enc.yaml` (Secret `keycloak-admin`, `namespace: keycloak`, keys `username`+`password`). Add `postgres/keycloak.enc.yaml` to **Storage's existing** `secrets/dev/storage/secret-generator.yaml`'s `files:` list (currently `[postgres/smoke.enc.yaml, valkey/smoke.enc.yaml]` — append, do not replace) — the exact touch Storage's consumption contract sanctions. Fill this feature's own `secrets/dev/platform/keycloak/secret-generator.yaml` (new, `kind: ksops`) with `files: [keycloak-db.enc.yaml, keycloak-admin.enc.yaml]`, and wire it into `secrets/dev/platform/keycloak/kustomization.yaml`'s `generators:`. Wire `platform/overlays/dev/keycloak/kustomization.yaml`'s `resources:` to add `../../../../secrets/dev/platform/keycloak` (four levels up — one deeper than Storage's three, since the reference originates from the `keycloak/` subdirectory). Append **one** entry to the shared `postgres` Cluster's `spec.managed.roles[]` in `storage/overlays/dev/postgres-cluster.yaml` (currently `[{name: smoke, ...}]` — append, do not replace): `{name: keycloak, login: true, passwordSecret: {name: keycloak-db}}`. Finally, fill `keycloak-database.yaml`'s spec (`name: keycloak` — the actual PostgreSQL database name, the CRD-required field beyond `owner`/`cluster.name` Storage's build discovered; `owner: keycloak`; `cluster: {name: postgres}`) and wire it into `platform/overlays/dev/keycloak/kustomization.yaml`'s `resources:` at wave `-5` — alongside the sealed-credential sub-kustomization and ahead of the wave-`0` `Keycloak` CR (Step 3), so the `keycloak` database exists before the CR's pod connects (the corrected placement above).

**Tests**

```bash
test "the keycloak-db credential is materialized identically in both namespaces; keycloak-admin exists; storage stays Synced/Healthy after its own role append":
  run kubectl --context k3d-agrippa-dev -n storage get secret keycloak-db \
    -o jsonpath='{.type} {.data.username} {.data.password}'
  assert status == 0
  assert output contains "kubernetes.io/basic-auth"
  storage_pw="$(kubectl --context k3d-agrippa-dev -n storage get secret keycloak-db -o jsonpath='{.data.password}')"
  run kubectl --context k3d-agrippa-dev -n keycloak get secret keycloak-db \
    -o jsonpath='{.data.password}'
  assert output == "$storage_pw"       # same generated value, two namespaces
  run kubectl --context k3d-agrippa-dev -n keycloak get secret keycloak-admin \
    -o jsonpath='{.type} {.data.username} {.data.password}'
  assert status == 0
  run kubectl --context k3d-agrippa-dev -n argocd get application storage \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"    # the shared postgres Cluster's managed.roles[] append reconciled cleanly
  run kubectl --context k3d-agrippa-dev -n storage get database.postgresql.cnpg.io keycloak \
    -o jsonpath='{.status.applied}'
  assert output == "true"              # the keycloak database exists before the wave-0 Keycloak CR connects (THEN 3)
```

- Edge case: the `Database` CR lands at wave `-5` in **this** step, ahead of the wave-`0` `Keycloak` CR (Step 3) — the deadlock fix. `owner: keycloak` must resolve to the `keycloak` role appended just above (reconciled by the `storage` Application, sync-wave 1, ahead of `platform`); CNPG errors on `CREATE DATABASE ... OWNER keycloak` if the role is not yet present. The role append and the `Database` CR are two different ArgoCD Applications (`storage` and `platform`), so same-wave numbering alone does not guarantee cross-Application ordering — verify live rather than trust the wave annotation.
- Edge case: confirm the exact CRD field spellings (`spec.name`, `spec.owner`, `spec.cluster.name`) against the pinned CNPG version at build — Storage's own build-time correction (the live CRD requires `spec.name` in addition to `owner`/`cluster.name`) is already reflected here, but re-verify against whatever CNPG version is live by this build.
- Edge case: this `Database` CR lives in `platform/overlays/dev/keycloak/` (the `platform` Application's subtree) but targets `metadata.namespace: storage` — confirm the `platform` Application can create a resource into a namespace outside its own `destination.namespace` default (the design's cited precedent: the `storage` Application already creates resources into both `cnpg-system` and `storage`).
- Edge case: the password must be generated **once** and reused for both ciphertext files — never regenerated independently per file, or CNPG's role password and the `Keycloak` CR's `db.passwordSecret` value will mismatch and Keycloak's DB connection will fail authentication (the exact failure mode `design.md`'s "Failure modes to design against" names).
- Edge case: each `sops --encrypt` invocation needs `--filename-override` set to its own eventual committed path (`secrets/dev/storage/postgres/keycloak.enc.yaml` vs `secrets/dev/platform/keycloak/keycloak-db.enc.yaml`) so `.sops.yaml`'s `^secrets/dev/.*$` creation rule applies to stdin input on both — omitting it makes `sops` see `/dev/stdin`, matching no rule, and fail to encrypt.
- Edge case: `storage/overlays/dev/postgres-cluster.yaml`'s `managed.roles[]` and `secrets/dev/storage/secret-generator.yaml`'s `files:` are both shared, mutable, append-only lists under concurrent contention from Forgejo/Flagsmith (each appends its own role/credential) — re-inspect the live committed content immediately before appending, append only this feature's own entry, and never reorder or drop an existing entry.
- Edge case: `secrets/dev/platform/keycloak/` must be a genuinely self-contained kustomization (verify `kustomize build platform/overlays/dev/keycloak` does not trip the default `LoadRestrictionsRootOnly` restrictor) — mirroring Storage's own Step 2 verification.
- Edge case: this is the **first** cross-feature-step write to an already-landed sibling's live Application (`storage`, already Synced/Healthy, sync-wave 1) from a later feature-step — confirm the append reconciles cleanly and does not disturb the existing `smoke` role/database or the live `smoke-db`/`smoke-valkey` credentials (`bats tests/storage.bats` re-run as a regression check, formally covered in Step 5).

**Implementation Outline**

```bash
# one password, two ciphertexts (design's exact discipline)
KC_DB_PW="$(openssl rand -base64 24 | tr -d '\n')"

printf '%s' "$KC_DB_PW" \
  | kubectl create secret generic keycloak-db -n storage \
      --type kubernetes.io/basic-auth \
      --from-literal=username=keycloak \
      --from-file=password=/dev/stdin \
      --dry-run=client -o yaml \
  | sops --encrypt --filename-override secrets/dev/storage/postgres/keycloak.enc.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > secrets/dev/storage/postgres/keycloak.enc.yaml

printf '%s' "$KC_DB_PW" \
  | kubectl create secret generic keycloak-db -n keycloak \
      --type kubernetes.io/basic-auth \
      --from-literal=username=keycloak \
      --from-file=password=/dev/stdin \
      --dry-run=client -o yaml \
  | sops --encrypt --filename-override secrets/dev/platform/keycloak/keycloak-db.enc.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > secrets/dev/platform/keycloak/keycloak-db.enc.yaml

# independent admin credential, single namespace/consumer
ADMIN_PW="$(openssl rand -base64 24 | tr -d '\n')"
ADMIN_PW="$ADMIN_PW" bash -c 'kubectl create secret generic keycloak-admin -n keycloak \
    --from-literal=username=admin --from-file=password=<(printf "%s" "$ADMIN_PW") \
    --dry-run=client -o yaml' \
  | sops --encrypt --filename-override secrets/dev/platform/keycloak/keycloak-admin.enc.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > secrets/dev/platform/keycloak/keycloak-admin.enc.yaml
```

```yaml
# secrets/dev/platform/keycloak/secret-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: platform-keycloak-secret-generator
files:
  - keycloak-db.enc.yaml
  - keycloak-admin.enc.yaml
```

```yaml
# platform/overlays/dev/keycloak/keycloak-database.yaml (filled) -- wave -5, ahead of the Keycloak CR
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: keycloak
  namespace: storage
  annotations: {argocd.argoproj.io/sync-wave: "-5"}
spec:
  name: keycloak
  owner: keycloak
  cluster: {name: postgres}
```

```text
secrets/dev/storage/secret-generator.yaml:
  files: [postgres/smoke.enc.yaml, valkey/smoke.enc.yaml, postgres/keycloak.enc.yaml]   # append

secrets/dev/platform/keycloak/kustomization.yaml:
  generators: [secret-generator.yaml]

platform/overlays/dev/keycloak/kustomization.yaml:
  resources:
    - operator/
    - ../../../../secrets/dev/platform/keycloak
    - keycloak-database.yaml   # wave -5, ahead of keycloak.yaml (Step 3)

storage/overlays/dev/postgres-cluster.yaml:
  spec.managed.roles:
    - {name: smoke, login: true, passwordSecret: {name: smoke-db}}
    - {name: keycloak, login: true, passwordSecret: {name: keycloak-db}}   # append
```

## Step 3: Wave `0` — the `Keycloak` CR

**Enables:** THEN 1 (`kubectl -n keycloak get keycloak keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` == `True`) — the Operator connected to the external shared Postgres over the plain-HTTP listener, reaching Ready against the **already-existing** `keycloak` database (created at wave `-5` in Step 2, ahead of this wave-`0` CR).

Fill `keycloak.yaml`'s spec per `design.md` § "The `Keycloak` CR": `instances: 1`; `db: {vendor: postgres, host: postgres-rw.storage.svc, port: 5432, database: keycloak, usernameSecret: {name: keycloak-db, key: username}, passwordSecret: {name: keycloak-db, key: password}}`; `ingress: {enabled: false}`; `http: {httpEnabled: true}`; `hostname: {hostname: https://auth.127.0.0.1.nip.io}`; `proxy: {headers: xforwarded}` (exact `hostname.strict`/`proxy.headers` spellings build-verified — research open item 6); `bootstrapAdmin: {user: {secret: keycloak-admin}}`. Wire `keycloak.yaml` into `platform/overlays/dev/keycloak/kustomization.yaml`'s `resources:`.

**Tests**

```bash
test "the Keycloak CR connects to the shared Postgres and reaches Ready":
  run kubectl --context k3d-agrippa-dev -n keycloak get keycloak keycloak \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  assert status == 0
  assert output == "True"
  run kubectl --context k3d-agrippa-dev -n keycloak get service keycloak-service
  assert status == 0    # the Operator's own Service; ingress.enabled: false means no Operator-owned Ingress
```

- Edge case (**resolved** — the deadlock the design's original wave `5` assignment would have caused): the `Keycloak` CR at wave `0` opens a JDBC connection to `spec.db.database: keycloak` at startup to run its Liquibase migration and never issues `CREATE DATABASE`, so it cannot reach Ready before the `keycloak` database physically exists. The design originally placed the `keycloak` `Database` CR at wave `5`, *after* this CR — a hard ArgoCD sync deadlock (the health-gated wave-`0` CR never reaches Ready, so ArgoCD never advances to wave `5`, so the database is never created; CNPG's `managed.roles[]` append creates only the *role*, never the database). The long-loop reviewer resolved this by moving the `Database` CR to wave `-5` (Step 2 above; see `design.md`'s "Correction by the long-loop reviewer (2026-07-09)"), matching the `feature-flags-flagsmith` and `git-hosting-forgejo` siblings' identical resolution. So the `keycloak` database already exists by the time this CR reconciles; verify live that the CR reaches Ready against the pre-existing database rather than treating a non-Ready status as "still starting up."
- Edge case: the shared `postgres` Cluster and the `keycloak` role (Step 2) must already exist by the time this CR reconciles — true by construction, since `storage` is sync-wave 1 and `platform` is sync-wave 2 (cross-layer ordering `gitops-argocd` already fixed), but confirm live rather than trust the layer-wave alone.
- Edge case: `bootstrapAdmin` is silently ignored on any re-sync after the `master` realm already exists — expected, not a bug; do not design a test around repeated bootstrap.
- Edge case: confirm the exact CRD field spellings (`spec.db.database`, `spec.hostname.hostname`/`.strict`, `spec.proxy.headers`, `spec.http.httpEnabled`, `spec.bootstrapAdmin.user.secret`) and the `status.conditions[type=="Ready"]` string against the pinned Operator version — the design fixes the shapes and names, build confirms spellings, and corrects `keycloak.yaml`/the feature test if any differ (the test is RED now regardless).
- Edge case: if Step 1's Operator RBAC namespace patch was needed, confirm the Operator's controller actually has permission to reconcile a `Keycloak` CR in the `keycloak` namespace before trusting a non-Ready status as "still starting up" rather than "permission denied."

**Implementation Outline**

```yaml
# platform/overlays/dev/keycloak/keycloak.yaml (filled)
apiVersion: k8s.keycloak.org/v2beta1
kind: Keycloak
metadata:
  name: keycloak
  namespace: keycloak
  annotations: {argocd.argoproj.io/sync-wave: "0"}
spec:
  instances: 1
  db:
    vendor: postgres
    host: postgres-rw.storage.svc
    port: 5432
    database: keycloak
    usernameSecret: {name: keycloak-db, key: username}
    passwordSecret: {name: keycloak-db, key: password}
  ingress:
    enabled: false
  http:
    httpEnabled: true
  hostname:
    hostname: https://auth.127.0.0.1.nip.io
  proxy:
    headers: xforwarded
  bootstrapAdmin:
    user:
      secret: keycloak-admin
```

```text
platform/overlays/dev/keycloak/kustomization.yaml:
  resources:
    - operator/
    - ../../../../secrets/dev/platform/keycloak
    - keycloak-database.yaml   # landed Step 2 (wave -5)
    - keycloak.yaml
```

## Step 4: Wave `5` — the `KeycloakRealmImport`, the HTTPRoute, and the Gateway cert's `dnsNames` append

**Enables:** THEN 2 (`KeycloakRealmImport` `Done` == `True`) and WHEN + THEN 4/5/6 (the discovery endpoint reachable through the Gateway with the correct `issuer` and the local-CA cert) — every remaining assertion. (THEN 3, the `Database` `status.applied`, already flipped in Step 2, where the `keycloak` `Database` CR now lands at wave `-5`, ahead of the `Keycloak` CR.)

Fill `keycloak-realm.yaml`'s spec: `keycloakCRName: keycloak`, `realm: {id: agrippa, realm: agrippa, enabled: true, displayName: Agrippa}`. Fill `keycloak-httproute.yaml`, copying `core/overlays/dev/argocd-httproute.yaml`'s exact shape but targeting the plain-HTTP backend directly (no `DestinationRule` — the whole reason `spec.http.httpEnabled: true` was chosen): `parentRefs: [{name: agrippa-gateway, namespace: istio-ingress, sectionName: https}]`, `hostnames: [auth.127.0.0.1.nip.io]`, `rules: [{matches: [{path: {type: PathPrefix, value: /}}], backendRefs: [{name: keycloak-service, port: 8080}]}]` (`matches:` authored explicitly, mirroring Networking's own structural-default fix for the identical nested-array OutOfSync symptom). Append `auth.127.0.0.1.nip.io` to `core/overlays/dev/gateway-cert.yaml`'s `dnsNames` (currently `[argocd.127.0.0.1.nip.io]` — append, do not replace; shared with Forgejo/Flagsmith, each appending their own host — re-check the file's live committed content first). Wire `keycloak-realm.yaml` and `keycloak-httproute.yaml` into `platform/overlays/dev/keycloak/kustomization.yaml`'s `resources:`. (The `keycloak` `Database` CR was already filled and wired at wave `-5` in Step 2, per the deadlock correction — not re-authored here.)

**Tests**

```bash
test "the realm import is done, and the discovery endpoint is reachable with the local-CA cert":
  run kubectl --context k3d-agrippa-dev -n keycloak get keycloakrealmimport agrippa \
    -o jsonpath='{.status.conditions[?(@.type=="Done")].status}'
  assert status == 0
  assert output == "True"
  run kubectl --context k3d-agrippa-dev -n keycloak get httproute keycloak \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
  assert output == "True"
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 15 \
    https://auth.127.0.0.1.nip.io/realms/agrippa/.well-known/openid-configuration
  assert status == 0
  assert output == "200"
```

- Edge case: `core/overlays/dev/gateway-cert.yaml`'s `dnsNames` append reconciles through the **`core`** Application (a different, already-landed, already-Synced/Healthy layer at sync-wave 0), independent of `platform`'s own wave sequence — cert-manager must actually re-issue `agrippa-gateway-tls` with the new SAN before the discovery endpoint's TLS handshake presents a cert covering `auth.127.0.0.1.nip.io`; this is an async cross-layer reconcile the build must tolerate (poll/retry), not assumed instantaneous with the commit.
- Edge case: the `keycloak` `Database` CR and the `Keycloak` CR reaching Ready are both prerequisites already satisfied before this step (the `Database` CR at wave `-5` in Step 2, the `Keycloak` CR at wave `0` in Step 3) — the wave-`5` resources here (realm import, HTTPRoute) depend on the Ready `Keycloak` CR and the created `keycloak-service`; confirm Step 3 actually went Ready before treating this step's own non-progress as a problem local to this step.
- Edge case: `KeycloakRealmImport.spec.keycloakCRName: keycloak` requires the same-namespace `Keycloak` CR to already be `Ready` (Step 3) — the wave gate (`0` before `5`) should guarantee this, verify live.
- Edge case: `core/overlays/dev/gateway-cert.yaml`'s `dnsNames` list is a shared, mutable, append-only list under concurrent contention from Forgejo/Flagsmith (each appends its own host) — re-inspect the live committed content immediately before appending.
- Edge case: confirm the exact `status.applied`/`status.conditions[type=="Done"]` strings and the discovery document's `issuer` JSON key spelling against the pinned Operator version — correcting `tests/auth.bats`' selectors here if build-time verification finds a difference (a test-definition correction inherited from live re-verification, mirroring both siblings' final steps), not new test authorship.

**Implementation Outline**

```yaml
# platform/overlays/dev/keycloak/keycloak-realm.yaml (filled)
apiVersion: k8s.keycloak.org/v2beta1
kind: KeycloakRealmImport
metadata:
  name: agrippa
  namespace: keycloak
  annotations: {argocd.argoproj.io/sync-wave: "5"}
spec:
  keycloakCRName: keycloak
  realm:
    id: agrippa
    realm: agrippa
    enabled: true
    displayName: Agrippa
```

```yaml
# platform/overlays/dev/keycloak/keycloak-httproute.yaml (filled)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: keycloak
  namespace: keycloak
  annotations: {argocd.argoproj.io/sync-wave: "5"}
spec:
  parentRefs:
    - name: agrippa-gateway
      namespace: istio-ingress
      sectionName: https
  hostnames:
    - auth.127.0.0.1.nip.io
  rules:
    - matches:
        - path: {type: PathPrefix, value: /}
      backendRefs:
        - name: keycloak-service
          port: 8080
```

```text
core/overlays/dev/gateway-cert.yaml:
  spec.dnsNames: [argocd.127.0.0.1.nip.io, auth.127.0.0.1.nip.io]   # append

platform/overlays/dev/keycloak/kustomization.yaml:
  resources:
    - operator/
    - ../../../../secrets/dev/platform/keycloak
    - keycloak-database.yaml   # landed Step 2 (wave -5)
    - keycloak.yaml            # landed Step 3 (wave 0)
    - keycloak-realm.yaml      # this step (wave 5)
    - keycloak-httproute.yaml  # this step (wave 5)
```

## Step 5: Full GREEN — the discovery-endpoint + local-CA-TLS proof, and the regression sweep

**Enables:** THEN 4/5/6 in full (the discovery endpoint's 200, its `issuer` string, and the local-CA `openssl x509 -issuer` check) and closes out THEN 0-3 already exercised incrementally in Steps 1-4. No new manifests: Steps 1-4 already wired the whole path, so this step is proof-and-regression, mirroring both completed siblings' own final step.

Run `bats tests/auth.bats` against the fully reconciled `platform` layer. If build-time verification (Steps 1-4's own recorded edge cases) found any status-condition string, CRD field spelling, or discovery-document key diverges from what `tests/auth.bats` assumes, correct the test's selectors here — a test-definition correction inherited from build-time re-verification, not new test authorship (mirroring Networking's Step 5 Q6 correction and Storage's Step 5). Then re-run the full harness `design.md`'s Metrics section names as no-regression evidence, including the two already-landed sibling suites this feature-step's cross-layer touches (`storage`'s `managed.roles[]`/generator append, `core`'s Gateway-cert `dnsNames` append) could in principle disturb.

**Tests**

```bash
test "tests/auth.bats passes end-to-end":
  run bats tests/auth.bats
  assert status == 0

test "no regression to earlier harness":
  run mise run test:push
  assert status == 0
  run mise run test:feature
  assert status == 0
  run bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats tests/storage.bats tests/rotate-keys.bats
  assert status == 0
```

- Edge case: `scripts/test-feature.sh` already excludes `auth.bats` from its throwaway-cluster auto-discovery (verified committed this session, landed with the feature test alongside the other three parallel siblings' own exclusions) — this step only needs to confirm that exclusion still holds, not add it.
- Edge case: `bats tests/storage.bats` re-run here is the actual regression proof that this feature-step's two Storage-layer touches (the `managed.roles[]` append, the `secret-generator.yaml` `files:` append) did not disturb the `smoke` role/database/credentials `storage.bats` exercises.
- Edge case: `bats tests/networking.bats` re-run here is the actual regression proof that this feature-step's `core/overlays/dev/gateway-cert.yaml` `dnsNames` append did not disturb `argocd.127.0.0.1.nip.io`'s own reachability or cert issuance.
- Edge case: re-running `bats tests/auth.bats` a second time back-to-back must not error or disrupt the permanent `agrippa` realm/`keycloak` database — ArgoCD's `selfHeal` should leave an already-Synced/Healthy `platform` alone, and the discovery-endpoint/TLS checks are read-only.
- Edge case: `mise run test:static`'s kubeconform/conftest pass does not walk `platform/overlays/dev/keycloak/`, `core/`, or `storage/` (only `apps/`, `charts/*/rendered/`, and `secrets/`) — do not assume `test:push` exercises Steps 1-4's new YAML; ArgoCD's own live reconcile and this bats suite are the only validators of that content, exactly as both completed siblings' Step 5 recorded.

**Implementation Outline**

```text
# no new manifests; this step is verification-only plus any build-time-discovered
# corrections to tests/auth.bats' status-condition/discovery-key selectors, surfaced
# by actually running the suite against the live reconciled cluster
run bats tests/auth.bats
run mise run test:push && mise run test:feature
run bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats tests/storage.bats tests/rotate-keys.bats
```

## Resolved by the long-loop reviewer (2026-07-09)

This is a paper plan against the cleared feature `design.md` in this folder; it has
not been built. A separately dispatched long-loop reviewer read it cold and, per the
completed siblings' precedent, checked: (1) transcription fidelity against the cleared
`design.md` (no re-litigating design decisions), (2) the plan's repo-state claims
against the actually-committed files and the live `k3d-agrippa-dev` cluster (read-only,
nothing applied or mutated), and (3) the `keycloak` `Database` CR's wave placement for
the now-confirmed ordering-vs-dependency deadlock this parallel platform band has hit
twice already. Items 1-2 cleared with one test-assertion correction (item 2). Item 3 —
the critical one — was **decided and applied directly** (not escalated): with two
confirmed sibling precedents (`git-hosting-forgejo`, `feature-flags-flagsmith`) and a
coordinator-blessed template for this exact bug class, and having researched Keycloak's
own startup DB behavior specifically, the reviewer moved the `keycloak` `Database` CR
from wave `5` to wave `-5` in both `design.md` and this plan. No escalation trigger
(irreversible, out of recorded scope, or underdetermined) fired, so this plan's draft
gate is cleared (marker now `*Reviewed 2026-07-09*`).

**1. Transcription fidelity against the cleared `design.md`. Decided: faithful — no
change needed beyond the wave correction (item 3).** Every step transcribes the
design's § Specification: the `apps/platform.yaml` two-part sync seam (Step 0), the
`platform/overlays/dev/keycloak/` + `secrets/dev/platform/keycloak/` layout and the
four-tier `-10/-5/0/5` wave scheme (Steps 0-4), the two-namespace `keycloak-db`
credential materialization plus the `keycloak-admin` credential and the storage
`managed.roles[]` append (Step 2), the `Keycloak` CR spec (Step 3), the
`KeycloakRealmImport`/HTTPRoute/`dnsNames` SAN append (Step 4), and the
proof-and-regression sweep (Step 5). The `Keycloak` CR's `spec.db`/`hostname`/`proxy`/
`bootstrapAdmin` fields, the two-namespace credential discipline (one password → two
ciphertext files differing only in `metadata.namespace`), the raw-manifest Operator
install, and the plain-HTTP HTTPRoute (no `DestinationRule`) all match the design.
Build-time deferrals (Operator/Keycloak version pin, exact CRD field/status-string
spellings, RBAC namespace patch, `hostname.strict`/`proxy.headers` values) are
legitimate `research:public` build-phase items, correctly left open.

**2. Repo-state claims re-verified live (read-only). Decided: accurate, with one
corrected Step 0 test assertion.** Confirmed against the working tree and the live
cluster: `apps/platform.yaml` carries `syncPolicy.automated` only (no `syncOptions`, no
`compare-options` annotation) — the shared seam has not landed and no sibling has raced
it in; `platform/overlays/dev/kustomization.yaml` is `resources: [argocd.yaml]` only (no
`keycloak/`, `forgejo/`, or `flagsmith/` subdir); `storage/overlays/dev/
postgres-cluster.yaml`'s `managed.roles[]` holds only `smoke` (live cluster confirms
`{.spec.managed.roles[*].name}` == `smoke`); `core/overlays/dev/gateway-cert.yaml`'s
`dnsNames` holds only `argocd.127.0.0.1.nip.io`; `scripts/test-feature.sh` already
excludes `auth.bats` in its probe-suite `case` list; the live `platform` Application is
`Synced/Healthy`, and no `keycloak`/Keycloak-CRD/`keycloak` namespace exists yet. **The
`.sops.yaml` recipient is a real, operative key, not a literal placeholder:** its value
`age1e8wr0f85w0yfqgxc3pc6426ghlu5xt069znn5yuwrtwz30u23quqjcx6vc` is byte-identical to
the `recipient:` embedded in the already-committed, live-decrypting
`secrets/dev/storage/postgres/smoke.enc.yaml`, so the plan's operative conclusion (no
`.sops.yaml` change needed; Keycloak's sealing will round-trip in-cluster) holds. **But
the file's leading *comment* still literally reads "PLACEHOLDER recipient"** — stale
text, not a gap — so Step 0's original test assertion `grep -c PLACEHOLDER .sops.yaml`
== `0` was **wrong** (the actual count is `1`, matching that comment line) and would
have failed the step. Corrected to a positive check that the operative recipient
(`age1e8wr0…`) is present, with a note not to assert `PLACEHOLDER`-absence and not to
run `rotate-keys` to "fix" the stale comment. (Cleaning up the comment is a project-wide
secrets-custody nicety outside this feature-step's recorded scope; the plan correctly
makes no `.sops.yaml` edit.) Reversible, in-scope, determined — no escalation.

**3. The `keycloak` `Database` CR wave placement (design's wave `5` vs. wave `-5`).
Decided: corrected to wave `-5`, applied directly to both `design.md` and this plan —
the same fix the two parallel siblings landed.** The originally-transcribed scheme
(`Database` CR at wave `5`, *after* the wave-`0` `Keycloak` CR) is a hard ArgoCD sync
deadlock. **Keycloak's actual startup/DB behavior was researched specifically
(`research:public`), not assumed identical to Forgejo's Go binary:** Keycloak
(Quarkus/JVM) opens a JDBC connection to the *target* database (`spec.db.database:
keycloak`) at startup to run its Liquibase schema migration, and **never issues `CREATE
DATABASE`** (it creates tables inside an existing database only), so a missing
`keycloak` database yields `FATAL: database "keycloak" does not exist` ("Failed to
obtain JDBC connection", keycloak/keycloak#19607); Keycloak's `start` then fails and the
container exits into CrashLoopBackOff — it does **not** wait gracefully for the database
to appear on first boot. The Keycloak Operator gates the `Keycloak` CR's `Ready`
condition on the pod's `/health/ready` probe, which cannot pass until that migration
succeeds, so the CR never reaches Ready while the database is absent. Placing the
`Database` CR (the sole creator of database `keycloak`) at wave `5`, behind the
health-gated wave-`0` `Keycloak` CR, is therefore the identical circular deadlock class
`git-hosting-forgejo` and `feature-flags-flagsmith` both hit and both fixed by moving
their own `Database` CR to wave `-5`: the CR that needs the database can never go Ready,
so ArgoCD never advances to the wave that would create it, and CNPG's `managed.roles[]`
append creates only the *role*, never the database. (This is not the graceful-retry
exemption the review question hypothesized — Keycloak fails hard on the missing target
database, and even an unbounded retry could not bridge a database whose creation is
strictly wave-gated behind the pod's own health.) Storage's own `smoke` `Database` sits
at wave `5` safely only because nothing in `storage` consumes the smoke database with a
DB-gated startup; Keycloak is a wave-`0` consumer of its own database, so it is subject
to the deadlock the smoke fixture never was. The design was internally inconsistent on
exactly this point (its § User Journey and § Failure modes both imply the database
exists before the `Keycloak` CR reaches Ready, which its original wave scheme violated).
**Fix applied:** `design.md` § Intra-`keycloak` sync-wave scheme now places the
`Database` CR at wave `-5` (with a "Correction by the long-loop reviewer (2026-07-09)"
subsection recording the reasoning), and this plan folds the `Database` CR's fill and
wiring from its old Step 4 into Step 2 (wave `-5`, alongside the sealed credentials and
the `managed.roles[]` append), moves THEN 3's `status.applied` assertion to Step 2,
updates Step 0's stub annotation, rewrites Step 3's formerly-deferred deadlock edge case
as resolved, and drops the `Database` CR from Step 4 (which keeps the realm import,
HTTPRoute, and `dnsNames` append at wave `5`). The `Database` CR's only real
prerequisites — the CNPG operator and the `keycloak` role — are already live from the
`storage` layer's own sync (sync-wave 1) before `platform` (sync-wave 2) starts, so the
earlier wave loses nothing. Reversible (a one-line annotation edit plus paper
reorganization), in-scope, determined — decided, not escalated, per the explicit
two-precedents-and-a-template basis.

**Reviewer verification (2026-07-09).** Checked live, read-only, against the committed
tree and the `k3d-agrippa-dev` cluster context: `apps/platform.yaml` (no seam),
`platform/overlays/dev/kustomization.yaml` (`resources: [argocd.yaml]`),
`platform/overlays/dev/` and `secrets/dev/platform/` (no sibling landing yet),
`storage/overlays/dev/postgres-cluster.yaml` (`smoke` role only; live cluster confirms),
`core/overlays/dev/gateway-cert.yaml` (`argocd` SAN only), `scripts/test-feature.sh`
(`auth.bats` excluded), and `.sops.yaml` (recipient byte-identical to the committed
storage ciphertext's `recipient:` — real key; `grep -c PLACEHOLDER` == `1`, comment
only). No custom ArgoCD health check for `k8s.keycloak.org/Keycloak` exists in the repo
(none is shipped built-in either — argoproj/argo-cd#16509/#22897 are open requests),
which does not change the verdict: the deadlock lands regardless via the crash-looping
StatefulSet child gating the App's health and the incremental build's own Step-3-Ready
assertion, and the fix is decisively the sibling-consistent conservative default. The
item-3 deadlock was confirmed from Keycloak's documented startup DB-connection behavior
(keycloak/keycloak#19607; the Operator's `/health/ready`-gated `Ready` condition) and
ArgoCD's documented wave health-gating. No live cluster state was mutated.

**Gate status: CLEARED.** Items 1-2 decided to their conservative defaults (item 2 with
a corrected Step 0 test assertion); item 3 — the confirmed build-breaking DB-wave
deadlock — is resolved by moving the `keycloak` `Database` CR from wave `5` to wave `-5`
in both `design.md` and this plan, matching the two parallel siblings' identical fix and
applied directly under the long-loop decide (not escalate) basis. Marker updated to
`*Reviewed 2026-07-09*`.
