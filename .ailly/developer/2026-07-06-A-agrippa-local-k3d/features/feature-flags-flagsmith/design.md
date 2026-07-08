# Feature Design: Feature flags (Flagsmith)

*Draft 2026-07-08*

> Feature-step design (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 7: Feature flags
> (Flagsmith)** of that project's plan: a `platform`-layer (sync-wave 2),
> Postgres-backed service, parallel with Feature 5 (Auth/Keycloak) and Feature 6
> (Git hosting/Forgejo), consuming Feature 4's storage-class + per-app DB/role
> naming contract and Feature 3's Gateway/HTTPRoute/hostname/TLS contract. It has
> its own feature test (recorded below). The project as a whole is measured by
> `closing-bell.md`, not by this test.
>
> This is a **small-to-medium** feature-step (one first-party Helm release plus
> three sealed credentials, one Database CR, one hand-authored HTTPRoute, and two
> append-only edits to shared files), so it stays near the one-page norm rather
> than running long like the `storage`/`networking` ensemble steps. Its research
> (`research.md`, `research/public.md`) is Reviewed; the reviewer block there
> (`Resolved by the long-loop reviewer`) settled all six research-phase open
> items — the chart choice, the three-Secret shape and names, the accepted
> browser password-reset bootstrap, the `flagsmith.127.0.0.1.nip.io` hostname,
> the feature-test reach, and the empirically-confirmed "no Redis" — and those
> decisions are carried in below as settled inputs, not re-litigated. This is a
> **long-loop** run: the draft gate is left open (`*Draft*`) for a separately
> dispatched reviewer to clear.

## Libraries & Skills (carry forward to plan and build)

Per this feature-step's cleared `research.md` (§ Libraries & Skills) and the
project `design.md`, the plan and build phases MUST load these skills via the
harness's skill-loading mechanism before working:

- **`developer:initialize`** — for any residual `mise` tool-pin work. This
  feature adds **no** new mise-managed CLI: Flagsmith is an in-cluster Helm
  release ArgoCD reconciles, not a local tool. Every CLI the credential-sealing
  and bootstrap steps need (`sops`, `age`, `kustomize`, `helm`, `kubectl`,
  `k3d`, `yq`, `jq`, `bitwarden`, `openssl`) is already pinned in `mise.toml`
  (live-confirmed, unchanged since `storage-postgres-valkey` landed). No
  `flagsmith`-specific CLI exists to pin.
- **`research:public`** and **`research:codebase`** — for the per-tool detail
  the build defers: the exact `flagsmith-charts` chart version, the API/frontend
  Service names and ports, the health-endpoint path, and the exact
  `databaseExternal` / `api.secretKeyFromExistingSecret` / `api.bootstrap` value
  keys against the pinned chart.

**No library-shipped agentic skill exists for Flagsmith, OpenFeature, or the
official `flagsmith-charts` Helm chart** (the research recorded a deliberate
per-source check — chart repo, chart README, docs site, provider packages on
npm/PyPI/crates.io). Build to the in-repo contracts: `ARCHITECTURE.html` § S5
Platform (the `OpenFeature → Flagsmith` service panel — self-hosted,
Postgres-backed, the three consuming-SDK rows), `DEVELOPMENT.md` § Secrets (the
sops+age+KSOPS wiring the three credentials follow), and the two completed
sibling designs — `storage-postgres-valkey` (the CNPG `Database`/`managed.roles[]`
pattern, the two-Secrets-from-one-password precedent, the committed-secret path
convention, the sealing discipline) and `networking-istio` (the shared
`agrippa-gateway`, the `HTTPRoute`-per-consumer + append-to-`dnsNames` contract) —
as the authoritative contracts to build to.

## Purpose

Stand up **Flagsmith** — self-hosted, Postgres-backed — as one more service in
the `platform` layer's `overlays/dev`, reconciled by ArgoCD alongside Keycloak
(Feature 5) and Forgejo (Feature 6), so that the platform has a running
feature-flag service with a Gateway-reachable admin UI. Production would run the
same first-party chart against the same shared Postgres; locally it runs
single-replica against the shared CNPG `postgres` Cluster on `local-path`, with
Redis/SSE off (empirically not required — see Alternatives) and TLS terminated by
the local-CA shared Gateway.

The deliverable is:

1. **One Flagsmith Helm release** (official `Flagsmith/flagsmith-charts`) in its
   own `flagsmith` namespace, Helm-inflated under the shared `platform`
   Application via a per-component subdirectory — the same
   `helmCharts:`-in-a-subdir shape `storage`'s `valkey/`/`cnpg-operator/` and
   `core`'s `istio-*/` already use. Its bundled dev Postgres subchart is
   disabled; SSE and Redis are off.
2. **`databaseExternal` wiring against the shared CNPG `postgres` Cluster**,
   consuming `storage`'s contract: a `flagsmith` database + `flagsmith` login
   role (database name = role name = slug), and a composed DSN the API reads from
   an existing Secret.
3. **Three KSOPS-sealed credentials** (below), generated and encrypted the way
   `storage` established: `flagsmith-db` (basic-auth, for the CNPG
   `managed.roles[]` password), `flagsmith-database-url` (Opaque DSN, for the
   chart's `urlFromExistingSecret`), and `flagsmith-secret-key` (Opaque Django
   `SECRET_KEY`).
4. **One Gateway-exposed admin UI** at `flagsmith.127.0.0.1.nip.io`, via a
   hand-authored `HTTPRoute` in the `flagsmith` namespace and one append to the
   shared `agrippa-gateway-tls` certificate's `dnsNames` — consuming
   `networking`'s contract, building no new Gateway/TLS infrastructure.
5. **A declarative admin bootstrap** (`api.bootstrap`: default superuser, org,
   project) plus the chart's own browser password-reset-link flow for the single
   local operator (no new imperative automation — decision 3).

The value is narrow but real: it lands the feature-flag service the project's own
Release Flag mechanism and any later Workload (Feature 9) can eventually consume
via an OpenFeature client — but wiring an actual consumer is explicitly **not**
this step's job (see Out of scope). This step's job ends at "Flagsmith is
reachable through the Gateway and its API is healthy against the shared Postgres."

Out of scope, kept as seams for a later feature-step or the deferred cloud cycle:
**the `sse` real-time component and any Valkey/Redis wiring** (optional, additive,
empirically not needed — Alternatives); **wiring any Workload to an OpenFeature
provider** (Feature 9's job, only where a workload reads a flag; a browser-based
client would additionally need the API host Gateway-exposed, not just the admin
UI — flagged for Feature 9, not built here); **this project's own release flag
actually reading from this instance** (relevant context, not built here);
**multi-org/project/environment structure** beyond the one bootstrap default; and
**`overlays/prod`** (a preserved seam).

## Prior Art

- **`storage-postgres-valkey` (Feature 4).** The authoritative in-repo contract
  this step consumes and mirrors: (a) the per-app DB/role naming contract —
  append one `{name: flagsmith, login: true, passwordSecret: {name: flagsmith-db}}`
  entry to the shared `postgres` Cluster's `managed.roles[]` (the shared,
  append-only list) and author a self-owned `Database` CR (`name/owner: flagsmith`,
  `cluster: {name: postgres}`) in the `storage` namespace; (b) the
  two-Secrets-from-one-password precedent (`smoke-db` basic-auth + `smoke-valkey`
  users Secret sealed from the same generated value) — extended here to
  `flagsmith-db` + `flagsmith-database-url`; (c) the committed-secret path
  convention `secrets/dev/<layer>/<component>/<name>.enc.yaml`; (d) the
  self-contained KSOPS `secrets/dev/.../` sub-kustomization referenced as a
  `resources:` entry with a `kind: ksops` generator; (e) the "generate in memory,
  `sops --encrypt` immediately, commit only ciphertext" sealing discipline; and
  (f) the intra-layer `-10/-5/0/5` sync-wave scheme.
