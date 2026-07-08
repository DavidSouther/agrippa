# Public Research: Flagsmith (self-hosted, Helm) + OpenFeature

Feeds `../research.md` § Search/Expand and § Libraries & Skills. Full findings
and IEEE-style citations below; the parent document synthesizes only what
bears on scope and design.

## The chart: `Flagsmith/flagsmith-charts`, official and actively maintained

Flagsmith publishes its own official Helm chart at
`https://flagsmith.github.io/flagsmith-charts/`, source at
`github.com/Flagsmith/flagsmith-charts` [1]. This is **not** a third-party or
Bitnami-style chart, so it carries none of the Broadcom-restructuring risk
`storage-postgres-valkey`'s research flagged for the Bitnami `postgresql`
chart. Commit history shows regular activity through the research date
(2026-07-08): the most recent commits are 2026-06-16 ("Expose
extraTemplateSpec, fix api extraSpec location", #547) and a 2026-06-05 release
of chart version **0.82.0** ("chore(main): release flagsmith 0.82.0", #544,
bumping the bundled Flagsmith application to 2.238.0) [2]. Install:

```bash
helm repo add flagsmith https://flagsmith.github.io/flagsmith-charts/
helm install -n flagsmith --create-namespace flagsmith flagsmith/flagsmith
```

Notably, the chart ships **native Gateway API support** as of 2026-04-09
("Add default rules for API, SSE, and frontend HTTPRoutes", #522) [2][3]: a
top-level `gateway:` values block with independent `frontend` / `api` / `sse`
sub-blocks, each taking `enabled`, `parentRefs`, `hostnames`, and `rules` —
i.e. the chart can render its own `HTTPRoute`(s) directly from Helm values
rather than requiring a hand-authored `HTTPRoute` alongside it. This maps
cleanly onto `networking-istio`'s shared contract shape (`parentRefs` to
`agrippa-gateway` in `istio-ingress` with `sectionName: https`, one
`hostnames` entry) [4], though whether to use the chart-native route or an
independently-authored `HTTPRoute` (the pattern every other consumer of that
contract has used so far) is a genuine open choice for the Design phase, not
resolved here.

An `ingress:` block (frontend/api/sse, `enabled`/`hosts`/`annotations`/`tls`)
exists as the pre-Gateway-API alternative; not needed here since the project's
shared ingress contract is Gateway API only [3][4].

## Architecture: `api` (Django/DRF), `frontend` (Next.js/proxy), optional `sse`

The chart deploys up to three components [1][3]:

- **`api`** — the Django REST backend. Talks to Postgres and (optionally)
  Redis.
- **`frontend`** — the web admin UI (Next.js), which also reverse-proxies
  `/api/*` calls to the backend on the same host — the reason the Kubernetes
  guide's ingress example exposes only `ingress.frontend` with one hostname,
  not a separate API hostname, for the UI-plus-proxied-API case [3].
- **`sse`** (Server-Sent Events) — optional, powers real-time flag-update
  push to connected SDKs. Docs state real-time updates need "at least one SSE
  service instance and one Redis node" [5]; if `sse` is left disabled, clients
  fall back to polling, which is the correct default for a reduced-replica dev
  overlay.

## Postgres: `databaseExternal`, not the bundled dev chart

The chart bundles a `devPostgresql` subchart (`bitnamilegacy/postgresql`,
disabled-by-default posture implied by its name) purely for zero-config
demoing — explicitly the wrong path here, both because it is a second Postgres
instance (violating the one-shared-`postgres`-Cluster contract
`storage-postgres-valkey` defines [4]) and because it inherits the same
Bitnami/Broadcom legacy-image risk that feature's research already rejected
[6]. The chart's external-database path is `databaseExternal`, with three
equivalent forms [1][3]:

```yaml
postgresql:
  enabled: false            # disable the bundled devPostgresql subchart
databaseExternal:
  enabled: true
  url: 'postgres://myuser:mypass@myhost:5432/mydbname'   # (a) inline URL
  # -- or --
  type: postgres            # (b) individual fields; `password` is a plain
  host: myhost               #     value here, NOT securable via a separate
  port: 5432                 #     existing-secret reference in this form
  database: mydbname
  username: myuser
  password: mypass
  # -- or --
  urlFromExistingSecret:    # (c) whole-DSN-from-Secret, the only
    enabled: true            #     existing-Secret-sourced form available
    name: my-db-config
    key: DB_URL
```

**Load-bearing finding for Design:** only the *whole DSN string* can be
sourced from an existing Secret (`urlFromExistingSecret`); there is no
`databaseExternal.passwordFromExistingSecret` sibling to the individual-field
form. This means the credential Secret Flagsmith itself consumes must be
**Opaque with one key holding a fully-composed `postgres://flagsmith:<pw>@postgres-rw.storage.svc:5432/flagsmith` string**, not the `kubernetes.io/basic-auth` (`username`+`password` keys) shape
`storage-postgres-valkey`'s own `Cluster.spec.managed.roles[].passwordSecret`
uses for CNPG's role management [4]. Precedent already exists for a
feature-step sealing two differently-shaped Secrets from one generated
password (the `smoke` fixture's `smoke-db` basic-auth Secret for CNPG plus
`smoke-valkey`'s users Secret for the Valkey chart) [4], so the natural
extension here is two Secrets: one basic-auth `flagsmith-db` for the
`managed.roles[]` append (matching every other consumer of that contract), and
one Opaque `flagsmith-database-url` (or similar) for
`databaseExternal.urlFromExistingSecret`, both derived from the same
in-memory-generated password at sealing time. Exact naming is a Design-phase
Open Artifact Decision.

## Redis/Valkey: optional, not a hard dependency for basic operation

The chart has **no bundled Redis/Valkey subchart and no `redis.enabled`
toggle** — Redis is wired purely through the API's env vars
(`REDIS_URL`) [1][7]. Cross-checking two Flagsmith doc pages gives an
apparently conflicting signal worth resolving explicitly: the Environment
Variables reference page marks `REDIS_URL` "Required" in its per-variable
table [5], while the Kubernetes/OpenShift hosting guide and the Caching
Strategies page describe Redis-backed caching (`GET_FLAGS_ENDPOINT_CACHE_*`,
`CACHE_ENVIRONMENT_DOCUMENT_SECONDS`) and the SSE realtime path as opt-in
performance/feature toggles layered on top of a Postgres-only deployment, with
no statement that the API process fails to boot without `REDIS_URL` set
[3][8]. The chart's own values (no Redis dependency wired into the `api`
deployment templates by default, `sse.enabled: false` leaves the realtime path
off entirely) [1] side with the "optional" reading: a Postgres-only Flagsmith
deployment boots and serves flag evaluation and the admin UI; Redis only adds
response caching and SSE push. This mirrors `storage-postgres-valkey`'s own
posture toward Valkey — "RECOMMENDED, not a mandated clause of the hard
[storage] contract" [4] — so the same non-mandatory framing applies to
Flagsmith's own use of the shared Valkey instance: skip it for the MVP dev
deployment (fewer moving parts, matches the project's reduced-replica dev
posture), and treat a `flagsmith` Valkey ACL user plus `REDIS_URL` /
`sse.enabled: true` as a documented, reversible follow-up if caching or
real-time flag propagation is later wanted. **Recommend build-time
verification** of this reading against the pinned chart/app version before
treating it as settled (the "Required" table entry is a real, if likely
overbroad, signal not to ignore silently).

## Django `SECRET_KEY`: a third, Flagsmith-internal secret

Separate from the database credential, the API needs its own
`DJANGO_SECRET_KEY` — the chart supports this from an existing Secret too:

```yaml
api:
  secretKeyFromExistingSecret:
    enabled: true
    name: flagsmith-secret-key
    key: SECRET_KEY
```

[1]. A third KSOPS-sealed credential, generated the same
`openssl rand`-into-`sops`-encrypt way `storage-postgres-valkey` established
[4], is the natural mechanism — no chart-side generation exists.

## Admin/bootstrap: declarative user+org+project creation, imperative password

The chart exposes a declarative bootstrap block:

```yaml
api:
  bootstrap:
    enabled: true
    adminEmail: admin@example.com
    organisationName: agrippa
    projectName: agrippa
```

which sets `ALLOW_ADMIN_INITIATION_VIA_CLI`-style env vars under the hood,
enabling a Django management command that creates a default superuser,
organisation, and project on first boot [1][9]. **There is no
`adminPassword`/password-from-Secret field anywhere in this block** — by
design, Flagsmith's CLI bootstrap path does not accept a password: on first
successful bootstrap it logs a one-time password-reset link
(`.../password-reset/confirm/<uid>/<token>/`) to the API pod's stdout, and the
operator is expected to follow that link (browser) or set the password another
way [9][10]. The documented "another way" for headless/CI use is `python
manage.py changepassword <email>` run inside the API container, which itself
prompts interactively rather than accepting a piped/`--noinput` password
[10] — so a fully non-interactive local-dev bootstrap needs either (a) a small
Django-shell one-liner (`User.objects.get(...).set_password(...); .save()`)
piped into `kubectl exec ... -- python manage.py shell`, reading the password
from the same in-memory-generated-then-sealed value the KSOPS credential uses,
mirroring `storage-postgres-valkey`'s "generate in memory, encrypt
immediately" discipline but adding one `kubectl exec` step since Flagsmith (unlike a
plain CNPG role) has no purely-declarative password-setting mechanism, or (b)
accept the browser password-reset-link flow as the documented, lower-effort
default for a single local operator, and skip full non-interactive automation.
Both are legitimate; Design should pick one explicitly. Retrieving the
environment API key an OpenFeature/SDK client actually authenticates with
(the `X-Environment-Key` value) after bootstrap needs the same kind of
one-shot script (a Django-shell query against the auto-created default
Environment, or a browser visit to the admin UI) — no separate chart-level
mechanism surfaces it declaratively.

