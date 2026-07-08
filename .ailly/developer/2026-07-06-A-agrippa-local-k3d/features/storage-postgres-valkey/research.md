# Research: Storage (Postgres + Valkey)

*Reviewed 2026-07-08*

> Feature-step research (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 4: Storage (Postgres +
> Valkey)** of that project's plan: the shared datastore layer, and the
> feature-step that **defines the storage-class + per-app DB/role naming shared
> contract** Features 5-8 (Auth/Keycloak, Git hosting/Forgejo, Feature
> flags/Flagsmith, Observability/LGTM) all bind to. Long-loop: the draft gate
> below is left open for a separately dispatched reviewer to clear; open items
> are surfaced here, not self-resolved.

## Topic and Intent

Original request, verbatim (from the dispatching coordinator's task framing for
this feature-step):

> "Feature 4: **Storage (Postgres + Valkey)**. ... This feature-step DEFINES the
> storage-class + DB-naming shared contract that Features 5-8 (Auth/Keycloak,
> Git hosting/Forgejo, Feature flags/Flagsmith, Observability/LGTM) will all
> consume — get the naming convention right and explicit, since four parallel
> feature-steps bind to it."

and the specific research directive, verbatim:

> "Research the standard local/dev-friendly ways to run Postgres and Valkey
> (Redis-compatible) on Kubernetes via Helm (candidate charts: Bitnami/Broadcom
> `postgresql`, CloudNativePG operator, `valkey`/Bitnami `redis`-compatible
> chart, etc.), how per-app DB/role provisioning is conventionally handled (one
> shared Postgres instance with per-app databases+roles vs. one Postgres
> instance per app), how the credential Secret should be generated and
> sops-encrypted for GitOps consumption ..., and what the storage-class +
> DB-naming convention should be."

Loosely stated goal, in the project's own framing (`plan.md` § Feature 4): stand
up Postgres and Valkey Helm-delivered workloads on the already-settled
`local-path` dev storage class, applied through the GitOps spine (Feature 2)
into the `storage` layer's `overlays/dev` (currently an empty, trivially
Synced/Healthy placeholder), and settle the per-app Postgres DB/role naming
convention that four parallel feature-steps (Layer 4 of the project's
dependency graph) will each bind to independently.

## Search/Expand

General-lens findings on the current (2026) state of running Postgres and
Valkey on Kubernetes via Helm/GitOps, and on per-app credential provisioning
conventions. Full citations and the falsification pass are in
`research/public.md`; this section synthesizes what bears on scope and design.

**The obvious default — Bitnami's `postgresql`/`valkey` charts — is no longer a
safe default.** Broadcom restructured Bitnami's public chart catalog through
2025: after 2025-09-29 most Bitnami Helm chart OCI packages moved behind a paid
"Bitnami Secure Images" subscription, leaving the free `bitnami/charts` tree a
frozen, security-patch-less "legacy" snapshot. This is a **falsified prior
assumption**, not a neutral option among several — any pre-2025 recommendation
to "just use the Bitnami chart" no longer holds for a new project starting now.

**The community/project response for Postgres is an operator, not a
Deployment-templating chart: CloudNativePG (CNPG).** CNPG is a CNCF-hosted
Postgres operator, installed via its own official Helm chart
(`https://cloudnative-pg.github.io/charts`, chart `cloudnative-pg`), independent
of Bitnami's licensing change and the option every current source comparing it
to the (now-paywalled) Bitnami chart recommends for anything beyond a
throwaway container. Operator-plus-authored-CRs is not a new composition shape
for this repo: it is exactly how the already-built `core` layer installs
cert-manager and metallb (a controller via chart/manifest, configuration via
plain authored CRs) — this feature-step extends the same pattern to storage.

