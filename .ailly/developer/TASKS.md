# Agrippa — Next Tasks

## Platform build roadmap

The component design sequence from
`ailly/developer/2026-06-10-A-agrippa/design.md` (§ Component design sequence).
Build in order; each item gets its own design → plan → implement cycle, and each
component design must define SLOs as Prometheus queries or Grafana alert
thresholds (not aspirational prose).

1. **Cluster core.** Node provisioning via cloud-init + k3s, single combined node
   pool (split on measured contention), scale-to-zero GPU pool. Development only. Cloud provider initially Digital Ocean with s-4vcpu-8gb.
   Autoscaling is researched: modularity lives at a Terraform `elastic-node-pool`
   seam (AWS CA-on-ASG, DigitalOcean DOKS-pool-or-destroy-recreate), with Cluster API
   + `clusterapi` cluster-autoscaler deferred until CAPDO reaches beta *and*
   cluster-api-k3s lists a DigitalOcean sample.
2. **Networking.** Cloudflare Tunnel, Istio Ambient Gateway (Gateway API),
   ExternalDNS, CertManager.
3. **Storage.** Longhorn block storage, Postgres, Valkey; DR tiers (RPO 2h).
4. **GitOps.** ArgoCD bootstrap (app-of-apps); takes over management of all
   subsequent layers.
5. **Git hosting.** Forgejo + forgejo-runner; GitHub push-mirror.
6. **Observability.** LGTM stack; OTel instrumentation. Triggers Rook-Ceph object
   storage when Loki/Mimir/Tempo needs a backend.
7. **Auth.** Keycloak + Cloudflare Access integration (deployed by ArgoCD,
   requires Postgres).
8. **Feature flags.** OpenFeature + Flagsmith.
9. **Workloads.** davidsouther.com, /blog, trips.davidsouther.com, /agathon,
   ailly.dev. Trips moved from a `/trips` path to its own subdomain for deploy
   isolation from the public `github:davidsouther/resume` repo that serves
   davidsouther.com — see the Trips workload design task below, including the
   existing auth and CI that need porting. Agathon's "sharing" win needs no
   separate platform component: it resolves once Agathon has its own per-user DB.
10. **Platform LLM** (future). Ollama, ZenML, LangFuse; its own cycle when a real
    consumer such as DavidBot is designed. Mlflow and Benchflow are unresolved
    candidates for this tier — researched in
    `ailly/developer/research/mlops-tooling.md` (draft, pending review).
    DavidBot's connector layer (Google, Slack, Notion, Linear, GitHub) and its
    agent gateway are researched ahead of that cycle in
    `ailly/developer/research/davidbot-agent-gateway.md` (draft, pending review),
    so the shape isn't lost by the time this item starts.

## Trips workload design

Trips already runs today at `trips.davidsouther.com` — it moved off
`davidsouther.com/trips` for deploy isolation, since davidsouther.com itself is
served from the public `github:davidsouther/resume` repo and Trips needs
broader permissions/secrets than that repo should carry. It already has a
working Cloudflare Access policy and CI running against it. This is a **port**
into this platform's GitOps/Terraform management, not a fresh design.

- **Port the existing Cloudflare Access policy to Terraform IaC.** Manage the
  email allowlist in `terraform/` rather than wherever it's managed today.
  Two patterns researched: (A) inline `email = [...]` in `cloudflare_access_policy`
  include block — simple, one variable; (B) `cloudflare_zero_trust_list` resource
  referenced via `email_list` — preferable if the same list gates more than one
  application. Google OAuth is the recommended IdP (one-time GCP project, ~15 min);
  email OTP is the fallback if non-Gmail guests are expected. Revocation takes
  effect on the next request after the session cookie expires (default 24h).
- **Port the existing CI.** Trips' current build/deploy pipeline needs to move
  onto Forgejo Actions (with the GitHub push-mirror as backup) once step 5
  (Git hosting) lands, rather than staying on whatever runs it today.

## Storage / DR

- **Review CloudNativePG for application-consistent Postgres backup + PITR.**
  Trigger: when any Postgres-backed workload requires RPO < 2h, point-in-time
  recovery, or guaranteed application-consistent restore (the current pg_dump
  q2h tier gives a 2h logical RPO and crash-consistent volume backups only).
  CNPG brackets CSI VolumeSnapshots with `pg_backup_start/stop` and archives WAL
  to object storage. Could replace the pg_dump tier with near-zero-RPO recovery.