## OpenFeature: a client-consumption convention, not a Flagsmith deployment concern

OpenFeature is a CNCF vendor-neutral flag-evaluation API; Flagsmith ships
first-party **provider** packages that plug a Flagsmith client into an
OpenFeature-shaped consumer, for both client-side (browser
`@openfeature/web-sdk` + `@openfeature/flagsmith-client-provider`, reading a
client-side/environment key) and server-side use (Rust `open-feature` +
`flagsmith` crate provider; Python `openfeature-sdk` +
`openfeature-provider-flagsmith`) [11][12][13] — exactly the three SDK rows
`ARCHITECTURE.html`'s own Platform-services panel already lists for the
`OpenFeature → Flagsmith` service [14]. The provider is a thin adapter: it
performs no evaluation of its own and delegates entirely to the underlying
Flagsmith SDK, which in server-side "local evaluation" mode fetches Flagsmith's
per-environment "Environment Document" once and evaluates flags in-process
with no per-request network call [11]. **This confirms the task's working
hypothesis stated as "likely the former": OpenFeature is purely a
later-consuming-workload's client-library choice.** It changes nothing about
how Flagsmith itself is deployed, configured, or exposed in this feature-step
— no OpenFeature-specific server component, port, CRD, or chart value exists.
It matters to *this* feature-step only insofar as the deployed Flagsmith
instance must expose something client SDKs can reach: an environment API key
(above) and a reachable API endpoint. For a **browser-based** OpenFeature
client (the `@openfeature/web-sdk` case a future static-site Workload might
use) that endpoint must be the public Gateway route, not cluster-internal
Service DNS — a consideration to flag for whichever feature-step (this one, or
Workloads) ends up exposing Flagsmith's API host, not just its admin-UI host,
through the shared Gateway. This feature-step's own job is limited to landing
Flagsmith itself and exposing its admin UI; wiring a specific Workload to
OpenFeature is out of this feature-step's scope per the parent plan ("feeds
Feature 9 ... only where a workload actually reads a flag").

