# Feature Design: Git hosting (Forgejo server, Postgres-backed)

> Feature-step design (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 6: Git hosting (Forgejo)**
> of that project's plan: a Postgres-backed platform service landing in the
> `platform` layer (sync-wave 2), alongside two parallel siblings — Feature 5
> (Auth/Keycloak) and Feature 7 (Feature flags/Flagsmith) — that share the
> storage-class + per-app DB/role naming contract Storage (Feature 4) defined
> and the Gateway/HTTPRoute/hostname/TLS contract Networking (Feature 3)
> defined, both already live. It has its own feature test (recorded below). The
> project as a whole is measured by `closing-bell.md`, not by this test.
>
> Its research (`research.md`, `research/public.md`, `research/codebase.md`) is
> Reviewed; the reviewer block there (`Resolved by the long-loop reviewer`)
> settled the six open items — decisively, **forgejo-runner/Actions is deferred
> for this build and the Forgejo server lands alone** — and those decisions are
> carried in as settled inputs below, not re-litigated. This is a **long-loop**
> run: the draft gate is left open for a separately dispatched reviewer to
> clear.

## Libraries & Skills (carry forward to plan and build)

Per the project's cleared `research.md` (§ Libraries & Skills), this
feature-step's own cleared `research.md` (§ Libraries & Skills), and the project
`design.md`, the plan and build phases MUST load these skills via the harness's
skill-loading mechanism before working:

- **`developer:initialize`** — for any residual `mise` tool-pin work. This
  feature adds **no** new mise-managed CLI: the Forgejo chart is an in-cluster
  resource ArgoCD reconciles via Helm inflation, not a local tool; the admin and
  DB credentials are sealed with `openssl`/`kubectl`/`sops`, all already pinned
  in `mise.toml`. (The forgejo-runner registration secret, which would have used
  `openssl rand -hex 20`, is out of scope this build — see § the deferral.)
- **`research:public`** and **`research:codebase`** — for the per-tool detail
  the build defers to build time: the exact Forgejo chart version pin, the exact
  `gitea.config`/`additionalConfigFromEnvs`/`admin.existingSecret` value-key
  spellings against that pinned chart, and the Forgejo API paths the feature
  test drives.

**No library-shipped agentic skill exists for Forgejo, CloudNativePG, the
official Valkey chart, sops, age, or KSOPS** (both the project research and this
feature's research recorded the deliberate per-tool check). Build to the in-repo
contracts: `ARCHITECTURE.html` (§ Platform layer / Git Hosting view — the
`git.davidsouther.com` hostname), `DEVELOPMENT.md` (§ Secrets — the sops/age/
KSOPS wiring), and the two most-recently-completed sibling designs —
`storage-postgres-valkey` (the DB/role naming contract, the credential-sealing
shell recipes, the KSOPS `generators:` wiring, the permanent-fixture proof style)
and `networking-istio` (the Gateway/HTTPRoute/hostname/TLS contract and the
shared append-only `dnsNames` list) — are the authoritative contracts this
feature-step builds to.

## Purpose

Stand up **Forgejo** (self-hosted Git hosting) as a Postgres-backed,
Helm-delivered workload in the already-live `platform` layer, reachable through
the shared Istio Gateway at its dev hostname, with its initial admin credential
and its database credential both sealed with the project's sops+age+KSOPS
discipline. This is the k3d-local equivalent of roadmap item 6's "code hosting ·
`git.davidsouther.com`."

The deliverable is:

1. **The official Forgejo Helm chart** (`code.forgejo.org/forgejo-helm/
   forgejo-helm`, OCI-distributed), inflated via `helmCharts:` inside a new
   `platform/overlays/dev/forgejo/` subdirectory and appended as one
   `resources:` entry to the shared `platform/overlays/dev/kustomization.yaml`
   — the same per-component-subdirectory composition `core` and `storage`
   already use. As of chart v14 the chart ships **no bundled Postgres/Redis
   subchart**, so "external datastore only" is simply the chart's only supported
   shape, not a flag fighting a default.
2. **Forgejo's own Postgres database and role** — a second `managed.roles[]`
   entry plus a `Database` CR on the already-live shared `postgres` Cluster,
   following Storage's `smoke` fixture's exact proven shape (slug `forgejo`:
   database name = role name = `forgejo`). Forgejo's `gitea.config.database`
   carries the plain `app.ini` keys (`DB_TYPE`, `HOST`, `NAME`, `USER`) and the
   password is injected from a sealed Secret, never a literal.
3. **A sealed initial-admin credential** referenced by `gitea.admin.
   existingSecret`, generated and sops-encrypted with the identical shell recipe
   Storage's `smoke-db` credential already established and proved live.
4. **One `HTTPRoute`** at `git.davidsouther.com.127.0.0.1.nip.io`, attached to
   the shared `agrippa-gateway`, plus one appended entry to the shared Gateway
   certificate's `dnsNames` — consuming Networking's contract exactly, adding no
   new Gateway/TLS infrastructure.

The value is narrow but real: an operator gets a working self-hosted Git server
— they can reach its web UI/API at the dev host over local-CA TLS, log in with
the sealed admin credential, create a repository, and push commits to it. Git
hosting rounds out the platform-services tier (alongside Auth and Feature flags)
that the project's Purpose commits to as part of the unified whole; no standalone
Closing Bell task names Git hosting directly.

**forgejo-runner (Actions/CI) is explicitly deferred** to a documented follow-up
increment — decided by the cleared research reviewer, not open here (§ The
deferred runner, and Alternatives). GitHub push-mirroring is confirmed to need
**zero** cluster wiring and is an opt-in, per-repository operator action, out of
this build's scope.

## Prior Art

- **`storage-postgres-valkey` (Feature 4), live.** The authoritative in-repo
  pattern this step consumes: the shared CNPG `Cluster` `postgres` in namespace
  `storage`, with its per-app DB/role naming contract (a `managed.roles[]`
  append + a self-owned `Database` CR, database name = role name = the app's
  slug) and its committed-encrypted-Secret + KSOPS `generators:` wiring. Storage
  is *also* the model for this step's own reachability proof: its permanent
  `smoke` fixture proves a contract end-to-end against a live client, exactly the
  shape this step's feature test mirrors for Forgejo's own function. The
  copy-pasteable sealing shell recipe (`openssl rand … | kubectl create secret …
  --from-file=…=/dev/stdin --dry-run=client -o yaml | sops --encrypt
  --filename-override … > secrets/dev/…`) is reused verbatim for both this step's
  credentials.
- **`networking-istio` (Feature 3), live.** Defines the Gateway/HTTPRoute/
  hostname/TLS contract this step consumes for exposing Forgejo's web UI: the
  `agrippa-gateway` in `istio-ingress` terminating TLS on `:443`, the
  `<prod-host>.127.0.0.1.nip.io` hostname scheme, the `agrippa-ca` local-CA
  issuer, and the one shared `agrippa-gateway-tls` certificate with an
  explicit-SAN `dnsNames` list every later UI feature appends one line to. The
  consumption contract is fixed: create one `HTTPRoute` in your namespace with
  `parentRefs` to `agrippa-gateway` (`sectionName: https`) at your dev host, and
  append that host to `agrippa-gateway-tls`'s `dnsNames`. No ReferenceGrant is
  needed. This step is one such consumer.
- **The `platform` layer skeleton (`gitops-argocd`, Feature 2), live.**
  `apps/platform.yaml` (sync-wave 2) points at `platform/overlays/dev`, whose
  only `resources:` entry today is `argocd.yaml` (ArgoCD self-management). Its
  own header comment names Keycloak/Forgejo/Flagsmith as "later feature-steps'
  added resources here." `kubectl -n argocd get application platform` →
  `Synced/Healthy`; no `forgejo` namespace exists yet. This step adds one
  `resources:` entry, mirroring the append-only-list precedent already set twice
  (Networking's Gateway `dnsNames`, Storage's `managed.roles[]`).
- **The KSOPS+Helm repo-server wiring (`gitops-argocd`), live and unchanged.**
  `argocd-cm`'s `kustomize.buildOptions` is `--enable-alpha-plugins
  --enable-exec --enable-helm` and the `ksops` binary is mounted at both paths
  (Storage's build-time fix). This step needs **zero** repo-server changes —
  purely additive `resources:`/`helmCharts:`/`secrets:` content.
- **External worked examples** (full IEEE citations in `research/public.md`):
  the chart's `gitea.admin.existingSecret`/`passwordMode` schema and its
  `additionalConfigFromEnvs`/`additionalConfigSources` external-database-
  credential indirection [4][5]; confirmation the chart ships no bundled
  datastore since v14 [4][5]; and the confirmed zero-cluster-footprint of GitHub
  push-mirroring [15].

## User Journey and Metrics

**The operator's flow, from the bootstrapped `agrippa-dev` cluster (Features
1-4) with this Forgejo content committed and ArgoCD reconciling `platform`:**

1. ArgoCD syncs the `platform` layer: the `forgejo` namespace comes up, CNPG
   creates the `forgejo` database and role from the sealed credential, and the
   Forgejo Deployment reaches Ready backed by that database on a `local-path`
   PVC. The operator runs `kubectl -n argocd get application platform` and sees
   it **Synced/Healthy**.
2. The operator opens `https://git.davidsouther.com.127.0.0.1.nip.io/` in a
   browser (or `curl -k`): the request goes host `:443` → k3d port-map → node IP
   via the Gateway's `externalIPs` → gateway pods → the `forgejo` HTTPRoute →
   the Forgejo Service, TLS terminated at the Gateway with the local-CA cert. The
   Forgejo web UI renders (browser shows the by-design untrusted-CA warning;
   `curl -k` accepts it).
3. The operator signs in with the **sealed admin credential** (username +
   password from the KSOPS-decrypted `forgejo-admin` Secret), creates a
   repository, and `git push`es a commit to it over HTTP. The repo and its
   commit persist (in Postgres + the PVC) — proving the whole path: Gateway →
   Forgejo → sealed admin auth → Postgres write → git object storage.

**The consumption seam for a later increment:** the deferred forgejo-runner
appends, with zero rework to the server that lands now — a runner Deployment, a
sops-sealed 40-hex registration secret, and a registration mechanism against
this live Forgejo instance (research § Search/Expand and `research/public.md`
[13][14] remain the starting point).

**Metrics / measures of done for this feature-step:**

- The feature test (`tests/git-hosting.bats`) is green: `platform` is
  Synced/Healthy with Forgejo reconciled; Forgejo's API is reachable through the
  Gateway at its dev host over local-CA TLS; an authenticated API call with the
  sealed admin credential succeeds; and a repository can be created and pushed to
  — proving Git hosting is live and usable. **No runner/Actions/CI assertion**
  (deferred).
- `kubectl -n argocd get application platform` is **Synced/Healthy** with the
  Forgejo Deployment, its `Database`/role, and its `HTTPRoute` all reconciled.
- Adding this step does not regress earlier harness: `mise run test:push`
  (`test:static` + `test:policy` + `test:chart`), `mise run test:feature`, and
  `bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats
  tests/storage.bats tests/rotate-keys.bats` stay green (the `git-hosting.bats`
  `test:feature` exclusion lands with the test).

**Per-component SLO (defined here, watched in Grafana once Observability lands;
not a CI step, per `DEVELOPMENT.md`).** Git hosting is a developer-facing
platform service, not on the critical request path, so its budget is looser than
the infrastructure layers'. Target over a rolling 28-day window once Feature 8
provides Prometheus/Grafana: **Forgejo's HTTP endpoint returns non-5xx ≥ 99.5%**
of the time (from Istio gateway telemetry for the `git.*` host,
`istio_requests_total`), and **the Forgejo→Postgres connection is up ≥ 99.9%**
(the shared Postgres SLO Storage already defines covers the datastore half).
Burn-rate alert at 2% budget consumed in 1h. Recorded here, instrumented when
Observability lands; not asserted by the feature test.

**Failure modes to design against.**

- **The Forgejo pod crash-looping because its DB credential never resolved** —
  KSOPS decrypts but the `additionalConfigFromEnvs` key name is wrong, or the
  role/database is not yet reconciled. Mitigated by the intra-`forgejo`
  sync-wave ordering (secret and DB before the Deployment) and by the feature
  test asserting an *authenticated* API call and a real push, not merely that
  the pod exists.
- **A permanent `platform`-OutOfSync from a controller-defaulted field** — the
  known argoproj/argo-cd#22151 symptom where `ServerSideApply=true` alone leaves
  a resource perpetually OutOfSync. Mitigated by adding **both**
  `syncOptions: [ServerSideApply=true, SkipDryRunOnMissingResource=true]` **and**
  the `argocd.argoproj.io/compare-options: ServerSideDiff=true` annotation to
  `apps/platform.yaml` — the exact pair `apps/core.yaml` and `apps/storage.yaml`
  both already carry (see § The `apps/platform.yaml` sync seam).
- **The Forgejo web UI unreachable through the Gateway** — a missing `dnsNames`
  SAN append (the cert would not cover the git host), or an HTTPRoute
  `parentRefs`/`sectionName` mismatch. Mitigated by the feature test's curl
  through the real `:443` port-map with the served cert checked for the local-CA
  issuer.
- **A committed plaintext Secret slipping past CI** — closed already by Storage,
  which extended `test:static`'s conftest walk to cover `secrets/`; this step
  simply adds files under that already-guarded tree.
- **`helm template` dropping a chart hook.** `helmCharts:` inflation runs `helm
  template` (no hooks, no cluster `lookup`). Research found the Forgejo chart's
  install is a plain Deployment + Service + PVC + ConfigMap/Secret shape with no
  hook the templated path would silently drop; **re-verify against the pinned
  chart version at build**.

## Specification

### Composition: one more `resources:` entry under the live `platform` Application

Following `storage/overlays/dev/`'s realized layout, Forgejo composes as a
**per-component subdirectory** `platform/overlays/dev/forgejo/` whose
`kustomization.yaml` carries a `helmCharts:` block inflating the upstream chart,
alongside authored CR files, ordered by an intra-`forgejo` sync-wave scheme. The
subdirectory is appended as **one entry** to the shared `platform/overlays/dev/
kustomization.yaml` `resources:` list. The proposed layout (object/file names
are Open Artifact Decisions where noted):

```text
platform/overlays/dev/
├── kustomization.yaml            # resources: [argocd.yaml, forgejo]  <- append `forgejo`
│                                 #   (shared file; Auth & Flagsmith append their own
│                                 #    entries; coordinator sequences the three appends)
└── forgejo/
    ├── kustomization.yaml        # helmCharts: [forgejo]; resources: the CRs + secrets kustomization
    ├── namespace.yaml            # wave -10; Namespace forgejo (helm template emits none)
    ├── forgejo-database.yaml     # wave 5; CNPG Database `forgejo` (ns storage; owner/cluster)
    ├── httproute.yaml            # wave 0; HTTPRoute `forgejo` (ns forgejo) -> forgejo Service
    └── (helmCharts: forgejo)     # wave 0; the Forgejo Deployment/Service/PVC/ConfigMap (ns forgejo)

secrets/dev/platform/forgejo/     # referenced by the forgejo overlay as a sub-kustomization
├── kustomization.yaml            # wave -5; generators: [secret-generator.yaml]
├── secret-generator.yaml         # kind: ksops; files: [admin, db-storage, db-forgejo].enc.yaml
├── admin.enc.yaml                # Secret `forgejo-admin` (ns forgejo; username/password)
├── db-storage.enc.yaml           # basic-auth Secret `forgejo-db` (ns storage; for CNPG's role)
└── db-forgejo.enc.yaml           # Secret `forgejo-db` (ns forgejo; same pw, for the pod)
```

(The `core/overlays/dev/gateway-cert.yaml` `dnsNames` SAN append and the
`storage/overlays/dev/postgres-cluster.yaml` `managed.roles[]` append are edits
to sibling-owned files, listed under Cross-step touches — not part of this
step's own subtree above.)

Two touch points on shared, sibling-owned lists — **not owned by this step**:

- **The shared `postgres` Cluster's `managed.roles[]`** (in `storage/overlays/
  dev/postgres-cluster.yaml`) gains one appended entry `{name: forgejo, login:
  true, passwordSecret: {name: forgejo-db}}` — the exact shape of the live
  `smoke` entry, changing only the slug. (The `forgejo-db` Secret and the
  `forgejo` `Database` CR it needs are this step's own, created into the
  `storage` namespace by the `platform` Application — see § The cross-namespace
  DB credential.)
- **The shared `agrippa-gateway-tls` certificate's `dnsNames`** (in
  `core/overlays/dev/gateway-cert.yaml` — the networking layer lives under
  `core/overlays/dev/`, verified live) gains one appended entry
  `git.davidsouther.com.127.0.0.1.nip.io`. This is a **`core`-layer** touch, not
  a `platform`-layer one: there is one shared cert object, and every UI feature
  appends its SAN to it (the accepted precedent — the live cert today carries the
  single `argocd.127.0.0.1.nip.io` entry).

Both are the accepted "append one line to a shared, mutable list" edits, never a
redesign of the sibling's object. The coordinator sequences them.

### The Forgejo chart configuration (external Postgres, sealed admin)

The `helmCharts:` block inflates `code.forgejo.org/forgejo-helm/forgejo-helm`
(OCI), pinned `version:` resolved at build time, into the `forgejo` namespace.
Load-bearing `valuesInline` (exact key spellings re-verified against the pinned
chart at build):

- **Database (external, sealed password).** `gitea.config.database` carries the
  plain `app.ini` `[database]` keys: `DB_TYPE: postgres`, `HOST:
  postgres-rw.storage.svc:5432`, `NAME: forgejo`, `USER: forgejo`. The password
  is **not** here — it is injected from the sealed `forgejo-db` Secret via
  `gitea.additionalConfigFromEnvs` mapping `app.ini`'s
  `FORGEJO__DATABASE__PASSWD` to a `valueFrom.secretKeyRef` on that Secret's
  `password` key (the `additionalConfigSources` whole-Secret form is the
  equivalent fallback). Never a chart-generated or `--set` literal — exactly the
  KSOPS-sealed-Secret convention Storage proved.
- **Initial admin (sealed).** `gitea.admin.existingSecret: forgejo-admin` points
  at the sealed Secret carrying `username`/`password` keys; `gitea.admin.email`
  is a plain (non-secret) chart value; `gitea.admin.passwordMode: keepUpdated`
  (the chart default) keeps the sealed credential authoritative — the password is
  re-asserted from the Secret on every pod restart, matching the "the sealed
  value is the source of truth" discipline. (`initialOnlyNoReset` is the
  alternative if drift-on-restart is ever unwanted; `keepUpdated` is proposed.)
- **Cache/queue/session:** left at the chart's **built-in in-process defaults** —
  the shared Valkey is deliberately **not** wired this build (research reviewer
  item 3: adequate for single-replica single-operator dev, avoids a second
  external dependency and sealed credential for no proof-of-concept benefit). The
  external-Valkey ACL user stays a documented, recommended-not-mandatory future
  enhancement (§ Deferred, and Storage's own "recommended, not mandatory" Valkey
  convention).
- **Persistence:** `persistence.enabled: true` on `local-path` with a small
  `size` (the repo/LFS/attachment store); single replica (dev).
- **Service:** the chart's default ClusterIP HTTP Service, which the `HTTPRoute`
  targets.

### Intra-`forgejo` sync-wave scheme

All resources carry `argocd.argoproj.io/sync-wave` annotations (via
`commonAnnotations` on the nested Helm/secrets kustomizations, inline on authored
CRs). Ordering inside the component:

- **wave `-10`** — the `forgejo` Namespace.
- **wave `-5`** — the KSOPS-decrypted `forgejo-admin` and `forgejo-db` Secrets,
  present before anything references them.
- **wave `0`** — the shared operands: the Forgejo `helmCharts:` release (which
  references both Secrets) and the `HTTPRoute`. The `forgejo` Postgres role is
  provisioned by the append to `storage`'s wave-0 Cluster, which is already
  Healthy from Storage's own sync.
- **wave `5`** — the `forgejo` `Database` CR (needs the operator running and the
  `forgejo` role to exist as its owner).

ArgoCD syncs waves ascending and waits for each Healthy before the next, so the
Forgejo pod never starts before its DB credential Secret exists, and the
`Database` never applies before its owner role.

### The shared Gateway route (consuming Networking's contract)

- `HTTPRoute` **`forgejo`** in the `forgejo` namespace (in this step's own
  `platform/overlays/dev/forgejo/httproute.yaml`, wave 0): `parentRefs: [{name:
  agrippa-gateway, namespace: istio-ingress, sectionName: https}]`, `hostnames:
  [git.davidsouther.com.127.0.0.1.nip.io]`, `backendRefs:` the Forgejo HTTP
  Service (same namespace), and an **explicit** `matches: [{path: {type:
  PathPrefix, value: /}}]` rule. That explicit `matches:` is not optional
  boilerplate: the live `argocd` HTTPRoute carries a comment recording that
  omitting it left `core` permanently OutOfSync (ArgoCD's diff does not replicate
  the Gateway API CRD's nested-array default for an absent `matches:`), so this
  step authors it explicitly to avoid the same trap.
- **No backend `DestinationRule` is needed** (unlike the `argocd` route, which
  re-originates TLS to `argocd-server`'s HTTPS `:443`): Forgejo serves plain HTTP
  from its chart's default Service, so the HTTPRoute targets that HTTP port
  directly and the Gateway terminates the only TLS on the path. (Confirm the
  chart's default `server.PROTOCOL: http` at build.)
- Append `git.davidsouther.com.127.0.0.1.nip.io` to the shared
  `agrippa-gateway-tls` `Certificate`'s `dnsNames` in
  `core/overlays/dev/gateway-cert.yaml` — the one-line SAN edit, never a change
  to the `Gateway` object. The dev hostname mirrors the production
  `git.davidsouther.com` (`ARCHITECTURE.html`) under the fixed
  `<prod-host>.127.0.0.1.nip.io` scheme.

### The `forgejo` database, role, and the cross-namespace DB credential

Following Storage's `smoke` fixture's proven three-part shape, with the slug
`forgejo`:

- **Role** — one appended `managed.roles[]` entry `{name: forgejo, login: true,
  passwordSecret: {name: forgejo-db}}` on `storage/overlays/dev/
  postgres-cluster.yaml` (the shared, append-only list). CNPG reads
  `passwordSecret` from the Cluster's own namespace, so `forgejo-db` must exist
  **in `storage`**.
- **Database** — a `Database` CR (in this step's `platform/overlays/dev/forgejo/
  forgejo-database.yaml`, wave 5) with `metadata.namespace: storage` and `spec:
  {name: forgejo, owner: forgejo, cluster: {name: postgres}}` — the exact live
  `smoke-database.yaml` shape (note the required `spec.name` literal DB name,
  Storage's build-discovered CRD field). It carries `metadata.namespace: storage`
  so it lands beside the Cluster it targets; the `platform` Application creates it
  there (an Application's `destination.namespace` is only the default for
  resources without an explicit namespace, exactly how the `storage` Application
  already creates resources into `cnpg-system` and `storage`).
- **The cross-namespace credential wrinkle.** Forgejo's pod (namespace `forgejo`)
  reads the DB password via `additionalConfigFromEnvs` → a `secretKeyRef`, which
  is namespace-local, so the pod needs the credential **in `forgejo`**; CNPG
  needs the same credential **in `storage`**. The clean resolution: generate the
  password **once** in memory and seal it into **two** Secret manifests carrying
  the same value — a `storage`-namespaced `kubernetes.io/basic-auth` Secret
  `forgejo-db` (for CNPG's managed role) and a `forgejo`-namespaced Secret
  `forgejo-db` (for the pod). Both live under this step's own
  `secrets/dev/platform/forgejo/` path and both are listed in this step's own
  KSOPS generator, so secret ownership stays entirely within this feature-step
  (honoring the "own only `secrets/dev/platform/forgejo/`" scope) — no touch to
  Storage's `secrets/dev/storage/` generator. The exact file split is an Open
  Artifact Decision (below).

### Sealing the credentials (sops+age+KSOPS, committed-Secret half)

Every credential is *committed, encrypted*, sealed with the identical discipline
Storage proved — generate in memory, encrypt immediately, never write plaintext
to disk, never put a secret in argv:

- **`forgejo-admin`** (ns `forgejo`, keys `username`, `password`). A multi-value
  Secret; the username (non-secret) may live in a `stringData` document whose
  `password` value comes from an in-memory `openssl rand`, piped straight to
  `sops --encrypt --filename-override secrets/dev/platform/forgejo/admin.enc.yaml
  … > …` — the multi-value case Storage's `smoke-valkey` recipe already spells
  out. (Confirm at build whether the chart's `existingSecret` expects the admin
  username as a Secret key or takes it as a plain `gitea.admin.username` value.)
- **`forgejo-db`** (`kubernetes.io/basic-auth`, keys `username: forgejo`,
  `password`), sealed twice from **one** generated password — once
  `-n storage` (for CNPG) and once `-n forgejo` (for the pod) — via the
  single-value pure-stdin recipe: `kubectl create secret generic forgejo-db -n
  <ns> --type kubernetes.io/basic-auth --from-literal=username=forgejo
  --from-file=password=/dev/stdin --dry-run=client -o yaml | sops --encrypt
  --filename-override … > …`, exactly Storage's `smoke-db` recipe with the slug
  and namespace changed. (Reuse the same in-memory password for both encryptions;
  the plan writes the exact two-target sealing sequence.)

All encrypted files live under `secrets/dev/platform/forgejo/`, matched by
`.sops.yaml`'s existing `^secrets/dev/.*$` creation rule (already a real
recipient, fixed by Storage), listed in this step's own
`secrets/dev/platform/forgejo/secret-generator.yaml` (`kind: ksops`) and reached
by the `forgejo` overlay as a `resources: [../../../../secrets/dev/platform/
forgejo]` sub-kustomization — the same self-contained-generator-referenced-as-a-
resource wiring Storage established (keeps every `files:` reference within one
kustomization root; no repo-server change). **This step owns only its own
`secrets/dev/platform/forgejo/` path**; if Auth/Flagsmith land credentials in
`secrets/dev/platform/` around the same time, the coordinator sequences any
reconciliation into a shared `secrets/dev/platform/` sub-kustomization (the same
append-only-list shape).

### The `apps/platform.yaml` sync seam (shared with Auth and Flagsmith)

`apps/platform.yaml`'s `syncPolicy` must carry **both** halves of the pair
`apps/core.yaml` and `apps/storage.yaml` already carry, or a controller-defaulted
field on a CNPG/Forgejo resource leaves `platform` permanently OutOfSync
(argoproj/argo-cd#22151 — `ServerSideApply=true` alone reproduces the bug):

- `syncPolicy.syncOptions: [ServerSideApply=true, SkipDryRunOnMissingResource=true]`
- `metadata.annotations: {argocd.argoproj.io/compare-options: ServerSideDiff=true}`

This edit is **shared by all three parallel platform siblings (Auth, Forgejo,
Flagsmith)**: whichever build lands first adds it; it is idempotent if the others
specify it identically. State it explicitly in each sibling's plan; the
coordinator ensures it lands once. This step does not otherwise touch
`apps/platform.yaml`.

### Cross-step touches (summary)

- **`platform/overlays/dev/kustomization.yaml`** — append one `resources:` entry
  (`forgejo`). Shared file; two siblings append their own; coordinator sequences.
- **`storage/overlays/dev/postgres-cluster.yaml`** — append one
  `managed.roles[]` entry (`forgejo`). Shared, append-only list (Storage's
  contract); coordinator sequences.
- **`core/overlays/dev/gateway-cert.yaml`** (the shared `agrippa-gateway-tls`
  `Certificate`, in the `core` layer) — append one `dnsNames` entry. Shared,
  append-only list (Networking's contract).
- **`apps/platform.yaml`** — add the `ServerSideApply`/
  `SkipDryRunOnMissingResource` syncOptions **and** the `ServerSideDiff=true`
  compare-options annotation (shared with Auth/Flagsmith; lands once).
- **`secrets/dev/platform/forgejo/…`** — new committed, sops-encrypted Secrets
  plus their KSOPS generator kustomization (this step's own path only).
- **`scripts/test-feature.sh`** — add `git-hosting.bats` to the probe-suite
  exclusion `case` list (it drives the long-lived `agrippa-dev` cluster and the
  GitOps-reconciled `platform` layer, not the throwaway `agrippa-feature`
  cluster) — the same one-line edit every sibling suite made. **Lands with the
  feature test in the design phase.**
- **`mise.toml`** — no new tool pins (see Libraries & Skills).

### The deferred runner (recorded, not built)

forgejo-runner/Actions is deferred for this build (cleared research reviewer item
1). Its only well-trodden Kubernetes shape needs a **privileged `docker:dind`
sidecar** — the first privileged container anywhere in this project (CNPG,
Valkey, Istio, cert-manager, metallb all run unprivileged); the `host` backend
trades that for a no-isolation job surface; and the native non-privileged
pod-per-job executor is still an author-acknowledged proof of concept upstream.
The build's definition of done does not require CI, the parent design twice
defers the only concrete CI use it names (Trips' CI → Forgejo Actions port), and
the Closing Bell names no Git-hosting or Actions task. The runner is **additive**:
a later increment appends it — a runner Deployment, a sops-sealed 40-hex
registration secret consumed by both a registration mechanism and the runner's
`.runner`, and its executor-backend choice — with zero rework to the server that
lands now, revisited when a production-ready non-privileged Kubernetes executor
lands upstream or the project accepts its first privileged workload.

### Challenges

- **Chart version pin deferred to build.** Resolve the exact current Forgejo
  chart release at build-time `research:public`, and re-verify the values schema
  (`gitea.config.database`, `additionalConfigFromEnvs`, `admin.existingSecret`/
  `passwordMode`, `persistence`) against it. Pin explicitly; do not float tags —
  consistent with every completed sibling's version-pin deferral.
- **Exact value-key and env-var spellings.** The `app.ini` env-var name
  (`FORGEJO__DATABASE__PASSWD` vs a `GITEA__…` legacy spelling), the
  `existingSecret` key names the chart expects, and whether the admin username is
  a Secret key or a plain value are build-verified against the pinned chart. The
  design fixes the shapes and names; the build confirms the exact spellings (the
  test is RED now regardless).
- **The `helmCharts:` namespace-stamp regression (kustomize #6058).** The live
  Valkey component carries a `patches:` block force-stamping
  `metadata.namespace: storage` onto its Helm-inflated resources, because
  kustomize 5.8.x (`mise.toml` pins `5.8.1`) no longer applies the top-level
  `namespace:` transformer to `helmCharts:`-generated objects whose templates do
  not hardcode `{{ .Release.Namespace }}` — the first Valkey sync landed every
  object in the wrong namespace until the workaround landed. The Forgejo chart's
  inflation may hit the identical trap. Build-time verify whether the Forgejo
  chart's templates set `metadata.namespace` from `.Release.Namespace`; if not,
  mirror Valkey's scoped `patches:` namespace-stamp for the `forgejo` namespace.
  (This is why `helmCharts[].namespace: forgejo` alone may not suffice — it sets
  `.Release.Namespace` for in-template use, not `metadata.namespace`.)
- **`helm template` semantics.** `helmCharts:` inflation runs `helm template` (no
  hooks). Confirm at build the Forgejo chart install needs no post-install
  hook/`lookup` the templated path drops (research found none); if the chart
  emits a `helm.sh/hook` test Pod as a literal object the way the Valkey chart
  does, add `skipTests: true` (the live Valkey component's own fix).
- **The chart's HTTP backend protocol.** The HTTPRoute targets Forgejo's HTTP
  Service on the assumption the chart defaults to `server.PROTOCOL: http`;
  confirm at build, since an HTTPS default would need the `argocd`-style backend
  `DestinationRule`.

## Alternatives

- **Bundle Postgres/Redis via the chart's old subcharts.** Not available — the
  chart dropped both subcharts at v14; external is the only supported shape, and
  it is exactly this project's posture (a shared `postgres`, no per-app
  datastore). No decision to make.
- **Ship forgejo-runner now with a privileged `docker:dind` sidecar (option a).**
  Rejected by the cleared research reviewer: the first privileged container in a
  project that runs everything else unprivileged, to deliver a capability the
  definition of done does not require. Deferred as a documented, additive
  follow-up.
- **Ship forgejo-runner with the `host` execution backend (option c).**
  Rejected: upstream documents the `host` backend as "no isolation at all — a
  single job can permanently destroy the host," trading the privilege risk for an
  arbitrary-code-in-the-runner-pod risk and a degraded, non-standard CI surface.
- **Wire Forgejo to the shared Valkey for cache/queue/session now.** Rejected for
  this build (research reviewer item 3): Forgejo's in-process defaults are
  adequate at single-replica dev scale; wiring Valkey adds a second external
  dependency and a third sealed credential for no proof-of-concept benefit. Kept
  as a recommended-not-mandatory future enhancement (one `auth.aclUsers` entry,
  one Forgejo-scoped Secret, three `gitea.config` keys — a determined, reversible
  append, already researched).
- **Own the whole `platform/overlays/dev/kustomization.yaml` file.** Rejected:
  three siblings append to it independently; this step owns one `resources:`
  entry, not the file (the accepted append-only-list precedent).
- **Vendor the chart under `charts/forgejo/`.** Rejected: `charts/` is reserved
  for this project's own-authored charts (Workloads' `charts/resume`/
  `charts/trips`). Every upstream-published chart so far is `helmCharts:`-inflated
  in-place (Istio, cert-manager, CNPG, Valkey); Forgejo follows that precedent.
- **A dedicated throwaway proof object instead of proving Forgejo's own
  function.** Not applicable the way it was for Storage — Forgejo *is* the
  running consumer, so the feature test proves the real service directly (reach
  the UI/API, authenticate the sealed admin, create and push a repo), and a
  created-then-deleted test repository is runtime data (Postgres + PVC), not a
  declarative resource ArgoCD's `prune`/`selfHeal` would fight.

## Summary

This feature-step lands the **Forgejo server** into the already-live `platform`
layer as one more `resources:` entry under the existing `platform` Application: a
`platform/overlays/dev/forgejo/` subdirectory whose `helmCharts:` block inflates
the official `code.forgejo.org/forgejo-helm/forgejo-helm` chart against the
shared `postgres` Cluster (a `forgejo` `managed.roles[]` append + a self-owned
`Database` CR, slug `forgejo`, database name = role name), with its initial admin
credential and its database credential both sops+age+KSOPS-sealed under
`secrets/dev/platform/forgejo/`, and its web UI exposed through the shared
`agrippa-gateway` at `git.davidsouther.com.127.0.0.1.nip.io` (one `HTTPRoute` +
one appended `dnsNames` SAN). It wires the shared `apps/platform.yaml` sync seam
(both `ServerSideApply`/`SkipDryRunOnMissingResource` syncOptions **and**
`ServerSideDiff=true` compare-options — shared with Auth and Flagsmith, landed
once), and adds one `test:feature` exclusion line. The shared Valkey is
deliberately not wired (in-process defaults; a recommended future enhancement),
and **forgejo-runner/Actions is deferred** as a documented, additive follow-up.
The one feature test proves Git hosting is live and usable end-to-end: the
Forgejo API reachable through the Gateway with a local-CA cert, an authenticated
call with the sealed admin credential, and a repository created and pushed to —
no runner/CI assertion.

This Design-phase run does **not** deploy the Forgejo content: reconciling it is
a full ArgoCD sync of a newly-committed chart and CRs, sealing the admin and DB
credentials is build-phase work, and the exact chart version and value-key
spellings want live re-verification at build time. The feature test is therefore
left **RED** (baseline recorded below); the build phase turns it green after
sealing the credentials, committing the `forgejo` composition and the three
shared-list appends, wiring the sync seam, and letting ArgoCD reconcile it.

### Resolved by the long-loop reviewer (2026-07-08)

These were the design's Open Artifact Decisions: concrete artifact choices this
design invents that are not fixed by a skill template, an existing project
convention, or the cleared `research.md` (whose reviewer block already settled the
chart choice, the runner deferral, the Valkey-not-wired decision, the `forgejo`
slug, the dev hostname, the `secrets/dev/platform/forgejo/` own-path scope, the
landing mechanism, and the `apps/platform.yaml` sync-seam pair). Each is decided to
its proposed conservative default. None triggered an escalation: every item is
reversible within this step's own subtree, none exceeds the scope the design
records, and repo conventions determine each default.

**1. The credential Secret names (`forgejo-admin`, `forgejo-db`) and the KSOPS
generator resource (`secret-generator.yaml`, `kind: ksops`). Decided:
`forgejo-admin` and `forgejo-db` as proposed, generator file
`secret-generator.yaml`.** Follows Storage's live `<slug>-db` fixture convention,
verified against `storage/overlays/dev/postgres-cluster.yaml` where the `smoke`
role carries `passwordSecret.name: smoke-db`, extended with `<slug>-admin` for the
admin credential. `kind: ksops` is KSOPS's required generator kind, not a free
choice. The feature test already binds `ADMIN_SECRET="forgejo-admin"`, so this is
the value-bound conservative default.

**2. The committed-secret path and file split
(`secrets/dev/platform/forgejo/{admin,db-storage,db-forgejo}.enc.yaml`). Decided:
as proposed.** Adapts Storage's `secrets/dev/<layer>/<component>/…` layout to the
`platform` layer with a per-credential leaf, and the `db-<ns>` leaf split is forced
by the cross-namespace constraint decided in item 5. Reversible because this step
owns the whole `secrets/dev/platform/forgejo/` path; the literal-mirror
`<store>/<slug>` alternative is rightly rejected as over-nested for one component.

**3. The overlay authored-CR and namespace file names (`forgejo-database.yaml`,
`httproute.yaml`, `namespace.yaml`, subdir `forgejo/`). Decided: as proposed.**
Mirrors the realized `storage/overlays/dev/` per-component-subdir shape. Fully
reversible: a rename touches only this step's own files, so matching the existing
sibling layout is the conservative default.

**4. `gitea.admin.passwordMode` (`keepUpdated` vs `initialOnlyNoReset`). Decided:
`keepUpdated`.** It is the chart default and it keeps the sealed Secret
authoritative, re-asserting the credential on every pod restart, matching this
project's "the sealed value is the source of truth" discipline so a restart can
never silently strand the admin password away from what git holds. Reversible
one-value edit if drift-on-restart is ever unwanted.

**5. The DB password cross-namespace delivery (one generated password sealed into
two `forgejo-db` Secrets, ns `storage` for CNPG and ns `forgejo` for the pod).
Decided: the two-copies form as proposed.** The constraint is real and verified:
CNPG reads `managed.roles[].passwordSecret` from the Cluster's own namespace
(`storage`), while Forgejo's `additionalConfigFromEnvs` `secretKeyRef` is
namespace-local to the pod (`forgejo`). The two alternatives are heavier or weaker:
a reflector/copier controller adds a standing component to the trust surface, and a
non-Secret indirection is less auditable. Sealing one in-memory password into two
ciphertext-only manifests keeps ownership wholly inside this step's
`secrets/dev/platform/forgejo/` path, adds no controller, and is the auditable
default. The exact `additionalConfigFromEnvs` env-var spelling stays build-confirmed
against the pinned chart; the contract (one password, slug `forgejo`, sealed in both
namespaces) is fixed.

**Reviewer verification (2026-07-08).** The design's load-bearing claims were
checked live and hold. The RED baseline reproduces exactly: `tests/git-hosting.bats`
aborts at THEN 1 (line 141's `grep -q '"version"'`), exit 1, with `platform`
Synced/Healthy on `argocd.yaml`-only content and no `forgejo` namespace, no side
effects. `scripts/test-feature.sh` excludes `git-hosting.bats` in its probe-suite
`case` list. `apps/core.yaml` and `apps/storage.yaml` both carry the cited
`ServerSideApply`/`SkipDryRunOnMissingResource` syncOptions plus the
`ServerSideDiff=true` compare-options annotation, while `apps/platform.yaml` does
not yet, correctly the shared "lands once" edit. `core/overlays/dev/gateway-cert.yaml`
carries the single `argocd.127.0.0.1.nip.io` SAN today, so the one-line `dnsNames`
append is specified correctly, and the `smoke` `managed.roles[]` entry matches the
proposed `forgejo` append shape. The cross-cutting bats claim was reproduced
empirically against this repo's pinned bats 1.13.0: a non-final bare `[[ false ]]`
does NOT fail a test (errexit exempts the conditional compound), while `[ … ]`,
simple commands, and a truly-final `[[ ]]` all gate. The `TASKS.md` record
(`## Test-quality: bats non-final [[ ]] doesn't gate`) is accurate, and this step's
own `tests/git-hosting.bats` is free of the footgun: every content assertion uses
`grep -q`/`grep -qF` or `[ … ]`, and its only `[[` is inside a comment (line 138).

## Feature Test

**Path:** `tests/git-hosting.bats` (following `DEVELOPMENT.md`'s
`tests/<feature>.bats` convention, feature = "git-hosting"; the `-forgejo` tool
qualifier is dropped just as `cluster-core.bats` dropped `-k3d`, `gitops.bats`
dropped `-argocd`, `networking.bats` dropped `-istio`, and `storage.bats` dropped
`-postgres-valkey`).

**User story (Given / When / Then):** *Given* the bootstrapped long-lived
`agrippa-dev` cluster (Features 1-4) with this Forgejo content committed and
reconciled by ArgoCD into the `platform` layer — the Forgejo server backed by the
shared `postgres` Cluster's `forgejo` database/role, its sealed admin credential,
and its `HTTPRoute` at `git.davidsouther.com.127.0.0.1.nip.io` — *When* an
operator reaches Forgejo's API through the shared Gateway, authenticates with the
KSOPS-decrypted admin credential, and creates and pushes to a repository, *Then*
the `platform` Application is Synced/Healthy, Forgejo's API answers through the
Gateway over a local-CA-issued cert, the authenticated admin call succeeds
(proving the sealed credential + the Postgres-backed user store), and a newly
created repository accepts a `git push` and serves the pushed commit back
(proving Git hosting end-to-end) — **with no runner/Actions/CI assertion, since
that is deferred**. `curl -k` and `-c http.sslVerify=false` tolerate the
deliberately-untrusted local CA (`research.md` decision 3). Like its sibling
suites it deliberately does **not** tear the cluster, Forgejo, or its datastore
down; the throwaway *test repository* it creates it also deletes (runtime data,
not a declarative resource, so no reconciler fight).

**Current state: RED (baseline captured live this run).** With
`platform/overlays/dev` still carrying only `argocd.yaml`, the `platform`
Application is already `Synced/Healthy` on that content (live-confirmed) — so the
suite's precondition (THEN 0, `platform` Synced/Healthy) passes even now, exactly
as Networking's THEN 0 passed on empty `core` and Storage's on empty `storage`.
The RED lands at **THEN 1**: no `forgejo` namespace exists and no HTTPRoute routes
the git host, so `curl` to `…/api/v1/version` reaches the shared Gateway but gets
an empty 404 body (the Gateway answers the TLS handshake for any SNI — so THEN 2's
local-CA-issuer check would in fact pass today — but returns no Forgejo payload),
and the `grep -q '"version"'` reachability assertion fails there (verified live:
the suite aborts at THEN 1, exit 1). That red state defines "done." This
Design-phase run does **not** turn it green: sealing the credentials, committing
the `forgejo` composition and the
shared-list appends, wiring the sync seam, and the ArgoCD reconcile are all
build-phase work outside this phase's write-only-the-test gate.