- **`networking-istio` (Feature 3).** The shared Gateway contract this step's UI
  exposure consumes verbatim: create one `HTTPRoute` with `parentRefs:
  [{name: agrippa-gateway, namespace: istio-ingress, sectionName: https}]` at a
  `<host>.127.0.0.1.nip.io` dev host, and append that host to
  `core/overlays/dev/gateway-cert.yaml`'s `dnsNames`. `core/overlays/dev/
  argocd-httproute.yaml` is the concrete per-consumer `HTTPRoute` this step's own
  route copies (including the explicit `matches: [{path: {type: PathPrefix,
  value: /}}]` that avoids the API-default OutOfSync symptom).
- **`storage/overlays/dev/valkey/kustomization.yaml`.** The concrete
  `helmCharts:`-in-a-subdir precedent (pinned `version`, `releaseName`,
  `namespace`, `valuesInline`, `skipTests`), including the live-discovered
  kustomize 5.8.0+ `metadata.namespace`-not-stamped regression and its scoped
  `patches:` workaround — a build-time watch-item this step inherits (Challenges).
- **`apps/storage.yaml` / `apps/core.yaml`.** The `syncPolicy.syncOptions:
  [ServerSideApply=true, SkipDryRunOnMissingResource=true]` plus
  `argocd.argoproj.io/compare-options: ServerSideDiff=true` seam that fixes the
  CNPG/Gateway permanent-OutOfSync bug (argoproj/argo-cd#22151) — needed on
  `apps/platform.yaml` too (see § Cross-step touches).
- **External worked examples** (full IEEE citations in `research/public.md`): the
  chart's `databaseExternal.urlFromExistingSecret`, `api.secretKeyFromExistingSecret`,
  and `api.bootstrap` value blocks [1][3]; the Kubernetes hosting guide's
  frontend-plus-proxied-API exposure model [3]; and the empirical "no `REDIS_URL`
  in the default-rendered API env" finding from the chart source [1].

## User Journey and Metrics

**The operator's flow, from the bootstrapped `agrippa-dev` cluster (Features 1-6
landed) with this Flagsmith content committed and ArgoCD reconciling `platform`:**

1. ArgoCD syncs the `platform` layer: the `flagsmith` namespace, its three
   decrypted Secrets, the Flagsmith Helm release (`api` + `frontend`
   Deployments/Services), the `flagsmith` `Database` CR, and the `HTTPRoute` come
   up in intra-`flagsmith` sync-wave order. The API pod's readiness probe passes
   only once it reaches the shared Postgres as role `flagsmith`. The operator
   runs `kubectl -n argocd get application platform` and sees it **Synced/Healthy**.
2. The operator opens `https://flagsmith.127.0.0.1.nip.io/` in a browser (or
   `curl -k`): the request goes host `:443` → k3d port-map → shared Gateway →
   the `flagsmith` HTTPRoute → the frontend Service; the Flagsmith admin login UI
   renders, TLS terminated at the Gateway with the local-CA cert (browser shows
   the by-design untrusted-CA warning; `curl -k` accepts it).
