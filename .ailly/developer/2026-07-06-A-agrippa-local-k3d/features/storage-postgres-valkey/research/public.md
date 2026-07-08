# Public: Postgres + Valkey on Kubernetes via Helm/ArgoCD (Storage feature-step)

## Findings

**Bitnami's free Postgres/Valkey/Redis charts are no longer a safe default as of
this research date.** Broadcom restructured Bitnami's public catalog in
2025: after 2025-09-29 (and a shorter-lived "legacy" bridge repository before
that), most Bitnami Helm chart OCI packages moved behind a paid "Bitnami Secure
Images" subscription (reported pricing around $6,000/month with a 12-month
minimum), leaving the free `bitnami/charts` GitHub tree effectively frozen/
unmaintained (`bitnamilegacy`) with no further security patches [1][2][3][4].
The still-public `bitnami/charts` `postgresql` and `valkey` chart directories
exist [5][6] but are the frozen legacy form community sources explicitly warn
against for anything beyond a short bridge [1][2]. This directly contradicts an
unstated assumption a 2025-or-earlier-trained recommendation might carry
("use the Bitnami postgresql/valkey chart," the default answer for years); it is
falsified for this project's timeframe and is the reason this research does not
default to it.

**The community/project response for Postgres is an operator, not a chart:
CloudNativePG (CNPG).** CNPG is a CNCF-hosted, actively released Postgres
operator purpose-built for Kubernetes (streaming replication, point-in-time
recovery, declarative lifecycle management), installed via its own official Helm
chart repository `https://cloudnative-pg.github.io/charts` (chart name
`cloudnative-pg`, GitHub `cloudnative-pg/charts`) [7][8][9]. It is independent of
Bitnami's licensing change and is the option every source comparing it to the
(now-paywalled) Bitnami `postgresql` chart recommends for anything beyond a
throwaway single-container Postgres [10][11]. Installing the operator via Helm
and then authoring plain Kubernetes-native CRs for the actual workload is the
same shape this project's `core` layer already uses for cert-manager and
metallb (operator/controller via chart or manifest, config via authored CRs) —
not a new composition pattern for this repo.

**CNPG's `Cluster` CR is the single shared Postgres instance**, not a
chart-templated Deployment. A minimal example:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: agrippa-postgres
spec:
  instances: 1
  storage:
    storageClass: local-path
    size: 1Gi
