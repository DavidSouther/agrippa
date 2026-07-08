# Research: Feature flags (Flagsmith)

*Reviewed 2026-07-08*

> Feature-step research (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 7: Feature flags
> (Flagsmith)** of that project's plan: a `platform`-layer, Postgres-backed
> service, parallel with Feature 5 (Auth/Keycloak) and Feature 6 (Git
> hosting/Forgejo), consuming both the storage-class + per-app DB/role naming
> contract (Feature 4) and the Gateway + HTTPRoute + hostname + TLS contract
> (Feature 3). Long-loop: the draft gate below is left open for a separately
> dispatched reviewer to clear; open items are surfaced here, not
> self-resolved. Three sibling agents are researching Feature 5, Feature 6,
> and Feature 8 concurrently, each in their own feature-step folder; this
> document and `research/public.md` are this feature-step's own files only.

## Topic and Intent

Original request, verbatim (from the dispatching coordinator's task framing
for this feature-step):

> "Feature 7: **Feature flags (Flagsmith)**. ... Research the standard way to
> run Flagsmith on Kubernetes for local dev (official Flagsmith Helm chart —
> check current maintenance status/source), how it's configured against an
> external Postgres, whether it needs Valkey/Redis for its API cache layer,
> what 'OpenFeature' integration means concretely here (is it a client-side
> SDK convention for later consuming workloads, or does it change anything
> about how Flagsmith itself is deployed — likely the former, since
> OpenFeature is a vendor-neutral client API and Flagsmith has an OpenFeature
> provider), a minimal API-key/admin-credential bootstrap approach (imperative
> first-run vs. declarative), and how credentials should be sealed (mirror
> Storage's discipline)."

Loosely stated goal, in the project's own framing (`plan.md` § Feature 7):
stand up Flagsmith (self-hosted, Postgres-backed) as one more service in the
`platform` layer's `overlays/dev`, alongside Keycloak and Forgejo, applied
through the GitOps spine (Feature 2), consuming Feature 4's storage-class +
per-app DB/role naming contract and Feature 3's Gateway/HTTPRoute/hostname/TLS
contract, so that a later Workloads feature-step (Feature 9) can, where it
chooses to, gate a rollout behind a flag via an OpenFeature client — and so
that this project's *own* release-flag mechanism (`design.md` § Release Flag)
has a real Flagsmith instance to eventually back it, once this feature-step
lands.

## Search/Expand

General-lens findings on the current (2026) state of running self-hosted
Flagsmith on Kubernetes. Full citations and deeper detail in
`research/public.md`; this section synthesizes what bears on scope and
design.

**The official chart is actively maintained and is the correct default.**
`Flagsmith/flagsmith-charts` is Flagsmith's own first-party Helm chart
(`https://flagsmith.github.io/flagsmith-charts/`), not a third-party or
Bitnami-style repackaging, with commits through 2026-06-16 and a
2026-06-05 release of chart **0.82.0** (bundled app 2.238.0). Unlike the
Bitnami `postgresql`/`redis` charts `storage-postgres-valkey`'s research
rejected (Broadcom's 2025 paywall restructuring), there is no maintenance-risk
finding here to falsify — first-party charts from the vendor whose product
they package do not carry that risk. [`research/public.md` §1-§2]

**External Postgres is a first-class, well-documented path, distinct in
credential shape from the CNPG contract.** `databaseExternal.enabled: true`
with `postgresql.enabled: false` disables the chart's own bundled
`devPostgresql` dev-only subchart (itself a `bitnamilegacy/postgresql` image —
another reason not to use it) and points at any external Postgres, our shared
CNPG `postgres` Cluster. The load-bearing finding: only a **whole DSN string**
can be sourced from an existing Secret
(`databaseExternal.urlFromExistingSecret`); there is no
per-field `passwordFromExistingSecret`. This means Flagsmith's own consumed
credential Secret is **Opaque with a composed `postgres://...` URL**, a
different shape from the `kubernetes.io/basic-auth` Secret
`storage-postgres-valkey`'s `Cluster.spec.managed.roles[].passwordSecret`
mechanism expects. Two Secrets from one generated password (mirroring the
`smoke` fixture's own two-Secret precedent) is the natural resolution; exact
naming is left to Design. [`research/public.md` §3]

**Redis/Valkey is optional, not a hard dependency, for basic operation.** No
bundled Redis subchart or `redis.enabled` toggle exists; `REDIS_URL` wires
only response-caching and the optional `sse` (real-time push) component. One
Flagsmith doc page marks `REDIS_URL` "Required" in a per-variable reference
table while two other doc pages (the Kubernetes hosting guide, the Caching
Strategies page) describe Redis-backed features as opt-in layered on a
Postgres-only base — a real, if likely overbroad, documentation
inconsistency, flagged for build-time re-verification rather than silently
picking a side. The chart's own defaults (`sse.enabled` independent toggle, no
Redis wiring in the `api` deployment) side with "optional." This mirrors
Storage's own framing of the Valkey ACL convention as "recommended, not
mandated" — the same non-mandatory posture extends naturally to Flagsmith's
own (non‑)use of the shared Valkey instance. [`research/public.md` §4]

**A third, Flagsmith-internal secret is needed: `DJANGO_SECRET_KEY`.**
Separate from the database credential, the chart supports
`api.secretKeyFromExistingSecret` for the Django app's own cryptographic
signing key — a third KSOPS-sealed value, generated the same
`openssl rand`-into-`sops`-encrypt way as every other credential in this
project. [`research/public.md` §5]

**Admin bootstrap is half-declarative, half-imperative — by the chart's own
design, not an omission to route around.** `api.bootstrap` (enable, admin
email, org name, project name) declaratively creates a default superuser,
organisation, and project on first boot, but the block has **no password
field anywhere** — Flagsmith's own bootstrap mechanism intentionally emits a
one-time password-reset link to the API pod's stdout rather than accepting a
supplied password, and the documented headless alternative
(`manage.py changepassword`) itself prompts interactively rather than reading
`--noinput`. A fully non-interactive local bootstrap therefore needs one
`kubectl exec`-delivered Django-shell one-liner (read the in-memory-generated
password the KSOPS Secret is also sealed from, `set_password`, save) — an
imperative step of the same shape as the workloads feature's planned
image-build step or the project's own `bootstrap` mise task, not a new kind of
seam. Retrieving the environment API key an SDK/OpenFeature client
authenticates with needs the same kind of one-shot script (there is no
chart-level mechanism that surfaces it declaratively). Design should pick
explicitly between this scripted non-interactive path and simply documenting
the browser password-reset-link flow for a single local operator.
[`research/public.md` §6]

**OpenFeature confirmed as a pure client-consumption convention — the task's
stated hypothesis holds.** OpenFeature is a vendor-neutral evaluation API;
Flagsmith ships first-party provider packages (client-side
`@openfeature/web-sdk` + `flagsmith-client-provider`; server-side Rust
`open-feature`+`flagsmith` and Python `openfeature-sdk`+
`openfeature-provider-flagsmith`) that a *later consuming workload* installs
and points at a Flagsmith environment key — exactly the three SDK rows
`ARCHITECTURE.html`'s own Platform-services panel already lists. Nothing about
OpenFeature changes how Flagsmith itself is built, configured, exposed, or
composed in this feature-step: no OpenFeature-specific server component, CRD,
port, or Helm value exists anywhere in the chart or Flagsmith's own API. The
one concrete implication for scope: a **browser-based** OpenFeature client (a
future static-site Workload using `@openfeature/web-sdk`) needs a
Gateway-reachable API host, not just cluster-internal Service DNS — worth
flagging for whichever feature-step ultimately wires a Workload to a flag, not
something this feature-step must solve now (this feature-step exposes the
admin UI; wiring a consumer is explicitly Feature 9's job, and only "where a
workload actually reads a flag" per the parent plan). [`research/public.md`
§7]

**The chart ships native Gateway API support.** A top-level `gateway:` values
block (`frontend`/`api`/`sse` sub-blocks, each with `enabled`, `parentRefs`,
`hostnames`, `rules`) landed 2026-04-09, letting the chart render its own
`HTTPRoute`(s) directly rather than requiring one hand-authored alongside it.
This maps directly onto `networking-istio`'s shared contract shape
(`parentRefs` to `agrippa-gateway` in `istio-ingress`,
`sectionName: https`), but every other consumer of that contract so far
(the Networking feature-step's own ArgoCD proof route) has hand-authored its
`HTTPRoute` as an independent manifest, not delegated it to a chart. Which
approach this feature-step takes is a genuine Design-phase Open Artifact
Decision, not resolved here — noting the option exists is the research
contribution. [`research/public.md` §1, §3]

## Libraries & Skills

**Before doing any work in this feature, load these skills via the active
harness's skill-loading mechanism:** `developer:initialize` (for any residual
`mise` tool-pin work — see below, likely none), and `research:public` /
`research:codebase` (for build-time re-verification of the version pins and
field spellings this research defers).

**No library-shipped agentic skill exists for Flagsmith, OpenFeature, or the
official `flagsmith-charts` Helm chart.** A deliberate check (chart
repository, chart README, Flagsmith's own docs site, the OpenFeature provider
packages on npm/PyPI/crates.io) surfaced no `SKILL.md`, MCP server, or
`skills/` directory shipped by any of them — consistent with every other
infrastructure component this project has researched (`research.md`'s own
project-level finding, reconfirmed here per-component rather than assumed).
Build to the in-repo contracts instead: `ARCHITECTURE.html` § S5 Platform (the
`OpenFeature → Flagsmith` service panel, Postgres-backed, the three SDK rows),
`DEVELOPMENT.md` § Secrets (the sops+age+KSOPS wiring this feature-step's
three credentials follow), and the two completed sibling
designs — `storage-postgres-valkey` (the CNPG `Database`/role-per-app pattern
this feature-step consumes, and the two-Secrets-from-one-password precedent
this feature-step's own credential-shape wrinkle extends) and
`networking-istio` (the shared append-only-`dnsNames`-list precedent, and the
`HTTPRoute`-per-consumer convention this feature-step's chart-native-Gateway
option sits alongside) — as the authoritative contracts to build to.

This feature-step adds **no new mise-managed CLI**: Flagsmith is an in-cluster
Helm release ArgoCD reconciles, not a local tool: every CLI the credential-
sealing and bootstrap-scripting steps need (`sops`, `age`, `kustomize`,
`helm`, `kubectl`, `k3d`, `yq`, `jq`, `bitwarden`, `openssl` for random
generation) is already pinned in `mise.toml` — live-confirmed, unchanged since
`storage-postgres-valkey` landed. No `flagsmith`-specific CLI exists to pin.

## Falsification/Refine

Specific-lens right-sizing.

**Size: one feature-step, not a project or a bug.** Matches the parent plan's
own decomposition (Feature 7 of 9); scoped to landing one Postgres-backed
Helm release plus its credentials, its DB/role, and its Gateway exposure — the
same shape as the already-completed `storage-postgres-valkey` and
`networking-istio` feature-steps, and directly parallel in scope/complexity to
the concurrently-researched Feature 5 (Keycloak) and Feature 6 (Forgejo).

**Off-the-shelf: accepted, not rejected — this is the correct default here.**
Unlike the project-level "off-the-shelf platform" question (rejected, since
the project's whole point is a self-managed, parity-preserving platform),
Flagsmith itself is the sanctioned off-the-shelf component: `ARCHITECTURE.html`
already names it as the platform's feature-flag service, and its official Helm
chart is exactly the "same Helm charts and manifests locally and in
production" parity model this project is built around. No in-house
alternative was considered or is warranted.

**Smallest version that still meets the intent.** The smallest honest slice:
one Flagsmith Helm release, external-Postgres-configured against the shared
CNPG `postgres` Cluster with its own `flagsmith` database/role (Feature 4's
contract), one admin bootstrap (declarative user/org/project plus one
imperative password-set step), one Gateway-exposed admin UI at a dev
hostname, and the credentials (DB DSN, Django secret key) sealed the way
`storage-postgres-valkey` established. Deliberately **not** in this
feature-step's smallest slice: the `sse` real-time component, any Valkey/Redis
wiring, and wiring any actual Workload to an OpenFeature provider (Feature 9's
job, and only for a workload that chooses to read a flag) — all reversible,
additive follow-ups if a later need arises.

**Claims falsified against reality.** Two initial assumptions did not fully
survive contact with the chart's actual shape:

1. The task's own framing left open whether Flagsmith "needs" Valkey/Redis for
   its cache layer. It does not, for basic operation — Redis is wired purely
   through opt-in env vars with no bundled dependency, though one Flagsmith
   doc page's "Required" label on `REDIS_URL` is a real inconsistency against
   the other two pages and the chart's own defaults, flagged for build-time
   re-verification rather than trusted outright either way.
2. "Declarative admin bootstrap" is only half true. The chart's `bootstrap`
   block declaratively creates the user/org/project, but by Flagsmith's own
   design there is no password field anywhere in that path — a one-time
   password-reset link logged to stdout is the documented mechanism. A fully
   non-interactive local-dev bootstrap needs one additional imperative
   `kubectl exec` step this research surfaces explicitly so Design does not
   assume pure declarativity where none exists.

## Scope

### In scope for this feature-step's Design phase

- One Flagsmith Helm release (`Flagsmith/flagsmith-charts`, chart ~0.82.0 —
  re-verify current version at build time) in the `platform` layer's
  `overlays/dev`, in its **own subdirectory** (e.g.
  `platform/overlays/dev/flagsmith/`) referenced as one more entry in the
  shared `platform/overlays/dev/kustomization.yaml`'s `resources:` list — see
  § Landing mechanism below.
- `databaseExternal` configuration against the shared CNPG `postgres` Cluster,
  consuming `storage-postgres-valkey`'s contract: a `flagsmith` database/role
  via a `managed.roles[]` append (the one shared, append-only edit to
  `storage/overlays/dev/postgres-cluster.yaml`) plus a self-owned `Database`
  CR authored in this feature-step's own layer, exactly mirroring the
  `keycloak`/`forgejo`/`flagsmith` slug pattern that design already names.
- Three KSOPS-sealed credentials, generated and encrypted the way
  `storage-postgres-valkey` established (in-memory generation, immediate
  `sops --encrypt`, only ciphertext committed): the `flagsmith` role's
  basic-auth Secret (for the CNPG `managed.roles[]` reference), a composed-DSN
  Opaque Secret (for `databaseExternal.urlFromExistingSecret`), and a Django
  `SECRET_KEY` Opaque Secret (for `api.secretKeyFromExistingSecret`). Exact
  Secret names are a Design-phase Open Artifact Decision.
- One Gateway-exposed admin UI route at a picked dev hostname (recommend
  `flags.127.0.0.1.nip.io`, following the `<prod-host>.127.0.0.1.nip.io`
  mirror scheme `networking-istio` fixed — noting no production hostname for
  Flagsmith is actually named anywhere in `ARCHITECTURE.html` or
  `ROUTING.md`, so this is a fresh pick, not a literal mirror; Design should
  confirm or adjust it) plus one append to the shared
  `agrippa-gateway-tls` `Certificate`'s `dnsNames` — consuming
  `networking-istio`'s contract, not building new Gateway/TLS infrastructure.
  Design decides whether to hand-author the `HTTPRoute` (matching every prior
  consumer of the contract) or use the chart's native `gateway.frontend.*`
  block (a Flagsmith-specific option this research surfaced).
- An admin bootstrap mechanism: the chart's declarative `api.bootstrap` block
  plus one explicit imperative step (a `kubectl exec` Django-shell one-liner,
  or documented browser password-reset-link acceptance) to actually set a
  usable password — Design picks which.
- Sync-wave placement inside `platform/overlays/dev/flagsmith/`'s own
  subdirectory, following the intra-layer sync-wave scheme precedent
  (`storage-postgres-valkey`'s four-tier `-10`/`-5`/`0`/`5` shape): the
  Postgres/Django-secret Secrets before the Helm release, the release itself,
  the `Database` CR after its owning role exists.
- A feature test (`tests/flagsmith.bats`, following the established
  `tests/<feature>.bats` convention) proving the deployed instance is
  reachable through the Gateway, the database connection and Django app both
  work (e.g. the admin login page renders, or a direct DB/role connection
  check mirroring `storage.bats`' own proof), and (only if within the
  feature-step's chosen bootstrap mechanism) that the sealed admin credential
  authenticates.

### Out of scope, kept as seams for a later feature-step or the deferred cloud
cycle

- **The `sse` real-time-push component and any Valkey/Redis wiring** — optional,
  additive, not needed for basic flag-serving; a documented follow-up if
  real-time propagation or response caching is later wanted (mirrors Storage's
  own "Valkey is recommended, not mandated" framing).
- **Wiring any actual Workload to an OpenFeature provider** — explicitly
  Feature 9's job, and only for a workload that chooses to read a flag; this
  feature-step's job ends at "Flagsmith is reachable and has an environment
  API key an SDK could use," not at actually consuming one.
- **This project's own release-flag mechanism actually using this Flagsmith
  instance** (`design.md` § Release Flag notes it will, "once this feature-step
  lands") — relevant context, not something this feature-step builds; the
  release flag itself stays the project's own promotion-of-a-branch mechanism
  regardless of whether any flag is actually read from this instance during
  the project's own build.
- **`overlays/prod`** — a preserved seam, not built, consistent with every
  other feature-step.
- **Organisation/project/environment structure beyond one default org and
  project** (multi-tenant flag management, environment promotion workflows) —
  Flagsmith supports these natively but nothing in this project's scope needs
  more than the one bootstrap-created default.

## Landing mechanism (shared `platform` layer — coordination note)

Per the parent design, Flagsmith lands in the **`platform`** layer
(sync-wave 2), alongside Feature 5 (Keycloak) and Feature 6 (Forgejo) — all
three "platform services" sharing one ArgoCD Application
(`apps/platform.yaml`, comment: "Platform owns ArgoCD self-management,
keycloak, forgejo, & flagsmith"). Live-checked `platform/overlays/dev/`
this session: it currently holds exactly two files —
`kustomization.yaml` (`resources: [argocd.yaml]`) and `argocd.yaml` (the
self-managing ArgoCD Application from the GitOps feature-step) — with the
`kustomization.yaml`'s own header comment already anticipating this:

> "Not empty like the other four layers -- it carries the thin argocd
> self-management Application (Step 3's design), so ArgoCD's own install
> reconciles from here going forward. Real platform content (keycloak,
> forgejo, flagsmith) lands as later feature-steps' added resources here."

**Recommendation, carried into Design and Plan:** this feature-step gets its
own subdirectory, `platform/overlays/dev/flagsmith/`, mirroring the
per-component-subdirectory shape `storage-postgres-valkey` and
`networking-istio` both already established (`cnpg-operator/`, `valkey/`,
`istio-base/`, `istio-control/`, etc. inside their own layer overlays), and
that subdirectory is referenced as **one more entry** in the shared
`platform/overlays/dev/kustomization.yaml`'s `resources:` list (alongside
`argocd.yaml`, and alongside whatever `keycloak/` and `forgejo/`
subdirectories Features 5 and 6 add independently).

**Explicit flag, not a decision this research makes:** three concurrently-
researched feature-steps (5, 6, and this one, 7) all append to the *same*
`platform/overlays/dev/kustomization.yaml` file. This research does **not**
assume ownership of that file, propose its full future content, or coordinate
with the sibling agents researching Features 5/6/8 — per this session's own
framing, "the coordinator sequences the actual builds." The only claim this
research makes is: (a) the file exists today with exactly one `resources:`
entry, (b) its own comment already anticipates exactly this
add-a-subdirectory pattern, and (c) the append-only-list shape is a proven
precedent in this project (the CNPG `managed.roles[]` list, the Gateway
certificate's `dnsNames` list) — so Design should follow it, and Plan/Build
should expect a merge/rebase against whatever Features 5/6/8 land first,
same as any other shared append-only file.

## Resolved Decisions

Answered by this research:

- The official `Flagsmith/flagsmith-charts` Helm chart is the correct,
  actively-maintained default — no Bitnami-style maintenance-risk finding
  applies to it.
- Flagsmith is configured against the shared CNPG Postgres instance via
  `databaseExternal`, not its bundled dev-only Postgres subchart; the
  credential Secret it consumes must be an Opaque composed-DSN string, a
  different shape from CNPG's own basic-auth `managed.roles[]` secret — two
  Secrets from one generated password is the natural resolution.
  connection, and a third `DJANGO_SECRET_KEY` Secret is needed alongside it —
  all three sealed the way `storage-postgres-valkey` established.
- Valkey/Redis is not required for Flagsmith's basic operation; treat it as an
  optional, deferred follow-up (mirroring Storage's own non-mandatory Valkey
  framing), with one flagged documentation inconsistency (a "Required"
  `REDIS_URL` table entry contradicted by the chart's own defaults and two
  other doc pages) to re-verify at build time rather than resolve from
  research alone.
- OpenFeature is confirmed as a pure client-consumption convention with zero
  effect on how this feature-step deploys, configures, or exposes Flagsmith;
  it only surfaces one forward-looking scope note (a browser-based OpenFeature
  client eventually needs a Gateway-reachable API host, not just the admin-UI
  host) for whichever later feature-step wires a real consumer.
- Admin bootstrap is half-declarative (user/org/project via the chart's
  `api.bootstrap` block) and half-imperative by Flagsmith's own design (no
  password field exists in that path); Design must pick explicitly between a
  scripted non-interactive password-set step and documenting the browser
  password-reset-link flow.
- The `platform` layer's landing mechanism is a shared, three-way-appended
  `platform/overlays/dev/kustomization.yaml`, already anticipating a
  per-component subdirectory pattern; this feature-step should add
  `platform/overlays/dev/flagsmith/` as one more `resources:` entry, without
  assuming ownership of the shared file.

### Resolved by the long-loop reviewer (2026-07-08)

A separately dispatched long-loop reviewer read this feature-step's `research.md`
and `research/public.md` cold and resolved the six items above, one entry per item
per Ailly's Draft Gate Enforcement convention. Each was researched against the
in-repo contracts (`ARCHITECTURE.html` § S5 Platform, `ROUTING.md`,
`DEVELOPMENT.md` § Secrets), the two cleared sibling feature-steps whose contracts
this step consumes (`networking-istio` design+plan, `storage-postgres-valkey`
design+plan) and their committed feature tests (`tests/networking.bats`,
`tests/storage.bats`), the Forgejo sibling's hostname finding, and — for item 6 —
the Flagsmith chart's actual source on `main` (`charts/flagsmith/values.yaml` and
`templates/_api_environment.yaml`) via `research:public`. The live `k3d-agrippa-dev`
cluster was **read only** (the `platform` Application confirmed `Synced/Healthy`
rendering only `Application/argocd`, so `platform/overlays/dev` carries exactly
`resources: [argocd.yaml]` live; no `flagsmith` namespace exists) and left untouched.
Each item is decided to the conservative, reversible default; no escalation trigger
(irreversible, out of recorded scope, underdetermined) fired, so this draft gate is
cleared (marker now `*Reviewed 2026-07-08*`). These are research-phase conservative
defaults the Design phase inherits as settled inputs — the same path
`storage-postgres-valkey`'s research reviewer block fed its design — not final
artifact spellings; Design may refine any of them with build-time evidence.

**1. Hand-authored `HTTPRoute` vs. the chart's native `gateway.frontend.*` block.
Decided: hand-author one independent `HTTPRoute` in Flagsmith's own namespace,
matching every prior consumer of the Networking contract; leave the chart's
`gateway.*` block disabled (its default).** Verified against the chart source that
the native route works — `templates/httproute-frontend.yaml` renders only when both
`.Values.frontend.enabled` and `.Values.gateway.frontend.enabled` are true, reading
`.Values.gateway.frontend.parentRefs`/`hostnames`/`rules`, so it *could* target
`agrippa-gateway`. But `networking-istio`'s design fixes the consumption contract as
"(1) create one `HTTPRoute` … `parentRefs: [{name: agrippa-gateway, namespace:
istio-ingress, sectionName: https}]`; (2) append your host to `agrippa-gateway-tls`'s
`dnsNames`," and every consumer so far (the ArgoCD proof route) authors that route as
a standalone manifest. A hand-authored `HTTPRoute` is the conservative default: it
keeps Flagsmith's ingress wiring byte-identical to the shared-contract shape every
sibling reviewer already cleared, decouples the route from the chart's own
(0.82-new, landed 2026-04-09) Gateway-values schema, and keeps the route reviewable
next to the cert `dnsNames` append rather than buried in Helm values. Reversible
(switching to the chart-native block later is a values edit), determined by the
established precedent; no escalation.

**2. Exact Secret names and the two-Secret-from-one-password mechanics. Decided:
three Secrets — `flagsmith-db` (`kubernetes.io/basic-auth`, keys `username`/
`password`, in the `storage` namespace, referenced by the shared Cluster's
`managed.roles[]`); `flagsmith-database-url` (Opaque, one key `DATABASE_URL` holding
`postgres://flagsmith:<pw>@postgres-rw.storage.svc:5432/flagsmith`, in Flagsmith's own
namespace, for `databaseExternal.urlFromExistingSecret`); and `flagsmith-secret-key`
(Opaque, key `SECRET_KEY`, Flagsmith's namespace, for
`api.secretKeyFromExistingSecret`).** `flagsmith-db` follows
`storage-postgres-valkey`'s settled `<slug>-db` basic-auth convention exactly
(its `smoke-db`/`<slug>-db` naming, sealed at
`secrets/dev/storage/postgres/flagsmith.enc.yaml` — the path convention that step
fixed for every consumer of its contract). The DSN Secret is the extra shape this
feature-step's own research surfaced (only `urlFromExistingSecret` exists — no
`passwordFromExistingSecret`, re-confirmed in `values.yaml`), so `flagsmith-db` and
`flagsmith-database-url` are both sealed from the **same** in-memory-generated
password at seal time — the two-Secrets-from-one-password precedent the storage
`smoke` fixture already established (`smoke-db` + `smoke-valkey`). Because CNPG's
`passwordSecret` must sit in the Cluster's own namespace (`storage`) while the DSN
and Django-key Secrets are consumed by the Helm release in Flagsmith's namespace, the
basic-auth half is sealed into `secrets/dev/storage/postgres/flagsmith.enc.yaml` and
the DSN half into a platform-side path (e.g. `secrets/dev/platform/flagsmith/…`); all
three follow the "generate in memory, `sops --encrypt` immediately, commit only
ciphertext" discipline. Reversible (renames touch only this step's own manifests +
test), determined by the storage convention; no escalation. (The Flagsmith namespace
slug — `flagsmith` vs a shared `platform` namespace — and the DSN key spelling stay
Design-phase artifact choices; the Secret *names* and the one-password-two-Secrets
mechanic are settled here.)

**3. The imperative password-set mechanism. Decided: accept the chart's own
documented browser password-reset-link flow for the single local operator (zero new
imperative mechanism); record the scripted `kubectl exec` Django-shell `set_password`
one-liner as the available upgrade if fully non-interactive automation is later
wanted.** The chart's `api.bootstrap` block declaratively creates the
superuser/org/project on first boot and — re-confirmed against `values.yaml`, which
has no `adminPassword` field — logs a one-time reset link to the API pod's stdout by
design. For a single local-dev operator this is the smallest honest slice: it adds no
out-of-band, un-GitOps'd pod mutation, and matches the project's consistent
conservative posture (storage's "recommended not mandated," "inline now, extract on
the rule-of-three"; this research's own "smallest version that still meets the
intent"). The scripted `kubectl exec … python manage.py shell` `set_password` path
stays fully available and is the right move the moment the feature test (or CI) needs
the admin credential asserted non-interactively — but item 5 deliberately keeps the
test off that surface, so nothing forces it now. Reversible (adding the scripted step
later is additive), in recorded scope (the research surfaced both and handed the pick
forward); no escalation.

**4. The exact dev hostname. Decided: `flagsmith.127.0.0.1.nip.io` (not the
research's proposed `flags.…`).** Re-checked `ROUTING.md` directly (zero Flagsmith
references) and `ARCHITECTURE.html`: its Platform panel names Forgejo's production
host (`git.davidsouther.com`) but names **no** production host for Flagsmith (the
OpenFeature→Flagsmith service line carries only "self-hosted Flagsmith ·
Postgres-backed · progressive rollout / A·B, no redeploy," no hostname). So, unlike
Forgejo — whose sibling research correctly took the full mirrored
`git.davidsouther.com.127.0.0.1.nip.io` *because* a prod host is named — Flagsmith has
no prod host to mirror. The governing precedent is then `networking-istio`'s own
no-prod-host case: "ArgoCD has no named prod host; the scheme's suffix is applied to
the service name directly" → `argocd.127.0.0.1.nip.io`. Applying that rule to
Flagsmith's component name gives `flagsmith.127.0.0.1.nip.io` — the full component
name plus suffix, exactly as ArgoCD used its full name (not an abbreviation). This is
more conservative than the research's abbreviated `flags.` (which matches no
precedent) and strictly better than inventing a `flags.davidsouther.com` production
host that appears nowhere in the repo. Reversible (a rename touches only this step's
`HTTPRoute` + the cert `dnsNames` append + the test host), determined by the ArgoCD
precedent; no escalation.

**5. How far the feature test reaches. Decided: a UI/health reachability check
through the shared Gateway (mirroring `networking.bats`'s ArgoCD-UI proof),
strengthened with an assertion against Flagsmith's own API health endpoint (which
transitively proves the Postgres connection, since Flagsmith's readiness check
queries the DB); the test does NOT assert a flag read and does NOT assert the sealed
admin credential authenticates.** Between the two poles item 5 names — a
UI-reachability check (Networking) vs. an API-level flag-read — the reachability check
is the conservative default: an actual flag read needs a fully bootstrapped
environment plus a retrieved environment API key, which depends entirely on item 3's
still-imperative password/key surface (the most fragile, least-settled part of this
feature-step), and asserting admin-credential auth would likewise couple the test to
whichever bootstrap path is chosen. Reaching only "served through the Gateway with a
local-CA cert (Networking's exact proof) and the API `/health` returns 200 (proving
the Django app plus its Postgres connection are live)" proves everything this
feature-step lands — Gateway exposure, DB-contract consumption, the app booting —
without binding the test to the un-GitOps'd bootstrap step. It sits deliberately
between `networking.bats` (pure UI reachability) and `storage.bats` (full
authenticated DB/ACL round-trip): Flagsmith owns the DB *connection*, but the
credential *round-trip* is already proven by the storage `smoke` fixture, so
re-proving it here would be redundant. Reversible (a later hardening pass can add a
flag-read once bootstrap is automated), determined by the sibling precedents; no
escalation.

**6. The `REDIS_URL` "Required" documentation inconsistency. Decided: RESOLVED
EMPIRICALLY — `REDIS_URL` is NOT required; the "Required" env-var-table label is
overbroad, and the "Valkey/Redis optional, deferred follow-up" recommendation is
settled, not merely flagged for build-time re-verification.** Checked the chart's
actual source on `main` rather than picking a doc-page side: (a) `values.yaml` has no
top-level `redis:` block and no `redis.enabled` toggle, and `sse.enabled` defaults to
`false`; (b) decisively, `templates/_api_environment.yaml` — the API container's env
block — contains **no** `REDIS_URL` or `CACHE` reference at all, conditional or
otherwise, so the default-rendered Flagsmith API Deployment is wired with zero Redis
env. A Postgres-only Flagsmith (external DB, SSE disabled, no `REDIS_URL`) is therefore
a complete, chart-default configuration that boots and serves flag evaluation and the
admin UI; Redis only adds opt-in response caching (`GET_FLAGS_ENDPOINT_CACHE_*`) and
the SSE realtime path. This directly falsifies the single "Required" table entry the
research flagged and confirms the chart-defaults + two-other-doc-pages reading. Build
should still pin an explicit chart/app version and re-confirm at that pin, but the
recommendation itself is now empirically settled. Determined by the chart source;
reversible (adding a `flagsmith` Valkey ACL user + `REDIS_URL` later is additive); no
escalation.

## Sources

Full IEEE-style citations for every external claim are in
`research/public.md`. In-repo Prior Art (authoritative, not external):
`ARCHITECTURE.html` § S5 Platform, `DEVELOPMENT.md` § Secrets,
`platform/overlays/dev/kustomization.yaml`, `apps/platform.yaml`, and this
project's completed sibling feature-steps
`storage-postgres-valkey/design.md` + `plan.md` and
`networking-istio/design.md` + `plan.md`.
