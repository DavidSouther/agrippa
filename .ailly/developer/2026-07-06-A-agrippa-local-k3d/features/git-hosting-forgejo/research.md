# Research: Git hosting (Forgejo)

*Reviewed 2026-07-08*

> Feature-step research (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 6: Git hosting
> (Forgejo)** of that project's plan: Forgejo plus forgejo-runner,
> Postgres-backed, landing in the `platform` layer alongside two parallel
> siblings (Feature 5 Auth/Keycloak, Feature 7 Feature flags/Flagsmith) that
> share the storage-class + per-app DB/role naming contract Storage (Feature
> 4) already defined and has already landed live. Long-loop: the draft gate
> below is cleared by a separately dispatched research-and-decide reviewer, so
> the open items below are surfaced and, where research and the repo
> conventions determine a clear answer, resolved to the conservative default —
> not left as unresolved questions for a human to pick up mid-session.
>
> A separately dispatched long-loop reviewer cleared this research draft gate
> on 2026-07-08. The six still-open items are resolved in the *Resolved by the
> long-loop reviewer* block under what was the "Open for the design phase"
> slot. The one flagged, non-mechanical decision (forgejo-runner's privileged-
> container posture) was re-researched against the current upstream state and
> decided to the conservative default: **defer forgejo-runner/Actions for this
> local build and land the Forgejo server itself now.** No escalation trigger
> (irreversible, out of recorded scope, or underdetermined) fired.

## Topic and Intent

Original request, verbatim (from the dispatching coordinator's task framing
for this feature-step):

> "Feature 6: **Git hosting (Forgejo)**. ... Read first: Parent project
> design ... the 'Git hosting (Forgejo)' bullet under Specification
> (forgejo-runner, GitHub push-mirror optional locally). Parent project plan
> ... 'Feature 6: Git hosting (Forgejo)' section, and 'Shared Contracts' at
> the top. ... Per the parent design, Forgejo lands in the **`platform`**
> layer (sync-wave 2), alongside Feature 5 (Keycloak) and Feature 7
> (Flagsmith) — all three 'platform services.' ... **Recommend Forgejo get
> its own subdirectory** ... referenced as one more entry in the shared
> `platform/overlays/dev/kustomization.yaml`'s `resources:` list ... **Do
> not assume you own the whole `platform/overlays/dev/kustomization.yaml`
> file** — three features append to it independently ... Research the
> standard way to run Forgejo on Kubernetes for local dev (official Forgejo
> Helm chart), how it's configured against an external Postgres (vs. its
> bundled SQLite dev mode), how `forgejo-runner` is deployed and registered
> against the Forgejo instance, whether the GitHub push-mirror feature needs
> any local-dev-specific handling ..., and how the initial admin credential
> should be sealed (mirror Storage's discipline)."

Loosely stated goal, in the project's own framing (`plan.md` § Feature 6):
stand up Forgejo (Git hosting) and forgejo-runner (CI execution) as
Postgres-backed Helm-delivered workloads in the `platform` layer's
`overlays/dev`, consuming the storage-class + per-app DB/role naming
contract Storage already defined and consuming the Gateway/HTTPRoute/
hostname/TLS contract Networking already defined, without assuming
ownership of the shared `platform/overlays/dev/kustomization.yaml` file two
parallel sibling feature-steps also append to.

## Search/Expand

General-lens findings on the current (2026) state of running Forgejo and
forgejo-runner on Kubernetes via Helm/GitOps. Full citations and the
per-source detail are in `research/public.md`; this section synthesizes
what bears on scope and design.

**Forgejo publishes its own official Helm chart, and current versions of it
are a clean fit for this project's "external datastore only, sealed
credentials only" posture — not a fit that needs fighting a bundled
default.** `code.forgejo.org/forgejo-helm/forgejo-helm`, OCI-distributed
(`helm install forgejo oci://code.forgejo.org/forgejo-helm/forgejo`), is the
Forgejo-maintained fork of the Gitea chart lineage. As of chart v14 it
dropped its bundled PostgreSQL and Redis/Valkey subcharts entirely — there
is no "flip `postgresql.enabled` to false" step, external is simply the
only supported database shape. `gitea.config.database` takes plain
Forgejo/Gitea `app.ini` `[database]` keys (`DB_TYPE: postgres`, `HOST`,
`NAME`, `USER`, `PASSWD`, optional `SCHEMA`), and the password (and any
other secret value) can be injected from a pre-created Kubernetes Secret via
`gitea.additionalConfigFromEnvs` (one `app.ini` key per `secretKeyRef`) or
`gitea.additionalConfigSources` (a whole Secret's keys mounted as config) —
either form references a Secret **by name**, exactly this project's
KSOPS-sealed-Secret convention, never a chart-generated or `--set` literal.
Cache/queue/session (`gitea.config.cache/queue/session`) follow the
identical shape for an external Redis-compatible store, so the shared
`valkey.storage.svc:6379` instance is a drop-in target with no bundled-chart
conflict either.

**The initial admin credential has a first-class `existingSecret` value —
this maps directly onto the Storage credential-sealing discipline already
proven live in this repo.** `gitea.admin.existingSecret` points at a
pre-created Secret carrying `username`/`password` keys;
`gitea.admin.passwordMode` (`keepUpdated` default, or
`initialOnlyNoReset`/`initialOnlyRequireReset`) controls whether the chart
re-asserts that password on every pod restart. This is the same "seal in
memory, commit only ciphertext, reference by Secret name" shape
`storage-postgres-valkey`'s `smoke-db` credential already established and
proved end-to-end (KSOPS decrypt → real Secret → an authenticated
connection), down to the reusable shell recipe
(`openssl rand ... | kubectl create secret ... --from-file=password=
/dev/stdin --dry-run=client -o yaml | sops --encrypt ... > secrets/dev/...`)
this feature-step's admin credential can reuse verbatim.

**forgejo-runner is the one component here with a genuinely different
operational shape, confirmed by research, not merely suspected — and it
raises a real open question this research does not resolve.** Forgejo's
`config.yaml` supports Docker, Podman, LXC, and Host execution backends for
running a job's own containers; there is **no documented, stable
Kubernetes-native executor**. Every worked deployment example (including
Forgejo's own reference Docker Compose) uses the Docker executor backed by
either a host Docker socket mount or a sibling `docker:dind`
**privileged** sidecar container in the runner's own Pod. A non-privileged,
pod-per-job Kubernetes executor exists only as an author-acknowledged,
in-progress proof of concept ("a big pile of hacks," missing service-
container support, caching, and full workflow-syntax compatibility) — not
production-ready. This project has run **zero** privileged containers so
far (CNPG, Valkey, Istio, cert-manager, and metallb are all unprivileged);
forgejo-runner's only well-trodden Kubernetes shape needs one. A k3d node's
containerd-only runtime has no host Docker socket to mount, so "host
socket" is not an option here even if desired — only the DIND-sidecar shape
is genuinely available among the well-trodden options. Two narrower
third-party options exist (a DIND-based community Helm chart, `wrenix/
forgejo-runner`; and a build-only, non-privileged `buildx`+
`driver=kubernetes` manifest set with no general Actions-executor
capability) but neither is Forgejo-official.

**forgejo-runner registration has a genuine GitOps-compatible offline path,
purpose-built by Forgejo for Infrastructure-as-Code — this directly answers
the task's "avoid a manual interactive token step" question.** Besides the
interactive UI-token flow, Forgejo ships `forgejo forgejo-cli actions
register --name <name> --scope <owner[/repo]> --secret <40-hex-value>`
(also accepting `--secret-file`/stdin), which registers the runner directly
against Forgejo's own database/config — not by calling a running server's
HTTP API — so it can plausibly run as a one-shot Job using the same Forgejo
image rather than an interactive `kubectl exec`. The matching runner-side
command, `forgejo-runner create-runner-file --secret <value>` (or
`--secret-file`), builds the `.runner` config file the runner daemon reads
at startup. Both sides consume the **same pre-generated 40-hex-character
value** (first 16 chars an identifier, the rest secret) — a value this
project can generate the same way it already generates the Storage `smoke`
credentials (`openssl rand -hex 20`, sealed via `sops`, never touching
disk unencrypted) and reference by Secret name from two independent
manifests (a registration Job and the runner's own container), the same
"one sealed value, two independent consumers" shape Storage's `smoke-db`
Secret already demonstrates (referenced by both the CNPG `managed.roles[]`
entry and the feature test). **Not resolved by this research:** whether
`forgejo-cli actions register` is idempotent against an already-registered
runner name (undocumented) — a build-time verification item, in the same
family as the "design fixes the shape, build confirms the exact spelling"
items every completed sibling feature-step has carried forward.

**GitHub push-mirroring needs no cluster-level component at all — the
parent design's "optional locally" framing is confirmed, not merely
plausible.** It is a plain per-repository, UI/API-driven Forgejo feature: a
GitHub Personal Access Token (HTTP Basic auth) or a Forgejo-generated SSH
keypair added as a GitHub deploy key. No controller, no cluster Secret, no
chart value. The only real local-dev consequence is that it needs outbound
internet access from the Forgejo pod to `github.com` — no different in kind
from any other outbound dependency this project already accepts (pulling
upstream Helm charts). This can be recorded as fully out of this
feature-step's build scope: a documented, per-repository, opt-in operator
action, needing nothing from this design.

**In-repo: the `platform` layer is live, Synced/Healthy, and genuinely still
a skeleton — the task's landing-mechanism framing is exactly right, and one
more concrete fact sharpens it.** `platform/overlays/dev/kustomization.yaml`
carries a comment stating outright that Keycloak/Forgejo/Flagsmith "land as
later feature-steps' added resources here"; its only live content today is
the self-managing ArgoCD Application. Confirmed live:
`kubectl -n argocd get application platform` → `Synced Healthy`; no
Forgejo/Keycloak/Flagsmith namespace exists yet. This feature-step should
add one `resources:` entry (a `forgejo/` subdirectory) to that shared file,
not redesign the file — the identical "many independent consumers append to
one shared, mutable list" shape already established twice over (Networking's
Gateway certificate `dnsNames`, Storage's `Cluster.spec.managed.roles[]`).
Sequencing the actual three-way append (this feature-step, Auth, Feature
flags) across parallel builds is the coordinator's job, flagged explicitly
per the task framing, not something this design should assume it owns
alone.

**In-repo: the Postgres and Valkey shared contract is live, not merely
designed, and this feature-step's own database is literally "append one
more entry" to files that already exist and already work.**
`storage/overlays/dev/postgres-cluster.yaml` already carries the shared
`Cluster` **`postgres`** (namespace `storage`, `local-path`,
`ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie`) with one live
`managed.roles[]` entry (`smoke`); the shared Valkey release
(`storage/overlays/dev/valkey/kustomization.yaml`, chart `0.10.0`,
standalone, `auth.aclUsers` a plain per-user permissions map) is live too.
Forgejo's own role/database/ACL-user each follow the exact same shape the
`smoke` fixture already proves end-to-end (a second `managed.roles[]`
entry, a `Database` CR with `owner`/`cluster.name`/`name`, a
KSOPS-sealed `kubernetes.io/basic-auth` Secret) — this is a proven,
low-risk pattern to consume, not a fresh design.

**In-repo: production names Forgejo's hostname explicitly, which settles
the dev hostname per the parent design's already-fixed mirroring rule.**
`ARCHITECTURE.html`'s Platform view states "code hosting · `git.
davidsouther.com`" verbatim. The parent design's resolved decision 6 fixes
the dev-hostname scheme as `<prod-host>.127.0.0.1.nip.io`, so Forgejo's dev
hostname is **`git.davidsouther.com.127.0.0.1.nip.io`** — the full mirrored
production host, not an abbreviated `git.127.0.0.1.nip.io` (which the task
framing offered only as an "e.g.," and which this research recommends
against for consistency with the fixed scheme every other host in this
project follows, e.g. `argocd.127.0.0.1.nip.io`, `dashboard.davidsouther.
com.127.0.0.1.nip.io`).

## Libraries & Skills

**Before doing any work in this feature, load these skills via the active
harness's skill-loading mechanism:** none new — carried forward unchanged
from the project's `research.md` and `design.md` § Libraries & Skills:
`developer:initialize` (this feature adds **no** new mise-managed CLI: the
Forgejo chart is an in-cluster resource ArgoCD reconciles via Helm, not a
local tool; forgejo-runner's registration secret is generated with
`openssl`, already available), `research:public` and `research:codebase`
(already exercised by this document and `research/public.md`/`research/
codebase.md`), and the `developer:ailly` project-shape references.

**No library-shipped agentic skill exists for Forgejo, forgejo-runner,
CloudNativePG, the official Valkey chart, sops, age, or KSOPS.** This
reconfirms, at the per-component level, the project's already-recorded
top-level finding (`research.md` § Libraries & Skills: "A deliberate check
of the relevant tools ... surfaced no `SKILL.md`, MCP server, or `skills/`
directory shipped by any of them"). `ARCHITECTURE.html` (§ Platform layer /
Git Hosting view), `DEVELOPMENT.md` (§ Secrets), and the two most-recently
completed sibling designs (`storage-postgres-valkey` for the DB/role naming
contract and the credential-sealing discipline; `networking-istio` for the
Gateway/HTTPRoute/hostname/TLS contract and the shared-append-only-list
precedent) remain the authoritative in-repo contracts this feature-step
builds to.

**Per-library docs review**, closest worked examples included, full
citations in `research/public.md`:

- **Forgejo (the server).** Getting-started: `forgejo.org/docs/latest/` and
  the chart's own README at `code.forgejo.org/forgejo-helm/forgejo-helm`.
  Closest worked examples: the `existingSecret`-based admin bootstrap block
  and the `additionalConfigFromEnvs`/`additionalConfigSources`
  external-database-credential indirection, both quoted in full in
  `research/public.md`. No skill.
- **forgejo-runner (Actions CI).** Getting-started: `forgejo.org/docs/
  latest/admin/actions/registration/` and `.../runner-installation/`.
  Closest worked examples: the offline `forgejo-cli actions register
  --secret`/`generate-secret` pair (`research/public.md` [13][14]), and two
  independent third-party Kubernetes deployment examples — a DIND-sidecar
  chart (`wrenix/forgejo-runner` [11]) and a non-privileged buildx-based
  manifest set (`kubernetes.build/forgejoRunner` [12]). No skill (and, per
  the research above, no first-class Kubernetes-native executor exists
  upstream at all yet).
- **sops / age / KSOPS (application-secret half).** Already covered by
  `gitops-argocd`'s and `storage-postgres-valkey`'s own research; this pass
  adds nothing new beyond confirming the exact live mechanism
  (`research/codebase.md`) and that this feature-step's credentials should
  reuse the identical shell recipe. No skill.

## Falsification/Refine

Specific-lens right-sizing.

**Size: one feature-step, already fixed by the project plan.** `plan.md`
names this Feature 6 with an explicit scope (Forgejo plus forgejo-runner,
Postgres-backed) and an explicit non-goal (GitHub push-mirror is optional
locally). Nothing in this research pass argues for resizing it — if
anything, the research narrows the genuinely open surface to one real
question (forgejo-runner's privileged-container posture).

**Off-the-shelf: the categorical choice ("run Forgejo") was already decided
upstream** (`README.md`, `ARCHITECTURE.html`, the project `research.md`);
this feature-step's genuine job, like Storage's, is the concrete delivery
mechanism. Unlike Storage (where the "obvious" Bitnami default had to be
falsified), Forgejo's own official chart survives contact cleanly — no
falsified assumption here, a rarer and simpler shape than Storage's own
research pass.

**Smallest version that still meets the intent.** The minimum that proves
"Git hosting is live and usable" is: the Forgejo server reachable through
the shared Gateway at its dev hostname, backed by the shared Postgres
instance with a properly isolated database/role, with a sealed initial
admin credential — a server-only proof, matching how Networking proved its
contract via the pre-existing ArgoCD UI and Storage via a synthetic `smoke`
fixture. **forgejo-runner (CI execution) is a separable, heavier-weight
addition** whose only well-trodden Kubernetes shape needs a privileged
container this project has not needed anywhere else — a genuine "is this in
the smallest honest slice" question for the design phase, not decided here.
Nothing in the parent Closing Bell names Forgejo Actions/CI as a critical
task (the Closing Bell's critical tasks are the platform coming up, the two
site workloads rendering, Grafana, and the gestalt bats suite — Git hosting
itself, like Auth and Feature flags, is named only as "rounds out the
platform-services tier," per `plan.md` § Feature 6's own "Advances Closing
Bell" line). This argues for **at minimum shipping the Forgejo server as the
proof**, with forgejo-runner either (a) accepted with its
privileged-sidecar cost, (b) deferred as a documented follow-up (server
lands, Actions/CI is a later increment), or (c) run in a reduced form (e.g.
`host` execution backend inside the runner's own already-isolated Pod,
trading generality for no elevated privilege) — three real options this
research surfaces for Design to weigh, not a foregone one.

**Claims falsified against reality.** One assumption in the task's own
framing did not survive contact, in a minor, self-correcting way: the
suggested example dev hostname `git.127.0.0.1.nip.io` is not what the
already-fixed project convention produces once `ARCHITECTURE.html`'s actual
production hostname (`git.davidsouther.com`) is looked up — the mirrored dev
hostname is the longer `git.davidsouther.com.127.0.0.1.nip.io`. This is a
small, easily-applied correction (a note, not a scope change), listed under
Resolved Decisions below.

## Scope

### In scope (this feature-step)

- **The official Forgejo Helm chart** (`code.forgejo.org/forgejo-helm/
  forgejo-helm`), inflated via `helmCharts:` inside a new `platform/
  overlays/dev/forgejo/kustomization.yaml` — the same per-component-
  subdirectory composition shape `core` and `storage` already use for their
  own Helm-sourced components, appended as one entry to the shared
  `platform/overlays/dev/kustomization.yaml` `resources:` list (not owned
  outright — two sibling feature-steps append their own entries
  independently).
- **A second `managed.roles[]` entry plus a `Database` CR** on the already-
  live shared Postgres `Cluster` `postgres`, following the `smoke` fixture's
  exact proven shape, and (recommended, not mandated, per Storage's own
  design) a Valkey ACL user if Forgejo's cache/queue benefits from it.
- **A sealed initial-admin credential** (`gitea.admin.existingSecret`),
  generated and sops-encrypted using the identical shell recipe
  `storage-postgres-valkey`'s `smoke-db` credential already established.
- **A sealed forgejo-runner registration secret** (the 40-hex-char offline-
  registration value), consumed by both a registration mechanism against
  the live Forgejo instance and the runner's own `.runner` config — exact
  registration mechanism (a one-shot authored `Job`, an operator-run `mise`
  task exec'd against the live pod, or another shape) is a Design-phase
  artifact decision this research surfaces options for but does not settle.
- **forgejo-runner itself**, deployed in whatever shape Design settles
  (full DIND-sidecar Actions executor now, vs. a documented deferral, vs. a
  reduced `host`-backend form) — this research's job is to make that
  decision informed, not to make it.
- **One `HTTPRoute`** at `git.davidsouther.com.127.0.0.1.nip.io`, attached
  to the shared `agrippa-gateway`, and one append to the shared Gateway
  certificate's `dnsNames` — consuming Networking's already-defined
  contract exactly, no new Gateway/TLS infrastructure.
- **A feature test**, `tests/git-hosting.bats` (dropping the `-forgejo`
  tool qualifier per every sibling suite's naming convention), targeting
  the long-lived `k3d-agrippa-dev` cluster, asserting the `platform`
  Application stays `Synced Healthy`, plus the Postgres/credential/
  reachability proof mirroring `storage.bats`'s and `networking.bats`'s own
  shape.

### Out of scope (deferred, per already-cleared parent artifacts or
genuinely this feature-step's non-concern)

- **GitHub push-mirroring** — confirmed by this research to need zero
  cluster-level wiring; documented as an opt-in, per-repository operator
  action requiring outbound network and a GitHub PAT or deploy key,
  matching the parent design's "optional locally" framing exactly. No
  chart value, Secret, or manifest for it in this feature-step's build.
- **Pre-provisioning Keycloak's or Flagsmith's databases** — each of those
  parallel feature-steps owns its own `managed.roles[]` append and
  `Database` CR, exactly as this feature-step owns only its own.
- **The `platform/overlays/dev/kustomization.yaml` file as a whole** —
  this feature-step owns one `resources:` entry inside it, not the file;
  the coordinator sequences the three parallel appends (Auth, Git hosting,
  Feature flags).
- **A native, non-privileged Kubernetes executor for forgejo-runner** —
  does not exist upstream yet (an author-acknowledged in-progress PoC,
  missing core features); not something this feature-step can build around
  a production-ready dependency that is not production-ready.
- **Longhorn, off-cluster DR, HA/replication, Valkey Cluster mode,
  `overlays/prod`** — all already out of scope per the parent project's
  settled decisions, unchanged by this research.

## Resolved Decisions

Answered by this research:

- **(a) Which Forgejo chart.** The official `code.forgejo.org/forgejo-helm/
  forgejo-helm` chart, OCI-distributed. No credible alternative surfaced
  (the GitHub mirror is explicitly read-only/unofficial).
- **(b) External-Postgres wiring shape.** `gitea.config.database` plain
  keys (`DB_TYPE: postgres`, `HOST`, `NAME`, `USER`), with `PASSWD` (and
  any other secret value) injected from a pre-created Secret via
  `gitea.additionalConfigFromEnvs`/`additionalConfigSources` — never a
  chart-generated or literal value. No bundled-Postgres flag to disable;
  current chart versions ship no bundled datastore at all.
- **(c) Admin-credential sealing shape.** `gitea.admin.existingSecret`
  pointed at a Secret with `username`/`password` keys, sealed via the
  identical `openssl rand ... | kubectl create secret ... --dry-run=client
  -o yaml | sops --encrypt ...` pipeline `storage-postgres-valkey` already
  established and proved live — no new discipline to invent.
- **(d) forgejo-runner's GitOps-compatible registration mechanism.**
  Forgejo's own offline path (`forgejo-cli actions generate-secret` →
  `register --secret`/`--secret-file` server-side, `forgejo-runner
  create-runner-file --secret`/`--secret-file` runner-side) is the
  documented, Infrastructure-as-Code-purpose-built answer — both sides
  consume one pre-generated, sops-sealed 40-hex-char value, no manual UI
  token step needed.
- **(e) GitHub push-mirror's cluster footprint.** Zero — a pure
  per-repository UI/API feature (PAT or SSH deploy key), no controller, no
  Secret, no chart value. Confirmed optional/deferred exactly as the parent
  design already states.
- **(f) Landing mechanism and file ownership.** The `platform` layer
  (already live, Synced/Healthy, genuinely still a skeleton) via one more
  `resources:` entry (a `forgejo/` subdirectory) in the shared `platform/
  overlays/dev/kustomization.yaml` — this feature-step does not own or
  redesign that file, only appends to it, mirroring the Gateway-`dnsNames`
  and `managed.roles[]` append-only precedents.
- **(g) Dev hostname.** `git.davidsouther.com.127.0.0.1.nip.io` — the full
  mirrored production hostname (`ARCHITECTURE.html`: "code hosting ·
  `git.davidsouther.com`"), per the parent design's already-fixed
  `<prod-host>.127.0.0.1.nip.io` scheme, correcting the task framing's
  abbreviated example.
- **(h) Postgres/Valkey consumption shape.** A second `managed.roles[]`
  entry plus a `Database` CR on the already-live shared `postgres`
  Cluster, following the `smoke` fixture's exact proven shape; a Valkey
  ACL user only if Design decides Forgejo benefits from external
  cache/queue (recommended, not mandated, per Storage's own settled
  decision on the Valkey convention).

### Resolved by the long-loop reviewer (2026-07-08)

The six items below were the "still open, for this feature-step's own design
phase to settle" slot. A separately dispatched research-and-decide reviewer
read this artifact cold, re-ran the one flagged non-mechanical decision
(item 1) against the **current** upstream state via `research:public`, and
checked each item against the repo conventions (`ARCHITECTURE.html`,
`DEVELOPMENT.md`, the parent `design.md`/`plan.md`/`closing-bell.md`, and the
already-cleared `storage-postgres-valkey` and `networking-istio` feature
artifacts) and the live `k3d-agrippa-dev` cluster (all seven layer
Applications `Synced/Healthy`; `platform` overlay carries only `argocd.yaml`;
no `forgejo` namespace yet). Each was decided to the conservative, reversible
default. No escalation trigger (irreversible, out of recorded scope, or
underdetermined) fired, so this research draft gate is cleared (marker at the
top now `*Reviewed 2026-07-08*`). Items 4 and 6 stay Design-/build-phase
artifact-authoring commitments; what the reviewer settled is that the research
is complete, its recommendations are sound, and the one genuinely open scope
decision now has a conservative default to carry into Design.

**1. forgejo-runner's execution-backend and privilege posture. Decided: defer
forgejo-runner/Actions for this local build and land the Forgejo server alone
(repo hosting, push, browse, plus the zero-footprint GitHub push-mirror
capability) as the proof — option (b).** This is the one flagged,
non-mechanical decision, and the reviewer re-researched the current upstream
state rather than trusting the body's snapshot. As of 2026-07 the picture is
unchanged and, if anything, sharper: (i) the native, non-privileged
Kubernetes-pod-per-job executor is still an author-acknowledged proof of
concept ("a big pile of hacks"), not merged, not officially supported
(Forgejo discussion #66, confirmed early-2026 status); (ii) even the newest
"rootless Forgejo runner in Kubernetes" writeups (e.g. a Nov 2025 Ubuntu 24.04
guide) still require a **privileged** `docker:dind` sidecar *and* relaxing the
node's kernel security (`kernel.apparmor_restrict_unprivileged_userns=0`) —
node-level tuning a k3d containerd-in-Docker node cannot be assumed to permit,
so it is not a genuine non-privileged path; (iii) the `host` backend (option
c) needs no Docker and no elevated privilege, but upstream documents it as
having "no isolation at all — a single job can permanently destroy the host,"
i.e. it trades the privilege risk for an arbitrary-code-in-the-runner-pod risk
and yields a degraded, non-standard CI surface. So option (a) means standing up
the **first privileged container anywhere in this project** (CNPG, Valkey,
Istio, cert-manager, and metallb all run unprivileged), and option (c) means
the project's first no-isolation job surface — both to deliver a capability the
build's own definition of done does not require. The parent design **twice**
defers the only concrete CI use it names ("Trips' CI → Forgejo Actions port …
deferred for the local build," `design.md`), the Closing Bell names **no**
Git-hosting or Actions task (this feature-step's own "Advances Closing Bell"
line says as much), and this artifact's Scope § already lists "a documented
deferral" as one of the three sanctioned in-scope shapes for the runner. The
one countervailing fact — the parent plan/design Feature 6 scope string
literally reads "Forgejo **+ forgejo-runner**," and `ARCHITECTURE.html`'s
aspirational Platform view lists "Forgejo Actions CI" as responsibility #3 — is
the *production/roadmap* vision, which this deferral preserves intact as a
documented follow-up increment (the runner is additive: a later cycle appends
it with zero rework to the server that lands now). Deferral is therefore
reversible, inside recorded scope (explicitly named as an option here, and
consistent with the parent's own local-build deferral of CI), and determined
by the conventions — a decide, not an escalate. **Design should build the
Forgejo server only; the runner, its DIND/host/native-executor choice, and its
registration secret are a documented follow-up, revisited when a
production-ready non-privileged Kubernetes executor lands upstream or the
project explicitly accepts its first privileged workload.**

**2. The registration Job's idempotency and exact shape. Decided: moot for this
build — deferred as a consequence of item 1.** The offline-registration
mechanism (`forgejo-cli actions register --secret` server-side,
`forgejo-runner create-runner-file --secret` runner-side) and its undocumented
re-registration idempotency exist only to register a runner; with the runner
deferred there is no registration Job, no runner-registration Secret, and
nothing to make idempotent in this build. When the runner lands in a later
increment, this returns as a build-time verification item then (the research
in § Search/Expand and `research/public.md` [13][14] remains the starting
point), in the same "design fixes the shape, build confirms the exact
spelling" family every sibling carries.

**3. Whether Forgejo uses the shared Valkey instance at all. Decided: do not
wire Forgejo to the shared Valkey in this build; use Forgejo's built-in
in-process cache/queue/session defaults, and keep the external-Valkey ACL user
as a documented, recommended-not-mandatory enhancement.** For a single-replica,
single-operator dev Forgejo, the in-process cache/queue/session are adequate
and are Forgejo's own default; wiring the shared Valkey adds a second external
dependency and another sealed credential for no proof-of-concept benefit at
this scale. This is the smallest honest slice (matching this research's own
Falsification § "smallest version that still meets the intent") and aligns with
Storage's settled decision that the Valkey ACL convention is "recommended, not
mandatory" — not every Feature 5-8 consumer must adopt it. The wiring shape is
already researched (`research/public.md`: `gitea.config` `[cache]`/`[queue]`/
`[session]` `redis://` keys via the same Secret indirection), so adding it
later is a determined, reversible append (one `auth.aclUsers` map entry, one
Forgejo-scoped Secret, three `app.ini` keys), not a design that has to be
gotten right now.

**4. The concrete file layout and object names inside `platform/overlays/dev/
forgejo/`. Decided: correctly deferred to Design as normal artifact authoring —
no research decision to make, only a shape to mirror.** These are not research
questions; they are the mechanical output of the Design phase authoring the
manifests, and inventing exact names now would be false precision. The shape is
fixed by precedent (mirror `storage/overlays/dev/`'s
per-component-subdirectory-plus-top-level-CR layout; the Forgejo server is a
`helmCharts:`-inflated upstream chart, not a vendored `charts/forgejo/`). With
the runner deferred (item 1), the object set this Design must name reduces to:
the Forgejo `helmCharts:` release, its `HTTPRoute`, the `Database` CR, the
`managed.roles[]` append, and two Secret names (admin credential, DB
credential) — the runner Deployment, registration Job, and registration Secret
drop out.

**5. `secrets/dev/platform/` layout and cross-feature-step coordination.
Decided: this feature-step creates only its own path (`secrets/dev/platform/
forgejo/...`) with its own `kustomization.yaml`/`secret-generator.yaml`, and
the coordinator sequences any reconciliation into a shared `secrets/dev/
platform/` sub-kustomization — the same append-only-list, coordinator-sequenced
shape already used for `platform/overlays/dev/kustomization.yaml`'s
`resources:` list.** Owning only its own path is the lowest-blast-radius
default (no assumption about siblings' timing, no shared file this step must
not clobber), exactly mirroring the file-ownership decision (f) this research
already settled for the overlay `resources:` list. With the runner deferred
(item 1), the credentials this path seals reduce to two — the initial admin
credential and the Postgres DB role password — dropping the runner-registration
secret. Flagged for the coordinator to sequence alongside the Auth and
Feature-flags platform-secret appends, mirroring the parent task's own explicit
flag about the `resources:` list. Reversible and inside recorded scope.

**6. Exact Forgejo chart version pin. Decided: correctly deferred to build-time
`research:public`, consistent with every completed sibling feature-step's
version-pin deferral.** Pinning a specific release now would only go stale
before build; the established project convention is to resolve the exact
current release at build time and re-verify the values schema against it
(`storage-postgres-valkey` and `networking-istio` both deferred their pins the
same way). No research decision is warranted here beyond confirming the
deferral is the sound, conventional default.

## Sources

Full IEEE-style citations (15 numbered sources) are in `research/public.md`.
Summary, deduplicated:

- [1]-[3] The official Forgejo Helm chart's source, OCI distribution, and
  the unofficial-mirror caveat.
- [4]-[5] The chart's `values.yaml`/README schema: external-database keys,
  `additionalConfigSources`/`additionalConfigFromEnvs`, `gitea.admin.
  existingSecret`/`passwordMode`, cache/queue/session `redis://` keys, and
  the confirmed absence of a bundled Postgres/Redis subchart since chart
  v14.
- [6]-[7] forgejo-runner's supported execution backends (Docker, Podman,
  LXC, Host) and the absence of a documented Kubernetes executor.
- [8]-[9] Independent practitioner writeups confirming the privileged
  `docker:dind`-sidecar Kubernetes deployment shape.
- [10] The Forgejo community discussion tracking the in-progress,
  not-production-ready native Kubernetes executor proof of concept.
- [11]-[12] Two third-party Kubernetes deployment options for
  forgejo-runner (a DIND-based chart; a non-privileged buildx-only manifest
  set), neither Forgejo-official.
- [13]-[14] Forgejo's own documented offline/shared-secret runner
  registration mechanism, purpose-built for Infrastructure-as-Code.
- [15] GitHub push-mirror setup: per-repository PAT/SSH auth, no
  cluster-level component.

In-repo Prior Art (authoritative, not external), full detail in
`research/codebase.md`: `ARCHITECTURE.html` (Platform layer / Git Hosting
view — the `git.davidsouther.com` hostname, the `forgejo`/`forgejo-runner`
app tiles), project `design.md` § Specification (the "Git hosting
(Forgejo)" bullet) and § Shared contracts, project `plan.md` § Feature 6
and § Shared Contracts, `DEVELOPMENT.md` § Secrets, `apps/platform.yaml`,
`platform/overlays/dev/kustomization.yaml`, `storage/overlays/dev/
postgres-cluster.yaml`, `storage/overlays/dev/valkey/kustomization.yaml`,
`secrets/dev/storage/kustomization.yaml`, `.sops.yaml`, `tests/
storage.bats`, and the two most-recently-completed sibling feature-step
artifacts (`.../features/storage-postgres-valkey/design.md` and `plan.md`;
`.../features/networking-istio/design.md` and `plan.md`). Live cluster
state (verified this session, 2026-07-08): `kubectl -n argocd get
applications` → all seven layer Applications `Synced`/`Healthy`, including
`platform`; `kubectl get ns` → no `forgejo`/`keycloak`/`flagsmith`
namespace yet; `.sops.yaml`'s `secrets/dev/.*` recipient is a real key
(no longer the placeholder Storage's own research once flagged).