**CloudNativePG's declarative `Database` CRD and `Cluster.spec.managed.roles`
are the GitOps-native mechanism for per-app DB/role provisioning on one shared
instance — the central finding answering this feature-step's naming-contract
question.** A `Cluster` CR is the single shared Postgres instance
(`spec.instances: 1` for dev, `spec.storage.storageClass: local-path`). Each
consumer's database is a separate, continuously-reconciled `Database` CR
(`spec.owner: <role>`, `spec.cluster.name: <shared-cluster>`) that can be
authored anywhere in the repo that references the shared Cluster — it does not
require editing the Cluster's own manifest. Role credentials are supplied via
`Cluster.spec.managed.roles[].passwordSecret`, a Secret reference the operator
continuously reconciles against (drift from a manual `ALTER ROLE` is reverted
on the next cycle). Appending a role to `managed.roles` does mean editing the
**one shared Cluster manifest** — but this project already has an accepted
precedent for exactly that shape: the Networking feature-step's shared Gateway
certificate, where every later consumer appends its own hostname to one shared,
mutable `dnsNames` list rather than each owning a separate object. CNPG 1.30
(released 2026-07, this week) introduces a newer `DatabaseRole` CRD that
promotes role management to its own namespaced resource specifically to fix
`managed.roles`' RBAC-scoping flaw — but its first cut supports **only**
certificate-based auth, no `passwordSecret` field at all, so it does not yet
cover this project's actual need (Keycloak/Forgejo/Flagsmith all expect a
plain username/password DSN). Recorded as a forward-looking watch-item, not
this feature-step's mechanism.

**Database-per-tenant on one shared instance is the standard middle ground**
for this class of problem (a handful of internal platform services, not
thousands of external tenants) — distinct from schema-per-tenant (weaker
isolation) and instance-per-tenant (full isolation, much higher operational
overhead for no benefit at this scale). This matches, rather than
contradicts, what `ARCHITECTURE.html` already states as this project's own
prior intent (`storage/postgres`'s design note: "single instance · per-app DBs
isolated by name + role").

**The official Valkey Helm chart (`valkey-io/valkey-helm`) is the same
community response to the same Bitnami disruption, for Valkey.** Maintained by
the Valkey project itself, standalone mode is the default (one pod — the shape
this dev overlay wants); persistence is opt-in via `dataStorage.enabled/
requestedSize/className`. Its authentication mechanism is ACL users
(`auth.aclUsers`, `auth.usersExistingSecret` for production-safe credential
delivery), each scoped by Valkey's native key-pattern glob syntax
(`~<pattern>`) — a direct Valkey analogue of a per-app Postgres role: an ACL
user named for its consumer, restricted to that consumer's own key prefix
(`~keycloak:*`), credentials delivered the same Secret-reference way. Valkey
Cluster mode is explicitly out of this chart's scope (a separate operator-based
chart is still in development upstream) — irrelevant here, since this project
needs neither Valkey Cluster nor Sentinel.

**`local-path` is confirmed live as the k3s default StorageClass on the running
`agrippa-dev` cluster** (`kubectl get storageclass` → `local-path (default)`,
`WaitForFirstConsumer`), matching the parent project's already-settled decision
1 with no new finding needed — and `WaitForFirstConsumer` is exactly the
binding mode that makes it safe for both the CNPG `Cluster`'s PVC and Valkey's
`dataStorage` PVC to co-locate on the one k3d node.

**The sops+age+KSOPS workflow for an application-level Secret (as distinct from
the trust-root `sops-age` Secret GitOps injects directly) is: generate a random
credential in memory, write it straight into a plaintext Secret manifest, pipe
it directly into `sops -e`, commit only the ciphertext.** This project's own
already-built `scripts/rotate-keys.sh` already implements exactly this
discipline for the trust-root key itself (`age-keygen` output piped straight to
`bw create item`, no disk round-trip); this feature-step's own per-app
credential generation should reuse that discipline as an established local
convention, not invent a new one.