3. To log in the first time, the operator reads the one-time password-reset link
   Flagsmith's bootstrap logs to the API pod's stdout
   (`kubectl -n flagsmith logs <api-pod> | grep -i password-reset`) and follows
   it in the browser to set the admin password — the chart's own documented
   single-operator flow, no scripted step (decision 3). From there the
   bootstrap-created default org/project/environment are ready; an environment
   API key an SDK/OpenFeature client would use is retrievable from the UI.
4. Any later Workload (Feature 9) that chooses to gate a rollout installs a
   Flagsmith OpenFeature provider and points it at that environment key — nothing
   this step builds.

**Metrics / measures of done for this feature-step:**

- The feature test (`tests/feature-flags.bats`) is green: the admin UI is served
  through the shared Gateway at `flagsmith.127.0.0.1.nip.io` with a local-CA cert
  (mirroring `networking.bats`'s ArgoCD-UI proof), and the API `/health` endpoint
  returns 200 through the same Gateway — transitively proving the Django app is up
  and its Postgres connection to the shared CNPG `flagsmith` database works.
- `kubectl -n argocd get application platform` is **Synced/Healthy** with the
  Flagsmith release reconciled.
- Adding this step does not regress earlier harness: `mise run test:push`
  (`test:static` + `test:policy` + `test:chart`), `mise run test:feature`, and
  `bats tests/cluster-core.bats tests/gitops.bats tests/networking.bats
  tests/storage.bats tests/rotate-keys.bats` stay green (the `feature-flags.bats`
  `test:feature` exclusion lands with the test).

**Per-component SLO (defined here, watched in Grafana once Observability lands;
not a CI step, per `DEVELOPMENT.md`).** Targets over a rolling 28-day window once
Feature 8 provides Prometheus/Grafana: **the Flagsmith API `/health` endpoint
returns 200 ≥ 99.5%** of the time, and **flag-evaluation requests succeed (non-5xx)
≥ 99.5%** of the time, measured from the Gateway's `istio_requests_total` for the
Flagsmith host plus the API's own health metric. Burn-rate alert at 2% budget
consumed in 1h. Recorded here, instrumented when Observability lands; not asserted
by the feature test.

**Failure modes to design against.**

- **The API pod never becoming Ready because the DSN, the role, or the database
  is missing.** The three are cross-layer: the `flagsmith` role + `flagsmith-db`
  password live in the `storage` layer (wave 1); the DSN Secret + the release live
  in `platform` (wave 2). Mitigated by the cross-layer wave ordering (storage
  before platform) plus the API readiness probe's own retry — and surfaced
  directly by the feature test's `/health` assertion, not merely a Secret-exists
  check.
- **A permanent `OutOfSync` on `platform`** from a controller-defaulted field
  (the CNPG `Database`, or a chart resource), the exact symptom `storage`/`core`
  hit. Mitigated by adding the `ServerSideApply`/`SkipDryRunOnMissingResource`
  syncOptions + `ServerSideDiff=true` compare-option to `apps/platform.yaml`
  (§ Cross-step touches) — the shared seam all three platform siblings need.
- **The Helm-inflated resources landing in the wrong namespace** (the kustomize
  5.8.0+ regression `storage/valkey` hit). Anticipated, not pre-solved: if the
  Flagsmith chart's templates don't hardcode `{{ .Release.Namespace }}`, apply the
  same scoped `patches:` `op: add /metadata/namespace` workaround `valkey/` uses.
  Confirm live at build.
- **Django `ALLOWED_HOSTS` rejecting the nip.io host.** If `/health` or the UI
  returns a 400 through the Gateway, set the chart's allowed-hosts value to include
  `flagsmith.127.0.0.1.nip.io` (or `*` for dev). Build-verified against the pinned
  chart's default.
- **A committed plaintext Secret** — covered by the existing `test:static`
  plaintext guard, whose `secrets/` coverage `storage` already extended; the three
  new encrypted files live under `secrets/dev/...` and are ciphertext-only.

## Specification

### Composition: one `flagsmith/` component subdir under the shared `platform` Application

The Flagsmith content lands in a **new per-component subdirectory**
`platform/overlays/dev/flagsmith/`, referenced as one more entry in the shared
`platform/overlays/dev/kustomization.yaml`'s `resources:` list (which today holds
only `argocd.yaml`). This mirrors the per-component-subdir shape `storage` and
`core` established, and the `platform` overlay's own header comment already
anticipates it ("Real platform content (keycloak, forgejo, flagsmith) lands as
later feature-steps' added resources here"). Proposed layout (file/object names
are Open Artifact Decisions where noted):