## Sources

- [1] "flagsmith-charts," Flagsmith, GitHub repository (README, and
  `charts/flagsmith/values.yaml` on `main`).
  https://github.com/Flagsmith/flagsmith-charts ,
  https://raw.githubusercontent.com/Flagsmith/flagsmith-charts/main/charts/flagsmith/values.yaml
- [2] "flagsmith-charts," commit history (`main` branch), accessed 2026-07-08.
  https://github.com/Flagsmith/flagsmith-charts/commits/main
- [3] "Kubernetes and OpenShift," Flagsmith Docs, Deployment & Self-Hosting ›
  Hosting Guides.
  https://docs.flagsmith.com/deployment-self-hosting/hosting-guides/kubernetes-openshift
- [4] "Feature Design: Storage (Postgres via CloudNativePG + Valkey)" and
  "Feature Design: Networking (Istio ambient + Gateway API + cert-manager +
  metallb)," this project's completed sibling feature-steps (in-repo).
  `.ailly/developer/2026-07-06-A-agrippa-local-k3d/features/storage-postgres-valkey/design.md` ,
  `.ailly/developer/2026-07-06-A-agrippa-local-k3d/features/networking-istio/design.md`
- [5] "Environment Variables," Flagsmith Docs, Deployment & Self-Hosting ›
  Core Configuration.
  https://docs.flagsmith.com/deployment-self-hosting/core-configuration/environment-variables