**Live-verified in-repo correction to this feature-step's task briefing:
`.sops.yaml`'s dev recipient is still the literal placeholder string**
(`AGE-PLACEHOLDER-REPLACE-WITH-REAL-agrippa-age-dev-PUBLIC-KEY`), not the "real
`agrippa-age-dev` recipient now live" the briefing asserted. No `secrets/`
directory exists yet anywhere in the repo, and this is the **first**
feature-step needing to commit an application-level sops-encrypted Secret (the
already-built `gitops-argocd` feature-step's own trust-root Secret is injected
directly by `bootstrap.sh`, never sops-encrypted-and-committed). The fix
mechanism already exists and needs no new design: `mise run rotate-keys dev`
(already committed, already covered by `tests/rotate-keys.bats` per this
session's `git status`) generates the real keypair, stores it in Bitwarden, and
rewrites `.sops.yaml`'s placeholder on its documented first-run branch. This is
a build-phase prerequisite this feature-step's design should name explicitly,
not a gap for this feature-step to solve.

> **[Reviewer correction, 2026-07-08 — see "Resolved by the long-loop reviewer"
> item 6 below.]** This claimed mechanism is falsified by live state.
> `agrippa-age-dev` **already exists** in Bitwarden (holding the real age
> identity `bootstrap.sh` already seeded the in-cluster `sops-age` trust root
> from — `age-keygen` public half
> `age1e8wr0f85w0yfqgxc3pc6426ghlu5xt069znn5yuwrtwz30u23quqjcx6vc`, verified this
> session). So `rotate-keys dev` does **not** take a first-run branch: it detects
> the existing item, prompts interactively for a typed `rotate` confirmation, and
> if confirmed **rotates** — archives the working key and mints a new one —
> desynchronising `.sops.yaml` (and any secret newly encrypted to it) from the
> trust root already in the cluster, which would then fail to decrypt until
> `bootstrap` is re-run. The conservative, non-destructive fix is **not**
> `rotate-keys`: write the existing item's public recipient into `.sops.yaml`,
> replacing the placeholder, without minting a new key.

## Libraries & Skills

**Before doing any work in this feature, load these skills via the active
harness's skill-loading mechanism:** none new — carried forward unchanged from
the project's `research.md` and `design.md` § Libraries & Skills:
`developer:initialize` (this feature adds **no** new mise-managed CLI: the CNPG
operator and the Valkey chart are both in-cluster resources ArgoCD reconciles
via Helm, not local tools; an optional `kubectl cnpg` plugin may aid
build-time/operator debugging, staying unpinned exactly the way `istioctl`
stayed optional/unpinned for Networking), `research:public` and
`research:codebase` (already exercised by this document and `research/
public.md`), and the `developer:ailly` project-shape references.

**No library-shipped agentic skill exists for CloudNativePG, the official
Valkey chart, sops, age, or KSOPS.** This reconfirms, at the per-component
level, the project's already-recorded top-level finding. `ARCHITECTURE.html`
(§ S4 Storage, § S5 Platform layer listing), `DEVELOPMENT.md` (§ Secrets — the
sops/age/KSOPS wiring this feature-step's credentials must follow), and the two
completed sibling designs (`gitops-argocd` for the KSOPS/`sops-age` convention
and the `secrets/dev/<component>.enc.yaml` path precedent; `networking-istio`
for the shared-append-only-list precedent and the `helmCharts:`+authored-CRs
composition precedent) remain the authoritative in-repo contracts this
feature-step builds to.

**Per-library docs review**, closest worked examples included, full citations
in `research/public.md`:

- **CloudNativePG.** Getting-started: `cloudnative-pg.io/docs/` and the
  official chart at `cloudnative-pg.io/charts/`. Closest worked examples: the
  minimal single-instance `storage.storageClass`/`storage.size` Cluster sample
  (`research/public.md` [12]), the `Database` CRD owner-role example [15], and
  the `Cluster.spec.managed.roles` `passwordSecret` example [16]. No skill.
- **Valkey (official chart).** Getting-started: `valkey.io/valkey-helm/` and
  the chart's own README (`research/public.md` [19][20]). Closest worked
  example: the `auth.aclUsers`/`usersExistingSecret` per-user ACL block quoted
  in full in `research/public.md`. No skill.
- **sops / age / KSOPS (application-secret half).** Already covered by
  `gitops-argocd`'s own research and this project's `DEVELOPMENT.md`; this pass
  adds only the "commit an encrypted application Secret, not just the
  trust-root Secret" worked pattern (`research/public.md` [25][26]). No skill.

## Falsification/Refine

Specific-lens right-sizing.

**Size: one feature-step, already fixed by the project plan.** `plan.md` names
this Feature 4 with an explicit scope (Postgres and Valkey Helm charts, the
`local-path` storage class already decided) and an explicit deliverable (the
storage-class + per-app DB/role naming shared contract for Features 5-8).
Nothing in this research pass argues for resizing it.

**Off-the-shelf: the categorical choice ("run Postgres and Valkey") was already
decided upstream** (`README.md`, `ARCHITECTURE.html`, the project `research.md`);
this feature-step's genuine job is the concrete **delivery mechanism**, and that
part is not a re-litigation but a real refinement this research forces: the
Bitnami charts `ARCHITECTURE.html`'s original architecture cycle would likely
have assumed are no longer a viable free default, so "which chart" is an open
question this research answers (CloudNativePG operator; the official
`valkey-io/valkey-helm` chart), not a foregone conclusion.

**Smallest version that still meets the intent.** The shared contract this
feature owes (storage class + per-app DB/role naming) needs: one shared
Postgres `Cluster` (single instance, dev-sized) on `local-path`, one shared
Valkey instance (standalone mode) on `local-path`, and a **documented,
demonstrated** mechanism for adding a per-app database/role/ACL-user — it does
**not** need to pre-provision Keycloak's, Forgejo's, or Flagsmith's actual
databases now, since none of those feature-steps has its own design yet
(mirroring the boundary Networking already drew: define the shared Gateway
contract, do not pre-build every future consumer's HTTPRoute). Unlike
Networking, which proved its contract end-to-end at zero new-workload cost by
routing the pre-existing ArgoCD UI through the new Gateway, **Storage has no
equivalent pre-existing consumer** — nothing already running needs a database.
This feature-step's own design therefore needs to define a minimal proof
object of its own (a smoke-test database/role pair) to demonstrate the
mechanism end-to-end (CNPG Cluster Healthy, a declaratively-managed role and
database both reconcile, the sops-encrypted credential round-trips through
KSOPS correctly) without inventing real application schema. This is flagged as
an open item for the design phase below, not decided here.

**Claims falsified against reality.** Two assumptions did not survive contact:

1. "Bitnami's `postgresql`/`valkey` charts remain a free, unrestricted default
   in 2026" — falsified; Broadcom's 2025 restructuring moved most of the free
   catalog behind a paid subscription, leaving only a frozen/unmaintained
   legacy snapshot. See `research/public.md` § Falsification pass.
2. This feature-step's own task briefing's claimed "live fact" that ".sops.yaml's
   real agrippa-age-dev recipient is now live... replacing the earlier
   placeholder" — falsified by direct inspection this session; `.sops.yaml`
   still carries the literal placeholder string. This is a note-only
   correction (the fix mechanism already exists and is a build-phase step, not
   a scope change), recorded here per the phase convention of checking briefed
   claims against live reality rather than restating them uncritically.

## Scope

### In scope (this feature-step)

- **The CloudNativePG operator**, installed via its official Helm chart
  (`helmCharts:` inflation inside `storage/overlays/dev/kustomization.yaml`,
  the same composition shape `networking-istio` already used for Istio inside
  `core` — no new `argocd-cm` `kustomize.buildOptions` wiring needed,
  `--enable-helm` already landed with that feature-step, live-confirmed this
  session).
- **One shared Postgres `Cluster` CR** (single instance for dev,
  `storage.storageClass: local-path`), the substrate every later Postgres-backed
  platform service (Auth, Git hosting, Feature flags) binds to.
- **The official Valkey Helm chart**, standalone mode, `dataStorage` on
  `local-path`.
- **The per-app Postgres DB/role naming convention** — this feature-step's
  headline deliverable — expressed as a documented mechanism (CNPG
  `Cluster.spec.managed.roles` append + a per-app `Database` CR) plus a
  concrete naming pattern (proposed: database name = role name = the
  consuming app's own slug, e.g. `keycloak`/`keycloak`, `forgejo`/`forgejo`,
  `flagsmith`/`flagsmith` — settling the exact spelling is a Design-phase
  artifact decision, flagged below).
- **The application-secret sops+age+KSOPS workflow**, applied for the first
  time in this project to a real per-app Postgres role credential: generate
  in memory, encrypt immediately, commit only ciphertext under
  `secrets/dev/storage/...` (extending `.sops.yaml`'s already-declared
  `secrets/dev/.*` path rule and `DEVELOPMENT.md`'s own example path).
- **A minimal proof object** (this feature-step's own smoke-test
  database/role/ACL-user) demonstrating the mechanism end-to-end for its
  feature test, since — unlike Networking's reuse of the pre-existing ArgoCD
  UI — Storage has no already-running consumer to route through.
- **Extending `storage/overlays/dev/kustomization.yaml`** from its current
  empty `resources: []` placeholder.

### Out of scope (deferred, per already-cleared parent artifacts or genuinely
this feature-step's non-concern)

- **Pre-provisioning Keycloak's, Forgejo's, or Flagsmith's actual application
  databases** — each of those feature-steps (Features 5-7) owns its own
  `Database` CR + `managed.roles` entry, consuming this feature-step's
  contract, not the other way around.
- **Longhorn** — declared in the app-of-apps per the project's app-of-apps
  contract but scoped out of `overlays/dev` (parent `research.md` decision 1);
  this feature-step's storage class is `local-path` only.
- **Off-cluster DR** (pg_dump, block-level backups to S3) — deferred; local DR
  is GitOps-only (RPO 0 for declarative state), per the parent design.
- **CNPG HA/replication (`instances` > 1), Valkey replication or Cluster
  mode** — dev is a single-node k3d cluster; both components run standalone/
  single-instance.
- **Observability's (Feature 8) own datastore need** — the parent plan's own
  Shared Contracts section lists Feature 8's shared contract as "storage
  class" only, not DB naming (Loki/Mimir/Tempo store signals on `local-path`
  PVCs directly, not Postgres); this feature-step's Postgres DB/role contract
  is scoped to Features 5-7 unless Design decides otherwise.

## Resolved Decisions

Answered by this research:

- **(a) Which Postgres/Valkey chart(s).** CloudNativePG (operator, official
  Helm chart at `cloudnative-pg.github.io/charts`) for Postgres; the official
  `valkey-io/valkey-helm` chart (standalone mode) for Valkey. Bitnami's
  `postgresql`/`valkey` charts are explicitly **not** recommended — Broadcom's
  2025 restructuring moved them behind a paid subscription, leaving only a
  frozen/unmaintained free snapshot.
- **(b) Single shared instance vs. per-app instance.** Single shared instance
  for both Postgres and Valkey, with per-app isolation at the
  database/role (Postgres) and ACL-user/key-prefix (Valkey) level — matching
  `ARCHITECTURE.html`'s already-stated intent and standard multi-tenant
  Postgres practice for this class of problem (a handful of internal platform
  services).
- **(c) The DB/role naming convention (the shared contract).** Database name =
  role name = the consuming app's own slug (`keycloak`, `forgejo`,
  `flagsmith`, ...), provisioned via a `Database` CR (owner = the same-named
  role) plus a `Cluster.spec.managed.roles[]` entry carrying a
  `passwordSecret` reference. Each later feature-step (Auth, Git hosting,
  Feature flags) appends its own `managed.roles[]` entry to the shared
  `Cluster` manifest (mirroring the accepted Gateway-certificate
  `dnsNames`-append precedent) and authors its own `Database` CR in its own
  layer/namespace (mirroring the accepted per-consumer-HTTPRoute precedent) —
  no other feature-step ever needs to touch this feature-step's own storage
  manifests beyond that one append. Valkey follows the same slug-scoped
  pattern via ACL users restricted to a `~<app>:*` key prefix, recommended as
  a consistent extension of the same convention (see open item 2 below for
  its exact scoping).
- **Credential generation and sops-encryption mechanism.** Reuses the
  already-established "generate in memory, encrypt immediately, never touch
  disk" discipline `scripts/rotate-keys.sh` already implements for the
  trust-root key; no new mechanism is needed, only its first application to
  an application-level Secret, committed under `secrets/dev/storage/...`.
- **`.sops.yaml`'s placeholder recipient (live-verified, correcting the task
  briefing).** Still the literal placeholder string. The fix is a build-phase
  prerequisite for this feature-step, not a new design item — but it is **not**
  `mise run rotate-keys dev` (which would destructively rotate the live trust
  root, since `agrippa-age-dev` already exists in Bitwarden). The correct fix is
  to write the existing `agrippa-age-dev` public recipient into `.sops.yaml`,
  replacing the placeholder, without minting a new key. See the reviewer block
  (item 6) for the verified mechanism.
- **Off-cluster DR, Longhorn, HA/replication, Valkey Cluster mode** — all
  confirmed out of scope, consistent with parent-level decisions already made.

### Open for the design phase (not resolved here)

1. **The exact shape of this feature-step's own feature-test proof object.**
   Networking proved its contract at zero new-workload cost by reusing the
   pre-existing ArgoCD UI; Storage has no equivalent free consumer. Design
   should settle a concrete smoke-test database/role/ACL-user name and decide
   whether it is a permanent fixture (kept as a live health-check target) or a
   throwaway the feature test creates and tears down.
2. **How rigidly Valkey inherits the same per-app naming convention.** The
   parent plan's own Shared Contracts section names "per-app Postgres DB/role
   naming" explicitly but is silent on a parallel Valkey ACL-user convention;
   this research recommends extending the same pattern for consistency but
   leaves it to Design whether to mandate it as part of the shared contract or
   leave it a lighter, per-consumer-opt-in recommendation.
3. **The concrete file layout inside `storage/overlays/dev/kustomization.yaml`**
   (a flat overlay vs. a `storage/base/` the overlay patches, mirroring the
   Open Artifact Decision Networking already resolved to "flat, no
   `overlays/prod` content to share a base with yet") and the exact
   object/namespace names (the `Cluster`'s own name, the CNPG operator's
   target namespace, e.g. `cnpg-system` vs. `storage`).
4. **Exact chart/operand version pins** — the CNPG chart version, the Postgres
   major version, the Valkey chart's `0.9.0` pin — deferred to build-time
   `research:public`, consistent with how `networking-istio`'s plan deferred
   its own upstream release tags and chart versions.
5. **`secrets/dev/storage/` sub-layout** — whether this feature-step
   pre-creates the directory structure now or each later consuming
   feature-step creates its own path under it, mirroring the still-open
   granularity question `gitops-argocd`'s own design left to "each layer's own
   feature-step."

## Sources

Full IEEE-style citations (26 numbered sources plus the falsification pass) are
in `research/public.md`. Summary, deduplicated:

- [1]-[4] Broadcom's 2025 Bitnami catalog restructuring and its paid "Bitnami
  Secure Images" successor (BLUESHOE, The New Stack, Broadcom TechDocs,
  Industrial Monitor Direct).
- [5]-[6] The still-public but frozen/legacy Bitnami `postgresql`/`valkey`
  chart directories (bitnami/charts GitHub).
- [7]-[11] CloudNativePG: official docs, official Helm chart repository, and
  comparisons against the (now-paywalled) Bitnami chart.
- [12]-[14] CloudNativePG storage-class Cluster samples, the operand image
  repository and its default/pinning guidance.
- [15]-[16] CloudNativePG's `Database` CRD and `Cluster.spec.managed.roles`
  declarative role management docs.
- [17] Gabriele Bartolini, CNPG 1.30's new `DatabaseRole` CRD announcement
  (no `passwordSecret` field; the `managed.roles` RBAC-scoping critique).
- [18] PlanetScale, multi-tenant Postgres approaches (database-per-tenant).
- [19]-[20] The official Valkey Helm chart announcement and its README
  (deployment modes, storage, `auth.aclUsers`/`usersExistingSecret`).
- [21]-[22] Valkey's native ACL mechanism and key-pattern glob syntax.
- [23]-[24] `local-path`/`local-path-provisioner` scope and
  `WaitForFirstConsumer` behavior.
- [25]-[26] Application-level sops+age+KSOPS encrypt-then-commit workflow.

In-repo Prior Art (authoritative, not external): `ARCHITECTURE.html` (§ S4
Storage, § S5 Platform), project `design.md` § Specification § Storage and §
Shared contracts, project `plan.md` § Feature 4 and § Shared Contracts, project
`research.md` decision 1 (`local-path`), `DEVELOPMENT.md` § Secrets,
`.sops.yaml`, `tests/policy/secrets.rego`, `apps/storage.yaml`,
`storage/overlays/dev/kustomization.yaml`, `mise.toml`, `scripts/
rotate-keys.sh`, `scripts/bootstrap.sh`, `features/networking-istio/design.md`,
`features/networking-istio/plan.md`, `features/gitops-argocd/design.md`. Live
cluster state (verified this session, 2026-07-08): `kubectl get storageclass`
→ `local-path (default)`; `kubectl -n argocd get cm argocd-cm` →
`kustomize.buildOptions` already carries `--enable-helm`; `kubectl -n argocd
get application storage` → `Synced`/`Healthy` on the empty placeholder; `cat
.sops.yaml` → placeholder recipient, not the real key.

## Resolved by the long-loop reviewer (2026-07-08)

A separately dispatched long-loop reviewer read this feature-step's research
artifact (`research.md` + `research/public.md`) cold, re-verified its live claims
against the working tree, the Bitwarden vault, and the running cluster, then
researched each open item against this repo's own conventions and the cleared
sibling feature-steps. Each was decided to the conservative default. No escalation
trigger (irreversible, out of recorded scope, or underdetermined) fired, so this
research draft gate is cleared (the top marker is now `Reviewed`). Remaining human
review happens at the project merge gate, not here. These are conservative
defaults the Design phase inherits and may still refine; none is locked.

**1. The feature-test proof object's shape. Decided: a small, permanent smoke
fixture — a Postgres database `smoke` owned by role `smoke`, plus a Valkey ACL
user `smoke` scoped to `~smoke:*` — kept as a live, always-on health-check target,
not a create-and-teardown throwaway.** A permanent declarative fixture is the
conservative default under this repo's GitOps model: ArgoCD's `prune`/`selfHeal`
(live in `apps/storage.yaml`) would re-create any declaratively-authored resource
a test tears down, so a throwaway fights the reconciler, while a standing fixture
exercises the whole contract continuously (CNPG `Cluster` Healthy, a `Database`
and a `managed.roles` entry both reconcile, the sops-encrypted credential
round-trips through KSOPS). This matches Networking, which proved its contract
against a live target (the ArgoCD UI). The `smoke` slug is deliberately distinct
from every Feature 5-8 app slug (`keycloak`/`forgejo`/`flagsmith`) so the fixture
never collides with a future real consumer.

**2. How rigidly Valkey inherits the per-app naming convention. Decided: a
RECOMMENDED, per-consumer-opt-in extension of the pattern, NOT a mandated clause
of the hard shared contract.** The parent `plan.md` § Shared Contracts fixes the
mandatory contract as "storage class + per-app Postgres DB/role naming" and is
deliberately silent on Valkey; Feature 8 even binds to "storage class" only,
showing the contract is intentionally minimal. Not every Feature 5-8 consumer
needs Valkey at all, so mandating an ACL convention on all four over-constrains.
A recommendation is also the reversible direction: a later feature-step can tighten
`~<app>:*`-scoped ACL users to mandatory if a real collision appears, but a mandate
four consumers already bound to cannot be cheaply loosened. So: document the
`~<app>:*`-scoped ACL-user pattern as the recommended convention for any consumer
that uses Valkey, parallel to but lighter than the Postgres DB/role contract.

**3. File layout inside `storage/overlays/dev/` and object/namespace names.
Decided: a flat `storage/overlays/dev/` (no `storage/base/`), with per-component
subdirectories for the CNPG-operator and Valkey `helmCharts:` inflation plus
top-level authored-CR yaml (the `Cluster`, `Database`, Valkey config), mirroring
the realized `core/overlays/dev/` layout exactly; the CNPG operator installed
into its own conventional `cnpg-system` namespace and the shared `Cluster`/Valkey
operands into a `storage` namespace; the shared Cluster named `postgres`.** The
flat choice matches `networking-istio`'s cleared Open Decision A ("flat
`core/overlays/dev/`") and both earlier siblings' flat layouts — there is no
`storage/overlays/prod` content to share a base with yet, so a base is premature
(YAGNI) and trivially extractable later. `core/overlays/dev/` is the realized
precedent for the internal shape (per-component subdirs for Helm inflation at
intra-layer sync-waves, plus top-level config-CR files, each component in its own
conventional namespace). `cnpg-system` is CNPG's own documented operator
namespace. All of these are reversible naming choices Design may refine.

**4. Exact chart/operand version pins. Decided: defer the exact version strings
to build-time `research:public` (pin-at-build), carrying two guardrails this
research already surfaced so build does not re-discover them.** Deferring is the
research author's own recommendation and matches how `networking-istio`'s plan
deferred its upstream release tags; versions move, so finalizing a string now
would only go stale. Guardrails to record for build: pin PostgreSQL to ≥17.6 if
on the 17 line (avoiding the documented 17.0–17.5 `max_slot_wal_keep_size` upgrade
bug, `research/public.md` [14]) or to the current stable major CNPG defaults to;
pin the CNPG operator chart and the Valkey chart (`0.9.0` / appVersion `9.0.1` as
the research-date reference) to explicit versions rather than floating tags. Pins
are trivially bumped, so this is neither irreversible nor underdetermined.

**5. `secrets/dev/storage/` sub-layout. Decided: this feature-step creates ONLY
its own path (`secrets/dev/storage/postgres/secret.enc.yaml`, plus a Valkey path
only if the proof object needs an ACL-user secret); it does NOT pre-scaffold empty
directories for Features 5-8.** This mirrors the still-open granularity question
`gitops-argocd`'s own design left to "each layer's own feature-step" (cited by
this artifact) and the Networking precedent of defining a contract without
pre-building consumers. `.sops.yaml`'s existing `^secrets/dev/.*$` rule already
covers any later `secrets/dev/storage/<app>/…` path, so no per-path sops config is
needed and each Feature 5-8 consumer authors its own sub-path when it lands.