```text
platform/overlays/dev/flagsmith/
├── kustomization.yaml     # resources: namespace, secrets ref, helm/, httproute, database
├── namespace.yaml         # wave -10; Namespace flagsmith
├── helm/
│   └── kustomization.yaml # wave 0; helmCharts: [flagsmith] -> flagsmith ns
├── httproute.yaml         # wave 5; HTTPRoute `flagsmith` in the flagsmith ns
└── database.yaml          # wave 5; CNPG Database `flagsmith` in the storage ns

secrets/dev/platform/flagsmith/
├── kustomization.yaml     # wave -5; generators: [secret-generator.yaml]
├── secret-generator.yaml  # kind: ksops; files: [database-url.enc.yaml, secret-key.enc.yaml]
├── database-url.enc.yaml  # sops-encrypted Opaque Secret flagsmith-database-url (key DATABASE_URL)
└── secret-key.enc.yaml    # sops-encrypted Opaque Secret flagsmith-secret-key (key SECRET_KEY)
```

- The **Helm release** is its own `helm/` sub-kustomization carrying
  `commonAnnotations: {argocd.argoproj.io/sync-wave: "0"}` and a `helmCharts:`
  block — exactly `storage/valkey/`'s shape — so its wave annotation stamps the
  multi-doc Helm output without bleeding onto the authored CRs, which carry their
  own inline waves.
- The **platform-side Secrets** are a self-contained
  `secrets/dev/platform/flagsmith/` sub-kustomization (its own `kind: ksops`
  generator listing its two local `*.enc.yaml` files), referenced from
  `platform/overlays/dev/flagsmith/kustomization.yaml` as
  `../../../../secrets/dev/platform/flagsmith` — a directory-kustomization
  reference the default root-only load restrictor permits, the same wiring
  `storage`'s `../../../secrets/dev/storage` uses. A **per-component** secrets
  subdir (not one shared `secrets/dev/platform/` generator) is deliberate: it
  keeps the three concurrent platform siblings (Auth/Forgejo/Flagsmith) off a
  shared-append generator file.

### The three sealed credentials (decision 2, carried in)

All three are generated in memory, `sops --encrypt`ed immediately, and only the
ciphertext committed — the `storage` sealing discipline exactly (the plan
reproduces the pure-stdin `kubectl create secret … | sops --encrypt` construction;
this design does not re-transcribe it). Two of the three are sealed from **one**
generated Postgres password (the two-Secrets-from-one-password precedent):

1. **`flagsmith-db`** — `kubernetes.io/basic-auth`, keys `username: flagsmith` /
   `password: <pw>`, in the **`storage`** namespace, referenced by the shared
   Cluster's appended `managed.roles[]` entry. Sealed at
   `secrets/dev/storage/postgres/flagsmith.enc.yaml`, following `storage`'s
   `<slug>-db` / `secrets/dev/storage/postgres/<slug>.enc.yaml` convention, and
   its file appended to `storage`'s existing KSOPS generator (§ Cross-step touches).
2. **`flagsmith-database-url`** — Opaque, one key `DATABASE_URL` holding
   `postgres://flagsmith:<pw>@postgres-rw.storage.svc:5432/flagsmith` (the same
   `<pw>` as `flagsmith-db`), in the **`flagsmith`** namespace, consumed by the
   chart's `databaseExternal.urlFromExistingSecret` (the chart offers no per-field
   `passwordFromExistingSecret` — only a whole-DSN existing-Secret form, the
   load-bearing research finding). Sealed at
   `secrets/dev/platform/flagsmith/database-url.enc.yaml`.