## Secrets (cross-cutting)

- **SOPS + age, settled — not ExternalSecrets.** Key policy, wiring (repo/mise,
  Terraform, k3s/ArgoCD), and build-sequence placement are all in
  `DEVELOPMENT.md` (## Secrets). Must be usable no later than Storage
  (item 3), since Postgres is the first component with real credentials, and
  lands with item 1 tooling and `mise` init — before ArgoCD (item 4) exists to
  apply anything.

- **`tests/rotate-keys.bats` fails, pre-existing, confirmed unrelated to the
  Storage feature-step's own changes.** Reproduced in isolation (a fresh
  `agrippa-age-citest` Bitwarden item, an isolated temp `secrets/citest/`
  fixture — not the real `agrippa-age-dev` trust root or any committed
  secret). `scripts/rotate-keys.sh` mints a new identity, then `sops
  updatekeys` reports the fixture file "already up to date" (does not
  actually re-encrypt it to the new identity), then `.sops.yaml`'s recipient
  is updated to the new key anyway — leaving the fixture file encrypted to
  neither the archived nor the new identity, so a subsequent `sops -d` fails
  with "no identity matched any of the recipients." Needs its own
  investigation into why `sops updatekeys` treats the freshly-created fixture
  as already current (likely a stale `.sops.yaml` read, or the fixture not
  being tracked as having a resolvable prior recipient at rotation time).
  Does not block any live secret or the running cluster's `sops-age` trust
  root — only the rotation *test path* itself is broken.

## Future targets

- **Home lab (on-prem) as a third substrate.** Not in scope for the current
  build — Production stays Digital Ocean cloud VMs, Development stays K3d —
  but it's a researched next step, not a hypothetical: the Home Lab Rack Bill
  of Materials costs two concrete builds (3× MS-01 x86 cluster, or a PiKube ARM
  control plane) plus a dedicated CI+LLM compute server. No current decision
  should foreclose it: keep node provisioning at the Terraform
  `elastic-node-pool` seam (item 1) and the k3s/Helm parity guarantee
  (prod/dev share charts and manifests) so a third substrate can slot in later
  without a redesign.

## Considered and out of scope

- **Fission/kubeless, AppSmith.** Considered from the original service list
  and intentionally dropped — no serverless-functions layer and no low-code
  internal-tool builder in this platform's scope.
- **Mlflow, Benchflow.** Not dropped, not yet decided — see the Platform LLM
  item above and `ailly/developer/research/mlops-tooling.md` (draft, pending
  review).

## Testing harness (cross-cutting)

