# Codebase: git-hosting-forgejo landing points and precedents (live-verified 2026-07-08)

## Findings

**The `platform` layer exists, is Synced/Healthy, and is genuinely still a
skeleton.** `apps/platform.yaml` (sync-wave `2`) points at
`platform/overlays/dev`, with the comment "Platform owns ArgoCD
self-management, keycloak, forgejo, & flagsmith." Live-checked:
`kubectl -n argocd get application platform` → `Synced Healthy`.
`platform/overlays/dev/kustomization.yaml`'s own header comment states it
plainly: *"Not empty like the other four layers — it carries the thin argocd
self-management Application (Step 3's design), so ArgoCD's own install
reconciles from here going forward. Real platform content (keycloak,
forgejo, flagsmith) lands as later feature-steps' added resources here."*
Its only `resources:` entry today is `argocd.yaml` (the self-managing ArgoCD
Application, `gitops-argocd`'s own artifact). **No Forgejo, Keycloak, or
Flagsmith directory exists anywhere in the repo yet.**

**This confirms the task briefing's landing-mechanism finding exactly, and
sharpens it.** Three sibling feature-steps (Auth/Keycloak, Git
hosting/Forgejo, Feature flags/Flagsmith) all land in this same `platform`
layer, all append to the same `platform/overlays/dev/kustomization.yaml`
`resources:` list — the identical "many independent consumers append to one
shared, mutable list" shape already established twice: Networking's Gateway
certificate `dnsNames` list, and Storage's `Cluster.spec.managed.roles[]`
list. This feature-step should **not** treat `platform/overlays/dev/
kustomization.yaml` as its own file to design freely — it owns one more
`resources:` entry (a `forgejo/` subdirectory, mirroring `core`'s and
`storage`'s per-component-subdirectory convention), not the file itself. The
coordinator, not this feature-step's own build, sequences the actual
three-way append (the same way three parallel PRs each add one list entry
without owning the file).

**The `storage-postgres-valkey` feature-step is mid-build, not merely
designed — its shared contract is *live*.** `storage/overlays/dev/
postgres-cluster.yaml` (real content, not a stub) already carries the CNPG
`Cluster` named `postgres` in namespace `storage`, `imageName:
ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie`,
`storage.storageClass: local-path`, and one `managed.roles[]` entry (`smoke`,
`passwordSecret: {name: smoke-db}`). This means Forgejo's own database is a
**second entry appended to this same live list**, not a hypothetical
pattern — `git-hosting-forgejo`'s own `Database` CR and `managed.roles[]`
append can follow the `smoke` entry's exact shape:
`{name: forgejo, login: true, passwordSecret: {name: forgejo-db}}` plus a
`Database` CR (`owner: forgejo`, `cluster: {name: postgres}`, and — a
build-time correction the Storage plan's own Step 4 discovered — the CRD
also requires `spec.name`, the literal PostgreSQL database name). The shared
Postgres Service is `postgres-rw.storage.svc:5432` (also `postgres-ro`,
`postgres-r`); the credential Secret is `kubernetes.io/basic-auth`
(`username`/`password` keys).

**The shared Valkey instance is live too**, `storage/overlays/dev/valkey/
kustomization.yaml`: official `valkey.io/valkey-helm` chart 0.10.0,
standalone, `auth.enabled: true`, `auth.aclUsers` is a plain map keyed by
username (a `smoke` entry scoped `~smoke:* +@all` exists today), passwords
read from `auth.usersExistingSecret` at a key matching the username.
Service/pod label: `app.kubernetes.io/name=valkey`, reachable at
`valkey.storage.svc:6379`. A Forgejo cache/queue/session ACL user would be
one more map entry in this same file (`forgejo: {permissions: "~forgejo:*
+@all"}`), with its password added to a Forgejo-specific KSOPS-sealed users
Secret (or, simpler, its own dedicated `forgejo-valkey` Secret referenced
only by this feature-step) — see the parent Storage design's own note that
the Valkey ACL convention is **recommended, not mandatory**: not every
Feature 5-8 consumer must use it.

**The KSOPS + sops + age credential-sealing path is proven end-to-end, not
just documented.** `.sops.yaml`'s `secrets/dev/.*` rule now carries a real
recipient (`age1e8wr0f85w0yfqgxc3pc6426ghlu5xt069znn5yuwrtwz30u23quqjcx6vc`)
— the placeholder Storage's research flagged is already fixed. The KSOPS
generator wiring (a self-contained `secrets/dev/<layer>/` sub-kustomization
referenced from the layer overlay as `../../../secrets/dev/<layer>`,
carrying its own `kustomization.yaml` with `generators: [secret-generator.
yaml]` at sync-wave `-5`, and a `secret-generator.yaml` of `apiVersion:
viaduct.ai/v1, kind: ksops, files: [...]`) is live and decrypting real
Secrets today (`storage`'s `smoke-db`/`smoke-valkey`). This feature-step's
own credential(s) — a Postgres role password, an initial Forgejo admin
credential, and a forgejo-runner registration secret — should follow the
identical `secrets/dev/platform/forgejo/<name>.enc.yaml` shape (component-
first, per-credential filename, mirroring Storage's `secrets/dev/storage/
<store>/<slug>.enc.yaml` convention adapted to the `platform` layer) and its
own `secrets/dev/platform/kustomization.yaml` + `secret-generator.yaml`
pair — **or**, if Auth/Flagsmith land credentials in the same layer around
the same time, a shared `secrets/dev/platform/` sub-kustomization all three
append `files:` entries to (another instance of the append-only-list shape,
worth flagging explicitly for the coordinator to sequence).

**The sealing discipline itself is a proven, copy-pasteable shell recipe**,
not merely a principle: `storage-postgres-valkey/plan.md` Step 2's exact
`openssl rand -base64 24 | tr -d '\n' | kubectl create secret generic
<name> ... --from-file=password=/dev/stdin --dry-run=client -o yaml | sops
--encrypt --filename-override secrets/dev/<path> ... > secrets/dev/<path>`
pipeline (single-value case) and its multi-value sibling (shell-variable
substitution into a `stringData` document, then the same `sops --encrypt`
pipe) are both live-verified, working code in this repo today — this
feature-step's own admin-credential and runner-registration-secret sealing
should reuse them verbatim rather than re-deriving the discipline.

**Test convention: one `tests/<feature>.bats` file, named after the domain
concept with the specific-technology qualifier dropped.** `cluster-core.bats`
dropped `-k3d`, `gitops.bats` dropped `-argocd`, `networking.bats` dropped
`-istio`, `storage.bats` dropped `-postgres-valkey`. Applying the same rule
to this feature-step's own folder name (`git-hosting-forgejo`) yields
`tests/git-hosting.bats` — dropping the `-forgejo` tool qualifier, keeping
the domain concept `git-hosting`. Every sibling suite: targets the
long-lived `k3d-agrippa-dev` context; asserts the owning layer Application
(`platform`, not a new one) is `Synced Healthy`; is added to `scripts/
test-feature.sh`'s exclusion `case` list **at design time** (with the test
file itself), not deferred to build, so `mise run test:feature`'s
throwaway-cluster auto-discovery does not pick it up; and deliberately never
tears down what it proves (ArgoCD's `prune`/`selfHeal` would fight a
throwaway teardown against a `Synced/Healthy` layer). `tests/storage.bats`'s
own structure (`setup()` just `cd`s to repo root; small `*_status`/`*_pod`
helper functions; one `@test` with numbered `THEN` blocks) is the shape to
mirror.

**No `charts/` directory exists yet.** `DEVELOPMENT.md`'s `charts/<chart>/`
convention (with `charts/<chart>/tests/` for helm-unittest) is reserved for
this project's **own-authored** charts — so far only anticipated for the
Workloads feature-step's `charts/resume/`/`charts/trips/` (not yet built
either). Every platform-layer component built so far (Istio, cert-manager,
metallb, CNPG, Valkey) is composed via `helmCharts:` **inflation** of an
upstream chart directly inside the layer's `overlays/dev/<component>/
kustomization.yaml` — no chart is vendored under `charts/`. Forgejo (an
upstream-published chart) should follow this same precedent: a `platform/
overlays/dev/forgejo/kustomization.yaml` with its own `helmCharts:` block,
not a new `charts/forgejo/` directory. forgejo-runner has **no** official
upstream chart (per `research/public.md`), which puts it in a different
bucket: either a hand-authored Deployment/StatefulSet CR (the same
authored-CR shape Networking used for the Gateway/Certificate/HTTPRoute) or
adopting a third-party chart via the same `helmCharts:` mechanism — a
Design-phase artifact choice this research surfaces but does not resolve.

**The repo-server's KSOPS/Helm kustomize build flags are already fully
wired and need no further change.** `apps/platform/argocd/kustomization.yaml`
already patches `argocd-cm`'s `kustomize.buildOptions` to
`"--enable-alpha-plugins --enable-exec --enable-helm"`, and (per
`storage-postgres-valkey`'s build-time-discovered fix) the `custom-tools`
`ksops` binary is mounted at both `/usr/local/bin/ksops` and kustomize's own
exec-plugin path. This feature-step needs **zero** repo-server changes —
purely additive `resources:`/`helmCharts:`/`secrets/` content, the same
"no cross-step touch needed" position Storage's own Step 1 confirmed for
itself.

## Sources

In-repo, live-verified this session (2026-07-08): `apps/platform.yaml`,
`platform/overlays/dev/kustomization.yaml`, `platform/overlays/dev/
argocd.yaml`, `storage/overlays/dev/kustomization.yaml`, `storage/overlays/
dev/postgres-cluster.yaml`, `storage/overlays/dev/valkey/kustomization.yaml`,
`secrets/dev/storage/kustomization.yaml`, `.sops.yaml`, `tests/storage.bats`,
`DEVELOPMENT.md` (§ Secrets, § Repo layout), `ARCHITECTURE.html` (Platform
layer / Git Hosting view, lines ~792-841 and the `forgejo`/`forgejo-runner`
docs-link map ~1206-1207), and `kubectl --context k3d-agrippa-dev get
applications -n argocd` / `get ns` (all seven layer Applications
`Synced/Healthy`; `platform` namespace list has no `forgejo`/`keycloak`/
`flagsmith` namespace yet). Sibling feature-step artifacts read as Prior Art:
`.ailly/developer/2026-07-06-A-agrippa-local-k3d/features/
storage-postgres-valkey/design.md` and `plan.md` (the DB/role naming
contract, the credential-sealing shell recipes, the KSOPS wiring, the
build-time-discovered CRD/kustomize fixes), `.../features/networking-istio/
design.md` and `plan.md` (the Gateway/HTTPRoute/hostname/TLS contract, the
shared-append-only-list precedent, the `helmCharts:`-plus-authored-CRs
composition shape).