3. **`flagsmith-secret-key`** — Opaque, key `SECRET_KEY`, a separate `openssl
   rand` value, in the **`flagsmith`** namespace, consumed by
   `api.secretKeyFromExistingSecret` (the Django cryptographic signing key). Sealed
   at `secrets/dev/platform/flagsmith/secret-key.enc.yaml`.

### The Helm values (shapes fixed here, exact keys build-verified)

The `helm/` sub-kustomization inflates the official chart (repo
`https://flagsmith.github.io/flagsmith-charts/`, `releaseName: flagsmith`,
`namespace: flagsmith`, `version:` **pinned at build** — `0.82.0` / app 2.238.0 is
the research-date reference; pin explicitly, do not float). Load-bearing
`valuesInline` (exact spellings re-verified against the pinned chart):

```yaml
postgresql:
  enabled: false                     # disable the bundled dev Postgres subchart
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
    adminEmail: admin@agrippa.local   # non-routable dev address
    organisationName: agrippa
    projectName: agrippa
frontend:
  enabled: true                       # serves the admin UI, proxies /api/* internally
sse:
  enabled: false                      # real-time push off (polling fallback) — decision 6
# gateway.* left at its disabled default — HTTPRoute is hand-authored (decision 1)
# any bundled influxdb/analytics subchart disabled if present (build-verified)
```

No `REDIS_URL`/`CACHE` values are set — empirically confirmed unnecessary for the
default-rendered API (decision 6). The single API and single frontend replica are
the dev default; a reduced-replica production overlay is a `overlays/prod` seam.

### The admin UI exposure: a hand-authored HTTPRoute (decision 1)

Following every prior consumer of the Networking contract (and decision 1's
explicit "leave the chart's `gateway.*` block disabled"), this step hand-authors
one `HTTPRoute` **`flagsmith`** in the `flagsmith` namespace, `parentRefs` to
`agrippa-gateway` in `istio-ingress` (`sectionName: https`),
`hostnames: [flagsmith.127.0.0.1.nip.io]`, with two path rules (Gateway API's
longest-prefix-wins precedence routes the more specific first):

- `/health` (PathPrefix) → the Flagsmith **API** Service — so the API health
  endpoint is directly reachable through the Gateway (the feature test's
  Postgres-proving assertion). *Optionally* `/api` too, but the admin UI does not
  require it (the frontend proxies `/api/*` to the API cluster-internally); a
  Gateway-reachable `/api` is a Feature-9 concern (browser OpenFeature clients),
  not built here.
- `/` (PathPrefix) → the Flagsmith **frontend** Service — the admin UI.

The exact API/frontend Service names and ports (expected `flagsmith-api` /
`flagsmith-frontend`, ports ~8000 / ~8080) and the exact health path (`/health`
vs `/health/readiness/`, whichever the chart's own readiness probe uses) are
**build-verified** against the pinned chart — the design fixes the route shape and
the two-backend split; the build confirms the spellings and corrects the route +
test if they differ (the test is RED regardless).

Plus one append: `flagsmith.127.0.0.1.nip.io` added to
`core/overlays/dev/gateway-cert.yaml`'s `dnsNames` (the shared explicit-SAN
certificate), so Istio serves a local-CA cert for this host's SNI. The `Gateway`
object itself is never edited — the append-only `dnsNames` list is the whole
mechanism, mirroring `argocd.127.0.0.1.nip.io`'s own line.

### The Database CR and the managed-role append (storage contract)

- **`platform/overlays/dev/flagsmith/database.yaml`** — a CNPG `Database`
  `{name: flagsmith, owner: flagsmith, cluster: {name: postgres}}`, `metadata.
  namespace: storage` (CNPG `Database` CRs are namespaced to the Cluster they
  reference — the `smoke` fixture is authored the same way). It is authored in
  this step's own overlay and reconciled by the `platform` Application, which
  reaches into the `storage` namespace (already created by the storage layer).
- **The `managed.roles[]` append** to `storage/overlays/dev/postgres-cluster.yaml`
  — one entry `{name: flagsmith, login: true, passwordSecret: {name: flagsmith-db}}`
  — the shared, append-only edit every Postgres consumer makes (§ Cross-step
  touches). CNPG creates/reconciles the role and sets its password from the
  KSOPS-decrypted `flagsmith-db` Secret.

### Intra-`flagsmith` sync-wave scheme

Following `storage`'s `-10/-5/0/5` precedent, scoped to this component's own
resources (each authored CR inline, the `helm/` and secrets sub-kustomizations via
`commonAnnotations`):

