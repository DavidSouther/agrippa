# Feature Design: Storage (Postgres via CloudNativePG + Valkey)

*Reviewed 2026-07-08*

> Feature-step design (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 4: Storage (Postgres +
> Valkey)** of that project's plan: the shared datastore layer, and the
> feature-step that **defines the storage-class + per-app DB/role naming shared
> contract** Features 5-8 (Auth/Keycloak, Git hosting/Forgejo, Feature
> flags/Flagsmith, Observability/LGTM) each bind to independently. It has its own
> feature test (recorded below). The project as a whole is measured by
> `closing-bell.md`, not by this test.
>
> This is a **larger, ensemble** feature-step (two upstream datastores — the CNPG
> operator and the Valkey chart — plus the first committed application-level
> sops-encrypted Secret, plus a shared contract four later features consume), so
> it runs longer than the one-page norm, per `design.md`'s "confirm before making
> a larger doc." Its research (`research.md`, `research/public.md`) is Reviewed;
> the reviewer block there (`Resolved by the long-loop reviewer`) already settled
> the research phase's five open items and corrected the `.sops.yaml`
> fix mechanism — those decisions are carried in as settled inputs below, not
> re-litigated. This is a **long-loop** run: the draft gate is left open for a
> separately dispatched reviewer to clear.

## Libraries & Skills (carry forward to plan and build)

Per the project's cleared `research.md` (§ Libraries & Skills), this feature-step's
own cleared `research.md` (§ Libraries & Skills), and the project `design.md`, the
plan and build phases MUST load these skills via the harness's skill-loading
mechanism before working:

- **`developer:initialize`** — for any residual `mise` tool-pin work. This feature
  adds **no** new mise-managed CLI: the CNPG operator and the Valkey chart are both
  in-cluster resources ArgoCD reconciles via Helm, not local tools. Everything the
  build needs for the `.sops.yaml` fix and for sealing the smoke-fixture credential
  Secret (`sops`, `age`, `kustomize`, `helm`, `kubectl`, `k3d`, `yq`, `jq`,
  `bitwarden`) is already pinned in `mise.toml`. An optional `kubectl cnpg` plugin
  may aid operator debugging at build time — it stays **unpinned**, exactly the way
  `istioctl` stayed optional/unpinned for Networking.
- **`research:public`** and **`research:codebase`** — for the per-tool detail the
  build defers to build time: the exact CNPG operator chart version, the CNPG
  operand PostgreSQL major/image, the Valkey chart version, and the exact chart
  value keys and CRD field spellings each component uses.

**No library-shipped agentic skill exists for CloudNativePG, the official Valkey
chart, sops, age, or KSOPS** (both the project research and this feature's research
recorded the deliberate per-tool check). Build to the in-repo contracts:
`ARCHITECTURE.html` (§ S4 Storage — "Postgres · single instance · per-app DBs
isolated by name + role"; § S5 Platform), `DEVELOPMENT.md` (§ Testing, § Secrets —
the sops/age/KSOPS wiring this feature-step's credentials follow), and the two
completed sibling designs — `gitops-argocd` (the KSOPS/`sops-age` convention, the
`secrets/dev/<component>.enc.yaml` path) and `networking-istio` (the shared
append-only-list precedent, and the `helmCharts:`-inflation-plus-authored-CRs
composition under one layer Application) — are the authoritative contracts this
step builds to.

## Purpose

Stand up the local **shared datastore layer** — one Postgres instance and one
Valkey instance — reconciled by ArgoCD into the already-Synced `storage` layer, and
— the load-bearing deliverable — **define the storage-class + per-app DB/role
naming shared contract** that Features 5-8 each bind to. Production would run the
same charts and CRs on Longhorn-backed volumes; locally both datastores run
single-instance on the `local-path` dev storage class (`local-path` confirmed live
as k3s's default, `WaitForFirstConsumer`), Longhorn stays declared-but-excluded
from `overlays/dev`, and off-cluster DR is deferred (local DR is GitOps-only, RPO 0
for declarative state) — all per the parent design's already-settled decision 1.

The deliverable is:

1. **The CloudNativePG (CNPG) operator**, Helm-inflated into a `cnpg-system`
   namespace — the declarative Postgres operator that replaces the now-paywalled
   Bitnami `postgresql` chart. Operator-plus-authored-CRs is the same shape the
   `core` layer already uses for cert-manager and metallb.
2. **One shared Postgres `Cluster`** named `postgres` (single instance for dev,
   `storage.storageClass: local-path`) in a `storage` namespace — the substrate
   every later Postgres-backed platform service binds to.
3. **One shared Valkey instance** (official `valkey-io/valkey-helm` chart,
   standalone mode) in the `storage` namespace, persistence on `local-path`.
4. **The per-app Postgres DB/role naming contract** — this feature-step's headline
   deliverable — expressed as a documented, demonstrated mechanism (a
   `Cluster.spec.managed.roles[]` append plus a per-app `Database` CR) and a
   concrete naming pattern (database name = role name = the consuming app's own
   slug), with the recommended, lighter Valkey ACL-user extension alongside it.
5. **The application-secret sops+age+KSOPS workflow**, applied for the first time
   in this project to a real per-app credential: generated in memory, encrypted
   immediately, only the ciphertext committed under `secrets/dev/storage/…`, and
   decrypted by KSOPS at `kustomize build` time — the first committed
   application-level encrypted Secret, so this step also establishes the
   `generators:` wiring every Feature 5-8 secret reuses.
6. **A permanent `smoke` fixture** — a Postgres database `smoke` owned by role
   `smoke`, and a Valkey ACL user `smoke` scoped to `~smoke:*` — that exercises the
   whole contract end-to-end as this feature's reachability proof, since (unlike
   Networking's reuse of the pre-existing ArgoCD UI) Storage has no already-running
   consumer to route through.

The value is narrow but load-bearing: no real application uses a database yet (that
is Features 5-8), but nothing Postgres- or Valkey-backed can be built until this
substrate and its naming contract exist. This step proves the contract end-to-end
against its own smoke fixture — a shared instance, an isolated declaratively-managed
database and role, a credential that round-trips through KSOPS, and an ACL-scoped
Valkey user.

Out of scope, kept as seams for the deferred cloud cycle or owned by a later
feature-step: **pre-provisioning Keycloak's / Forgejo's / Flagsmith's actual
databases** (each of Features 5-7 owns its own `Database` CR + `managed.roles[]`
append, consuming this contract), **Longhorn** (declared in the app-of-apps,
excluded from `overlays/dev`), **off-cluster DR** (pg_dump / block backups to S3),
**CNPG HA/replication** (`instances` > 1), **Valkey replication / Cluster mode /
Sentinel**, **Observability's own signal stores** (Loki/Mimir/Tempo store on
`local-path` PVCs directly, not Postgres — Feature 8's shared contract is "storage
class" only), and **`overlays/prod`** (a seam, not built).

## Prior Art

- **`networking-istio` (Feature 3), `core/overlays/dev/`.** The authoritative
  in-repo pattern this step mirrors one-for-one: a single layer Application
  (`apps/core.yaml`, sync-wave 0) pointing at a **flat `<layer>/overlays/dev/`**
  overlay that composes upstream Helm charts via per-component subdirectories
  (`istio-base/`, `istio-control/`, each with its own `kustomization.yaml` carrying
  a `commonAnnotations` sync-wave and a `helmCharts:` block plus a `namespace.yaml`
  because `helm template` emits no Namespace), alongside top-level authored-CR
  files, all ordered by a fine-grained intra-layer sync-wave scheme. This step
  applies exactly that layout to `storage/overlays/dev/`.
- **`networking-istio`, the shared append-only list.** The shared Gateway
  certificate's `dnsNames` — one shared, mutable, append-only list every later
  consumer adds one line to (never editing the Gateway object itself). This step's
  `Cluster.spec.managed.roles[]` is the direct analogue: every later Postgres
  consumer appends one role entry to the one shared `postgres` Cluster manifest,
  and authors its own `Database` CR elsewhere — the exact "many independent
  consumers, one shared list plus one self-owned object" shape this project already
  accepted.
- **`gitops-argocd` (Feature 2), `apps/platform/argocd/kustomization.yaml`.** The
  KSOPS-enabled repo-server (init container installs `ksops`, `sops-age` Secret
  mounted, `SOPS_AGE_KEY_FILE` resolved, `kustomize.buildOptions:
  "--enable-alpha-plugins --enable-exec --enable-helm"` — live-confirmed all
  present). No repo-server change is needed here: `--enable-helm` (for the CNPG and
  Valkey `helmCharts:` inflation) and `--enable-alpha-plugins --enable-exec` (for
  the KSOPS exec generator) all already landed. This step is the **first to
  actually exercise** the KSOPS decrypt path end-to-end for a committed Secret.
- **`gitops-argocd`, `apps/storage.yaml` and `storage/overlays/dev/`.** The
  `storage` Application already exists (sync-wave 1, `path: storage/overlays/dev`,
  `automated.prune/selfHeal`), reconciling an empty-but-valid `resources: []`
  placeholder that is live **Synced/Healthy** today — the placeholder this step
  replaces with real content. Its `automated.prune/selfHeal` is precisely why the
  smoke fixture must be **permanent**: a torn-down declarative resource is
  re-created on the next reconcile, so a throwaway would fight the reconciler.
- **`DEVELOPMENT.md` § Secrets and `scripts/rotate-keys.sh` / `scripts/bootstrap.sh`.**
  The "generate in memory, encrypt immediately, never touch disk, only the
  ciphertext committed" discipline (`rotate-keys.sh` pipes `age-keygen` straight to
  `bw create`; `bootstrap.sh` pipes `bw get notes` straight into `kubectl create
  secret --from-file=…=/dev/stdin`, never argv). `DEVELOPMENT.md` even names this
  step's own worked path — `secrets/dev/storage/postgres/secret.enc.yaml` — which
  this step refines to a per-slug filename (`postgres/<slug>.enc.yaml`) so each
  consumer of the one shared instance owns a distinct encrypted file (see § The
  committed-secret path convention). This step reuses that discipline for a Secret
  that (unlike the injected `sops-age` trust root) **does** get committed, encrypted.
- **`tests/policy/secrets.rego`.** The plaintext-`Secret` conftest guard from
  `DEVELOPMENT.md` § Secrets — denies any `kind: Secret` with non-empty
  `data`/`stringData` and no `sops:` block, allows a sops-encrypted Secret. Built
  for exactly the committed encrypted Secret this step introduces (see Specification
  § Extending the plaintext guard's coverage).
- **External worked examples** (full IEEE citations in `research/public.md`): the
  CNPG single-instance `storage.storageClass` Cluster sample [12], the `Database`
  CRD owner-role example [15], the `Cluster.spec.managed.roles` `passwordSecret`
  example [16], the CNPG 17.0–17.5 upgrade-bug note [14], the official Valkey chart
  README's `auth.aclUsers`/`usersExistingSecret` schema [20], Valkey's ACL
  key-pattern glob syntax [21][22], and the application-secret encrypt-then-commit
  ArgoCD+KSOPS+sops walkthroughs [25][26].

## User Journey and Metrics

**The consumer's flow — the shared contract in use.** The primary audience for this
feature-step is a *later feature-step's author* (Keycloak's, Forgejo's,
Flagsmith's), because the deliverable is a contract four of them consume. From the
bootstrapped `agrippa-dev` cluster with this Storage content reconciled:

1. ArgoCD syncs the `storage` layer: the CNPG operator comes up in `cnpg-system`,
   the shared `postgres` Cluster reaches Healthy on a `local-path` PVC in the
   `storage` namespace, and the shared Valkey instance comes up standalone on a
   `local-path` PVC. The operator runs `kubectl -n argocd get application storage`
   and sees it **Synced/Healthy**.
2. A later consumer (say Keycloak) needs a Postgres database. It does exactly three
   things, all declarative, none of which touches another feature-step's manifests
   beyond one shared-list append: (a) it seals a random credential into
   `secrets/dev/storage/postgres/keycloak.enc.yaml` (the discipline in Specification §
   Sealing a per-app credential); (b) it **appends one entry** to the shared
   `postgres` Cluster's `spec.managed.roles[]` — `{name: keycloak, login: true,
   passwordSecret: {name: keycloak-db}}` — the one shared-list edit, mirroring the
   Gateway `dnsNames` append; (c) it authors its own `Database` CR (`name: keycloak,
   owner: keycloak, cluster: {name: postgres}`) in its own layer/overlay. ArgoCD
   reconciles all three; CNPG creates the database, creates/updates the role, and
   sets its password from the KSOPS-decrypted Secret. Keycloak connects with the
   DSN `postgres://keycloak:<pw>@postgres-rw.storage.svc:5432/keycloak`.
3. If that consumer also uses Valkey, it follows the **recommended** (not mandated)
   parallel: add a `keycloak` ACL user scoped `~keycloak:*` to the Valkey release's
   `auth.aclUsers`, with its password in the shared Valkey users Secret; connect at
   `valkey.storage.svc:6379` as user `keycloak`.

**The operator's flow — the reachability proof.** Because Storage has no
already-running consumer, this step ships its own permanent `smoke` fixture standing
in for step 2/3 above: a database `smoke` owned by role `smoke` (via a
`managed.roles[]` entry + a `Database` CR + `secrets/dev/storage/postgres/
smoke.enc.yaml`), and a Valkey ACL user `smoke` scoped `~smoke:*` (via
`auth.aclUsers` + `secrets/dev/storage/valkey/smoke.enc.yaml`). The operator runs
`bats tests/storage.bats`: it connects to database `smoke` as role `smoke` with the
committed credential, and authenticates to Valkey as `smoke`, proving the whole
contract end-to-end.

**Metrics / measures of done for this feature-step:**

- The feature test (`tests/storage.bats`) is green: the shared `postgres` Cluster is
  Healthy on a `local-path` PVC, the `smoke` `Database` reconciles, a client
  connects to database `smoke` as role `smoke` with the sops-encrypted credential
  (proving Database CR + managed role + KSOPS credential path), and Valkey ACL user
  `smoke` can write within `~smoke:*` but is denied outside it — proving the
  storage-class + per-app DB/role naming contract.
- `kubectl -n argocd get application storage` is **Synced/Healthy** with the CNPG
  operator, the shared Cluster, and the Valkey instance all reconciled.
- Adding this step does not regress earlier harness: `mise run test:push`
  (`test:static` + `test:policy` + `test:chart`), `mise run test:feature`, and
  `bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats
  tests/rotate-keys.bats` stay green (the `storage.bats` `test:feature` exclusion
  lands with the test).

**Per-component SLO (defined here, watched in Grafana once Observability lands; not
a CI step, per `DEVELOPMENT.md`).** Storage backs every platform service, so its
budget is among the tightest of the infrastructure layers. Targets, measured over a
rolling 28-day window once Feature 8 provides Prometheus/Grafana: **the shared
Postgres read-write endpoint accepts connections ≥ 99.9%** of the time (from CNPG's
exported metrics — `cnpg_pg_postmaster_start_time` present and the primary
`Ready`), and **the shared Valkey instance responds to `PING` ≥ 99.9%** of the time.
Burn-rate alert at 2% budget consumed in 1h. Recorded here, instrumented when
Observability lands; not asserted by the feature test.

**Failure modes to design against.**

- **A `Cluster`/`Database` CR syncing before the CNPG operator's CRDs or webhook
  exist.** Mitigated by the intra-`storage` sync-wave scheme (operator at wave -10,
  Cluster at 0, Database at 5) plus the `ServerSideApply`/`SkipDryRunOnMissingResource`
  seam this step adds to `apps/storage.yaml` (CNPG's `Cluster` CRD is large enough
  to overflow client-side apply's last-applied-configuration annotation, the same
  reason `core` and ArgoCD's own install use server-side apply).
- **A CNPG controller-owned status/defaulted field leaving `storage` permanently
  `OutOfSync`** even though every resource applied — the exact symptom Networking
  hit with istiod's self-patched webhooks. Anticipated, not pre-solved: if it
  surfaces at build, resolve it with a narrowly-scoped `ignoreDifferences` and/or
  the `compare-options: ServerSideDiff=true` annotation `apps/core.yaml` already
  documents, scoped to the offending field only.
- **The credential path silently half-working** — KSOPS decrypts but CNPG never
  applies the password, or the Secret's keys/type are wrong. Mitigated by the
  feature test asserting an actual authenticated connection as role `smoke`, not
  merely that the Secret exists.
- **A committed plaintext Secret slipping past CI** because `test:static`'s manifest
  walk does not currently include the `secrets/` tree (live-confirmed:
  `scripts/test-static.sh` walks only `apps/` and `charts/*/rendered/`). Mitigated
  by extending the plaintext guard's coverage to `secrets/` (Specification §
  Extending the plaintext guard's coverage).
- **`local-path` `WaitForFirstConsumer` co-location.** Both the Cluster's PVC and
  Valkey's PVC bind lazily on the single k3d node — safe, and the reason
  `WaitForFirstConsumer` matters (research `research/public.md` [23]).

## Specification

### Composition: one `storage` Application, one KSOPS+Helm `kustomize build`

Following `core/overlays/dev/`'s realized layout exactly, `storage/overlays/dev/`
becomes a **flat overlay** (no `storage/base/` — there is no `overlays/prod` content
to share a base with yet; extraction stays a reversible refactor deferred to when
the prod seam is built) composing two Helm sources plus authored CRs plus the KSOPS
secrets, ordered by a four-tier intra-`storage` sync-wave scheme this step defines.
The proposed file layout (object/file names are Open Artifact Decisions where noted):

```text
storage/overlays/dev/
├── kustomization.yaml            # resources: the two subdirs, the authored CRs,
│                                 #   and the secrets kustomization (below)
├── namespace.yaml                # wave -10; Namespace storage
├── cnpg-operator/
│   ├── kustomization.yaml        # wave -10; helmCharts: [cloudnative-pg] -> cnpg-system
│   └── namespace.yaml            # Namespace cnpg-system (helm template emits none)
├── valkey/
│   └── kustomization.yaml        # wave 0; helmCharts: [valkey] standalone -> storage
├── postgres-cluster.yaml         # wave 0; CNPG Cluster `postgres` (+ managed.roles[smoke])
└── smoke-database.yaml           # wave 5; CNPG Database `smoke`

secrets/dev/storage/             # referenced by the overlay as a sub-kustomization
├── kustomization.yaml            # wave -5; generators: [secret-generator.yaml]
├── secret-generator.yaml         # kind: ksops; files: [postgres/smoke…, valkey/smoke…]
├── postgres/
│   └── smoke.enc.yaml            # sops-encrypted basic-auth Secret `smoke-db`
└── valkey/
    └── smoke.enc.yaml            # sops-encrypted users Secret `smoke-valkey`
```

Two composition points deserve explicit treatment:

- **Helm inflation** uses `helmCharts:` in the per-component subdirectory's
  `kustomization.yaml`, exactly as `istio-base/`/`istio-control/` do (the
  repo-server's `--enable-helm` is already live). CNPG's operator chart bundles its
  CRDs, controller, and webhook (like cert-manager's static manifest); the Valkey
  chart renders a plain standalone workload (StatefulSet/Deployment + Service + PVC)
  with no CRDs. Each subdir carries its own `namespace.yaml` because `helm template`
  never emits a Namespace.
- **KSOPS decryption of the committed Secret** is wired with a `generators:` entry —
  the piece `gitops-argocd` installed the repo-server plumbing for but never
  exercised. `DEVELOPMENT.md` fixes the encrypted-Secret path at repo-root
  `secrets/dev/storage/…`, so the encrypted files live outside the `storage/overlays/
  dev/` tree. Kustomize's default load restrictor forbids a generator from reading
  *files* above its own root, but permits a `resources:` reference to another
  **directory that has its own `kustomization.yaml`** (the standard "overlay
  references `../../base`" shape). So `secrets/dev/storage/` is a self-contained
  kustomization: it holds a KSOPS `generators:` manifest (`kind: ksops`) whose
  `files:` are its own local `postgres/smoke.enc.yaml` and `valkey/smoke.enc.yaml`,
  and the `storage` overlay references `../../../secrets/dev/storage` as a resource.
  This keeps every file reference within a kustomization root (no repo-server
  `--load-restrictor` change), and establishes the generator pattern Features 5-8
  reuse. The decrypted Secrets carry `metadata.namespace: storage` and a wave `-5`
  annotation (via the secrets kustomization's `commonAnnotations`), so they exist
  before the wave-0 Cluster references them.

### Intra-`storage` sync-wave scheme (this feature-step defines it)

`gitops-argocd` fixed the cross-layer waves (`core=0`, `storage=1`, …) on the
`storage` **Application**; this step defines the ordering *inside* the layer. All
resources carry `argocd.argoproj.io/sync-wave` annotations (via `commonAnnotations`
on each nested kustomization for Helm-sourced multi-doc output, inline on authored
CRs):

- **wave `-10` — operator + CRDs + namespaces:** the `storage` and `cnpg-system`
  Namespaces, and the CNPG operator chart (its CRDs, controller, webhook).
- **wave `-5` — the decrypted credential Secrets:** the KSOPS-generated `smoke-db`
  and `smoke-valkey` Secrets in `storage`, present before anything references them.
- **wave `0` — the shared operands:** the `postgres` Cluster (which carries the
  `smoke` role in `managed.roles[]`, referencing `smoke-db`) and the Valkey release
  (which carries the `smoke` ACL user, referencing `smoke-valkey`).
- **wave `5` — the per-consumer object:** the `smoke` `Database` CR (needs the
  operator running and the Cluster's `smoke` role to exist as its owner).

ArgoCD syncs waves ascending and waits for each Healthy before the next, so the
`Cluster` never applies before the operator's webhook is up and the `Database` never
applies before its owner role and the Cluster exist.

### The shared Postgres instance and the per-app DB/role naming contract

This is the feature-step's headline deliverable.

- **The shared instance.** One CNPG `Cluster` named **`postgres`** in the `storage`
  namespace: `spec.instances: 1` (dev; production HA would raise this),
  `spec.storage.storageClass: local-path`, `spec.storage.size: 1Gi`. The operand
  PostgreSQL major/image is a **build-time `research:public` pin** with a recorded
  guardrail: if on the 17 line, **≥ 17.6** (avoiding the documented 17.0–17.5
  `max_slot_wal_keep_size` upgrade bug, `research/public.md` [14]); otherwise CNPG's
  current stable default major. CNPG creates its default `app` database on
  bootstrap; per-app databases are separate `Database` CRs (below), not that default.
  CNPG exposes the read-write endpoint as the Service `postgres-rw.storage.svc:5432`
  (read-only `postgres-ro`, all-instances `postgres-r`).

- **The naming contract (settled spelling): database name = role name = the
  consuming app's own slug** — `keycloak`/`keycloak`, `forgejo`/`forgejo`,
  `flagsmith`/`flagsmith`. Provisioned by two complementary declarative mechanisms:
  1. **Role:** a `Cluster.spec.managed.roles[]` entry `{name: <slug>, login: true,
     passwordSecret: {name: <slug>-db}}`, continuously reconciled (a manual `ALTER
     ROLE` drift is reverted next cycle). `passwordSecret` references a
     `kubernetes.io/basic-auth` Secret (`username`+`password`) in the `storage`
     namespace — the KSOPS-decrypted, sops-committed credential.
  2. **Database:** a `Database` CR `{name: <slug>, owner: <slug>, cluster: {name:
     postgres}}`, continuously reconciled (CNPG runs `CREATE DATABASE`/`ALTER
     DATABASE` to converge). It can be authored **anywhere in the repo that
     references the shared `postgres` Cluster** — it does not require editing the
     Cluster manifest.

- **The consumption contract for later Postgres feature-steps** (Auth, Git hosting,
  Feature flags): (a) seal a random credential into `secrets/dev/storage/postgres/
  <slug>.enc.yaml` and add its file to the KSOPS generator; (b) **append one**
  `managed.roles[]` entry to this step's `postgres-cluster.yaml` — the one shared,
  append-only edit, mirroring the accepted Gateway `dnsNames` precedent; (c) author
  a `Database` CR in your own layer/overlay. No other feature-step ever touches this
  step's storage manifests beyond that one append. Connect with
  `postgres://<slug>:<pw>@postgres-rw.storage.svc:5432/<slug>`.

- **The `DatabaseRole` CRD (CNPG 1.30, 2026-07) is a forward-looking watch-item, not
  this step's mechanism.** It promotes role management to its own namespaced CR to
  fix `managed.roles`' RBAC-scoping flaw, but its first cut supports **only**
  certificate-based auth — **no `passwordSecret` field** — and every Feature 5-7
  consumer needs a plain username/password DSN. Recorded so the plan/build don't
  reach for it; revisit when it gains password support.

### The shared Valkey instance and its recommended per-app ACL convention

- **The shared instance.** The official `valkey-io/valkey-helm` chart, **standalone
  mode** (default, one pod), in the `storage` namespace, persistence on `local-path`
  (`dataStorage.enabled: true`, `className: local-path`, a small `requestedSize`).
  Cluster mode / Sentinel are out of scope. `auth.enabled: true` with
  `auth.usersExistingSecret` pointing at the KSOPS-decrypted `smoke-valkey` Secret;
  the chart requires a `default` user be defined once auth is on (else
  unauthenticated access), so the users Secret carries both `default` and `smoke`
  passwords. The exact chart value keys and Service name are **build-time
  `research:public`** against the pinned chart README (`0.9.0` / appVersion `9.0.1`
  as the research-date reference; pin explicitly, not a floating tag).

- **The Valkey ACL convention is RECOMMENDED, not a mandated clause of the hard
  contract** (carried from the research reviewer's decision 2). The parent plan
  fixes the mandatory contract as "storage class + per-app Postgres DB/role naming"
  and is deliberately silent on Valkey; not every Feature 5-8 consumer uses Valkey,
  and a recommendation is the reversible direction (a later feature can tighten it
  to mandatory with real evidence; a mandate four consumers bound to cannot be
  cheaply loosened). The recommended pattern, parallel to but lighter than the
  Postgres contract: an ACL user named for the consumer's slug, scoped to that
  consumer's own key prefix — `auth.aclUsers.<slug>.permissions: "~<slug>:* +@all"`,
  password in the shared Valkey users Secret — reachable at
  `valkey.storage.svc:6379`.

### The permanent `smoke` fixture (this feature's reachability proof)

Because Storage has no pre-existing consumer, and ArgoCD's `prune`/`selfHeal` would
re-create anything a test tears down, the proof object is a **permanent, standing
fixture** deliberately slugged `smoke` — distinct from every Feature 5-8 app slug so
it never collides with a future real consumer. It is a minimal instance of the
consumption contract itself:

- **Postgres:** role `smoke` (a `managed.roles[]` entry in `postgres-cluster.yaml`,
  `passwordSecret: {name: smoke-db}`), database `smoke` owned by `smoke`
  (`smoke-database.yaml`), credential in
  `secrets/dev/storage/postgres/smoke.enc.yaml` as basic-auth Secret `smoke-db`.
- **Valkey:** ACL user `smoke` scoped `~smoke:* +@all` (in the Valkey release's
  `auth.aclUsers`), plus the required `default` user, both passwords in
  `secrets/dev/storage/valkey/smoke.enc.yaml` as users Secret `smoke-valkey`.

The `smoke` fixture's own `managed.roles`/`Database`/secret live in **this** step's
overlay (it is this step's proof object); later real consumers author their own in
their own layers, appending only their `managed.roles[]` line here.

### The committed-secret path convention

One convention for every committed storage credential, so the contract four later
features bind to is unambiguous: **`secrets/dev/storage/<store>/<slug>.enc.yaml`**,
where `<store>` is `postgres` or `valkey` and `<slug>` is the consuming app (or
`smoke` for the fixture). This is component-first (matching `DEVELOPMENT.md`'s
`secrets/dev/storage/postgres/…` grouping) with a per-slug filename, so a consumer
that uses both stores has one file per store (`postgres/keycloak.enc.yaml` and
`valkey/keycloak.enc.yaml`), each listed in the KSOPS generator's `files:`. It
refines `DEVELOPMENT.md`'s single illustrative `postgres/secret.enc.yaml` to a
per-slug filename because the one shared instance has many per-app credentials; the
in-cluster Secret *names* (`smoke-db`, `smoke-valkey`, and per consumer
`<slug>-db`/`<slug>-valkey`) are what the Cluster/`usersExistingSecret` references
and the feature test reads, independent of the file path.

### Sealing a per-app credential (the sops+age+KSOPS discipline, committed-Secret half)

The trust-root `sops-age` Secret is *injected* (`bootstrap.sh`, never committed);
this step's per-app credential is *committed, encrypted*. The sealing discipline
mirrors `bootstrap.sh`/`rotate-keys.sh` — **generate in memory, encrypt
immediately, never write plaintext to disk, never put a secret in argv or shell
history** — adapted to write ciphertext to the repo. The mechanism, spelled out so
the plan/build reproduce it exactly rather than re-improvising a security-sensitive
step:

- **The single-secret-value case (the Postgres `smoke-db` Secret).** Pipe an
  in-memory random password straight through `kubectl create secret` (reading the
  secret value from **stdin**, not argv) into `sops --encrypt`, writing only the
  ciphertext:

  ```bash
  openssl rand -base64 24 | tr -d '\n' \
    | kubectl create secret generic smoke-db -n storage \
        --type kubernetes.io/basic-auth \
        --from-literal=username=smoke \
        --from-file=password=/dev/stdin \
        --dry-run=client -o yaml \
    | sops --encrypt --filename-override secrets/dev/storage/postgres/smoke.enc.yaml \
        --input-type yaml --output-type yaml /dev/stdin \
    > secrets/dev/storage/postgres/smoke.enc.yaml
  ```

  `username` is not secret, so it may live in argv; the password enters only via
  stdin (`--from-file=password=/dev/stdin`), exactly as `bootstrap.sh` feeds the age
  key. `--filename-override` makes sops apply the `^secrets/dev/.*$` creation rule to
  stdin input (the filename sops sees would otherwise be `/dev/stdin` and match no
  rule). Plaintext exists only in the pipe buffer; only the encrypted file is
  written. The result is a `kind: Secret` carrying a `sops:` block — allowed by
  `secrets.rego`, denied if ever committed plaintext.

- **The multi-secret-value case (the Valkey `smoke-valkey` users Secret, keys
  `default` and `smoke`).** `kubectl create secret --from-file=…=/dev/stdin` reads
  only one stdin value, so a two-key Secret is built by piping a `stringData` YAML
  document — whose values come from in-memory `openssl rand` command substitutions —
  straight into `sops --encrypt` the same way. Those two values pass through shell
  variables/env rather than pure stdin (a minor, same-user-only exposure via
  `/proc/<pid>/environ`, versus `bootstrap.sh`'s pure pipe) — acceptable because
  these are ephemeral dev smoke credentials whose only committed form is ciphertext,
  and no lower-exposure single-pipe construction exists for a multi-key Secret. The
  plan may instead express both as two single-key Secrets if it prefers pure-stdin
  parity; the chart's `usersExistingSecret` expects one Secret with per-username
  keys, so the one-Secret form is the default.

Whether this sealing runs as inline build steps or a small committed reusable helper
(a `mise` task) is an Open Artifact Decision — the discipline is security-sensitive
and identical for every Feature 5-8 credential, which argues for a shared helper, but
the parent research reviewer's decision 5 (don't pre-scaffold for later features)
argues for keeping it minimal now.

### The `.sops.yaml` placeholder fix — IN SCOPE, and NOT via `rotate-keys`

`.sops.yaml`'s `secrets/dev/.*` rule still carries the literal placeholder
`AGE-PLACEHOLDER-REPLACE-WITH-REAL-agrippa-age-dev-PUBLIC-KEY` (live-verified). A
placeholder is not a valid `age` recipient, so `sops -e` cannot encrypt until it is
replaced — this blocks this step's credential path and every Feature 5-8 secret
after it. Fixing it is **in-scope build-time work for this feature-step** (the first
to commit an application-level encrypted Secret), genuinely actionable now: `bw` is
on PATH, the `.env` `BW_SESSION` still unlocks the vault, and the required key
already exists in Bitwarden.

**The correct fix is a plain, non-destructive edit — read the existing recipient,
write it into `.sops.yaml` via `yq`:**

```bash
recipient="$(bw get notes agrippa-age-dev | grep '^# public key: ' | sed -E 's/^# public key: //')"
SOPS_NEW_AGE="$recipient" \
  yq -i '(.creation_rules[] | select(.path_regex == "^secrets/dev/.*$") | .age) = strenv(SOPS_NEW_AGE)' .sops.yaml
```

This is the same `.sops.yaml` recipient write `rotate-keys.sh` performs in its
Stage 5 (a `yq -i` on the `secrets/dev/.*` rule's `age` field), minus the key
generation — no `age-keygen`, no `bw create`, no archival. It keeps `.sops.yaml`
consistent with the `sops-age` trust root already in the running cluster (seeded from
`agrippa-age-dev`'s private half by `bootstrap.sh`), whose public half is
`age1e8wr0f85w0yfqgxc3pc6426ghlu5xt069znn5yuwrtwz30u23quqjcx6vc`.

> **Do NOT run `mise run rotate-keys` / `scripts/rotate-keys.sh` to populate the
> placeholder.** `agrippa-age-dev` already exists in Bitwarden, so `rotate-keys.sh`'s
> item-existence check (line 47) fires: it prompts for a typed `rotate` confirmation
> and, if confirmed, **rotates** — archives the working key and mints a new one —
> desynchronising `.sops.yaml` (and any secret newly encrypted to it) from the trust
> root the cluster already holds, which would then fail to decrypt until `bootstrap`
> is re-run. `rotate-keys` is the tool for *rotating an existing key*, not for
> *populating a placeholder*. This distinction is recorded explicitly here so the
> plan and build phases do not reach for it by habit; the correct fix is the
> `yq` edit above.

### Extending the plaintext guard's coverage to `secrets/`

`DEVELOPMENT.md` § Secrets promises "a `conftest`/CI guard in `test:static` that
fails if any committed `kind: Secret` carries plaintext `data`/`stringData`." The
guard exists (`tests/policy/secrets.rego`, with self-tests) and is correct, but
`scripts/test-static.sh`'s manifest walk currently feeds it only `apps/` and
`charts/*/rendered/` — **not** the `secrets/` tree where committed secrets actually
live (live-confirmed). This step is the first to commit anything under `secrets/`, so
it is the step that must close that coverage gap, or the guard silently never sees
the very files it was written to protect.

The fix extends `scripts/test-static.sh` to also feed `secrets/` files to
**conftest** (the plaintext guard) — but **not** to `kubeconform -strict`: an
sops-encrypted Secret carries a top-level `sops:` block that `-strict` (which rejects
additional properties) would flag against the core Secret schema. So the edit builds
a separate `secrets/` file list run through conftest only. Exact form is a
build-phase edit re-verified against the live behavior; recorded here as a required
cross-step touch, not an optional one, because the security posture
`DEVELOPMENT.md` states depends on it.

### Cross-step touches (summary)

- **`.sops.yaml`** — replace the placeholder recipient with the existing
  `agrippa-age-dev` public key via the `yq` edit above (build-time prerequisite,
  non-destructive; **not** `rotate-keys`).
- **`storage/overlays/dev/kustomization.yaml`** — replace `resources: []` with the
  real composition.
- **`secrets/dev/storage/…`** — new committed, sops-encrypted Secrets plus their
  KSOPS generator kustomization (this step's own path only; no pre-scaffolding for
  Features 5-8, per research reviewer decision 5).
- **`apps/storage.yaml`** — add `syncOptions: [ServerSideApply=true,
  SkipDryRunOnMissingResource=true]` to its `syncPolicy` (CNPG's large `Cluster` CRD
  and CRD-before-CR ordering need it, exactly as `apps/core.yaml` carries it). If a
  CNPG controller-owned field causes a perma-`OutOfSync`, add a narrowly-scoped
  `ignoreDifferences` and/or `compare-options: ServerSideDiff=true` — anticipated,
  confirmed at build, mirroring `apps/core.yaml`.
- **`scripts/test-static.sh`** — extend the conftest walk to cover `secrets/` (not
  kubeconform-strict), so the plaintext guard covers the secrets tree.
- **`scripts/test-feature.sh`** — add `storage.bats` to the probe-suite exclusion
  `case` list (it drives the long-lived `agrippa-dev` cluster and the
  GitOps-reconciled `storage` layer, not the throwaway `agrippa-feature` cluster) —
  the same one-line, convention-consistent edit `networking.bats` and its siblings
  already made. **This exclusion lands with the feature test in the design phase**
  (mirroring Networking): the test is committed now, so without it `mise run
  test:feature` would pick `storage.bats` up and loop against a datastore-less
  cluster before failing.
- **`mise.toml`** — no new tool pins (see Libraries & Skills).

### Challenges

- **Version pins deferred to build.** The CNPG operator chart version, the CNPG
  operand PostgreSQL major/image (≥ 17.6 on the 17 line), and the Valkey chart
  version are build-time `research:public`, consistent with how `networking-istio`
  deferred its own upstream chart versions and release tags. Pin explicitly; do not
  float tags.
- **Exact CRD field and chart-value spellings.** The CNPG `Cluster`/`Database`
  field paths (`spec.managed.roles[]`, `spec.storage.storageClass`, `Database.spec.
  owner`/`.cluster.name`, and the primary-pod / PVC label keys the feature test
  selects on) and the Valkey chart's `auth.aclUsers`/`usersExistingSecret`/
  `dataStorage` keys and its Service name are build-verified against the pinned
  versions. The design fixes the shapes and names; the build confirms the exact
  spellings and corrects the feature-test selectors if a label differs (the test is
  RED now regardless).
- **`helm template` semantics.** `helmCharts:` inflation runs `helm template` (no
  hooks, no cluster `lookup`) — the correct GitOps behavior. Confirm at build that
  neither the CNPG operator chart nor the Valkey chart relies on a hook/`lookup` the
  templated path drops (e.g. a post-install job); the CNPG operator installs cleanly
  this way in practice, but verify.

## Alternatives

- **Bitnami `postgresql` / `valkey` charts.** Rejected on the cleared research:
  Broadcom's 2025 restructuring moved them behind a paid "Bitnami Secure Images"
  subscription, leaving only a frozen, unpatched legacy snapshot — no longer a free
  default for a project starting now (`research/public.md` § Falsification pass).
- **Postgres as a plain StatefulSet/Deployment chart instead of the CNPG operator.**
  Rejected: it would hand-roll what CNPG does declaratively — continuously-reconciled
  databases and roles with drift reversion, credential reconcile from a Secret
  reference, health/primary management — and would not match the operator-plus-CRs
  shape `core` already established for cert-manager and metallb. CNPG is the option
  every current source recommends over the paywalled Bitnami chart.
- **One Postgres instance per app (instance-per-tenant) instead of one shared
  instance with per-app databases.** Rejected: full isolation at much higher
  operational overhead for no benefit at this scale (a handful of internal platform
  services). Database-per-tenant on one shared instance is the standard middle
  ground and matches `ARCHITECTURE.html`'s already-stated intent.
- **CNPG's new `DatabaseRole` CRD (1.30) for per-app roles.** Rejected as the
  mechanism (kept as a watch-item): its first cut has no `passwordSecret` field —
  certificate-auth only — and every Feature 5-7 consumer needs a username/password
  DSN. The stable `managed.roles` + `Database` pair covers the actual need.
- **A throwaway create-and-teardown proof object instead of the permanent `smoke`
  fixture.** Rejected: ArgoCD's `prune`/`selfHeal` (live on `apps/storage.yaml`)
  would re-create any declaratively-authored resource a test tears down, so a
  throwaway fights the reconciler. A permanent standing fixture exercises the whole
  contract continuously, matching Networking's proof against a live target.
- **`mise run rotate-keys dev` to populate the `.sops.yaml` placeholder.** Rejected
  as destructive (see Specification § The `.sops.yaml` placeholder fix): the key
  already exists, so `rotate-keys` would rotate it and desync the live trust root. A
  plain `yq` edit reading the existing recipient is the non-destructive fix.
- **Relaxing the repo-server load restrictor (`--load-restrictor
  LoadRestrictionsNone`) so a generator can read the encrypted files directly across
  directories.** Rejected in favor of the self-contained `secrets/dev/storage/`
  sub-kustomization referenced as a resource: it needs no repo-server config change,
  keeps every file reference within a kustomization root, and establishes a pattern
  Features 5-8 reuse without loosening a global safety setting.
- **Mandating the Valkey per-app ACL convention as part of the hard shared
  contract.** Rejected in favor of a recommendation (research reviewer decision 2):
  the mandatory contract is deliberately minimal ("storage class + per-app Postgres
  DB/role naming"); not every consumer uses Valkey, and a recommendation is the
  reversible direction.

## Summary

This feature-step lands the shared datastore layer into the already-Synced
`storage` layer — the CloudNativePG operator in `cnpg-system`, one shared Postgres
`Cluster` named `postgres` on `local-path` in a `storage` namespace, and one shared
standalone Valkey instance — composed under the **single existing `storage`
Application** as one KSOPS+Helm `kustomize build` (flat `storage/overlays/dev/`,
per-component `helmCharts:` subdirs plus authored CRs, ordered by a four-tier
intra-`storage` sync-wave scheme this step defines). Above all it **defines the
storage-class + per-app DB/role naming shared contract** every Feature 5-8 consumer
binds to: database name = role name = the consuming app's own slug, provisioned by a
`Cluster.spec.managed.roles[]` append (the shared, append-only list, mirroring
Networking's Gateway `dnsNames` precedent) plus a self-owned `Database` CR, with the
recommended lighter Valkey `~<slug>:*` ACL-user extension alongside. It also
establishes the project's first committed application-level sops-encrypted Secret and
its KSOPS `generators:` wiring, fixes `.sops.yaml`'s placeholder recipient
non-destructively (explicitly **not** via `rotate-keys`), and closes the plaintext
guard's `secrets/`-coverage gap. The one feature test proves the whole contract
end-to-end against a permanent `smoke` fixture: a shared instance Healthy on
local-path, an isolated declaratively-managed database and role reachable with a
KSOPS-decrypted credential, and an ACL-scoped Valkey user.

This Design-phase run does **not** deploy the Storage content: reconciling it
requires a full ArgoCD sync of newly-committed charts and CRs, the `.sops.yaml` fix
and credential sealing are build-phase prerequisites, and the exact chart versions,
CRD field spellings, and chart-value keys want live re-verification at build time.
The feature test is therefore left **RED** (baseline recorded below); the build phase
turns it green after fixing `.sops.yaml`, sealing the credentials, committing the
`storage` composition, and letting ArgoCD reconcile it.

### Open Artifact Decisions

Concrete artifact choices this design invents that are not fixed by a skill
template, an existing project convention, or the cleared `research.md` (whose
reviewer block already settled the CNPG/Valkey chart choice, the single-shared-instance
model, the slug naming pattern, the permanent-`smoke`-fixture shape, the
`cnpg-system`/`storage` namespaces and the `postgres` Cluster name, the flat-overlay
layout, the deferred version pins, the `secrets/dev/storage/` own-path-only scope,
and the `.sops.yaml` fix mechanism — all stated above as conclusions, not surfaced
here).

**The credential Secret and KSOPS-generator artifact names —
`smoke-db` (Postgres basic-auth Secret), `smoke-valkey` (Valkey users Secret), and
the `secret-generator.yaml` / `kind: ksops` generator resource:** the concrete
spellings the feature test and the Cluster/`usersExistingSecret` references bind to.
Proposed: as named throughout the Specification (`<slug>-db` / `<slug>-valkey`
Secret names, `smoke-db` / `smoke-valkey` for the fixture), following the `smoke`
fixture slug. Recorded here because the feature test binds to these exact names.

**The committed-secret path convention — `secrets/dev/storage/<store>/<slug>.enc.yaml`
(component-first, per-slug filename):** refines `DEVELOPMENT.md`'s single
illustrative `secrets/dev/storage/postgres/secret.enc.yaml` so the one shared
instance's many per-app credentials each get a distinct file, and so the contract
Features 5-8 bind to has one unambiguous home per (store, consumer).
Proposed: as stated in Specification § The committed-secret path convention
(`postgres/smoke.enc.yaml`, `valkey/smoke.enc.yaml` for the fixture;
`postgres/<slug>.enc.yaml`, `valkey/<slug>.enc.yaml` per consumer). The alternative
— slug-first (`secrets/dev/storage/<slug>/…`) — was rejected because it diverges
from `DEVELOPMENT.md`'s `postgres/` grouping. Confirm the refinement fits intent.

**The overlay's authored-CR and namespace file names — `postgres-cluster.yaml`,
`smoke-database.yaml`, `namespace.yaml`, and the `cnpg-operator/` and `valkey/`
subdir names:** the internal file layout of `storage/overlays/dev/`.
Proposed: as in the Specification's layout block, mirroring `core/overlays/dev/`'s
per-component-subdir-plus-top-level-CR shape. Reversible; a rename touches only this
step's own files.

**How the encrypted secrets are wired into `kustomize build` — a self-contained
`secrets/dev/storage/` sub-kustomization referenced as a `resources:` entry, vs.
relaxing the repo-server load restrictor to read the files cross-directory.**
Proposed: the self-contained sub-kustomization (no repo-server config change, stays
within kustomize's default load restrictor, establishes a reusable pattern). This is
the first committed encrypted Secret, so the wiring is genuinely invented here and
consumed by Features 5-8.

**Where the credential-sealing discipline lives — inline build steps vs. a small
committed reusable helper (a `mise` task, e.g. `seal-secret`).** Proposed: leave it
as documented inline build steps for now (research reviewer decision 5: don't
pre-scaffold for later features), while noting that a shared helper is the DRY home
for a security-sensitive discipline four later features repeat — a judgment the plan
phase may take either way.

### Resolved by the long-loop reviewer (2026-07-08)

This block resolves, in one pass per Ailly's Draft Gate Enforcement convention, this
design's five Open Artifact Decisions above. A separately dispatched long-loop reviewer
read this feature-step's `design.md` cold, re-verified its load-bearing claims against
the working tree and the running `k3d-agrippa-dev` cluster, and researched each open item
against the in-repo contracts (`DEVELOPMENT.md` § Secrets; `apps/platform/argocd/
kustomization.yaml`'s committed KSOPS repo-server patch; `tests/policy/secrets.rego`; the
realized `core/overlays/dev/` layout; `tests/storage.bats`), the cleared parent
`design.md`/`plan.md`, and this feature's cleared `research.md` reviewer block. Each was
decided to the conservative, reversible default. **No separate design-intent review
exists for this feature-step** (no `reviews/` subfolder — checked), so there are no
intent-review OPEN questions to fold in; this pass resolves only the design's own five
items. The CNPG-operator, single-shared-instance, database=role=slug, and permanent-`smoke`-fixture
decisions inherited from the cleared `research.md` were checked for faithful transcription
and are carried through unchanged — the sole design-phase refinement of an inherited
default is item 2's per-slug filename, resolved below. No escalation trigger (irreversible,
out of recorded scope, or underdetermined) fired, so this draft gate is cleared (marker now
`*Reviewed 2026-07-08*`). The live cluster was **read only** (the `storage` Application
`Synced/Healthy` on its empty `resources: []` placeholder, the absent CNPG/Valkey CRDs
confirming the RED baseline, and `argocd-cm`'s `kustomize.buildOptions`) and left exactly
as found — nothing was installed, and the `storage` layer remains Synced/Healthy on the
placeholder.

**1. The credential Secret and KSOPS-generator artifact names (`smoke-db`,
`smoke-valkey`, `secret-generator.yaml`, `kind: ksops`). Decided: accept the proposed
spellings unchanged.** The feature test already binds to these exact names —
`tests/storage.bats` reads Secret `${SLUG}-db` = `smoke-db` and `${SLUG}-valkey` =
`smoke-valkey` (verified in the committed RED test this session) — so they are the
conservative default by virtue of being the names the RED baseline was captured against;
any other spelling would silently desync the test. `kind: ksops` (apiVersion
`viaduct.ai/v1`) is not a free choice: it is KSOPS's required generator kind, matching the
`viaductoss/ksops` install the committed repo-server patch provides. `secret-generator.yaml`
is a local filename internal to this step. Reversible (a rename touches only this step's
own files plus one test constant); in recorded scope; determined by the committed test.

**2. The committed-secret path convention `secrets/dev/storage/<store>/<slug>.enc.yaml`
(component-first, per-slug filename). Decided: accept it.** Component-first (`postgres/…`,
`valkey/…`) is exactly `DEVELOPMENT.md` § Secrets' own grouping
(`secrets/dev/storage/postgres/…`); the design only refines that section's single
illustrative `secret.enc.yaml` to a per-slug `<slug>.enc.yaml`, which the one-shared-instance
model forces — the one `postgres` Cluster carries many per-app credentials, so each needs a
distinct file. The slug-first alternative (`secrets/dev/storage/<slug>/…`) is correctly
rejected for diverging from `DEVELOPMENT.md`'s grouping. `.sops.yaml`'s existing
`^secrets/dev/.*$` creation rule already matches every such path (verified live — still the
placeholder recipient, but the path regex is correct), so no per-path sops config is
needed. This is the contract four features bind to, yet it stays reversible: only this step
commits files under it now; Features 5-8 simply follow the documented pattern when they
land. This refines — does not contradict — research reviewer decision 5, whose
`secret.enc.yaml` was an explicitly inheritable-and-refinable default, not locked.
Conservative default = follow the existing `DEVELOPMENT.md` grouping with the minimal
refinement the shared-instance model requires.

**3. The overlay's authored-CR and namespace file names (`postgres-cluster.yaml`,
`smoke-database.yaml`, `namespace.yaml`, and the `cnpg-operator/` / `valkey/` subdir
names). Decided: accept as proposed.** They mirror the realized `core/overlays/dev/`
layout one-for-one (per-component subdirs carrying the `helmCharts:` inflation, top-level
authored-CR files), which research reviewer decision 3 fixed as this step's layout and
which `networking-istio` established as cleared precedent. Fully reversible — as the design
itself notes, a rename touches only this step's own files. In scope; determined by the
sibling precedent.

**4. How the encrypted secrets are wired into `kustomize build` — a self-contained
`secrets/dev/storage/` sub-kustomization referenced as a `resources:` entry vs. relaxing
the repo-server load restrictor. Decided: the self-contained sub-kustomization.** Because
this wiring is what four later features reuse, it was verified against the *actual*
committed KSOPS mechanism rather than accepted on assertion. `apps/platform/argocd/
kustomization.yaml`'s repo-server patch installs KSOPS as a kustomize **exec generator**
(the `viaductoss/ksops` binaries mounted over the repo-server's own, the `sops-age` Secret
mounted with `SOPS_AGE_KEY_FILE=/.config/sops/age/key.txt`), and `argocd-cm`'s
`kustomize.buildOptions` is live-confirmed as `--enable-alpha-plugins --enable-exec
--enable-helm` — exactly the flags a `generators:`-declared `kind: ksops` manifest needs,
plus `--enable-helm` for the two `helmCharts:` inflations. The design's construction is
coherent with that mechanism: placing the `kind: ksops` generator manifest and its
`postgres/smoke.enc.yaml` / `valkey/smoke.enc.yaml` targets together inside
`secrets/dev/storage/` keeps every `files:` reference within one kustomization root
(satisfying kustomize's default `LoadRestrictionsRootOnly`), and the overlay reaches them
through a `resources: [../../../secrets/dev/storage]` sub-kustomization reference — the same
cross-directory kustomization reference the standard `overlays/dev → ../../base` shape
relies on, which the root-only restrictor permits (it restricts *file* loads, not
directory-kustomization references). So the plan does **not** dead-end: no repo-server
config change, no global-safety-setting loosening, and it establishes the exact
`generators:` pattern Features 5-8 copy. Relaxing `--load-restrictor LoadRestrictionsNone`
is rightly rejected — a second mutation of Feature 2's cleared repo-server config that
would loosen a global safety setting for every Application. Reversible, in scope, determined
by the committed KSOPS wiring.

**5. Where the credential-sealing discipline lives — inline build steps vs. a small
committed reusable `mise` helper (e.g. `seal-secret`). Decided: inline build steps for this
feature-step; keep the `mise` helper as a recorded, deferrable option the plan may still
elect.** The governing convention is research reviewer decision 5 (don't pre-scaffold for
later features) and the project's consistently-applied YAGNI posture (Networking defined its
contract without pre-building consumer HTTPRoutes; research decision 5 declined to
pre-create `secrets/` dirs for Features 5-8). The sealing discipline is already fully
specified inline — both the single-value pure-stdin case and the multi-value case are
written out in § Sealing a per-app credential — so the plan/build reproduce it exactly
without a helper. A `mise seal-secret` task is the right DRY home for a security-sensitive
step four features repeat, but building it now is speculative parameterization for consumers
whose designs do not yet exist; the honest extraction happens on the rule-of-three, when
Feature 5 first actually repeats it and reveals the correct interface. Extraction later is a
cheap, reversible refactor, and the design already frames this as "a judgment the plan phase
may take either way," so this decision preserves that latitude rather than foreclosing it.
Conservative default = inline now, extract when a second real caller proves the shape.
Reversible, in scope, determined by the standing convention.

## Feature Test

**Path:** `tests/storage.bats` (following `DEVELOPMENT.md`'s `tests/<feature>.bats`
convention, feature = "storage"; the `-postgres-valkey` qualifier is dropped just as
`cluster-core.bats` dropped `-k3d`, `gitops.bats` dropped `-argocd`, and
`networking.bats` dropped `-istio`).

**User story (Given / When / Then):** *Given* the bootstrapped long-lived
`agrippa-dev` cluster (Features 1-2) with this Storage content committed and
reconciled by ArgoCD into the `storage` layer — the CNPG operator, the single shared
Postgres `Cluster` `postgres` on `local-path`, the shared standalone Valkey instance,
and the permanent `smoke` fixture (database `smoke` owned by role `smoke`, Valkey ACL
user `smoke` scoped `~smoke:*`) standing in for a future per-app consumer, *When* an
operator connects to database `smoke` as role `smoke` using the sops-encrypted
credential (decrypted by KSOPS into the `storage` namespace) and authenticates to
Valkey as ACL user `smoke`, *Then* the shared Postgres instance is Healthy on a
`local-path` PVC, the `smoke` database exists and is owned by role `smoke` with the
committed credential working (proving the `Database` CR + managed role + KSOPS
credential path end-to-end), and the Valkey `smoke` user can write within `~smoke:*`
but is denied outside it (proving the per-app ACL isolation) — the storage-class +
per-app DB/role naming shared contract, proven end-to-end. Like its sibling suites it
deliberately does **not** tear the cluster, the datastores, or the `smoke` fixture
down.

**Current state: RED (baseline captured this run).** With `storage/overlays/dev`
still the empty `resources: []` placeholder, the `storage` Application is already
`Synced/Healthy` on that empty content (live-confirmed) — so the suite's THEN 0
precondition (`storage` Synced/Healthy) passes even now, exactly as Networking's THEN
0 passed on empty `core`. The RED comes at THEN 1 onward: no CNPG CRDs exist, no
`storage` namespace exists, and `kubectl get cluster.postgresql.cnpg.io postgres -n
storage` fails, so the suite fails there. That red state defines "done." This
Design-phase run does **not** turn it green: the `.sops.yaml` fix, the credential
sealing, committing the `storage` composition, and the ArgoCD reconcile are all
build-phase work outside this phase's write-only-the-test gate.