- **Implement the testing harness.** The testing styles, run commands,
  per-component test contract, CI lanes, repo layout, and tool choices are all
  settled in `DEVELOPMENT.md` (## Testing): `kubeconform`, `helm-unittest`,
  `SLOs`, and `probers`. Build the harness those names refer to: the `mise` test
  tasks, `conftest` policies, `helm-unittest` suites, k3d feature probers, and the
  CI workflows. What's still open — the bootstrap-ordering trigger and the
  deferred decisions (kyverno, terraform apply-based e2e, snapshot-test
  breadth) — is in `TASK-NOTES-testing-harness.md`.
- **Initialize mise.** Settled as the scripting / task runner and tool-version
  pinner for the repo. Create `mise.toml` pinning kubeconform, helm, kubectl, k3d,
  chainsaw, conftest, terraform, tflint, and bats; a `setup` task that installs
  the helm-unittest Helm plugin; and the `test:static` / `test:chart` /
  `test:policy` / `test:feature` / `test:gestalt` / `test:tf` tasks plus the
  `test:push` umbrella. Foundational to the harness above. Consider
  `developer:initialize`.
- **Promote probers to a continuous synthetic-monitoring lane.** The existing
  prober lanes only fire on git activity (`test:feature` per PR, `test:gestalt`
  post-sync), so nothing catches drift or an outage between deploys. Probers
  can't run in-cluster — they test the real Cloudflare-edge request path, and a
  monitor that shares fate with the cluster it watches can't report the outage
  that matters most. Decision, rationale, and where it should run instead:
  `ailly/developer/research/prober-synthetic-monitoring.md`.
  `.github/workflows/watch.yml` lands now as a scheduling/alerting placeholder
  (no live target to probe yet); wire in the real `bats tests/agrippa.bats`
  assertions once staging is live.

## Feature-step deferred decisions: Step 0 (mise + testing harness)

From the feature-step `2026-07-06-A-agrippa-local-k3d/features/step0-mise-testing-harness/design.md`:

- **`terraform` / `tflint` pins and the `test:tf` lane.** Deferred to the cloud
  cycle (research decision 6). These land when cloud work starts and require a
  one-line `[tools]` addition and one umbrella-lane edit. Feature-step omits
  them for the local build since there is no `terraform/` to operate on.

- **`test:gestalt` CI wiring to a staging or live target.** The local
  `test:gestalt` task runs `bats tests/agrippa.bats` against whatever `ENV` and
  host overrides point to (defaulting to `ENV=dev` local k3d). The post-sync CI
  lane that runs against deployed staging or production targets lands with the
  staging cycle. `.github/workflows/watch.yml` remains a placeholder until
  staging exists.

- **Chainsaw assertion breadth and helm-unittest snapshot-test breadth.** The
  `test:feature` k3d loop (create, apply component, run assertions, destroy) is
  wired by Feature 0. The actual chainsaw `.yaml` resource-reconcile assertions
  and helm-unittest snapshot suites are authored per-component in each
  subsequent feature-step.

- **Repoint or drop two dangling citations in `TASKS.md`.** (Research decision 7,
  docs cleanup only.) The references to `TASK-NOTES-testing-harness.md` (line
  112) and `prober-synthetic-monitoring.md` (line 126) name files that do not
  exist. Either replace them with inline notes, or remove them and file a
  separate docs cleanup task if the content is no longer needed.

## Feature-step deferred decisions: Cluster Core (local k3d substrate)

From the feature-step `2026-07-06-A-agrippa-local-k3d/features/cluster-core-k3d/design.md`:

+ **Production substrate.** cloud-init, Terraform, DigitalOcean node pools, the
  `elastic-node-pool` autoscaling seam, and the scale-to-zero GPU pool. Deferred
  to the cloud cycle; the single-node dev config is the local form and the overlay
  seam is preserved.

+ **metallb + `IPAddressPool`.** Logically part of Cluster Core, but delivered by
  the GitOps bootstrap at a sync-wave (research decision 8). Settled in the GitOps
  feature-step; may move into the manual `bootstrap` task if a chicken-and-egg
  surfaces, with no rework here.

+ **k3s version parity with production.** Local pins the k3d default image for
  reproducibility; matching production's exact k3s version is a cloud-cycle
  concern.

## Feature-step deferred decisions: GitOps (ArgoCD app-of-apps, KSOPS/age, local bootstrap)

From the feature-step `2026-07-06-A-agrippa-local-k3d/features/gitops-argocd/design.md`:

+ **Terraform / cloud-init injection of `sops-age` and the `overlays/prod` environment.** Deferred
  to the cloud cycle. The `mise run bootstrap` task and the `secrets/prod/.*` / prod-recipient seam
  are the local stand-ins; these seams are preserved in the git history so the cloud-cycle
  implementation has a clear contract to replace them with.

+ **ArgoCD UI ingress and Tier-1 gating.** Reached by `kubectl port-forward` locally until
  Networking lands. The Istio-Gateway HTTPRoute and (production) Cloudflare Access on the ArgoCD UI
  are Networking / cloud concerns, deferred to the Networking feature-step and cloud cycle.

+ **metallb placement.** Declared in `core` layer and reconciled at a sync-wave. May move into
  the manual `bootstrap` step if a chicken-and-egg surfaces (metallb needed before ArgoCD can pull
  an image on a LoadBalancer IP), with no rework elsewhere. Local k3d's node port-map makes this
  unlikely, since image pulls use the node's own network, not a LoadBalancer IP.

## Feature-step deferred decisions: Networking (Istio + cert-manager)

From the feature-step `2026-07-06-A-agrippa-local-k3d/features/networking-istio/design.md`:

+ **cloudflared and ExternalDNS, `overlays/prod`, and public ACME TLS.** Deferred to the cloud
  cycle. The local CA, `*.nip.io` hostnames, and the `externalIPs` reachability fix are the local
  stand-ins, with seams preserved in the repo for the cloud-cycle implementation.

+ **Per-workload HTTPRoutes and Certificates.** Feature 9 (Workloads) consumes the shared
  Gateway/HTTPRoute/hostname/TLS contract defined here. Auth and Observability consume it for
  their own UIs. None of these per-workload routes or certs are built in this step.

+ **Importing the local CA into the host trust store.** An opt-in operator action; the feature
  test and local development use `curl -k` to accept the deliberately-untrusted local CA.

+ **HTTP→HTTPS redirect HTTPRoute.** The `:80` listener is provisioned on the shared Gateway;
  the redirect route itself is a convention later steps may add. The local `curl -k` path uses
  `:443` directly.

+ **GitOps-native machine-independent IP derivation.** The committed `externalIPs: 172.18.0.3`
  and metallb pool `172.18.255.200-172.18.255.250` are documented defaults for the current
  long-lived `agrippa-dev` cluster, with a manual `docker inspect` / `docker network inspect`
  re-derivation note. A second operator or a `cluster:down`/`up` cycle on the same machine can
  draw a different Docker subnet and break the request path. Moving IP derivation into the build
  (a `mise` task or kustomize component that patches values from `docker` commands at apply time)
  would eliminate this reproducibility gap; parked here pending a cross-cutting bootstrap/build-phase
  decision.

+ **Per-feature Certificates and per-host blast radius.** The design uses one shared
  `agrippa-gateway-tls` Certificate with explicit SANs that every feature appends to. The
  alternative — per-feature `Certificate` objects each contributing its own Secret to separate
  Gateway listener `certificateRefs` — can avoid merge contention if parallel Features 5–8
  contend on the shared file. Kept as designed with a watch-item: if real contention surfaces,
  the first contending feature can split this to per-host certs via a mechanical refactor with
  the Gateway listener accepting multiple `certificateRefs` by SNI.

## Feature-step deferred decisions: Storage (Postgres + Valkey)

From the feature-step `2026-07-06-A-agrippa-local-k3d/features/storage-postgres-valkey/design.md`:

+ **The `DatabaseRole` CRD (CNPG 1.30, 2026-07) — forward-looking watch-item.** The CRD
  promotes role management to its own namespaced CR, fixing `managed.roles`' RBAC-scoping flaw,
  but its first cut supports only certificate-based auth — no `passwordSecret` field. Every
  Feature 5-7 consumer (Auth/Keycloak, Git hosting/Forgejo, Feature flags/Flagsmith) needs a
  plain username/password DSN, so this feature-step uses the stable `managed.roles +
  Database` pair. Revisit when the `DatabaseRole` CRD gains password support.

+ **Credential sealing as a shared `mise seal-secret` helper — potential DRY extraction.** This
  feature-step documents the security-sensitive sealing discipline (generate in memory, encrypt
  immediately, never plaintext to disk, never in argv/shell history) inline in the plan's Steps
  2. Features 5-8 (Auth, Git hosting, Feature flags, Observability) will repeat this pattern.
  Extract to a shared reusable helper when Feature 5 actually repeats it and the correct
  interface becomes evident; the conservative default per the project's YAGNI posture is inline
  now, extract on the rule-of-three (when the second real caller proves the shape).

## Test-quality: bats non-final `[[ ]]` doesn't gate (cross-cutting)

- **`tests/networking.bats` and `tests/storage.bats` carry non-final, non-terminal bare
  `[[ ... ]]` content assertions (e.g. a `*healthy*` glob match, a `2xx/3xx` regex) that do NOT
  actually fail the test on a mismatch** — confirmed empirically against this repo's bats
  1.13.0: `set -e` exempts bash conditional compounds (`[[ ]]`) unless they're the test's final
  command, unlike `[ ... ]` or a `grep -q` pipeline, which do reliably gate. Only each suite's
  `[ "$status" -eq 0 ]` checks and truly-final `[[ ]]` assertions are load-bearing today; the
  in-between content assertions currently pass even on a wrong value. Discovered by the
  `feature-flags-flagsmith` and `git-hosting-forgejo` design-phase authors while writing their
  own feature tests (both rewrote their own new suites to the safe `grep -q`/`[ ]` idiom
  `gitops.bats` already uses). Fix: audit `networking.bats`/`storage.bats` and replace any
  non-final bare `[[ ]]` with an idiom that actually gates. Low urgency (both suites are
  currently green for the right underlying reason, live-verified by their own build phases) but
  a latent false-GREEN risk on any future regression in those two components.