- **wave `-10`** — the `flagsmith` Namespace.
- **wave `-5`** — the two platform-side Secrets (`flagsmith-database-url`,
  `flagsmith-secret-key`), present before the release references them.
- **wave `0`** — the Flagsmith Helm release (`api` + `frontend`).
- **wave `5`** — the `flagsmith` `Database` CR (needs the operator + Cluster +
  owner role, all live from the storage layer) and the `HTTPRoute` (needs the
  Gateway, already live from `core`, and the release's Services).

The storage-side pieces (`flagsmith-db` Secret, the `managed.roles[flagsmith]`
entry) reconcile in the `storage` layer (Application sync-wave 1), which lands
before `platform` (sync-wave 2), so the role and its password exist before the
API pod connects.

### Cross-step touches (summary)

- **`platform/overlays/dev/kustomization.yaml`** — append `- flagsmith/` to
  `resources:`. **Shared with the Auth/Forgejo siblings**; each appends its own
  subdir entry independently (append-only, merge/rebase like any shared list).
- **`storage/overlays/dev/postgres-cluster.yaml`** — append the `flagsmith`
  `managed.roles[]` entry (the storage consumption contract's one shared-list edit).
- **`secrets/dev/storage/secret-generator.yaml`** — append
  `- postgres/flagsmith.enc.yaml` to its `files:` (the storage generator's
  companion append), and add the encrypted file
  `secrets/dev/storage/postgres/flagsmith.enc.yaml`.
- **`core/overlays/dev/gateway-cert.yaml`** — append
  `flagsmith.127.0.0.1.nip.io` to `dnsNames` (the Networking contract's one
  shared-list edit).
- **`apps/platform.yaml`** — add `syncPolicy.syncOptions: [ServerSideApply=true,
  SkipDryRunOnMissingResource=true]` **and** the
  `argocd.argoproj.io/compare-options: ServerSideDiff=true` annotation, exactly as
  `apps/storage.yaml`/`apps/core.yaml` carry them (ServerSideApply alone reproduces
  the permanent-OutOfSync bug argoproj/argo-cd#22151). **Shared by all three
  platform siblings (Auth/Forgejo/Flagsmith); whichever lands first adds it,
  idempotent for the others.**
- **`scripts/test-feature.sh`** — add `feature-flags.bats` to the probe-suite
  exclusion `case` list (it drives the long-lived `agrippa-dev` cluster and the
  GitOps-reconciled `platform` layer, not the throwaway `agrippa-feature`
  cluster) — the same one-line edit `networking.bats`/`storage.bats` already made.
  **This exclusion lands with the feature test in this design phase** (mirroring
  the siblings): the test is committed now, so without it `mise run test:feature`
  would pick it up and loop against a Flagsmith-less throwaway cluster.
- **`mise.toml`** — no new tool pins (see Libraries & Skills).

### Challenges

- **Version pins + exact spellings deferred to build.** The chart version, the
  API/frontend Service names and ports, the health-endpoint path, and the exact
  `databaseExternal`/`secretKeyFromExistingSecret`/`bootstrap`/allowed-hosts value
  keys are build-time `research:public`, consistent with how `storage` and
  `networking` deferred their upstream chart specifics. Pin explicitly; do not
  float tags.
- **kustomize `helmCharts` namespace regression.** If the chart's templates don't
  hardcode `{{ .Release.Namespace }}`, the 5.8.0+ regression drops
  `metadata.namespace` and objects land in the Application's fallback namespace —
  apply `valkey/`'s scoped `patches:` `op: add /metadata/namespace` workaround.
  Confirm live at build.
- **`helm template` semantics.** `helmCharts:` inflation runs `helm template` (no
  hooks, no cluster `lookup`). Confirm at build that the Flagsmith chart's
  bootstrap/migration runs as a normal Deployment/init flow the templated path
  keeps (not a Helm hook ArgoCD would mishandle); `skipTests: true` if the chart
  ships a `helm.sh/hook: test` Pod (as Valkey did).
- **First-login bootstrap is manual by design.** The password-reset link is read
  from the API pod logs (decision 3); the feature test deliberately does **not**
  touch the admin credential or a flag read (decision 5), so nothing in CI depends
  on the manual step.

## Alternatives

- **The chart's native `gateway.frontend.*` block instead of a hand-authored
  HTTPRoute.** Rejected (decision 1): every prior consumer of the Networking
  contract hand-authors its route as a standalone manifest; a hand-authored route
  keeps Flagsmith's ingress byte-identical to the cleared shared-contract shape,
  decouples it from the chart's 0.82-new Gateway-values schema, and keeps the
  route reviewable next to the cert `dnsNames` append. Reversible (switching to the
  chart block later is a values edit).
- **The chart's bundled `devPostgresql` subchart instead of the shared CNPG
  `postgres`.** Rejected: a second Postgres instance violates the one-shared-Cluster
  contract, and the subchart is a `bitnamilegacy/postgresql` image carrying the same
  Broadcom legacy-image risk `storage` already rejected.
- **Wiring Valkey/Redis (`REDIS_URL`) and the `sse` component now.** Rejected
  (decision 6, empirically settled): the chart's default-rendered API env block
  contains no `REDIS_URL`/`CACHE` reference at all, so a Postgres-only Flagsmith is
  a complete, boot-and-serve configuration; Redis only adds opt-in response caching
  and the SSE realtime path — an additive, reversible follow-up (mirroring
  `storage`'s "Valkey recommended, not mandated").
- **A scripted `kubectl exec` Django-shell `set_password` bootstrap.** Rejected as
  the default (decision 3) in favor of the chart's own browser password-reset-link
  flow for the single local operator — zero new un-GitOps'd pod mutation. The
  scripted path stays the documented upgrade the moment CI needs the admin
  credential asserted non-interactively; decision 5 keeps the test off that surface,
  so nothing forces it now.
- **A flag-read or admin-credential-auth feature test.** Rejected (decision 5):
  both would couple the test to the fragile, still-manual password/key bootstrap
  surface. The chosen reach — Gateway reachability + local-CA TLS + API `/health`
  200 — proves everything this step lands (Gateway exposure, the DB-contract
  consumption transitively, the app booting) without binding to the un-GitOps'd
  bootstrap step. It sits deliberately between `networking.bats` (pure UI
  reachability) and `storage.bats` (full authenticated DB round-trip).
- **A shared `secrets/dev/platform/` generator for all three platform siblings.**
  Rejected in favor of per-component `secrets/dev/platform/<component>/`
  sub-kustomizations: it keeps the three concurrent siblings off a shared-append
  generator file, each self-contained.

## Summary

This feature-step lands **Flagsmith** (self-hosted, Postgres-backed) into the
shared `platform` layer as one `helmCharts:`-inflated component subdirectory
(`platform/overlays/dev/flagsmith/`, referenced from the shared
`platform/overlays/dev/kustomization.yaml`), consuming both prior shared
contracts: `storage`'s per-app DB/role naming (a `flagsmith` database + role via a
`managed.roles[]` append and a self-owned `Database` CR, credentialed by
KSOPS-sealed Secrets) and `networking`'s Gateway/HTTPRoute/hostname/TLS (a
hand-authored `HTTPRoute` at `flagsmith.127.0.0.1.nip.io` plus one
`agrippa-gateway-tls` `dnsNames` append). Three credentials are sealed the way
`storage` established — `flagsmith-db` (basic-auth, storage ns) and
`flagsmith-database-url` (Opaque DSN, flagsmith ns) from one generated password,
and `flagsmith-secret-key` (Opaque Django key) from another. Redis/SSE are off
(empirically unneeded), the admin bootstrap accepts the chart's browser
password-reset flow, and `apps/platform.yaml` gains the shared
ServerSideApply/ServerSideDiff seam all three platform siblings need. The one
feature test proves the deliverable end-to-end: the admin UI served through the
shared Gateway with a local-CA cert, and the API `/health` returning 200 —
transitively proving the shared-Postgres connection.

This Design-phase run does **not** deploy the Flagsmith content: reconciling it
requires a full ArgoCD sync of newly-committed charts, CRs, and sealed Secrets, and
the chart version, Service names/ports, and health path want live re-verification
at build time. The feature test is therefore left **RED** (baseline recorded
below); the build phase turns it green after sealing the three credentials,
committing the `flagsmith/` composition and the four shared-file appends, and
letting ArgoCD reconcile it.

### Open Artifact Decisions

Concrete artifact choices this design invents that are not fixed by a skill
template, an existing project convention, or the cleared `research.md` (whose
reviewer block already settled the chart choice, the hand-authored HTTPRoute, the
three Secret **names** and the one-password-two-Secrets mechanic, the accepted
browser-reset bootstrap, the `flagsmith.127.0.0.1.nip.io` hostname, the
feature-test reach, and the no-Redis finding — all stated above as conclusions,
not surfaced here).

**The `flagsmith` namespace choice (a dedicated `flagsmith` namespace vs. a shared
`platform` namespace):** research decision 2 left the namespace slug open.
Proposed: a dedicated **`flagsmith`** namespace, matching every other component's
own-namespace convention (`istio-ingress`, `cnpg-system`, `storage`) and the
chart's own `helm install -n flagsmith --create-namespace` idiom. Reversible; a
change touches only this step's manifests + the test's `NS`/host.

**The overlay file/subdir layout — `platform/overlays/dev/flagsmith/` with
`namespace.yaml` / `helm/` / `httproute.yaml` / `database.yaml`, and
`secrets/dev/platform/flagsmith/` with `database-url.enc.yaml` / `secret-key.enc.yaml`
/ `secret-generator.yaml`:** the internal file layout and the platform-side secret
path.
Proposed: as in the Specification layout block, mirroring `storage/overlays/dev/`'s
per-component-subdir + top-level-CR shape and extending the
`secrets/dev/<layer>/<component>/` convention to the `platform` layer. Reversible;
a rename touches only this step's own files.

**The DSN key spelling (`DATABASE_URL`), the admin bootstrap email
(`admin@agrippa.local`), and the org/project name (`agrippa`):** concrete values
the sealed Secret and the chart values bind to.
Proposed: `DATABASE_URL` (the chart's own example key name), a non-routable
`admin@agrippa.local`, and `agrippa` for both org and project (matching the
`agrippa-*` naming family). Reversible; re-sealing/re-bootstrapping is a build step.

**The HTTPRoute path split — `/health` → API, `/` → frontend (two rules on one
route):** the route shape that exposes both the admin UI and a Gateway-reachable API
health endpoint from one host.
Proposed: the two-rule split, so the feature test's `/health` assertion reaches the
API directly (proving Postgres) while `/` renders the admin UI. The alternative — a
single `/` → frontend route relying on the frontend's internal `/api` proxy —
cannot expose the API `/health` endpoint the research settled on. The exact Service
names/ports and health path are build-verified.

## Feature Test

**Path:** `tests/feature-flags.bats` (following `DEVELOPMENT.md`'s
`tests/<feature>.bats` convention, feature = "feature-flags"; the `-flagsmith`
tool qualifier is dropped just as `cluster-core.bats` dropped `-k3d`,
`gitops.bats` dropped `-argocd`, `networking.bats` dropped `-istio`, and
`storage.bats` dropped `-postgres-valkey`).

**User story (Given / When / Then):** *Given* the bootstrapped long-lived
`agrippa-dev` cluster (Features 1-6) with this Flagsmith content committed and
reconciled by ArgoCD into the `platform` layer — the Flagsmith Helm release
(`api` + `frontend`) in the `flagsmith` namespace, wired via `databaseExternal`
to the shared CNPG `postgres` Cluster's own `flagsmith` database/role, its three
KSOPS-sealed credentials, its `Database` CR, and its hand-authored `HTTPRoute` at
`flagsmith.127.0.0.1.nip.io` — *When* an operator requests
`https://flagsmith.127.0.0.1.nip.io/` and `.../health` through the k3d `:443`
host port-map, *Then* the admin UI is served through the shared Istio Gateway
(host `:443` → k3d loadbalancer → node IP via `externalIPs` → gateway pods → the
`flagsmith` HTTPRoute → the frontend/API Services), the response is a live UI
status (`2xx`/`3xx`, not a 404/connection failure), the TLS certificate presented
is **issued by the local CA** (`CN=Agrippa Local Dev CA`), and the API `/health`
endpoint returns **200** — transitively proving the Django app is up and its
connection to the shared Postgres `flagsmith` database works. `curl -k` tolerates
the deliberately-untrusted local CA. Like its sibling suites it deliberately does
**not** tear the cluster, the datastores, or Flagsmith down, and it does **not**
assert a flag read or admin-credential auth (decision 5).

**Current state: RED (baseline captured this run, `bats` 1.13.0).** With
`platform/overlays/dev` still `resources: [argocd.yaml]` only, the `platform`
Application is already `Synced/Healthy` on that content (live-confirmed) — so the
suite's THEN 0 precondition (`platform` Synced/Healthy) passes even now, exactly
as `networking`'s/`storage`'s THEN 0 passed on their empty layers. The **RED
discriminator** is the reachability assertion (THEN 1): no `HTTPRoute` claims the
`flagsmith` host, so `curl -k https://flagsmith.127.0.0.1.nip.io/` returns **404**
from `istio-envoy` (live-confirmed 6/6 this session) rather than a UI `2xx`/`3xx`,
and the suite aborts there — `/health` likewise returns **404** rather than the
required `200` (THEN 3). Two nuances the baseline records: (a) the shared Gateway
is up (from Networking) and serves the shared cert for any SNI, so were THEN 2
reached its `CN=Agrippa Local Dev CA` issuer check would already pass — THEN 1
just aborts first; (b) the two pattern assertions use `[[ … ]] || false` because
`bats` 1.13.0 does **not** abort a test on a bare mid-test `[[ … ]]` (verified this
session), so the guard is load-bearing for a reliable green gate. That red state
defines "done." This Design-phase run does **not** turn it green: sealing the
three credentials, committing the `flagsmith/` composition and the four
shared-file appends, and the ArgoCD reconcile are all build-phase work outside
this phase's write-only-the-test gate.
