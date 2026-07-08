# Public: Running Forgejo + forgejo-runner on Kubernetes for local/dev, GitOps-compatible

## Findings

**The official Helm chart.** Forgejo publishes its own Helm chart at
`code.forgejo.org/forgejo-helm/forgejo-helm`, distributed as an OCI artifact:
`helm install forgejo oci://code.forgejo.org/forgejo-helm/forgejo` [1][2]. A
read-only mirror exists on GitHub (`project-mirrors/forgejo-helm`) for tooling
that only speaks GitHub [3]. This chart is the Forgejo-maintained fork of the
Gitea Helm chart lineage; **as of chart v14 it dropped its bundled PostgreSQL
and Redis/Valkey subcharts entirely** — there is no `postgresql.enabled` or
`redis-cluster.enabled` toggle in current `values.yaml` [4][5]. This is a
positive fit for this project: it means "point at an external datastore" is
not an opt-in flag fighting a bundled default, it is simply the only
supported shape — `gitea.config.database` starts `{}` and is populated
entirely by the operator [5].

**External Postgres wiring.** `gitea.config.database` takes the plain
Forgejo/Gitea `app.ini` `[database]` keys directly: `DB_TYPE: postgres`,
`HOST`, `NAME`, `USER`, `PASSWD`, optional `SCHEMA` [4][5]. Because a
plaintext `PASSWD` in `values.yaml` is exactly what this project's sops+KSOPS
discipline exists to avoid, the chart supports two secret-based
indirections: `gitea.additionalConfigFromEnvs` — a list mapping an
`app.ini` key to `valueFrom.secretKeyRef` (`FORGEJO__DATABASE__PASSWD` from a
pre-created Secret key) — or the more general
`gitea.additionalConfigSources: [{secret: {secretName: <name>}}]`, which
mounts an entire pre-created Secret's keys as additional `app.ini`
fragments [4][5]. Either form takes a **pre-created Secret name**, not a
chart-generated one — the same shape this project's `existingSecret`/KSOPS
convention already uses for Storage's `smoke-db`/`smoke-valkey` credentials.

