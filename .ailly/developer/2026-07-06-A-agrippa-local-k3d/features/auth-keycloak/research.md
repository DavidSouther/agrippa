# Research: Auth (Keycloak)

*Reviewed 2026-07-08*

> Feature-step research (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 5: Auth (Keycloak)** of
> that project's plan: Tier-2 in-cluster OIDC, Postgres-backed, parallel with
> Git hosting (Forgejo), Feature flags (Flagsmith), and Observability (LGTM) —
> three sibling feature-steps researching concurrently in their own session
> folders right now. Depends on Feature 4 (Storage), which has already landed
> and defined the storage-class + per-app DB/role naming shared contract this
> feature-step consumes; also consumes Feature 3 (Networking)'s already-landed
> Gateway/HTTPRoute/hostname/TLS contract. Long-loop: this draft is left open
> for a separately dispatched reviewer to clear; open items are surfaced below,
> not self-resolved.
>
> A separately dispatched long-loop reviewer cleared this research draft gate on
> 2026-07-08. The two items the author flagged for resolution (the Keycloak/CNPG
> namespace split, and whether `apps/platform.yaml` needs the CRD-heavy-operator
> sync seam) are decided to the conservative default in the *Resolved by the
> long-loop reviewer* block at the end of this document; the namespace claim was
> re-verified against the upstream CNPG and Keycloak sources and the `apps/*.yaml`
> claim against the live `k3d-agrippa-dev` cluster. No escalation trigger fired.
> The remaining "Open for the design phase" items are genuine design-altitude
> choices left for the design gate's own reviewer.

## Topic and Intent

Original request, verbatim (from the dispatching coordinator's task framing for
this feature-step):

> "Feature 5: **Auth (Keycloak)**. ... Research the standard way to run
> Keycloak on Kubernetes for local dev (official Keycloak Helm chart / Bitnami
> alternative — note Bitnami's 2025 paywall already ruled it out for Storage,
> check if that applies here too or if Keycloak ships its own official chart),
> how it's configured to use an external Postgres (vs. its bundled dev H2/
> embedded DB), realm/client bootstrap approach for a local dev realm
> (imperative first-run import vs. declarative Operator CRs — check if the
> Keycloak Operator is relevant here), and how the initial admin credential
> should be sealed (mirror Storage's `openssl rand` → stdin → sops
> discipline)."

and, on the landing mechanism:

> "Per the parent design, Keycloak lands in the **`platform`** layer
> (sync-wave 2)... Your research should recommend Keycloak get its own
> subdirectory (e.g. `platform/overlays/dev/keycloak/`) referenced as one more
> entry in the shared `platform/overlays/dev/kustomization.yaml`'s
> `resources:` list — the same shared-append-only-list pattern Networking's
> Gateway `dnsNames` and Storage's `managed.roles[]` already established. Do
> not assume you own the whole `platform/overlays/dev/kustomization.yaml`
> file... Flag this explicitly as a research finding."

Loosely stated goal, in the project's own framing (`plan.md` § Feature 5):
stand up Keycloak (Tier-2 OIDC), Postgres-backed, into the `platform` layer
(sync-wave 2), consuming both of Storage's and Networking's already-landed
shared contracts rather than inventing new storage or ingress infrastructure,
and settle enough of the concrete delivery mechanism (chart/operator, DB
wiring, realm bootstrap, credential sealing) that the design phase has a
determined path rather than an open question.

## Search/Expand

General-lens findings on the current (2026) state of running Keycloak on
Kubernetes/GitOps. Full citations and the falsification pass are in
`research/public.md`; this section synthesizes what bears on scope and design.

**Keycloak ships no official Helm chart — only an official Operator, installed
by raw manifests.** The keycloak.org docs document exactly two installation
paths (OLM, or plain `kubectl apply` of two CRDs plus one operator Deployment
manifest from `keycloak/keycloak-k8s-resources`); no chart is mentioned, and a
community request to add one is still open. This is a genuine three-way
choice, not a two-way one: the official Operator, a community Helm chart
(`codecentric/helm-charts`' `keycloakx`, actively maintained; the older
`helm/charts` "stable" `keycloak` chart is dead — archived since ~2020), or
Bitnami's chart.