```

`storage.storageClass` and `storage.size` are the load-bearing fields; `instances`
controls replica count (1 is the documented single-instance/dev shape; production
HA uses 3+) [12]. CNPG's own container images default to the latest supported
major (PostgreSQL 18 at the time of this research; 17.6+ if pinned to the 17
line — a documented upgrade bug affects 17.0-17.5) [13][14].

**CNPG's declarative Database and role-management CRs are the GitOps-native
mechanism for per-app DB/role provisioning on one shared instance — this is the
central finding for this feature-step's shared contract.** Two complementary,
independently-versioned mechanisms:

- **`Database` CRD** (stable since CNPG ~1.25): a namespaced CR that declares a
  Postgres database and its owning role, reconciled continuously (not a
  run-once initdb script). Example: `apiVersion: postgresql.cnpg.io/v1, kind:
  Database, spec: {name: one, owner: app, cluster: {name: cluster-example}}`.
  CNPG uses `CREATE DATABASE`/`ALTER DATABASE` to converge, and can also manage
  extensions per database declaratively [15]. Critically, this CR can be
  authored **anywhere in the repo that references the shared Cluster** — it does
  not require editing the Cluster's own manifest.
- **Role management — two generations found, a real design choice.**
  (a) **`Cluster.spec.managed.roles`** (stable since ~1.20): a list of role
  specs (name, login, superuser, `inRoles`, `connectionLimit`, `passwordSecret`
  referencing a `kubernetes.io/basic-auth` Secret, etc.) inside the Cluster CR
  itself, continuously reconciled, with drift (a manual `ALTER ROLE`) reverted
  on the next cycle [16]. Every later consumer appending a role here means
  editing the **same shared file**, mirroring how this project's Networking
  feature-step already handles its one shared, mutable, append-only list (the
  Gateway certificate's `dnsNames`) [see in-repo Prior Art below] — a precedent
  this project already accepted for exactly this "many independent consumers,
  one shared list" shape.
  (b) **`DatabaseRole` CRD (new in CNPG 1.30, released 2026-07)**: role
  management promoted to its own standalone, namespaced CR — explicitly to fix
  managed.roles' access-control flaw ("granting an application team the ability
  to add a role to `managed.roles` means granting them write access to the
  `Cluster` itself," and Kubernetes RBAC cannot scope to individual fields
  within a CR) [17]. However, in this first cut `DatabaseRole` carries **no
  `passwordSecret` field at all** — it is scoped to certificate-based
  (`clientCertificate: enabled: true`) authentication only, not
  password/basic-auth, which is what every off-the-shelf chart this contract
  must serve (Keycloak, Forgejo, Flagsmith) expects via a plain
  username/password DSN [17]. This is a genuinely new (2026-07) capability, not
  yet broadly documented outside its announcing blog post, and does not yet
  cover this project's actual credential-delivery need.

**Multi-tenant Postgres pattern: database-per-tenant on one shared instance is
the standard middle ground**, distinct from schema-per-tenant (shared database,
namespaced tables) and instance-per-tenant (full isolation, highest overhead).
Database-per-tenant gives each consumer its own connection namespace and
independent role-based access control while sharing one instance's compute/
storage/operational overhead — the standard trade-off referenced across
multi-tenancy literature for this class of problem (a handful of internal
platform services, not thousands of external tenants) [18]. This matches
`ARCHITECTURE.html`'s own already-stated intent (`storage/postgres`'s design
note: "single instance · per-app DBs isolated by name + role" — in-repo, not an
external source, cited for cross-reference only) rather than introducing a new
architectural stance.

**The official Valkey Helm chart is the community/project answer to the same
Bitnami disruption, for Valkey specifically.** `valkey-io/valkey-helm` (chart
subdirectory `valkey/`, current chart `0.9.0` / appVersion `9.0.1` at this
research date) is maintained by the Valkey project itself, published at
`https://valkey.io/valkey-helm/` — created explicitly in response to
Bitnami-chart breakage reports (`ImagePullBackOff`/auth 404s once free image
pulls stopped resolving) [19][20]. It supports standalone mode (default, one
pod, the shape this project's dev overlay wants) and a separate replication
mode; **cluster mode is explicitly out of scope for this chart** ("this chart
does not and will not support Valkey cluster mode... a separate chart is being
developed that uses the valkey-operator") [20] — irrelevant here since this
project needs neither Valkey Cluster nor Sentinel.

**Valkey's chart-native authentication mechanism is ACL users, directly
analogous to Postgres roles.** Exact schema from the chart's own README:

```yaml
auth:
  enabled: true
  usersExistingSecret: "my-valkey-users"   # recommended over inline passwords
  aclUsers:
    default:
      permissions: "~* &* +@all"
      # password read from Secret key "default" (username), or override via passwordKey
    keycloak:
      permissions: "~keycloak:* +@all"     # key-pattern-scoped, mirrors Postgres per-app isolation
      passwordKey: "keycloak-pwd"
```

The chart requires a `default` user be defined once auth is enabled (else
unauthenticated access is possible) [20]. Valkey's own ACL mechanism (`ACL
SETUSER`, key-pattern restriction via `~<pattern>`/`%R~<pattern>`/`%W~<pattern>`
glob syntax) is the stable, long-documented primitive this chart wraps [21][22]
— so a per-app ACL user scoped to that app's own key-prefix (`~<app>:*`) is the
direct Valkey analogue of a per-app Postgres role/database pair, using the same
"one shared instance, named-and-scoped per consumer" model. Persistence for
standalone mode is opt-in via `dataStorage.enabled/requestedSize/className`
(defaults to ephemeral if unset) [20].

**local-path is confirmed live as the k3s default StorageClass** (`kubectl get
storageclass` on the running `agrippa-dev` cluster returns `local-path
(default)`, provisioner `rancher.io/local-path`, `VolumeBindingMode:
WaitForFirstConsumer`) — this matches the parent project's already-settled
decision 1 (`research.md`) with no new finding needed; `WaitForFirstConsumer`
is what makes it safe for both the CNPG `Cluster`'s PVC and Valkey's
`dataStorage` PVC on the same single-node cluster [23]. Public sources
independently confirm `local-path-provisioner` is explicitly the documented
dev/single-node/CI answer and explicitly **not** a production multi-node
recommendation (no replication of the underlying host-path volume) — consistent
with, not contradicting, this project's already-decided dev-vs-prod storage
split [23][24].

**The sops+age+KSOPS workflow for an *application-level* Secret (as opposed to
the `sops-age` trust-root Secret GitOps injects) is: generate a random
credential locally, write it directly into a plaintext Kubernetes Secret
manifest, pipe it straight into `sops -e`, and commit only the ciphertext** —
confirmed against the general pattern this project's own `DEVELOPMENT.md`
already names ("encrypt secrets with sops, commit to git," `secrets/dev/
storage/postgres/secret.enc.yaml` as its own worked example path) and against
external walkthroughs of the same ArgoCD+KSOPS+sops+age composition [25][26].
Nothing in the public sources contradicts or improves on the mechanism this
project's own `scripts/rotate-keys.sh` already implements for the *trust-root*
key generation (`age-keygen` output piped directly to `bw create item`, secret
material never touching disk, `.sops.yaml` and already-committed secrets
updated via `yq`/`sops updatekeys`) — the same "generate in memory, encrypt
immediately, no disk round-trip" discipline this feature-step's own per-app
credential generation should reuse, not reinvent.

## In-repo finding, load-bearing for the build phase (not an external claim)

**`.sops.yaml`'s dev recipient is still the literal placeholder string
`AGE-PLACEHOLDER-REPLACE-WITH-REAL-agrippa-age-dev-PUBLIC-KEY`, verified live
this session** (`cat .sops.yaml`) — contradicting the placeholder-replaced
"live fact" this feature-step's task briefing asserted. No `secrets/` directory
exists yet in the repo, and no other feature-step (including the already-built
`gitops-argocd`, whose own trust-root Secret is injected directly by
`bootstrap.sh` and never sops-encrypted-and-committed) has yet exercised the
"commit an application-level sops-encrypted Secret" path end-to-end. This
feature-step is the **first** to need one. This is recorded as a build-phase
prerequisite this feature-step's design should surface explicitly, not a gap
this feature-step's design must solve.

> **[Reviewer correction, 2026-07-08.]** The generation mechanism named here
> (`mise run rotate-keys dev`, "first-run branch") is **falsified** by live
> state and must not be used. `agrippa-age-dev` **already exists** in Bitwarden
> (verified this session: 1 item, a valid `AGE-SECRET-KEY` identity, public half
> `age1e8wr0f85w0yfqgxc3pc6426ghlu5xt069znn5yuwrtwz30u23quqjcx6vc`), and
> `bootstrap.sh` already seeded the in-cluster `sops-age` trust root from its
> private half. `rotate-keys.sh`'s item-existence check therefore fires: it
> prompts interactively for a typed `rotate` confirmation and, if confirmed,
> **rotates** — archiving the working key and minting a new one — which would
> desynchronise `.sops.yaml` (and any secret newly encrypted to it) from the
> trust root the running cluster already holds. The Stage-4 "no prior key to
> re-encrypt from" comment is the *secrets-re-encryption* sub-branch (fires
> because `secrets/` is empty), not a whole-run first-time-key path. The
> conservative, non-destructive fix is to read the existing item's public half
> (`bw get notes agrippa-age-dev | grep '^# public key: '`) and write that
> recipient into `.sops.yaml` via `yq`, replacing the placeholder without
> minting a new key. See `research.md`'s reviewer block, item 6.

## Falsification pass

Restated claim: "the Bitnami `postgresql`/`valkey` Helm charts remain a free,
unrestricted default for a new Kubernetes GitOps project in 2026." Searched
specifically for confirmation (chart pages, pricing pages, migration guides,
several phrasings) and found uniform disconfirmation: every source addressing
Bitnami's 2025 restructuring independently describes the same
paywall/legacy-freeze outcome [1][2][3][4], including Broadcom's own current
techdocs for the paid "Bitnami Secure Images" tier as the now-supported path
[3]. The claim is refuted; this research does not recommend the Bitnami charts
as the default for either component.

Restated second claim: "CloudNativePG's `DatabaseRole` CRD (1.30) already
covers this project's password-based, per-app-role need." Searched
specifically for a `passwordSecret`-equivalent field on `DatabaseRole` and
found the announcing source itself states the opposite verbatim ("notice there
is no `passwordSecret` anywhere in the `DatabaseRole`") [17] — refuted. This
feature-step's design should default to the older, stable
`Cluster.spec.managed.roles` + `Database` CRD pair for password-based
per-app credentials, and may record `DatabaseRole` as a forward-looking,
not-yet-applicable watch-item.

## Sources

- [1] "The End of an Era for Developers: Bitnami Discontinues Free Container
  Images for the Most Part," BLUESHOE Blog.
  https://www.blueshoe.io/blog/bitnami-and-alternatives/
- [2] "Broadcom Ends Free Bitnami Images, Forcing Users to Find Alternatives,"
  The New Stack. https://thenewstack.io/broadcom-ends-free-bitnami-images-forcing-users-to-find-alternatives/
- [3] "Bitnami Secure Images Helm chart for PostgreSQL HA," Broadcom TechDocs
  (the current paid-tier successor). https://techdocs.broadcom.com/us/en/vmware-tanzu/bitnami-secure-images/bitnami-secure-images/services/bsi-app-doc/apps-charts-postgresql-ha-index.html
- [4] "Bitnami Charts Breaking Aug 2025: Migration Guide & Free Alternatives,"
  Industrial Monitor Direct. https://industrialmonitordirect.com/blogs/knowledgebase/bitnami-helm-charts-migration-action-required-before-august-28-2025
- [5] "Bitnami PostgreSQL chart," bitnami/charts GitHub (frozen/legacy form).
  https://github.com/bitnami/charts/tree/main/bitnami/postgresql
- [6] "Bitnami Helm chart for Valkey," bitnami/charts GitHub (frozen/legacy
  form). https://github.com/bitnami/charts/tree/main/bitnami/valkey
- [7] "CloudNativePG," official documentation site.
  https://cloudnative-pg.io/
- [8] "CloudNativePG Helm Chart," chart index. https://cloudnative-pg.io/charts/
- [9] "cloudnative-pg/charts," GitHub (official chart repo,
  `https://cloudnative-pg.github.io/charts`). https://github.com/cloudnative-pg/charts
- [10] "PostgreSQL Helm Chart: How to Deploy Postgres on Kubernetes," lowcloud.
  https://lowcloud.io/en/blog/postgresql-helm-chart-kubernetes
- [11] "PostgreSQL on Kubernetes - A Complete Guide to Deployment Methods,"
  CICube. https://cicube.io/blog/postgres-kubernetes/
- [12] "Examples," CloudNativePG Documentation (storage-class Cluster sample).
  https://cloudnative-pg.io/docs/1.28/samples/
- [13] "cloudnative-pg/postgres-containers," GitHub (operand image repo,
  default/major-version policy). https://github.com/cloudnative-pg/postgres-containers
- [14] "PostgreSQL upgrades," CloudNativePG Documentation (17.0-17.5
  `max_slot_wal_keep_size` upgrade bug, fixed 17.6+).
  https://cloudnative-pg.io/docs/1.28/postgres_upgrades/
- [15] "PostgreSQL Database management," CloudNativePG Documentation (`Database`
  CRD, `owner`, extensions). https://cloudnative-pg.io/docs/1.27/declarative_database_management/
- [16] "Database Role Management," CloudNativePG Documentation
  (`Cluster.spec.managed.roles`, `passwordSecret`, drift reversion).
  https://cloudnative-pg.io/documentation/1.20/declarative_role_management/
- [17] Gabriele Bartolini, "CNPG Recipe 25 - Declarative Roles and Passwordless
  TLS in CloudNativePG 1.30," gabrielebartolini.it, 2026-07 (the `DatabaseRole`
  CRD announcement; no `passwordSecret` field; the `managed.roles` RBAC-scoping
  critique). https://www.gabrielebartolini.it/articles/2026/07/cnpg-recipe-25-declarative-roles-and-passwordless-tls-in-cloudnativepg-1.30/
- [18] "Approaches to tenancy in Postgres," PlanetScale Blog
  (shared-schema / schema-per-tenant / database-per-tenant trade-offs).
  https://planetscale.com/blog/approaches-to-tenancy-in-postgres
- [19] "Valkey Helm: The new way to deploy Valkey on Kubernetes," Valkey
  Project Blog. https://valkey.io/blog/valkey-helm-chart/
- [20] "valkey" chart README, valkey-io/valkey-helm GitHub (deployment modes,
  storage, `auth.aclUsers`/`usersExistingSecret` schema, cluster-mode
  exclusion). https://github.com/valkey-io/valkey-helm/blob/main/valkey/README.md
- [21] "ACL," Valkey Documentation (key-pattern glob syntax
  `~pattern`/`%R~pattern`/`%W~pattern`). https://valkey.io/topics/acl/
- [22] "ACL SETUSER," Valkey Command Reference. https://valkey.io/commands/acl-setuser/
- [23] "Storage," CloudNativePG Documentation
  (`storageClass`/`size`, `WaitForFirstConsumer` interaction).
  https://cloudnative-pg.io/documentation/1.20/storage/
- [24] "rancher/local-path-provisioner," GitHub (dev/single-node/CI scope,
  explicit non-production-multi-node guidance).
  https://github.com/rancher/local-path-provisioner
- [25] "A Guide to GitOps and Secret Management with ArgoCD Operator and
  SOPS," Red Hat Blog (already cited by the project's top-level `research.md`
  [9]; application-secret encrypt-then-commit workflow).
  https://www.redhat.com/en/blog/a-guide-to-gitops-and-secret-management-with-argocd-operator-and-sops
