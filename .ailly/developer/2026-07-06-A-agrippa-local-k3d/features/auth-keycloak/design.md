# Feature Design: Auth (Keycloak via the Keycloak Operator)

*Reviewed 2026-07-08*

> Feature-step design (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 5: Auth (Keycloak)** of that
> project's plan: Tier-2 in-cluster OIDC, Postgres-backed, in the `platform` layer
> (sync-wave 2), running **parallel** with Feature 6 (Forgejo), Feature 7
> (Flagsmith), and Feature 8 (Observability). It has its own feature test (recorded
> below). The project as a whole is measured by `closing-bell.md`, not by this test.
>
> Unlike Storage and Networking, this feature-step **defines no shared contract** —
> it is a pure *consumer* of two already-landed ones: Storage's storage-class +
> per-app DB/role naming contract (Feature 4) and Networking's
> Gateway/HTTPRoute/hostname/TLS contract (Feature 3). Both are live and Synced on
> the running `k3d-agrippa-dev` cluster (verified this session). Its research
> (`research.md`, `research/public.md`) is Reviewed; the reviewer block there
> settled the two flagged items (the Keycloak/CNPG namespace split, and the full
> `apps/platform.yaml` sync seam) — those decisions are carried in as settled inputs
> below, not re-litigated. This is a **long-loop** run: the draft gate is left open
> for a separately dispatched reviewer to clear.
>
> This is a slightly **larger** feature-step than the one-page norm (an operator
> plus four authored CRs, a two-namespace credential materialization, and touches to
> three files shared with parallel siblings), so it runs a little longer, per
> `design.md`'s "confirm before making a larger doc." It stays well short of
> Storage's/Networking's ensemble length because it defines no contract of its own.

## Libraries & Skills (carry forward to plan and build)

Per the project's cleared `research.md` (§ Libraries & Skills), this feature-step's
own cleared `research.md` (§ Libraries & Skills), and the project `design.md`, the
plan and build phases MUST load these skills via the harness's skill-loading
mechanism before working:

- **`developer:initialize`** — for any residual `mise` tool-pin work. This feature
  adds **no** new mise-managed CLI: the Keycloak Operator is installed by raw
  in-cluster manifests ArgoCD reconciles directly (not a local tool), and it is
  **not** Helm-sourced, so it needs neither a new tool pin nor any repo-server
  `--enable-helm` wiring (that already landed for Storage/Networking regardless).
  Everything the build needs for sealing the two credential Secrets (`sops`, `age`,
  `kubectl`, `openssl`, `k3d`, `yq`, `bitwarden`) is already pinned in `mise.toml`.
- **`research:public`** and **`research:codebase`** — for the per-tool detail the
  build defers to build time: the exact Operator/Keycloak version pin, the exact
  `Keycloak`/`KeycloakRealmImport` CRD field spellings (`spec.db.database`,
  `spec.hostname.hostname`, `spec.hostname.strict`, `spec.proxy.headers`,
  `spec.http.httpEnabled`), the Operator manifest's default namespace / RBAC binding
  target, and the CR `status` condition strings the feature test selects on.

**No library-shipped agentic skill exists for the Keycloak Operator, the
`keycloak-k8s-resources` raw manifests, or CNPG's `Database`/`managed.roles`
mechanism this feature-step consumes** (both the project research and this feature's
research recorded the deliberate per-tool check). Build to the in-repo contracts:
`ARCHITECTURE.html` (§ S5 Platform — Keycloak identity/OIDC/SpiceDB-deferred),
`ROUTING.md` (host-vs-path policy this feature's hostname choice applies),
`DEVELOPMENT.md` (§ Secrets — the sops/age/KSOPS discipline the credentials follow),
and the two already-landed sibling designs — `storage-postgres-valkey` (the
`managed.roles[]` + `Database` CR + `secrets/dev/storage/…` sealing contract this
step consumes) and `networking-istio` (the `agrippa-gateway`/`agrippa-gateway-tls`
consumption contract: one HTTPRoute + one `dnsNames` append) — are the authoritative
contracts this step builds to.

## Purpose

Stand up **Keycloak** as the platform's local Tier-2 OIDC identity provider,
Postgres-backed, reconciled by ArgoCD into the already-Synced `platform` layer
(sync-wave 2), and reachable in a browser through the shared Istio Gateway with
local-CA TLS. Production runs the same Operator and CRs; locally the only
differences are the dev hostname (`auth.127.0.0.1.nip.io` via the `*.nip.io`
loopback scheme), the local-CA leaf cert in place of the Cloudflare edge's public
TLS, and a single-instance (`spec.instances: 1`) dev-sized deployment. Cloudflare
Access (Tier-1) has no local equivalent and is out of scope everywhere in this
project.

The deliverable is:

1. **The Keycloak Operator**, installed via raw pinned-URL manifests from
   `keycloak/keycloak-k8s-resources` (two CRDs + the operator Deployment/RBAC
   manifest) into a **new `keycloak` namespace** — the same raw-manifest composition
   shape `core` already uses for the Gateway API CRDs, cert-manager, and metallb.
2. **One `Keycloak` CR** in the `keycloak` namespace, wired to the shared `postgres`
   Cluster (`spec.db.vendor: postgres`, `host: postgres-rw.storage.svc`,
   `usernameSecret`/`passwordSecret` → the sealed `keycloak-db` credential),
   `spec.ingress.enabled: false`, `spec.http.httpEnabled: true`, `spec.hostname` set
   to the dev host, `spec.bootstrapAdmin.user.secret` → the sealed `keycloak-admin`
   credential.
3. **The Storage consumption:** one `managed.roles[]` append to the shared `postgres`
   Cluster (`{name: keycloak, login: true, passwordSecret: {name: keycloak-db}}`),
   one sealed `keycloak-db` credential added to Storage's KSOPS generator, and one
   same-namespace-to-`storage` `Database` CR (`name: keycloak, owner: keycloak,
   cluster: {name: postgres}`) authored in this feature's own tree.
4. **One `KeycloakRealmImport` CR** declaratively importing a minimal local dev realm
   (`agrippa`) — the GitOps-native realm bootstrap, mirroring Storage's `smoke`
   fixture minimalism (proof-object minimal, not a production-realm-parity import).
5. **The Networking consumption:** one `HTTPRoute` in the `keycloak` namespace to
   `keycloak-service:8080`, and one dev-host append (`auth.127.0.0.1.nip.io`) to the
   shared `agrippa-gateway-tls` certificate's `dnsNames`.

The value is narrow but load-bearing: no real workload is OIDC-gated yet (Feature 9
consumes Auth later; the parent design's resolved item 3 keeps local `trips` at plain
reachability, not Keycloak-gated). This step proves **Keycloak itself** reaches Ready,
persists a declaratively-imported realm in Postgres, and serves that realm's OIDC
discovery endpoint through the shared Gateway with a local-CA cert — the substrate a
later OIDC integration binds to.

Out of scope, kept as seams or owned by a later feature-step: **wiring OIDC into any
real workload** (Feature 9); **Cloudflare Access / Tier-1** (no local equivalent);
**SpiceDB** (`ARCHITECTURE.html` records it deferred alongside Keycloak); **any
Valkey/session-store integration** (Keycloak's single-instance dev deployment uses its
embedded cache; Storage's Valkey ACL convention is opt-in, and this step found no
reason to take it); **HA/clustering** (`spec.instances` > 1); **client-SDK wiring in
application code** (`openidconnect`/`keycloak-js`/`python-keycloak`, consumer-side
work for a later step); and **`overlays/prod`** (a seam, not built).

## Prior Art

- **`storage-postgres-valkey` (Feature 4) — the DB consumption contract this step
  binds to.** Its `Cluster.spec.managed.roles[]` append-only list, its per-app
  `Database` CR (`{name, owner, cluster: {name: postgres}}`), its
  `secrets/dev/storage/<store>/<slug>.enc.yaml` sealing convention, its KSOPS
  `generators:` wiring, and its four-tier intra-layer sync-wave scheme are the exact
  mechanisms this step reuses. Its own design § User Journey even names *Keycloak* as
  the worked consumer example (`{name: keycloak, login: true, passwordSecret: {name:
  keycloak-db}}` and DSN `postgres://keycloak:<pw>@postgres-rw.storage.svc:5432/
  keycloak`). Live-verified this session: the `postgres` Cluster is Healthy, service
  `postgres-rw.storage.svc:5432` exists, `managed.roles[]` currently carries only
  `smoke`, and the storage KSOPS generator lives at
  `secrets/dev/storage/secret-generator.yaml`.
- **`networking-istio` (Feature 3) — the ingress consumption contract this step
  binds to.** The shared `agrippa-gateway` (`istio-ingress`, `https` listener on
  `:443`, `allowedRoutes.namespaces.from: All`), the append-only
  `agrippa-gateway-tls` certificate `dnsNames` list
  (`core/overlays/dev/gateway-cert.yaml`, currently `[argocd.127.0.0.1.nip.io]`),
  and the `<prod-host>.127.0.0.1.nip.io` hostname scheme. Its `argocd` HTTPRoute
  (`core/overlays/dev/argocd-httproute.yaml`) is the literal template this step's
  HTTPRoute copies (`parentRefs` → `agrippa-gateway`/`sectionName: https`, explicit
  `matches: [{path: {type: PathPrefix, value: /}}]`). Live-verified: the Gateway is
  `Programmed: True`, the cert carries `[argocd.127.0.0.1.nip.io]`, and `agrippa-ca`
  is Ready. **Crucially, Keycloak's exposure is *simpler* than ArgoCD's:** ArgoCD's
  HTTPS-only backend forced Networking into a `DestinationRule` backend-TLS
  re-origination; Keycloak's `spec.http.httpEnabled: true` opens a plain-HTTP `:8080`
  listener, so this step routes to `keycloak-service:8080` with **no** second
  TLS-re-origination object.
- **`core/overlays/dev/` and `storage/overlays/dev/` — the composition shape.** A
  per-component subdirectory carrying the upstream install (raw `resources:` for
  metallb/cert-manager/Gateway-API-CRDs in `core`; `helmCharts:` for CNPG/Valkey in
  `storage`) plus a `namespace.yaml`, alongside top-level authored-CR files, all
  ordered by a fine-grained intra-layer sync-wave scheme. This step applies exactly
  that layout to a new `platform/overlays/dev/keycloak/` subdirectory (raw-manifest
  operator, matching `core`'s raw-manifest sources rather than `storage`'s Helm ones).
- **`apps/core.yaml` / `apps/storage.yaml` — the CRD-heavy-operator sync seam.** Both
  carry the full two-part seam this step adds to `apps/platform.yaml`:
  `syncPolicy.syncOptions: [ServerSideApply=true, SkipDryRunOnMissingResource=true]`
  **and** the `argocd.argoproj.io/compare-options: ServerSideDiff=true` annotation.
  Their own live comments document why both halves are needed together
  (argoproj/argo-cd#22151): `ServerSideApply=true` alone auto-enables Structured
  Merge Diff, which mispredicts CRD-webhook-defaulted fields and leaves the
  Application permanently OutOfSync — the exact symptom Keycloak's two webhook-backed
  CRDs would reproduce.
- **`DEVELOPMENT.md` § Secrets and `scripts/bootstrap.sh` / `scripts/rotate-keys.sh`.**
  The "generate in memory, encrypt immediately, never touch disk, secret value only
  via stdin" discipline this step reuses for both sealed credentials. `.sops.yaml`'s
  `^secrets/dev/.*$` creation rule already carries the real `agrippa-age-dev`
  recipient (Storage's build populated it; live-verified), and already matches
  `secrets/dev/platform/…` paths — so no `.sops.yaml` change is needed here.
- **External worked examples** (full IEEE citations in `research/public.md`): the
  canonical external-Postgres `Keycloak` CR [9], the `KeycloakRealmImport` CR and its
  same-namespace `keycloakCRName` binding [12], `spec.bootstrapAdmin`/`spec.ingress`/
  `spec.http.httpEnabled` [13][14][15], the CNPG same-namespace `Database`↔`Cluster`
  limitation [11], and the Keycloak Operator installation/multi-namespace note [1][2].

## User Journey and Metrics

**The operator's flow**, from the bootstrapped `agrippa-dev` cluster (Features 1-4)
with this Auth content committed and ArgoCD reconciling the `platform` layer:

1. ArgoCD syncs the `platform` layer: the Keycloak Operator comes up in the new
   `keycloak` namespace (CRDs, controller, RBAC), the shared `postgres` Cluster gains
   a `keycloak` role, the `keycloak` `Database` CR reconciles in `storage`, the
   `Keycloak` CR reaches Ready connected to Postgres, and the `KeycloakRealmImport`
   imports the `agrippa` realm. The operator runs `kubectl -n argocd get application
   platform` and sees it **Synced/Healthy**.
2. The operator opens `https://auth.127.0.0.1.nip.io/` in a browser (or `curl -k`):
   the request goes host `:443` → k3d loadbalancer port-map → node IP (Gateway
   Service `externalIPs`) → gateway pods → the `keycloak` HTTPRoute →
   `keycloak-service:8080`, TLS terminated at the Gateway with the local-CA leaf.
   Keycloak's welcome/admin UI renders. The browser shows an untrusted-CA warning by
   design; `curl -k` accepts it. The operator logs into the admin console with the
   sealed `keycloak-admin` credential.
3. The operator (or a later OIDC consumer) fetches the imported realm's discovery
   document at `https://auth.127.0.0.1.nip.io/realms/agrippa/.well-known/
   openid-configuration` and gets a 200 whose `issuer` is
   `https://auth.127.0.0.1.nip.io/realms/agrippa` — proving the realm was imported,
   is persisted in Postgres, and is served correctly behind the reverse-proxying
   Gateway (correct issuer/redirect URLs depend on `spec.hostname` + `spec.proxy`
   being right).
4. A **later** feature-step that wants OIDC (Feature 9, or a future gated app)
   creates a client in the `agrippa` realm and points its SDK at that issuer. This
   step does not build that; it proves the issuer exists and is reachable.

**Metrics / measures of done for this feature-step:**

- The feature test (`tests/auth.bats`) is green: the `platform` Application is
  Synced/Healthy, the `Keycloak` CR is Ready, the `KeycloakRealmImport` is done, the
  `keycloak` `Database` CR (in `storage`) is applied, and `curl -k` reaches the
  `agrippa` realm's OIDC discovery endpoint through the Gateway (200, correct
  `issuer`) presenting a **local-CA** cert (`CN=Agrippa Local Dev CA`).
- `kubectl -n argocd get application platform` is **Synced/Healthy** with the
  Operator, the `Keycloak` CR, the realm import, and the HTTPRoute all reconciled.
- Adding this step does not regress earlier harness: `mise run test:push`
  (`test:static` + `test:policy` + `test:chart`), `mise run test:feature`, and `bats
  tests/cluster-core.bats tests/gitops.bats tests/networking.bats tests/storage.bats
  tests/rotate-keys.bats` stay green (the `auth.bats` `test:feature` exclusion lands
  with the test).

**Per-component SLO (defined here, watched in Grafana once Observability lands; not a
CI step, per `DEVELOPMENT.md`).** Auth is a Tier-2 dependency of every OIDC-gated
workload, so its availability budget is tight but looser than Storage's or the
ingress front door's. Targets, measured over a rolling 28-day window once Feature 8
provides Prometheus/Grafana: **the `agrippa` realm's OIDC token endpoint returns
non-5xx ≥ 99.5%** of the time, and **the Keycloak login page (`/realms/agrippa/…`)
is reachable ≥ 99.5%** of the time. Burn-rate alert at 2% budget consumed in 1h.
Recorded here, instrumented when Observability lands; not asserted by the feature test.

**Failure modes to design against.**

- **The `Database` CR authored in the wrong namespace.** CNPG's `Database.spec.cluster`
  is a same-namespace-only `LocalObjectReference` (issue #6043) — a `Database` CR in
  the `keycloak` namespace would silently never reconcile. Mitigated by authoring it
  with `metadata.namespace: storage` (Specification § The DB provisioning).
- **The credential Secret present in only one namespace.** CNPG reads
  `managed.roles[].passwordSecret` from the Cluster's namespace (`storage`); the
  `Keycloak` CR reads `spec.db.*Secret` from *its* namespace (`keycloak`). A single
  sealed Secret in one namespace leaves the other consumer unable to resolve it.
  Mitigated by the two-namespace materialization (Specification § The credential),
  the load-bearing correctness point of this design.
- **A CR syncing before its prerequisite exists.** The `Keycloak` CR before the
  Operator webhook; the `Keycloak` CR before the `keycloak` PostgreSQL database it
  connects to at startup (the `Database` CR now lands at wave `-5`, ahead of the CR —
  see § Correction by the long-loop reviewer (2026-07-09)); the `KeycloakRealmImport`
  before the `Keycloak` CR is Ready. Mitigated by the intra-`keycloak` sync-wave scheme
  plus the `ServerSideApply`/`SkipDryRunOnMissingResource` + `ServerSideDiff` seam this
  step adds to `apps/platform.yaml`.
- **A Keycloak-controller-owned status/defaulted field leaving `platform` permanently
  OutOfSync** — the exact symptom that made `core`/`storage` need `ServerSideDiff`.
  Anticipated and pre-empted by adding the full seam (both halves) to
  `apps/platform.yaml`; if a specific field still drifts, resolve with a
  narrowly-scoped `ignoreDifferences` at build (mirroring `apps/core.yaml`'s
  istiod-webhook scoping).
- **`bootstrapAdmin` silently ignored on re-sync.** After the first successful
  bootstrap the `master` realm exists, so `spec.bootstrapAdmin` is ignored [13] — an
  expected bootstrap-only property, not a gap. The feature test asserts realm
  reachability and CR readiness, not admin re-login, so it does not depend on this.
- **Wrong `spec.hostname`/`spec.proxy` behind the Gateway** producing bad
  issuer/redirect URLs (e.g. `http://` issuer, or the internal Service host).
  Mitigated by setting `spec.hostname.hostname` to the dev host and
  `spec.proxy.headers: xforwarded`; the exact `strict`/`headers` spellings are
  build-time live-verified (research open item 6).

## Specification

### Composition: the `platform` layer, a new `keycloak/` subdirectory

Following `core/overlays/dev/`'s and `storage/overlays/dev/`'s realized layout, this
step adds a **per-component subdirectory** `platform/overlays/dev/keycloak/` and
appends it to the platform overlay's `resources:` list. The Operator installs from
**raw pinned-URL manifests** (matching `core`'s raw-manifest sources, since Keycloak
publishes no Helm chart), so there is no `helmCharts:` block anywhere in this step.
Proposed file layout (object/file names are Open Artifact Decisions where noted):

```text
platform/overlays/dev/keycloak/
├── kustomization.yaml            # resources: operator/, the platform secrets sub-kustomization,
│                                 #   the Keycloak CR, the Database CR, the realm import, the HTTPRoute
├── operator/
│   ├── kustomization.yaml        # wave -10; namespace: keycloak; resources: namespace.yaml + 3 pinned URLs
│   │                             #   (2 CRDs + the operator Deployment/RBAC manifest)
│   └── namespace.yaml            # Namespace keycloak
├── keycloak.yaml                 # wave 0;  Keycloak CR `keycloak` (namespace keycloak)
├── keycloak-database.yaml        # wave -5; CNPG Database `keycloak` -- metadata.namespace: storage
├── keycloak-realm.yaml           # wave 5;  KeycloakRealmImport `agrippa` (namespace keycloak)
└── keycloak-httproute.yaml       # wave 5;  HTTPRoute `keycloak` (namespace keycloak)

secrets/dev/platform/keycloak/    # referenced by the keycloak overlay as a sub-kustomization
├── kustomization.yaml            # wave -5; generators: [secret-generator.yaml]
├── secret-generator.yaml         # kind: ksops; files: [keycloak-db.enc.yaml, keycloak-admin.enc.yaml]
├── keycloak-db.enc.yaml          # sops-encrypted basic-auth Secret `keycloak-db` (namespace keycloak)
└── keycloak-admin.enc.yaml       # sops-encrypted Secret `keycloak-admin` (namespace keycloak)
```

Two composition points deserve explicit treatment:

- **No blanket `namespace:` transformer at the `keycloak/` top level.** The `Database`
  CR must carry `metadata.namespace: storage` while everything else is in `keycloak`,
  so the top-level kustomization sets no `namespace:` transformer and each authored CR
  declares its own `metadata.namespace` explicitly (exactly as `storage`'s authored
  CRs do). The Operator install is the exception: its upstream raw manifest declares
  no namespace, so it lives in the `operator/` **sub-kustomization** that *does* set
  `namespace: keycloak` (safe there — the sub-kustomization holds only Operator
  resources; the two CRDs and the Namespace object are cluster-scoped and the
  namespace transformer skips them). The RBAC binding may need a build-time patch if
  the upstream manifest's ClusterRoleBinding subject hardcodes a different namespace
  (`research/public.md` [1]).
- **KSOPS decryption of the platform credentials** reuses Storage's established
  `generators:` pattern, in a new self-contained `secrets/dev/platform/keycloak/`
  sub-kustomization referenced by the keycloak overlay as
  `../../../../secrets/dev/platform/keycloak` (four levels up — one deeper than
  Storage's three, because the reference originates from the `keycloak/`
  subdirectory). This keeps every KSOPS `files:` reference within one kustomization
  root (the default `LoadRestrictionsRootOnly` never trips) and is the **first Secret
  committed under a `platform/` prefix** — see § The committed-secret path convention.

### Intra-`keycloak` sync-wave scheme

`gitops-argocd` fixed the cross-layer waves (`core=0`, `storage=1`, `platform=2`, …).
This step defines the ordering *inside* its own subdirectory, mirroring Storage's
four-tier scheme (annotations via `commonAnnotations` on nested kustomizations,
inline on authored CRs):

- **wave `-10` — Operator + CRDs + namespace:** the `keycloak` Namespace and the
  Operator's two CRDs, controller Deployment, and RBAC.
- **wave `-5` — the decrypted credential Secrets and the `keycloak` `Database` CR:**
  the KSOPS-generated `keycloak-db` and `keycloak-admin` Secrets in `keycloak`,
  present before the `Keycloak` CR references them, **and the `keycloak` `Database` CR**
  (in `storage`), so the `keycloak` PostgreSQL database physically exists before the
  `Keycloak` CR's pod ever tries to connect to it. **Corrected placement** (see §
  Correction by the long-loop reviewer (2026-07-09) below): the `Database` CR was
  originally scheduled at wave `5`, *after* the wave-`0` `Keycloak` CR that connects to
  it — a hard ArgoCD sync deadlock, not a safe ordering. Its only real prerequisites —
  the CNPG operator and the `keycloak` role — are already live from the `storage`
  layer's own sync (sync-wave 1), not from anything in this component, so moving it to
  wave `-5` (alongside the two sealed Secrets) breaks the cycle cleanly.
- **wave `0` — the `Keycloak` CR:** needs the Operator's webhook up, both Secrets
  present, and the `keycloak` database already created (wave `-5`, above). (The shared
  `postgres` Cluster and the `keycloak` role it connects to are provisioned by the
  `storage` layer, sync-wave 1 — which lands before `platform`, sync-wave 2 — so
  Postgres and the role already exist by the time this CR reconciles.)
- **wave `5` — the dependent resources:** the `KeycloakRealmImport` (needs the
  `Keycloak` CR Ready) and the HTTPRoute (needs the Operator to have created
  `keycloak-service`).

ArgoCD syncs waves ascending and waits for each Healthy before the next.

### The Keycloak Operator install (raw pinned manifests)

Three raw manifests from `keycloak/keycloak-k8s-resources` at a pinned version tag
(exact pin deferred to build-time `research:public`; current stable is the 26.6.x
line — 26.6.3, 2026-06-04): the two CRDs (`keycloaks.k8s.keycloak.org-v1.yml`,
`keycloakrealmimports.k8s.keycloak.org-v1.yml`) and the operator Deployment/RBAC
manifest (`kubernetes.yml`), all as `resources:` pinned-URL entries in
`operator/kustomization.yaml`. The Operator lives in the `keycloak` namespace and,
per the upstream docs, is **not** expected to watch multiple namespaces — which is
why the `Keycloak` and `KeycloakRealmImport` CRs co-locate with it here (settled by
the research reviewer; `research.md` § Resolved Decisions (f)). Pin explicitly; do
not float the tag.

### The `Keycloak` CR (external Postgres, no bundled H2, plain-HTTP exposure)

One `Keycloak` CR named `keycloak` in the `keycloak` namespace:

- `spec.instances: 1` (dev; production HA would raise this).
- `spec.db.vendor: postgres`, `spec.db.host: postgres-rw.storage.svc`,
  `spec.db.port: 5432`, `spec.db.database: keycloak`,
  `spec.db.usernameSecret: {name: keycloak-db, key: username}`,
  `spec.db.passwordSecret: {name: keycloak-db, key: password}`. Setting `spec.db` is
  precisely what opts out of the bundled dev H2 database.
- `spec.ingress.enabled: false` (disables the Operator's own Ingress; the
  Operator still creates the `keycloak-service` ClusterIP Service).
- `spec.http.httpEnabled: true` (opens the plain-HTTP `:8080` listener the HTTPRoute
  targets — the first-class toggle that avoids ArgoCD's backend-TLS dance).
- `spec.hostname.hostname: https://auth.127.0.0.1.nip.io` and
  `spec.proxy.headers: xforwarded` so Keycloak's self-generated issuer/redirect URLs
  are correct behind the TLS-terminating Gateway. (`spec.hostname.strict` and the
  exact `proxy.headers` value are build-time live-verified — research open item 6.)
- `spec.bootstrapAdmin.user.secret: keycloak-admin` (the sealed admin credential).

The exact CRD field spellings are build-verified against the pinned Operator; the
design fixes the shapes and names, the build confirms spellings and corrects the
feature-test selectors if a `status` string differs (the test is RED now regardless).

### The credential: one password, two namespaces (the load-bearing nuance)

Keycloak's DB role needs the **same** username/password visible to two consumers in
two different namespaces, and Kubernetes Secrets are namespace-scoped:

- **CNPG** sets the `keycloak` role's password from `managed.roles[].passwordSecret:
  {name: keycloak-db}` — a Secret resolved in the **`storage`** namespace (the
  Cluster's namespace).
- **The `Keycloak` CR** reads `spec.db.usernameSecret`/`passwordSecret: {name:
  keycloak-db}` — a Secret resolved in the **`keycloak`** namespace (the CR's
  namespace).

So the one credential is materialized as **two Secrets named `keycloak-db`, one per
namespace, carrying the identical generated password**:

1. `secrets/dev/storage/postgres/keycloak.enc.yaml` → Secret `keycloak-db`
   (`metadata.namespace: storage`, `type: kubernetes.io/basic-auth`,
   `username: keycloak`), **added to Storage's existing KSOPS generator**
   (`secrets/dev/storage/secret-generator.yaml`) — exactly the touch Storage's
   consumption contract sanctions ("seal a credential into
   `secrets/dev/storage/postgres/<slug>.enc.yaml` and add its file to the KSOPS
   generator").
2. `secrets/dev/platform/keycloak/keycloak-db.enc.yaml` → Secret `keycloak-db`
   (`metadata.namespace: keycloak`, same shape, **same password**), in this feature's
   own new platform KSOPS generator.

**Build-time discipline:** generate the DB password **once** in memory, then seal it
into *both* encrypted files (each a `kubectl create secret … --dry-run=client -o yaml
| sops --encrypt`, differing only in `metadata.namespace`), so the two Secrets stay
in lockstep. A single generated value, two ciphertext files. This makes the cleared
research's "one sealed Secret serves both consumers" **precise** rather than
contradicting it: the research settled that no new *sealing mechanism* is needed (one
credential, one basic-auth shape, one `openssl rand → sops` pipeline), which holds.
What its shorthand glossed is that Kubernetes Secrets cannot cross namespaces, so the
one credential is *materialized* as two Secret objects once the reviewer-settled
namespace split puts CNPG in `storage` and the `Keycloak` CR in `keycloak`. This is
the sole point where this feature diverges from Storage's single-namespace `smoke-db`
pattern, and it is forced by that split, not a stylistic choice.

The **admin** credential is single-namespace and single-consumer:
`secrets/dev/platform/keycloak/keycloak-admin.enc.yaml` → Secret `keycloak-admin`
(`metadata.namespace: keycloak`, keys `username`+`password`), sealed by the identical
`openssl rand`→stdin→`sops --encrypt` pipeline, in this feature's platform generator.

### The DB provisioning (Storage consumption contract)

Two declarative mechanisms, exactly as Storage's contract prescribes:

- **Role:** append **one** entry to the shared `postgres` Cluster's
  `spec.managed.roles[]` in `storage/overlays/dev/postgres-cluster.yaml` —
  `{name: keycloak, login: true, passwordSecret: {name: keycloak-db}}`. This is the
  one shared, append-only edit (the same shape as Networking's Gateway `dnsNames`
  append). CNPG creates/updates the `keycloak` role and sets its password from the
  `storage`-namespace `keycloak-db` Secret.
- **Database:** author a `Database` CR `{name: keycloak, owner: keycloak, cluster:
  {name: postgres}}` in this feature's own `platform/overlays/dev/keycloak/
  keycloak-database.yaml`, **carrying `metadata.namespace: storage`** (forced by
  CNPG's same-namespace-only `LocalObjectReference` — the load-bearing namespace
  correction; the file lives in this feature's tree but the object lands in
  `storage`, exactly as `core`'s `Certificate`/`Gateway` land in `istio-ingress`).

Keycloak then connects with the DSN
`postgres://keycloak:<pw>@postgres-rw.storage.svc:5432/keycloak`.

### The realm bootstrap (declarative `KeycloakRealmImport`)

One `KeycloakRealmImport` CR named `agrippa` in the `keycloak` namespace:
`spec.keycloakCRName: keycloak` (binds to the same-namespace `Keycloak` CR — the
constraint that helped force the single-namespace co-location), `spec.realm` a
minimal inline `RealmRepresentation` (`{id: agrippa, realm: agrippa, enabled: true,
displayName: Agrippa}`). Proof-object minimal, mirroring Storage's `smoke` fixture —
a single dev realm proving the declarative import mechanism works end-to-end, **not**
a fully-populated production realm (no clients/roles/users pre-seeded; a later OIDC
consumer adds a client when it needs one). Any secret material a richer realm later
needs (a client secret) uses the Operator's `spec.placeholders` sealed-Secret
substitution rather than inline plaintext — the same "reference a sealed Secret,
never inline the value" discipline used everywhere else; not exercised by this
minimal import.

### Exposure (Networking consumption contract)

- **HTTPRoute** `keycloak` in the `keycloak` namespace, copying
  `core/overlays/dev/argocd-httproute.yaml`'s exact shape: `parentRefs: [{name:
  agrippa-gateway, namespace: istio-ingress, sectionName: https}]`, `hostnames:
  [auth.127.0.0.1.nip.io]`, `rules: [{matches: [{path: {type: PathPrefix, value:
  /}}], backendRefs: [{name: keycloak-service, port: 8080}]}]`. The explicit
  `matches:` is authored (not omitted) to dodge the same nested-array
  structural-default OutOfSync Networking documented. **No `DestinationRule`** — the
  plain-HTTP `:8080` listener means no backend-TLS re-origination (the whole reason
  the research chose `spec.http.httpEnabled: true`).
- **Certificate `dnsNames` append:** add `auth.127.0.0.1.nip.io` to the shared
  `agrippa-gateway-tls` certificate's `dnsNames` in
  `core/overlays/dev/gateway-cert.yaml` — one line to the shared append-only list,
  never a change to the `Gateway` object itself (the Networking contract's exact
  mechanism). No `ReferenceGrant` is needed (the cert Secret is in the Gateway's own
  namespace; the backend is same-namespace as the route; cross-namespace *attachment*
  is governed by the listener's `allowedRoutes.namespaces.from: All`).

### The `apps/platform.yaml` sync seam (shared with three siblings)

`apps/platform.yaml` currently carries **neither** the `syncOptions` block **nor** the
`compare-options` annotation (live-verified: its `syncPolicy` has only `automated`).
Keycloak ships two webhook-backed CRDs (`Keycloak`, `KeycloakRealmImport`) plus a
controller that defaults spec/status fields the way CNPG's `Cluster` webhook does — so
`platform` needs the identical seam `core`/`storage` carry. This step adds the **full,
two-part** seam, copying `apps/storage.yaml`'s exact pattern verbatim:

- `metadata.annotations`: `argocd.argoproj.io/compare-options: ServerSideDiff=true`
- `spec.syncPolicy.syncOptions`: `[ServerSideApply=true,
  SkipDryRunOnMissingResource=true]`

Both halves are required together: `ServerSideApply=true` alone auto-enables
Structured Merge Diff, which mispredicts CRD-webhook-defaulted fields and reproduces
the permanent-OutOfSync bug (argoproj/argo-cd#22151) `networking-istio` hit and
`storage` pre-empted; `ServerSideDiff=true` forces a real API-server dry-run diff.

**This file is shared by the three parallel `platform`-layer siblings (Auth, Forgejo,
Flagsmith).** All three independently need this identical seam. Whichever build lands
first adds it; the other two find it already present (idempotent — no conflict if
specified identically to `apps/storage.yaml`'s pattern). The build phase MUST treat
"already there" as success, not a surprise. (Observability lands in its own
`observability` Application and does not touch this file.) The `platform/overlays/dev/
kustomization.yaml` `resources:` append below is the same shape of shared touch; its
ordering among the three siblings is a **coordinator sequencing** concern (last-writer
-wins on one shared list), not this design's to solve beyond noting it.

### Cross-step touches (summary)

- **`apps/platform.yaml`** — add the full two-part sync seam (annotation +
  syncOptions), copying `apps/storage.yaml` verbatim. Shared with Forgejo/Flagsmith;
  idempotent; whoever lands first adds it.
- **`platform/overlays/dev/kustomization.yaml`** — append `keycloak/` to the
  `resources:` list (currently `[argocd.yaml]`). Shared with Forgejo/Flagsmith;
  coordinator sequences the append order.
- **`storage/overlays/dev/postgres-cluster.yaml`** — append the `keycloak`
  `managed.roles[]` entry (the shared append-only list; Storage's consumption
  contract). Shared with Forgejo/Flagsmith (each appends its own role).
- **`secrets/dev/storage/postgres/keycloak.enc.yaml`** (new) + add its filename to
  **`secrets/dev/storage/secret-generator.yaml`**'s `files:` — Storage's consumption
  contract's KSOPS-generator touch, materializing `keycloak-db` in `storage`.
- **`secrets/dev/platform/keycloak/…`** (new) — this feature's own platform KSOPS
  generator + the `keycloak-db` (keycloak-namespace copy) and `keycloak-admin`
  encrypted Secrets. First Secrets committed under a `platform/` prefix.
- **`core/overlays/dev/gateway-cert.yaml`** — append `auth.127.0.0.1.nip.io` to
  `dnsNames` (the Networking consumption contract's shared append-only list). Shared
  with Forgejo/Flagsmith (each appends its own host).
- **`scripts/test-feature.sh`** — add `auth.bats` to the probe-suite exclusion `case`
  list (line 71; it drives the long-lived `agrippa-dev` cluster and the
  GitOps-reconciled `platform` layer, not the throwaway `agrippa-feature` cluster) —
  the same one-line, convention-consistent edit `networking.bats`/`storage.bats`
  already made. **This exclusion lands with the feature test in the design phase**
  (mirroring the siblings): the test is committed now, so without it `mise run
  test:feature` would pick `auth.bats` up and loop against a Keycloak-less cluster.
- **`mise.toml`** — no new tool pins (raw manifests, no CLI; see Libraries & Skills).
- **`.sops.yaml`** — no change (the `^secrets/dev/.*$` rule already carries the real
  recipient and already matches `secrets/dev/platform/…` paths).
- **`scripts/test-static.sh`** — no change (its conftest walk already recurses all of
  `secrets/`, live-confirmed, so the new encrypted files are covered by the plaintext
  guard automatically).

### Challenges

- **Version pin deferred to build.** The Operator/Keycloak version (the three
  raw-manifest URLs' tag) is build-time `research:public`, consistent with how
  Storage/Networking deferred their upstream versions. Pin explicitly; do not float.
- **Exact CRD field and status-string spellings.** The `Keycloak`/`KeycloakRealmImport`
  field paths (`spec.db.database`, `spec.hostname.hostname`/`.strict`,
  `spec.proxy.headers`, `spec.http.httpEnabled`, `spec.bootstrapAdmin.user.secret`)
  and the CR `status` condition strings the feature test selects on (`Ready`/`Done`
  and their exact spelling) are build-verified against the pinned Operator. The
  design fixes the shapes and names; the build confirms spellings and corrects the
  feature-test selectors if any differ (the test is RED now regardless).
- **Operator RBAC namespace binding.** The upstream `kubernetes.yml` may bind its
  ServiceAccount RBAC to a default namespace; if that is not `keycloak`, patch the
  ClusterRoleBinding subject at build (`research/public.md` [1] flags this).
- **Cross-namespace DB reachability inside the mesh.** Keycloak → `postgres-rw.storage`
  is a plain cross-namespace ClusterIP hop, which works with or without ambient-mesh
  membership. Whether to label the `keycloak` namespace `istio.io/dataplane-mode:
  ambient` (so ztunnel mTLS-wraps the hop) is an optional build-time nicety, not a
  reachability requirement.
- **`platform` permanent-OutOfSync residue.** If a specific Keycloak-controller-owned
  field still drifts after the full sync seam, add a narrowly-scoped
  `ignoreDifferences` at build (mirroring `apps/core.yaml`'s istiod-webhook scoping),
  not a blanket ignore.

## Alternatives

- **The community `codecentric/keycloakx` Helm chart instead of the Operator.**
  Rejected on the cleared research: it supports external Postgres and admin
  credentials but has **no declarative realm import** — only Keycloak's imperative
  container-level `--import-realm` flag (a run-once, first-boot file load), a
  materially less GitOps-native mechanism than the continuously-reconciled
  `KeycloakRealmImport` CR every other declarative resource in this project mirrors.
- **Bitnami's `bitnami/keycloak` chart.** Rejected: caught in the same 2025 Broadcom
  paywall restructuring already ruled out for Storage's Postgres/Valkey — confirmed to
  apply to `bitnami/keycloak` identically (`research/public.md` § Falsification pass).
- **No official Keycloak Helm chart exists at all** — the naive "just use the official
  chart" default does not survive contact (only an Operator, installed by raw
  manifests, is officially documented; the community request for an Operator Helm
  chart is still open). So the choice was Operator-vs-community-chart, and the Operator
  wins on its own merits (declarative realm import) independent of Bitnami's licensing.
- **Mirroring CNPG's operator/operand namespace split** (Operator in one namespace,
  CRs in another). Rejected: the Keycloak Operator does not fully support
  multi-namespace watching, and `KeycloakRealmImport.spec.keycloakCRName` binds
  same-namespace — the opposite shape from CNPG, so the Operator + both CRs co-locate
  in one `keycloak` namespace (settled by the research reviewer).
- **A `keycloak` namespace `Database` CR** (co-locating it with the rest of this
  feature's resources). Rejected: CNPG's `Database.spec.cluster` is a same-namespace
  `LocalObjectReference` (issue #6043) — it must be `metadata.namespace: storage` or
  it silently never reconciles.
- **Backend-TLS re-origination via a `DestinationRule`** (the `argocd-server`
  precedent). Rejected as unnecessary: Keycloak's `spec.http.httpEnabled: true` opens
  a plain-HTTP `:8080` listener, so the HTTPRoute targets it directly with no second
  TLS object (Istio ambient's ztunnel still mTLS-wraps the pod hop within the mesh).
- **Mirroring a prod hostname** (`auth.davidsouther.com.127.0.0.1.nip.io` /
  `sso.…`). Rejected because no such prod host is recorded anywhere
  (`ARCHITECTURE.html`/`ROUTING.md`/`DEVELOPMENT.md`/`tests/agrippa.bats`) — so the
  service-name-direct `auth.127.0.0.1.nip.io` follows ArgoCD's precedent (a service
  with no named prod host gets the scheme's suffix applied to the service name),
  not Grafana's full-mirror precedent (which exists only because `DASHBOARD_HOST` is
  a recorded prod host). See Open Artifact Decisions.
- **A throwaway realm the test creates and deletes** instead of the standing `agrippa`
  realm. Rejected for the same reason Storage kept a permanent `smoke` fixture:
  ArgoCD's `prune`/`selfHeal` re-creates any declarative resource a test tears down,
  so a permanent standing realm is the honest health-check target.

## Summary

This feature-step lands Keycloak into the already-Synced `platform` layer (sync-wave
2) as the local Tier-2 OIDC identity provider: the **Keycloak Operator** (raw pinned
manifests) in a new `keycloak` namespace, one **`Keycloak` CR** wired to the shared
`postgres` Cluster over a plain-HTTP listener, one declarative **`KeycloakRealmImport`**
of a minimal `agrippa` dev realm, and exposure through the shared `agrippa-gateway`
with a local-CA cert at `auth.127.0.0.1.nip.io`. It is a **pure consumer** of two
already-landed shared contracts — Storage's (`managed.roles[]` append + a
`metadata.namespace: storage` `Database` CR + a sealed `keycloak-db` credential) and
Networking's (one HTTPRoute + one `dnsNames` append) — and defines no contract of its
own. Its one genuinely novel correctness point is the **two-namespace credential
materialization** (one generated password sealed into a `storage`-namespace Secret for
CNPG and a `keycloak`-namespace Secret for the `Keycloak` CR), forced by the
Keycloak/CNPG namespace split. It also adds the full two-part CRD-heavy-operator sync
seam (`ServerSideApply`/`SkipDryRunOnMissingResource` + `ServerSideDiff`) to the
shared `apps/platform.yaml`, idempotently coordinated with the two parallel siblings.
The one feature test proves the whole path end-to-end: the `platform` Application
Synced/Healthy, the `Keycloak` CR Ready, the realm imported and DB-persisted, and the
`agrippa` realm's OIDC discovery endpoint reachable through the Gateway with the
local-CA cert.

This Design-phase run does **not** deploy the Auth content: reconciling it requires a
full ArgoCD sync of newly-committed manifests, the credential sealing is build-phase
work, and the exact Operator version pin, CRD field spellings, and CR status strings
want live re-verification at build time. The feature test is therefore left **RED**
(baseline recorded below); the build phase turns it green after sealing the two
credentials, committing the composition and the shared-file touches, and letting
ArgoCD reconcile it.

### Open Artifact Decisions

Concrete artifact choices this design invents that are not fixed by a skill template,
an existing project convention, or the cleared `research.md` (whose reviewer block
already settled the Operator-vs-chart choice, the Keycloak/CNPG namespace split, the
`spec.db`/`bootstrapAdmin`/`ingress`/`http` wiring, and the declarative-realm-import
mechanism — all stated above as conclusions, not surfaced here). The
`research.md` § "Open for the design phase" items 1-3 map onto these.

**The dev hostname — `auth.127.0.0.1.nip.io`** (research open item 1). The choice is
service-name-direct (following ArgoCD's precedent) vs full-prod-mirror (Grafana's
precedent). No `auth`/`sso`/`keycloak` prod host is recorded anywhere in the repo, so
the full-mirror form has no prod host to mirror.
Proposed: `auth.127.0.0.1.nip.io` (service-name-direct). The feature test binds to
this exact host; a different spelling desyncs the test.

**The namespace, CR, Secret, and realm names — `keycloak` namespace; `keycloak`
`Keycloak` CR (→ `keycloak-service`); `keycloak-db` / `keycloak-admin` Secrets;
`agrippa` realm** (research open item 2). Proposed as named throughout the
Specification, following the app-slug convention Storage established (database = role
= slug = `keycloak`) and the `agrippa-*` family for the realm. The realm id/name
`agrippa` (mirroring `agrippa-dev`/`agrippa-gateway`/`agrippa-ca`) is the one genuinely
free pick; `dev` or `local` were the alternatives, rejected as less on-brand and less
descriptive of "this platform's realm." The feature test binds to `keycloak-service`
and the `agrippa` realm path.

**The committed-secret path convention under `platform/` —
`secrets/dev/platform/keycloak/<secret>.enc.yaml`** (research open item 3). This is
the **first** Secret committed under a `platform/` prefix. It generalizes Storage's
`secrets/dev/<layer>/<component>/<slug>.enc.yaml` grouping cleanly (`<layer>=platform`,
`<component>=keycloak`), and its self-contained sub-kustomization mirrors
`secrets/dev/storage/`'s exactly. The `storage`-namespace copy of the DB credential
follows Storage's *existing* convention unchanged (`secrets/dev/storage/postgres/
keycloak.enc.yaml`), so only the new `platform/` grouping is invented here.
Proposed: as stated. The alternative — folding the keycloak-namespace DB Secret under
`secrets/dev/storage/` too — was rejected because it is not a storage credential and
would muddy Storage's per-store grouping. Forgejo and Flagsmith will each add their
own `secrets/dev/platform/<component>/` sibling under this same new prefix.

### Resolved by the long-loop reviewer (2026-07-08)

A separately dispatched long-loop reviewer read this feature-step's `design.md` cold,
re-verified its live claims against the working tree and the running `k3d-agrippa-dev`
cluster (read-only), and decided the three Open Artifact Decisions above to the
conservative default. No `reviews/` intent-review subfolder exists, so there were no
intent-review questions to fold in. No escalation trigger (irreversible, out of
recorded scope, or underdetermined) fired, so this design draft gate is cleared (top
marker now `Reviewed`). The two scrutiny points the design surfaces — the
two-namespace credential materialization and the `apps/platform.yaml` sync seam — were
independently re-verified and require no change (recorded as entries 4-5 for the audit
trail). CRD field/status-string spellings and the exact Operator version pin remain
correctly deferred to build-time `research:public`, unchanged by this review.

**1. The dev hostname — `auth.127.0.0.1.nip.io`. Decided: adopt as proposed
(service-name-direct, following ArgoCD's precedent).** Reversible (a hostname string;
the feature test binds to it but that coupling is within this feature-step), in
recorded scope, and determinate. Re-verified independently: no `auth`/`sso`/`keycloak`
prod host is recorded anywhere in the repo — `tests/agrippa.bats` records only
`davidsouther.com` (`PUBLIC_HOST`), `trips.davidsouther.com` (`TRIPS_HOST`), and
`dashboard.davidsouther.com` (`DASHBOARD_HOST`), and `ROUTING.md` treats Keycloak as
*in-cluster OIDC* gating paths (`davidsouther.com/agathon`), never as its own
hostname. So the full-prod-mirror form (Grafana's `dashboard.davidsouther.com`
precedent, which exists only because that prod host is recorded) has nothing to
mirror; the service-name-direct scheme applied to a host with no recorded prod name is
exactly ArgoCD's live precedent (`argocd.127.0.0.1.nip.io` in
`core/overlays/dev/gateway-cert.yaml`, live-verified). Conservative default = the
proposed spelling.

**2. The namespace, CR, Secret, and realm names — `keycloak` namespace; `keycloak`
`Keycloak` CR (→ `keycloak-service`); `keycloak-db` / `keycloak-admin` Secrets;
`agrippa` realm. Decided: adopt as proposed.** Reversible, in recorded scope, and
determinate from an established convention. The database = role = slug = `keycloak`
naming is exactly the app-slug convention Storage established and named Keycloak as
the worked example of (`storage-postgres-valkey/design.md` § User Journey uses `{name:
keycloak, login: true, passwordSecret: {name: keycloak-db}}` verbatim); the live
`postgres` Cluster's only current role is `smoke`, confirming the append shape. The
one genuinely free pick, the realm id `agrippa`, sits in the same `agrippa-*` family
as the live `agrippa-dev`/`agrippa-gateway`/`agrippa-ca` objects and is more
descriptive than `dev`/`local`. Conservative default = the proposed names.

**3. The committed-secret path convention under `platform/` —
`secrets/dev/platform/keycloak/<secret>.enc.yaml`. Decided: adopt as proposed.**
Reversible, in recorded scope, and a clean generalization of the settled Storage
convention. Storage's live layout is `secrets/dev/storage/<store>/<slug>.enc.yaml`
(verified: `secrets/dev/storage/postgres/smoke.enc.yaml`,
`secrets/dev/storage/valkey/smoke.enc.yaml`), so `<layer>=platform`,
`<component>=keycloak` is the natural extension, and its self-contained
`generators:`-only sub-kustomization mirrors `secrets/dev/storage/`'s exactly. The
`.sops.yaml` creation rule `^secrets/dev/.*$` already matches
`secrets/dev/platform/…` (verified in-file), so no `.sops.yaml` change is required.
The `storage`-namespace copy of the DB credential stays under Storage's *existing*
`secrets/dev/storage/postgres/keycloak.enc.yaml` grouping unchanged. Conservative
default = the proposed prefix.

**4. Scrutiny — the two-namespace credential materialization. Verified; no change; no
escalation.** The design's reasoning is sound and its "reaching into Storage's scope"
reading is correct, not an overreach. One generated password is materialized as two
namespace-scoped Secret objects (`keycloak-db` in `storage` for CNPG's
`managed.roles[].passwordSecret`, resolved in the Cluster's namespace; `keycloak-db`
in `keycloak` for the `Keycloak` CR's `spec.db.*Secret`, resolved in the CR's
namespace) because Kubernetes Secrets are namespace-scoped and the reviewer-settled
Keycloak/CNPG namespace split forces the two consumers apart. The `storage`-namespace
copy (a new `secrets/dev/storage/postgres/keycloak.enc.yaml` + one filename appended
to `secrets/dev/storage/secret-generator.yaml`) plus the one `managed.roles[]` entry
appended to `storage/overlays/dev/postgres-cluster.yaml` is **precisely** the
consumption contract Storage's own design published for Features 5-8:
`storage-postgres-valkey/design.md` names Keycloak as the literal worked example of a
later consumer that "(a) seals a random credential into
`secrets/dev/storage/postgres/keycloak.enc.yaml` … (b) appends one entry to …
`spec.managed.roles[]` — `{name: keycloak, login: true, passwordSecret: {name:
keycloak-db}}` … (c) authors its own `Database` CR." The live generator currently
carries `postgres/smoke.enc.yaml` + `valkey/smoke.enc.yaml`, and the live Cluster's
`managed.roles[]` carries only `smoke` — appending one more of each is the same
"later feature appends to a settled append-only shared list" shape as the Gateway
`dnsNames` append (which this step also makes), not a re-opening of Storage's
cleaned-up feature-step. It does **not** need flagging beyond the design's own
Cross-step-touches note. Escalation triggers: none — additive, reversible, and
explicitly in Storage's recorded contract scope.

**5. Scrutiny — the `apps/platform.yaml` sync seam. Verified correct and internally
consistent; no change; no escalation.** Live-verified: `apps/platform.yaml` carries no
seam (empty `syncOptions`, no `compare-options` annotation), while `apps/core.yaml`
and `apps/storage.yaml` both carry the full two-part seam this design copies — the
`argocd.argoproj.io/compare-options: ServerSideDiff=true` annotation **and**
`syncOptions: [ServerSideApply=true, SkipDryRunOnMissingResource=true]` (confirmed in
both files and on the live `core`/`storage` Applications, whose syncOptions read
`["ServerSideApply=true","SkipDryRunOnMissingResource=true"]`). The design specifies
both halves, cites the correct `argoproj/argo-cd#22151` rationale that both files' own
comments document (`ServerSideApply=true` alone auto-enables Structured Merge Diff,
which mispredicts webhook-defaulted CRD fields and leaves the Application permanently
OutOfSync; `ServerSideDiff=true` forces a real dry-run diff), and correctly frames the
touch as additive, idempotent, and last-writer-wins-safe across the three
`platform`-layer siblings (Auth/Forgejo/Flagsmith), with Observability landing in its
own `observability` Application (live-confirmed separate, does not touch this file).
Internally consistent with the cited `apps/core.yaml`/`apps/storage.yaml` pattern.
Escalation triggers: none.

### Correction by the long-loop reviewer (2026-07-09): `keycloak` `Database` CR wave moved from `5` to `-5`

The plan-gate reviewer (dispatched over the `plan.md` this design feeds) found
that § Intra-`keycloak` sync-wave scheme's original placement of the `keycloak`
`Database` CR at wave `5` — *after* the wave-`0` `Keycloak` CR that connects to it
— is a hard ArgoCD sync deadlock, not a safe ordering, and applied the fix
directly (§ scheme above now places the `Database` CR at wave `-5`, alongside the
two sealed Secrets). This is the **third confirmed instance of one well-understood
bug class** in this parallel platform band: the `feature-flags-flagsmith` plan-gate
reviewer found Flagsmith's api pod blocks in `migrate`/`waitfordb` initContainers
until its database exists and resequenced its own `Database` CR to wave `-5`; the
`git-hosting-forgejo` plan-gate reviewer found Forgejo's Gitea binary crash-loops
on a missing database (go-gitea/gitea#27079), which the coordinator fixed by moving
that `Database` CR to wave `-5` (see `../git-hosting-forgejo/design.md`'s own
"Correction by the coordinator (2026-07-09)"). With two confirmed sibling
precedents and a coordinator-blessed template, this third instance is a *decide*,
not an *escalate*.

**Keycloak's actual startup/DB behavior was researched specifically (`research:public`),
not assumed identical to a Go binary's `log.Fatal`.** The verdict is the same
deadlock class, for Keycloak's own reasons: Keycloak (Quarkus/JVM) opens a JDBC
connection to the *target* database (`spec.db.database: keycloak`) at startup to run
its Liquibase schema migration; it creates the schema (tables) inside an existing
database but never issues `CREATE DATABASE`, so a missing `keycloak` database yields
`FATAL: database "keycloak" does not exist` ("Failed to obtain JDBC connection",
keycloak/keycloak#19607), Keycloak's `start` fails, and the container exits into
CrashLoopBackOff — it does not sit and wait for the database to appear on first boot.
The Keycloak Operator gates the `Keycloak` CR's `Ready` condition on the pod's
`/health/ready` probe, which cannot pass until that migration succeeds, so the
`Keycloak` CR never reaches `Ready` while the database is absent. Placing the
`Database` CR (the sole creator of database `keycloak`) at wave `5`, behind the
health-gated wave-`0` `Keycloak` CR, is therefore the same circular deadlock Forgejo
hit: the CR that needs the database can never go Ready, so ArgoCD never advances to
the wave that would create it — and CNPG does not auto-create the database (its
`managed.roles[]` append creates only the *role*; the `Database` CR is the sole
creator, exactly as Storage's `smoke` proved). Storage's own `smoke` `Database` sits
at wave `5` safely only because nothing in `storage` consumes the smoke database with
a DB-gated startup; Keycloak is a wave-`0` consumer of its own database, so it is
subject to the deadlock the smoke fixture never was.

The fix — moving the `keycloak` `Database` CR to wave `-5`, ahead of the wave-`0`
`Keycloak` CR — is mechanical, low-risk, reversible, paper-only (no live cluster or
already-built sibling touched), and identical in shape to both siblings' resolutions.
The CR's only real prerequisites (the CNPG operator and the `keycloak` role) are
already live from the `storage` layer's own sync (sync-wave 1) before `platform`
(sync-wave 2) starts, so the earlier wave loses nothing. The `plan.md` this design
feeds is updated to match (the `Database` CR folded from its old Step 4 into Step 2 at
wave `-5`; downstream steps adjusted), and its own draft gate is cleared against the
corrected design.

## Feature Test

**Path:** `tests/auth.bats` (following `DEVELOPMENT.md`'s `tests/<feature>.bats`
convention, feature = "auth"; the `-keycloak` tool qualifier is dropped just as
`cluster-core.bats` dropped `-k3d`, `gitops.bats` dropped `-argocd`, `networking.bats`
dropped `-istio`, and `storage.bats` dropped `-postgres-valkey`).

**User story (Given / When / Then):** *Given* the bootstrapped long-lived
`agrippa-dev` cluster (Features 1-4) with this Auth content committed and reconciled
by ArgoCD into the `platform` layer — the Keycloak Operator in the `keycloak`
namespace, the `Keycloak` CR wired to the shared `postgres` Cluster, the `keycloak`
`Database` CR in `storage`, and the declaratively-imported `agrippa` realm, *When* an
operator requests the `agrippa` realm's OIDC discovery document at
`https://auth.127.0.0.1.nip.io/realms/agrippa/.well-known/openid-configuration`
through the k3d `:443` host port-map, *Then* the `platform` Application is
Synced/Healthy, the `Keycloak` CR reports Ready and the `KeycloakRealmImport` reports
done, the `keycloak` `Database` CR (in `storage`) is applied, the discovery endpoint
returns 200 with `issuer` `https://auth.127.0.0.1.nip.io/realms/agrippa` (proving the
realm was imported, persisted in Postgres, and served correctly behind the
reverse-proxying Gateway), and the TLS certificate presented is **issued by the local
CA** (`CN=Agrippa Local Dev CA`), not the Operator's built-in default — proving the
Operator + external-Postgres + declarative-realm-import + shared-Gateway/HTTPRoute/
local-CA-TLS path end-to-end. `curl -k` tolerates the deliberately-untrusted local CA.
Like its sibling suites it deliberately does **not** tear the cluster, Keycloak, or
the realm down.

**Current state: RED (baseline captured this run, verified live 2026-07-08).** The
`platform` Application is already `Synced/Healthy` on its current `argocd.yaml`-only
content (live-confirmed) — so the suite's THEN 0 precondition (`platform`
Synced/Healthy) passes even now, exactly as `storage.bats`'/`networking.bats`' THEN 0
passed on empty layers. The RED comes at THEN 1 onward: the `keycloak` namespace does
not exist, no Keycloak CRDs exist (`kubectl get crds | grep keycloak` → none), the
`Keycloak`/`KeycloakRealmImport`/`Database` CRs do not exist, and nothing serves
`auth.127.0.0.1.nip.io` (not in the Gateway cert's `dnsNames`, no HTTPRoute) — so the
suite fails there. That red state defines "done." This Design-phase run does **not**
turn it green: sealing the two credentials, committing the composition and the
shared-file touches, and the ArgoCD reconcile are all build-phase work outside this
phase's write-only-the-test gate.