**Bitnami's 2025 paywall is confirmed to apply to Keycloak too, not just
Storage's Postgres/Valkey.** The same catalog restructuring (most free
`bitnami/*` chart OCI packages moved behind paid "Bitnami Secure Images" after
2025-09-29, leaving a frozen, patch-less `bitnamilegacy` snapshot) affects
`bitnami/keycloak` identically, and Keycloak's own GitHub tracks the fallout
directly. This is not a new kind of finding — it is Storage's already-recorded
finding, confirmed to generalize rather than being Storage-specific.

**The deciding factor is declarative realm/client bootstrap, and it tips the
choice to the Operator on its own merits, independent of the Bitnami
question.** The Operator's `KeycloakRealmImport` CR (`k8s.keycloak.org/
v2beta1`) is a continuously-reconciled resource that accepts a full Keycloak
`RealmRepresentation` inline, with `spec.placeholders` letting secret values
resolve from a referenced Kubernetes Secret rather than sitting in plaintext.
This is a direct, declarative analogue of CNPG's `Database` CR, cert-manager's
`Certificate`, and metallb's `IPAddressPool` — every other in-cluster
declarative resource this project already reconciles via ArgoCD. The
community Helm-chart route has no equivalent: its own docs cover database and
admin-credential wiring but are silent on realm import, leaving only
Keycloak's container-level imperative `--import-realm` flag (a run-once,
first-boot-only file load, not a continuously-reconciled resource) — a
materially different, less GitOps-native mechanism than what this project's
every other component already uses.

**The Operator's `Keycloak` CR wires an external Postgres with the identical
"Secret-reference role/password" shape CNPG already produces on this
project's shared instance.** `spec.db.vendor: postgres`, `spec.db.host`, and
`spec.db.usernameSecret`/`passwordSecret` (referencing a plain Secret's
`username`/`password` keys) is the whole external-DB configuration surface;
omitting `spec.db` is what falls back to the bundled dev H2 database, so
setting it is what opts out. Because CNPG's `Cluster.spec.managed.roles[].
passwordSecret` already expects a `kubernetes.io/basic-auth` Secret with those
same two keys, **one sealed Secret can serve both consumers** — no new
sealing mechanism is needed, only a second reference to the same shape of
object Storage's `smoke-db` Secret already established.

**Two genuinely load-bearing namespace nuances surfaced, both worth flagging
explicitly since a naive CNPG-mirroring assumption would get them wrong.**
First, CNPG's `Database` CRD is a same-namespace-only `LocalObjectReference`
to its `Cluster` (an open CNPG feature request confirms this is a current
limitation, not a misreading) — so Keycloak's own `Database` CR must carry
`metadata.namespace: storage`, even though the YAML file authoring it can
still live inside this feature-step's own directory tree (this repo already
applies cross-namespace resources from one ArgoCD Application, so this is a
one-line namespace-field correctness point, not a composition blocker).
Second, the Keycloak Operator explicitly does **not** fully support watching
multiple/all namespaces, unlike CNPG's operator-in-`cnpg-system`/
operand-in-`storage` split — the Operator and its `Keycloak`/
`KeycloakRealmImport` CRs are expected to live together in one namespace.
Recommend one `keycloak` namespace holding the Operator and both of those CRs,
with only the `Database` CR carried in `storage` (forced by the first
nuance).

**Admin credential sealing has a first-class "bring your own sealed Secret"
field, matching the requested Storage-mirroring discipline exactly.**
`spec.bootstrapAdmin.user.secret: <name>` references a pre-existing Secret
with `username`+`password` keys, sealed by the identical `openssl rand |
kubectl create secret --dry-run=client -o yaml | sops --encrypt` pipeline
Storage's `smoke-db` Secret already established — no new mechanism, only its
second application. One documented caveat worth recording: if the `master`
realm already exists (i.e., after a cluster's first successful bootstrap),
`spec.bootstrapAdmin` is ignored — an expected bootstrap-only property, not a
gap.

**Exposure avoids the ArgoCD precedent's backend-TLS complication.**
`spec.ingress.enabled: false` disables the Operator's own Ingress, leaving
only the `<cr-name>-service` ClusterIP Service it always creates — the same
"operator creates the Service, an externally-authored HTTPRoute targets it"
shape Networking already uses for `argocd-server`. Unlike `argocd-server`
(HTTPS-only by default, forcing Networking's `DestinationRule`/backend-TLS
re-origination), Keycloak exposes `spec.http.httpEnabled: true`, a first-class
plain-HTTP toggle on the Service — so this feature-step's HTTPRoute can target
`<cr-name>-service:8080` directly with no second TLS-re-origination object,
since Istio ambient's mTLS already wraps the pod-to-pod hop regardless of the
app-layer protocol.

## Libraries & Skills

**Before doing any work in this feature, load these skills via the active
harness's skill-loading mechanism:** none new — carried forward unchanged from
the project's `research.md` and `design.md` § Libraries & Skills:
`developer:initialize` (this feature adds **no** new mise-managed CLI: the
Keycloak Operator is installed by raw in-cluster manifests ArgoCD reconciles
directly, not a local tool — it needs no `--enable-helm` repo-server wiring
either, since it is not Helm-sourced), `research:public` and
`research:codebase` (already exercised by this document and `research/
public.md`), and the `developer:ailly` project-shape references.

**No library-shipped agentic skill exists for the Keycloak Operator, the
`keycloak-k8s-resources` raw manifests, or CNPG's `Database`/`managed.roles`
mechanism this feature-step consumes (already established as no-skill by
Storage's own research).** `ARCHITECTURE.html` (§ S5 Platform — "Keycloak —
Identity: in-cluster OIDC · Tier-2 auth · Postgres-backed · SpiceDB
deferred"), `ROUTING.md` (Keycloak/OIDC Tier-2 gating references),
`DEVELOPMENT.md` (§ Secrets — the sops/age/KSOPS wiring this feature-step's
credentials must follow), and the two already-landed sibling designs
(`storage-postgres-valkey` for the DB/role naming contract and the sealing
discipline; `networking-istio` for the Gateway/HTTPRoute/hostname/TLS
consumption contract) remain the authoritative in-repo contracts this
feature-step builds to.

**Per-library docs review**, closest worked examples included, full citations
in `research/public.md`:

- **Keycloak Operator.** Getting-started: `keycloak.org/operator/
  installation` and `keycloak.org/operator/basic-deployment`. Closest worked
  examples: the canonical external-Postgres `Keycloak` CR (`research/
  public.md` [9]), the `KeycloakRealmImport` CR (`research/public.md` [12]),
  and the `spec.bootstrapAdmin`/`spec.ingress`/`spec.http` advanced-config
  fields (`research/public.md` [13][14][15]). No skill.
- **CloudNativePG (consumed, not owned, by this feature-step).** Already
  covered by Storage's own research; this pass adds only the same-namespace
  `Database`↔`Cluster` constraint (`research/public.md` [11]), a correction
  this feature-step's design needs and Storage's own research did not need to
  surface (Storage's own `Database` CR was always same-namespace with its
  Cluster by construction). No skill.
- **Bitnami / codecentric Keycloak charts (evaluated, not chosen).**
  `bitnami.com/stack/keycloak/helm`, `github.com/codecentric/helm-charts`
  (`research/public.md` [3][4][6][7][8]). No skill.

## Falsification/Refine

Specific-lens right-sizing.

**Size: one feature-step, already fixed by the project plan.** `plan.md`
names this Feature 5 with an explicit scope (Keycloak, Postgres-backed,
parallel with Features 6-8, consuming the storage-class + DB-naming shared
contract) and no independent shared-contract-defining job of its own (unlike
Storage and Networking, this feature-step is a pure *consumer* of two
already-settled contracts). Nothing in this research pass argues for resizing
it.

**Off-the-shelf: the categorical choice ("run Keycloak") was already decided
upstream** (`README.md`, `ARCHITECTURE.html`, the project `research.md`); this
feature-step's genuine job is the concrete delivery mechanism, and — exactly
as Storage found for its own charts — the naive "official Helm chart" or
"Bitnami" defaults do not survive contact: there is no official chart, and
Bitnami is paywalled. The Operator is the actual off-the-shelf answer, and it
is a *better* fit than a chart would have been (declarative realm import),
not merely the fallback after the other two options failed.

**Smallest version that still meets the intent.** The consumption contract
this feature-step owes: one Keycloak Operator installation (own namespace),
one `Keycloak` CR wired to the shared Postgres instance via one
`managed.roles[]` append plus one same-namespace-to-`storage` `Database` CR
plus one sealed DB-credential Secret, one sealed admin-credential Secret, one
minimal `KeycloakRealmImport` CR (a single dev realm — proof-object minimal,
mirroring Storage's `smoke` fixture rather than a fully-populated
production-realm import), and one HTTPRoute + one Gateway-certificate
`dnsNames` append. It does **not** need to pre-wire OIDC into any real
workload (Feature 9 Workloads consumes Auth later, and the parent design's
already-resolved item 3 keeps local `trips` at plain reachability, not
Keycloak-gated) and does not need SpiceDB (`ARCHITECTURE.html` already
records it as deferred).

**Claims falsified against reality.** Both tested this session:

1. "Keycloak ships its own official Helm chart" — falsified; only the
   Operator (raw manifests) is officially documented, and a community request
   for an Operator Helm chart is still open. See `research/public.md` §
   Falsification pass.
2. "Bitnami's paywall is Storage-specific; Keycloak's Bitnami chart might
   still be free" — falsified; the same 2025 restructuring and the same paid
   successor program apply to `bitnami/keycloak` identically.

## Scope

### In scope (this feature-step)

- **The Keycloak Operator**, installed via raw pinned-URL manifests
  (`resources:` entries — the same composition shape `core` already uses for
  metallb/cert-manager/Gateway API CRDs — two CRDs plus the operator
  Deployment/RBAC manifest from `keycloak/keycloak-k8s-resources`), in its own
  `keycloak` namespace (proposed name; a Design-phase artifact decision).
- **One `Keycloak` CR** wired to the shared `postgres` Cluster
  (`spec.db.vendor: postgres`, `spec.db.host: postgres-rw.storage.svc`,
  `usernameSecret`/`passwordSecret`), `spec.ingress.enabled: false`,
  `spec.http.httpEnabled: true`, `spec.hostname.hostname` set to this
  feature-step's dev host, `spec.bootstrapAdmin.user.secret` pointing at a
  sealed admin credential.
- **The one shared-list append to Storage's contract**: one
  `Cluster.spec.managed.roles[]` entry (`{name: keycloak, login: true,
  passwordSecret: {name: keycloak-db}}`) appended to `storage/overlays/dev/
  postgres-cluster.yaml`, plus one same-namespace-to-`storage` `Database` CR
  (`name: keycloak, owner: keycloak, cluster: {name: postgres}`) authored in
  this feature-step's own directory tree but carrying `metadata.namespace:
  storage`.
- **Two sealed Secrets**, following Storage's exact `openssl rand`→stdin→
  `sops --encrypt` discipline: the Postgres role/DB credential (`keycloak-db`,
  serving both the CNPG role reference and the `Keycloak` CR's `db.
  usernameSecret`/`passwordSecret`) and the admin bootstrap credential
  (`keycloak-admin` or similar, for `spec.bootstrapAdmin.user.secret`). Exact
  committed paths are a Design-phase artifact decision (Storage's
  `secrets/dev/storage/<store>/<slug>.enc.yaml` convention generalizes to a
  `secrets/dev/platform/...` prefix, but this is the first Secret committed
  under `platform/`, so the exact spelling is not fixed here).
- **One minimal `KeycloakRealmImport` CR** — a proof-object-minimal local dev
  realm (mirroring Storage's `smoke` fixture minimalism, not a
  production-realm-parity import), reconciled declaratively rather than
  imported imperatively.
- **The Networking consumption contract**: one `HTTPRoute` in the `keycloak`
  namespace, `parentRefs` to the shared `agrippa-gateway`, `backendRefs` to
  `<cr-name>-service:8080`; one dev-host append to `agrippa-gateway-tls`'s
  `dnsNames`.
- **One append to `platform/overlays/dev/kustomization.yaml`'s `resources:`
  list** for this feature-step's own subdirectory (proposed
  `platform/overlays/dev/keycloak/`) — see § Landing mechanism finding below
  for why this is flagged, not silently assumed safe.

### Out of scope (deferred, per already-cleared parent artifacts or genuinely
this feature-step's non-concern)

- **Wiring OIDC into any real workload.** Feature 9 (Workloads) consumes Auth
  later; the parent design's already-resolved item 3 keeps local `trips` at
  plain reachability, not Keycloak-gated. This feature-step proves Keycloak
  itself reaches Healthy and serves its login/admin UI through the Gateway —
  it does not gate any app.
- **Cloudflare Access (Tier-1)** — no local equivalent, per the parent design;
  out of scope everywhere in this project, not specific to this feature-step.
- **SpiceDB** — `ARCHITECTURE.html` already records it as deferred alongside
  Keycloak.
- **Any Valkey/session-store integration for Keycloak.** Storage's Valkey
  ACL-user convention is a recommended, per-consumer-opt-in extension, not a
  mandatory clause of the shared contract; Keycloak's own single-instance dev
  deployment uses its embedded session cache, and this research found no
  reason to introduce a Valkey dependency for this feature-step.
- **HA/clustering (`spec.instances` > 1)** — dev is a single-node k3d cluster,
  matching every other component's dev-sized posture.
- **`overlays/prod`** — a seam, not built, per the parent design.
- **Client SDK wiring in application code** (Rust `openidconnect`, TypeScript
  `keycloak-js`/`openid-client`, Python `python-keycloak`, all named in
  `ARCHITECTURE.html`) — consumer-side work for whichever later feature-step
  actually authenticates against this Keycloak instance, not this
  feature-step's own job.

## Resolved Decisions

Answered by this research:

- **(a) Chart/operator.** The official Keycloak Operator, installed by raw
  pinned-URL manifests from `keycloak/keycloak-k8s-resources` — **not** a
  Helm chart of any kind. No official chart exists; Bitnami's chart is
  paywalled by the same 2025 restructuring already ruled out for Storage; the
  actively-maintained community alternative (`codecentric/keycloakx`) lacks
  declarative realm import, the deciding factor.
- **(b) External Postgres.** `spec.db.vendor: postgres`, `spec.db.host:
  postgres-rw.storage.svc`, `usernameSecret`/`passwordSecret` referencing the
  same basic-auth Secret that also feeds CNPG's `managed.roles[].
  passwordSecret` — one sealed Secret, two consumers, zero new sealing
  mechanism. Setting `spec.db` is what opts out of the bundled dev H2
  database.
- **(c) Realm/client bootstrap.** Declarative `KeycloakRealmImport` CR, not
  imperative first-run import — the single deciding factor tipping the
  Operator-vs-Helm-chart choice, and consistent with every other declarative
  CR this project already reconciles via ArgoCD.
- **(d) Admin credential sealing.** `spec.bootstrapAdmin.user.secret`, sealed
  via the identical `openssl rand`→stdin→`sops --encrypt` discipline
  Storage's `smoke-db` Secret already established. No new mechanism.
- **(e) Namespace nuance — CNPG `Database` CR is same-namespace-only.**
  Recorded explicitly as a load-bearing correction: this feature-step's
  `Database` CR must carry `metadata.namespace: storage`, even though the
  file lives in this feature-step's own directory tree.
- **(f) Namespace nuance — the Keycloak Operator does not fully support
  multi-namespace watching.** Recorded explicitly against a naive
  CNPG-mirroring assumption: recommend one `keycloak` namespace holding the
  Operator, the `Keycloak` CR, and the `KeycloakRealmImport` CR together.
- **(g) Exposure.** Disable the Operator's own Ingress
  (`spec.ingress.enabled: false`), enable plain HTTP internally
  (`spec.http.httpEnabled: true`), route via one HTTPRoute to
  `<cr-name>-service:8080` — avoiding Networking's `argocd-server`
  `DestinationRule`/backend-TLS precedent entirely, since Keycloak (unlike
  `argocd-server`) offers a first-class plain-HTTP toggle.

### Landing mechanism finding (flagged explicitly, per the dispatch brief)

**`platform/overlays/dev/kustomization.yaml` is not an empty `resources: []`
placeholder — it already carries `resources: [argocd.yaml]`** (ArgoCD
self-management, landed by the GitOps feature-step). This feature-step
recommends landing as its own subdirectory (`platform/overlays/dev/keycloak/`,
mirroring `core`'s and `storage`'s per-component-subdirectory shape) appended
as one more line in that same shared `resources:` list — extending the
project's existing shared-append-only-list pattern (Gateway `dnsNames`, CNPG
`managed.roles[]`) to a **third** kind of shared object: a layer's own
`resources:` array. **This feature-step does not own the whole file.** Three
sibling feature-steps (Auth, Git hosting/Forgejo, Feature flags/Flagsmith) are
researching concurrently right now and will each want to append their own one
line to it independently — the coordinator, not any one feature-step, needs to
sequence the actual commits to avoid a three-way git conflict on one shared
list. This is not a novel category of risk (it is the same shape as four
features appending to Storage's `managed.roles[]`), but it is the first time
the shared-mutable-list-under-parallel-contention is a raw kustomize
`resources:` array rather than a field inside one already-existing CR, which
makes accidental last-writer-wins overwrites (rather than clean git merge
conflicts on adjacent lines) a real risk if two feature-steps' builds run
without checking each other's latest commit first.

**A second, related shared-file risk surfaced live and is recorded here for
the same reason: `apps/platform.yaml` itself currently lacks the
`syncOptions: [ServerSideApply=true, SkipDryRunOnMissingResource=true]` that
both `apps/core.yaml` and `apps/storage.yaml` carry for their own CRD-heavy
operators.** Keycloak ships two CRDs (`Keycloak`, `KeycloakRealmImport`) and a
controller that defaults status/spec fields the way CNPG's webhook does for
its `Cluster` — the exact symptom that made `apps/core.yaml` and
`apps/storage.yaml` need this syncOptions fix. This feature-step will likely
need the identical fix on `apps/platform.yaml`, and — like the
`resources:`-list risk above — Forgejo and Flagsmith may independently reach
the same conclusion for their own operators/controllers. Recommend the
coordinator treat this the same way Networking's design-intent reviewer
treated a parallel single-shared-file touch (Q4 in `networking-istio/
design.md`): sanction it as an additive, idempotent fix any one of the three
parallel feature-steps may land first, with the other two simply finding it
already done rather than each re-deriving and re-applying it.

### Open for the design phase (not resolved here)

1. **Exact dev hostname spelling.** Research recommends `auth.127.0.0.1.nip.io`
   — following ArgoCD's precedent (service-name-direct, since no
   `auth.davidsouther.com`/`sso.davidsouther.com` prod hostname is recorded
   anywhere in `ARCHITECTURE.html`/`ROUTING.md`/`DEVELOPMENT.md`/
   `tests/agrippa.bats`) rather than Grafana's `dashboard.davidsouther.com`
   full-mirror precedent (which exists only because that prod hostname is
   already recorded in `tests/agrippa.bats`'s `DASHBOARD_HOST` default).
   Design should confirm or pick a different spelling.
2. **Exact namespace, CR, and Secret names** (`keycloak` namespace,
   `keycloak-db`/`keycloak-admin` Secret names, the `Keycloak`/
   `KeycloakRealmImport` CR names, the dev realm's id). Proposed throughout
   this document; not locked.
3. **The exact committed-secret path convention under `platform/`.** Storage's
   `secrets/dev/storage/<store>/<slug>.enc.yaml` pattern generalizes cleanly
   to something like `secrets/dev/platform/keycloak/<secret>.enc.yaml`, but
   this is the first Secret committed under a `platform/` prefix, so Design
   should settle the exact spelling the way Storage's own design settled its
   analogous open item.
4. **Exact Operator/Keycloak version pin.** Current stable is the 26.6.x line
   (26.6.3 released 2026-06-04); deferred to build-time `research:public`,
   consistent with how Storage and Networking both deferred their own
   upstream version strings.
5. **The `platform/overlays/dev/kustomization.yaml` append sequencing among
   three parallel sibling feature-steps**, and **whether `apps/platform.yaml`
   needs the `ServerSideApply`/`SkipDryRunOnMissingResource` syncOptions
   touch** — both flagged above as coordinator-level sequencing concerns, not
   resolved by this research. **[Reviewer, 2026-07-08 — the `apps/platform.yaml`
   half is now decided (yes, and the full seam is BOTH the syncOptions block AND
   the `compare-options: ServerSideDiff=true` annotation, not the syncOptions
   half alone); see entry 2 of the *Resolved by the long-loop reviewer* block at
   the end. The `kustomization.yaml` `resources:`-append ordering remains a pure
   coordinator sequencing concern.]**
6. **Exact `spec.hostname.strict` / `spec.proxy.headers` values** for running
   correctly behind the shared Gateway in local dev — a build-time
   live-verification item, mirroring how Networking deferred its own
   CNI-path values to build time.

## Sources

Full IEEE-style citations (17 numbered sources plus the falsification pass)
are in `research/public.md`. Summary, deduplicated:

- [1]-[2] The Keycloak Operator's installation docs and the still-open
  community request for an Operator Helm chart (confirming no official chart
  exists).
- [3]-[4] Community Helm chart options: the archived `helm/charts` "stable"
  chart (dead) and the actively-maintained `codecentric/keycloakx` chart
  (external Postgres and admin-credential support, no realm-import support).
- [5]-[8] Bitnami's 2025 catalog restructuring, confirmed to apply to
  `bitnami/keycloak` identically to Storage's already-recorded
  Postgres/Valkey finding.
- [9]-[10] The canonical `Keycloak` CR external-Postgres shape and Keycloak's
  general database-configuration docs.
- [11] CloudNativePG's `Database` CRD same-namespace-only `LocalObjectReference`
  limitation (an open feature request) — the load-bearing namespace
  correction this feature-step's design needs.
- [12] The `KeycloakRealmImport` CR and its `spec.placeholders` secret-value
  substitution mechanism.
- [13]-[15] `spec.bootstrapAdmin`, `spec.ingress`, and `spec.http.httpEnabled`
  advanced-configuration fields.
- [16] Keycloak 26.x's admin env-var rename (`KEYCLOAK_ADMIN*` →
  `KC_BOOTSTRAP_ADMIN_*`), noted as irrelevant to the chosen Operator path but
  recorded against stale-tutorial drift.
- [17] Keycloak 26.6.3 release notes (current stable at research time).

In-repo Prior Art (authoritative, not external): `ARCHITECTURE.html` (§ S5
Platform — Keycloak identity/OIDC/SpiceDB-deferred note), `ROUTING.md`
(Keycloak/OIDC Tier-2 references), project `design.md` § Specification (Auth
bullet) and § Shared contracts, project `plan.md` § Feature 5 and § Shared
Contracts, `DEVELOPMENT.md` § Secrets, `features/storage-postgres-valkey/
design.md` and `research.md` (the `managed.roles[]`/`Database` consumption
contract and the sops sealing discipline this feature-step reuses
unchanged), `features/networking-istio/design.md` (the Gateway/HTTPRoute/
hostname/TLS consumption contract, and the `argocd-server` backend-TLS
precedent this feature-step's plain-HTTP choice deliberately avoids
repeating). Live cluster state (verified this session, 2026-07-08):
`kubectl -n argocd get application platform core storage` → all
`Synced`/`Healthy`; `cat platform/overlays/dev/kustomization.yaml` →
`resources: [argocd.yaml]`, not an empty placeholder; `cat apps/platform.yaml`
→ no `ServerSideApply`/`SkipDryRunOnMissingResource` syncOptions (unlike
`apps/core.yaml`/`apps/storage.yaml`); `storage/overlays/dev/
postgres-cluster.yaml` and the `secrets/dev/storage/` tree inspected directly
for the exact live shape of the contract this feature-step binds to.

## Resolved by the long-loop reviewer (2026-07-08)

A separately dispatched long-loop reviewer read this feature-step's research
artifact (`research.md` + `research/public.md`) cold, re-verified its live claims
against the working tree and the running `k3d-agrippa-dev` cluster (read-only),
and independently re-researched the two items the author flagged for resolution
against this project's own conventions, the cleared sibling feature-steps
(`storage-postgres-valkey`, `networking-istio`), and the upstream sources. Both
were decided to the conservative default. No escalation trigger (irreversible,
out of recorded scope, or underdetermined) fired, so this research draft gate is
cleared (the top marker is now `Reviewed`). These stay Design-phase commitments
the design may still refine; what is settled is that the research is complete and
its two flagged items are decided. The remaining "Open for the design phase"
items 1-4 and 6 are genuine design-altitude choices, correctly left for the design
gate's own reviewer, not research-gate blockers.

**1. The Keycloak/CNPG namespace split (verifies Resolved Decisions (e)+(f) and
the two flagged namespace nuances). Decided: follow the split exactly as the
research states — the CNPG `Database` CR carries `metadata.namespace: storage`
(co-located with the shared `postgres` Cluster), while the Keycloak Operator, the
`Keycloak` CR, and the `KeycloakRealmImport` CR co-locate together in one
`keycloak` namespace.** The split is not a stylistic preference; it is forced by
two independent upstream constraints pulling in opposite directions, with no
single-namespace arrangement satisfying both, so the conservative default is to
adopt it rather than fight it. *CNPG side (re-verified independently, not just via
the author's citation):* CNPG's `Database.spec.cluster` is a `LocalObjectReference`
— a name-only reference, which by Kubernetes API convention resolves in the
object's own namespace and carries no `namespace` field to cross. CNPG issue #6043
confirms the live limitation in the maintainers' own framing (Database resources
and their referenced Clusters must exist in the same namespace), and
cross-namespace support is an open, unshipped feature request, not current
behavior. So a `Database` CR authored inside this feature-step's own
`platform/overlays/dev/keycloak/` tree MUST declare `metadata.namespace: storage`;
this repo already applies cross-namespace objects from one Application (`core`'s
`Certificate`/`Gateway` land in `istio-ingress`), so it is a one-field correctness
point, not a composition blocker. *Keycloak side (two independent constraints,
either alone sufficient):* the Operator is "not fully supported to watch multiple
or all namespaces" (keycloak.org operator install docs), AND
`KeycloakRealmImport.spec.keycloakCRName` binds to a `Keycloak` CR in the SAME
namespace (realm-import docs) — so the Operator/`Keycloak`/`KeycloakRealmImport`
trio cannot be split across namespaces even if one wanted to. This is the opposite
shape from CNPG's operator-in-`cnpg-system`/operand-in-`storage` split, and the
research is right to flag it against a naive CNPG-mirroring habit. Reversible
(namespace is a per-object field), in recorded scope (the research already scopes
both a `keycloak` namespace and the `storage` namespace), and fully determinate.
No escalation.

**2. Whether THIS feature-step's design/plan should add the CRD-heavy-operator
sync seam to `apps/platform.yaml`. Decided: yes — recorded as a coordinator-level
heads-up that ANY ONE of the three platform-layer siblings (Auth / Forgejo /
Flagsmith) lands it first, the other two simply finding it already done; it is NOT
a hard requirement only this feature owns, and NOT an escalation.** Live-verified
this session: `apps/platform.yaml` carries no sync seam at all (empty
`.spec.syncPolicy.syncOptions`, no `compare-options` annotation), while both
`apps/core.yaml` and `apps/storage.yaml` carry it for their own CRD-heavy
operators (confirmed both in the working tree and on the live cluster —
`kubectl -n argocd get application platform` shows empty syncOptions, `core` and
`storage` show `["ServerSideApply=true","SkipDryRunOnMissingResource=true"]`).
Keycloak ships two CRDs (`Keycloak`, `KeycloakRealmImport`) plus a controller that
defaults spec/status fields the way CNPG's `Cluster` webhook does — the exact
symptom that made core and storage need the seam — so platform will need it too,
independent of which sibling builds first. This clears all three escalation
triggers: additive and reversible (a one-block change ArgoCD self-heal converges),
in recorded scope (platform is THIS feature-step's own landing layer, this file is
flagged in this research, and `networking-istio` design Q4 already set the
precedent of sanctioning exactly this class of additive touch to a shared file a
feature-step's own layer owns), and fully determinate from the core/storage
precedent. *Load-bearing correction to the research's framing:* the research names
only the `syncOptions: [ServerSideApply=true, SkipDryRunOnMissingResource=true]`
half. The FULL seam core and storage actually carry is BOTH that syncOptions block
AND the `argocd.argoproj.io/compare-options: ServerSideDiff=true` annotation. Per
those two files' own live comments, `ServerSideApply=true` ALONE silently
auto-enables ArgoCD's "Structured Merge Diff" strategy, which mispredicts
CRD-webhook-defaulted fields and leaves the Application permanently OutOfSync
(argoproj/argo-cd#22151); the actual OutOfSync fix was
`compare-options: ServerSideDiff=true`, forcing a real API-server dry-run diff. So
applying only the syncOptions half to `apps/platform.yaml` would reproduce the
exact symptom for Keycloak's webhook-defaulted CRs — Design/plan should copy the
full pattern (both parts) from `apps/core.yaml`/`apps/storage.yaml` verbatim.
*Scope note for the coordinator:* only the three PLATFORM-layer siblings contend on
`apps/platform.yaml`; Observability (LGTM) lands in its own `observability` layer
Application (live, Synced/Healthy) and does not touch this file. The separate
`platform/overlays/dev/kustomization.yaml` `resources:`-append ordering among those
same three remains a pure coordinator sequencing concern (last-writer-wins on one
shared list), unchanged by this decision.