- [26] "How to Manage Secrets with ArgoCD and SOPS," OneUptime Blog.
  https://oneuptime.com/blog/post/2026-02-26-argocd-sops-secrets/view

In-repo Prior Art consulted (not external, cited for cross-reference only):
`ARCHITECTURE.html` (§ S4 Storage — "Postgres · single instance · per-app DBs
isolated by name + role"; § S5 Platform layer listing), project `design.md` §
Specification § Storage and § Shared contracts, project `plan.md` § Feature 4
and § Shared Contracts, project `research.md` decision 1 (`local-path`),
`DEVELOPMENT.md` § Secrets, `.sops.yaml`, `tests/policy/secrets.rego`,
`apps/storage.yaml`, `storage/overlays/dev/kustomization.yaml`, `mise.toml`,
`scripts/rotate-keys.sh`, `scripts/bootstrap.sh`, and the two completed sibling
feature designs `features/networking-istio/design.md` (the shared
append-only-list precedent, the `helmCharts:`+authored-CRs composition
precedent) and `features/gitops-argocd/design.md` (the KSOPS/`sops-age`
convention, the `secrets/dev/<component>.enc.yaml` path precedent). Live
cluster state (verified this session, 2026-07-08): `kubectl get storageclass`
→ `local-path (default)`, provisioner `rancher.io/local-path`,
`WaitForFirstConsumer`; `kubectl -n argocd get cm argocd-cm` →
`kustomize.buildOptions: "--enable-alpha-plugins --enable-exec --enable-helm"`
(already carries `--enable-helm` from the `networking-istio` feature-step, so
no new repo-server wiring is needed for a `helmCharts:`-based CNPG/Valkey
install); `kubectl -n argocd get application storage` → `Synced`/`Healthy` on
the empty `resources: []` placeholder; no `metallb-system`/`cnpg-system`/
`valkey` namespace exists yet.