**External Valkey/Redis wiring.** Same shape as the database: `gitea.config`
carries plain `[cache]`/`[queue]`/`[session]` keys —
`cache.ADAPTER: redis`, `cache.HOST: redis://<url>:<port>/<db>`;
`queue.TYPE: redis`, `queue.CONN_STR: redis://...`; `session.PROVIDER: redis`,
`session.PROVIDER_CONFIG: redis://...` — again with no bundled subchart, so
the shared `valkey.storage.svc:6379` instance is a drop-in target [4][5]. If
Valkey requires ACL auth (as the Storage contract's per-app users do), the
password portion of the `redis://` URL should come from the same
`additionalConfigFromEnvs`/`additionalConfigSources` Secret indirection used
for the database password, not a literal in `values.yaml`.

**Initial admin credential.** The chart has a first-class
`gitea.admin.existingSecret` value: point it at a pre-created Secret
carrying `username` and `password` keys (email is a plain chart value,
not secret) [4][5]. `gitea.admin.passwordMode` controls reconcile
behavior — `keepUpdated` (default, resets the password to the Secret's
value on every pod restart), `initialOnlyNoReset`, or
`initialOnlyRequireReset` [4][5]. This maps directly onto this project's
sops+KSOPS "seal a credential, reference it by name" discipline
(`storage-postgres-valkey`'s `smoke-db`/`smoke-valkey` precedent): generate
the admin password in memory, seal it as `secrets/dev/platform/forgejo/
admin.enc.yaml`, reference it via `existingSecret:`.

**Kustomize `helmCharts:` fit.** No source surfaced a Helm hook (post-install
Job, etc.) in the Forgejo chart's own lifecycle that the project's established
`helmCharts:`-inflation-runs-`helm-template` constraint (no hooks executed)
would silently drop — the chart's own install is a plain Deployment +
Service + PVC + ConfigMap/Secret shape, matching the Storage/Networking
precedent of Helm-sourced components that render cleanly under `helm
template` [4][5]. This should still be build-time re-verified against the
exact pinned chart version, per this project's established "design fixes the
shape, build confirms the exact spelling" posture (`storage-postgres-valkey`
design, `networking-istio` design).

**forgejo-runner: no first-class Kubernetes executor yet.** Forgejo's
`config.yaml` supports **Docker, Podman, LXC, and Host** execution backends
for running a job's containers — there is **no documented, stable Kubernetes
executor** [6][7]. The standard Docker-executor deployment (the shape every
worked example uses, including Forgejo's own Docker Compose reference)
mounts a Docker socket into the runner container, either from the host or
from a sibling `docker:dind` (Docker-in-Docker) **privileged** sidecar
container in the same Pod [6][8][9]. A native, non-privileged
Kubernetes-pod-per-job executor exists only as an **in-progress proof of
concept** (Mark Glines' PoC, tracked in a Forgejo community discussion),
explicitly described by its own author as "a big pile of hacks" missing
service-container support, caching, and full workflow-syntax compatibility —
not production-ready [10]. Community workarounds today besides DIND include
Kaniko/Buildah for rootless image builds and GARM-based autoscaling
integration, none of which is a drop-in "run forgejo-runner as a plain
Kubernetes Deployment with no elevated privilege" answer [10]. **This is the
one component in this feature-step whose operational shape genuinely
diverges from the rest of the platform**: every other workload in this
project (CNPG, Valkey, Istio, cert-manager, metallb) runs unprivileged;
forgejo-runner's only well-trodden Kubernetes deployment shape needs a
privileged `docker:dind` sidecar (or, less commonly, a host Docker socket
mount, which is not available inside a k3d node's containerd-only runtime).
This is a design-phase decision this research surfaces, not resolves:
whether to accept the privileged DIND sidecar for local dev (simplest,
matches every official example), or to run forgejo-runner with the `host`
(non-container) backend inside its own already-privileged-enough Pod, or to
defer registering any runner at all for the initial build (Actions/CI is not
named in the Closing Bell's critical tasks) and record it as a documented
follow-up.

**Kubernetes chart options for forgejo-runner exist but are third-party, not
official.** `wrenix/forgejo-runner` (Artifact Hub) is cited by several blog
posts as "the practical solution" for a DIND-based runner deployment [8][11].
A second, differently-shaped example — the "Mint System Forgejo Runner"
manifest set — targets a **buildx/`driver=kubernetes`** pattern instead of
DIND: it pre-creates a `forgejo-runner` Secret (`forgejoInstanceToken` key)
via `secretRef`, and grants the runner a ServiceAccount/RBAC role so it can
spawn build pods directly via Docker Buildx's Kubernetes driver rather than a
Docker daemon — an existingSecret pattern, no privileged sidecar, but a
narrower "build-only" use case (not a general Actions executor) [12]. Neither
is Forgejo-official; whichever is chosen (or a hand-authored Deployment,
consistent with how this project prefers "chart where an official one exists,
authored CR otherwise") is a design-phase artifact choice, not settled here.

**forgejo-runner registration: a GitOps-compatible offline/shared-secret path
exists and is Forgejo's own documented answer for Infrastructure-as-Code.**
Besides the interactive UI-token flow (visit `/admin/actions/runners`, click
"create new runner," copy a one-time token into the runner's `.runner`
file) [13], Forgejo ships a **server-side, non-interactive registration
path** purpose-built for this exact scenario [13][14]:

1. `forgejo forgejo-cli actions generate-secret` (or the operator's own
   `openssl rand -hex 20`, per the docs' own equivalence note) produces a
   40-character hex string: the first 16 characters are the runner's
   identifier, the rest is its secret [13][14]. This can be generated the
   same way this project already seals the Storage `smoke-db` password — in
   memory, piped straight to `sops --encrypt`, only ciphertext committed.
2. **Server side:** `forgejo forgejo-cli actions register --name <name>
   --scope <owner[/repo]> --secret <the-40-hex-value>` (or
   `--secret-file <path>` / stdin, for exactly the "don't put a secret in
   argv" reason this project's Storage credential-sealing discipline already
   cares about) registers the runner **directly against Forgejo's database**
   [13][14]. Community discussion of the originating feature request
   describes this as able to "generate a secret," "configure Forgejo with
   the secret," and run independently of a live server request/response
   cycle — i.e., it operates against the Forgejo installation's config +
   database, not by calling a running server's HTTP API, so it is plausible
   to run as a one-shot Job using the same Forgejo image/config rather than
   requiring an interactive `kubectl exec` into the main Deployment's running
   container [14]. Idempotency (whether re-running against an
   already-registered runner name errors harmlessly or duplicates) is **not
   documented** and is flagged here as a build-time verification item.
3. **Runner side:** `forgejo-runner create-runner-file --secret <value>` (or
   `--secret-file`) writes the `.runner` config file consumed at
   startup [13][14] — or, per the third-party Kubernetes-chart precedent
   above, the runner container can read the same value from a mounted
   Secret directly [12].

Both sides consume the **same pre-generated 40-hex-char value** — exactly the
shape this project's per-app credential Secrets already take (seal once,
reference by Secret name from two independent manifests, mirroring how
Storage's `smoke-db` Secret is referenced by both the CNPG `managed.roles[]`
entry and the feature test). No source describes a `--no-interactive
--token` flag on `forgejo-runner register` itself for pulling a
pre-existing UI-generated token non-interactively — the offline path above
(generate-secret → register --secret → create-runner-file --secret) is the
sanctioned automatable route, not a variant of the interactive one [13][14].

**GitHub push-mirror needs no cluster-level component.** Setting up a push
mirror to GitHub is a plain per-repository, UI/API-driven Forgejo feature:
add a mirror URL, and either a GitHub Personal Access Token (with
`public_repo` and, if mirroring workflow files, the `workflow` scope) as
HTTP Basic auth, or Forgejo-generated SSH keypair added as a GitHub deploy
key [15]. Nothing about it touches Kubernetes wiring, a controller, or a
cluster-level Secret — it is exactly the "optional, needs outbound network +
a per-repo GitHub PAT, safe to defer/document as opt-in" shape the parent
design already assumes [15]. The only cluster-relevant fact is that it
requires the Forgejo pod to reach `github.com` over the internet, which is
available from a k3d node unless the operator is offline — no different from
any other outbound dependency already accepted elsewhere in this project
(e.g., pulling upstream Helm charts).

## Sources

- [1] "Forgejo Helm Chart," Forgejo, code.forgejo.org/forgejo-helm/forgejo-helm — official chart source and OCI install command.
- [2] "Helm Chart Registry," Forgejo docs, forgejo.org/docs/latest/user/packages/helm/ — confirms the OCI registry distribution model.
- [3] "project-mirrors/forgejo-helm," GitHub — confirms the GitHub copy is an unofficial read-only mirror, not the source of truth.
- [4] "forgejo-helm/forgejo-helm," code.forgejo.org — chart README describing external-database `gitea.config.database` keys, `additionalConfigSources`/`additionalConfigFromEnvs`, `gitea.admin.existingSecret`/`passwordMode`, and cache/queue/session `redis://` config keys; confirms no bundled Postgres/Redis subchart as of chart v14+.
- [5] "Forgejo Helm Chart," Artifact Hub, artifacthub.io/packages/helm/forgejo-helm/forgejo — cross-check of the same values schema and current chart version.
- [6] "Forgejo Runner installation guide," Forgejo docs, forgejo.org/docs/v11.0/admin/actions/runner-installation/ — enumerates supported executors (Docker, Podman, LXC, Host) and the Docker-socket/`docker:dind` deployment shape; states no Kubernetes executor is documented.
- [7] "Forgejo Actions | Reference," Forgejo docs, forgejo.org/docs/latest/user/actions/reference/ — general Actions/runner reference, cross-checked for executor-backend claims.
- [8] Cowley, "Forgejo on Kubernetes," cowley.tech/posts/2024/09/forgejo-on-kubernetes/ — practitioner writeup of a DIND-sidecar runner deployment on Kubernetes.
- [9] margau.net, "Forgejo Runner with IPv6 only on Kubernetes" — a second independent practitioner DIND-sidecar deployment, corroborating the privileged-sidecar shape.
- [10] "#66 Native Kubernetes Forgejo runners," Forgejo community discussions, codeberg.org/forgejo/discussions/issues/66 — the PoC-stage-only status of a non-privileged, pod-per-job Kubernetes executor, and current community workarounds (Kaniko/Buildah, GARM).
- [11] "forgejo-runner," wrenix, Artifact Hub, artifacthub.io/packages/helm/forgejo-runner/forgejo-runner — a third-party DIND-based Helm chart cited by multiple practitioner sources as the practical Kubernetes deployment path.
- [12] "Mint System Forgejo Runner," kubernetes.build/forgejoRunner/README.html — an alternative third-party manifest set using Docker Buildx's `driver=kubernetes` and an `existingSecret`-style `secretRef` for the registration token, no privileged sidecar, narrower build-only use case.
- [13] "Forgejo Runner Registration," Forgejo docs, forgejo.org/docs/latest/admin/actions/registration/ — canonical description of both the interactive UI-token flow and the offline `forgejo-cli actions register --secret`/`generate-secret` flow, and the 40-hex-char secret format.
- [14] "#983 [FEAT] offline actions runner registration," Forgejo, codeberg.org/forgejo/forgejo/issues/983 — the originating feature discussion; confirms the offline path was purpose-built for Infrastructure-as-Code, describes `--secret-file`/stdin delivery options, and that registration acts on Forgejo's own database/config rather than requiring a live server round-trip.
- [15] "Repository Mirrors," Forgejo docs, forgejo.org/docs/v15.0/user/repo-mirror/ — push-mirror setup: per-repo PAT or SSH-deploy-key auth, no cluster-level component.