- [6] "Feature Design: Storage ..." § Alternatives (Bitnami/Broadcom
  restructuring finding), same document as [4].
- [7] `charts/flagsmith/values.yaml`, `sse.extraEnvFromSecret.REDIS_PASSWORD`
  example and absence of a top-level `redis:` dependency block, same source
  as [1].
- [8] "Caching Strategies," Flagsmith Docs, Deployment & Self-Hosting › Core
  Configuration.
  https://docs.flagsmith.com/deployment-self-hosting/core-configuration/caching-strategies
- [9] "Environment Variables" (`ALLOW_ADMIN_INITIATION_VIA_CLI`, `ADMIN_EMAIL`,
  `ORGANISATION_NAME`, `PROJECT_NAME`), same source as [5]; and
  `charts/flagsmith/values.yaml`'s `api.bootstrap` block, same source as [1].
- [10] "Django Admin," Flagsmith Docs, Deployment & Self-Hosting ›
  Administration & Maintenance (`changepassword`); and community-documented
  bootstrap-password-reset-link behavior (Docker Compose bootstrap log
  message), cross-checked via web search, 2026-07-08.
  https://docs.flagsmith.com/deployment-self-hosting/administration-and-maintenance/using-the-django-admin
- [11] "OpenFeature," Flagsmith Docs, Integrating with Flagsmith.
  https://docs.flagsmith.com/integrating-with-flagsmith/openfeature
- [12] "@openfeature/flagsmith-client-provider," npm.
  https://www.npmjs.com/package/@openfeature/flagsmith-client-provider
- [13] "flagsmith-openfeature-provider-python," Flagsmith, GitHub repository.
  https://github.com/Flagsmith/flagsmith-openfeature-provider-python
- [14] `ARCHITECTURE.html` (in-repo), § S5 Platform, "OpenFeature → Flagsmith"
  service panel (client SDK rows: Rust `open-feature`+`flagsmith`, TypeScript
  `@openfeature/web-sdk`+`flagsmith-client-provider`, Python
  `openfeature-sdk`+`openfeature-provider-flagsmith`).