**6. The `.sops.yaml` placeholder-recipient gap — scope AND mechanism (correcting
this artifact's own claim). Decided: fixing it is IN-SCOPE build-time work for
THIS feature-step, not an escalation and not another feature-step's concern; AND
the mechanism the artifact names (`mise run rotate-keys dev`) is WRONG and must
not be run.** Scope: Storage is the first feature-step that commits an
application-level sops-encrypted Secret (its Postgres role credential), and a
placeholder is not a valid `age` recipient, so `sops -e` cannot encrypt until it
is replaced — blocking this feature-step's credential path and every Feature 5-8
secret after it. It is genuinely actionable right now with no human/Bitwarden-write
action: verified this session, `bw` is on PATH, the `.env`-provided `BW_SESSION`
still unlocks the vault (`bw unlock --check` → "Vault is unlocked!", the same
live session `gitops-argocd`'s bootstrap used), and the required key already
exists — so this is in-scope Build work, not an escalation. Mechanism correction
(the load-bearing finding): the artifact assumed `rotate-keys dev` would take a
clean first-run branch, but `agrippa-age-dev` **already exists** in Bitwarden
(verified: 1 item, a valid `AGE-SECRET-KEY` identity, public half
`age1e8wr0f85w0yfqgxc3pc6426ghlu5xt069znn5yuwrtwz30u23quqjcx6vc`), and
`bootstrap.sh` already seeded the in-cluster `sops-age` trust root from its
private half. `rotate-keys.sh`'s item-existence check therefore fires: it prompts
interactively for a typed `rotate` confirmation and, if confirmed, **rotates** —
archives the working key and mints a new one — which would desynchronise
`.sops.yaml` and any newly-encrypted secret from the trust root the running
cluster already holds (decryption would then fail until `bootstrap` is re-run).
The author conflated `rotate-keys`' Stage-4 "no committed secrets to re-encrypt"
sub-branch (true, `secrets/` is empty) with a whole-run first-time-key path
(false). The conservative, non-destructive, reversible Build step is: read the
existing item's public half (`bw get notes agrippa-age-dev | grep '^# public
key: '`) and write that recipient into `.sops.yaml`'s `secrets/dev/.*` rule via
`yq` (the same Stage-5 write `rotate-keys.sh` already performs), replacing the
placeholder without generating a new key. This keeps `.sops.yaml` consistent with
the trust root already in the cluster. Because the correct fix is a single
git-revertable local edit informed by a read — not a rotation of the shared trust
root — no escalation trigger fires.
