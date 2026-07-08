# Research: Agrippa Local (k3d, no cloud)

*Reviewed 2026-07-06*

> Project Shape. This research feeds a project-altitude Design phase (one umbrella
> design doc with Prior Art, a feature-step Specification, and a Closing Bell),
> not a single feature design. Long-loop: the draft gate below is cleared by a
> separately dispatched reviewer, so open questions are surfaced, not resolved here.

## Topic and Intent

Original request, verbatim:

> "building out Agrippa locally (k3d, no cloud yet)"

Loosely stated goal, in the operator's framing: stand up a from-scratch, working
copy of a Agrippa self-hosted Kubernetes platform on a local k3d cluster, so that
a operator can develop against a real cluster on a laptop. Build the roadmap in
`docs/developer/TASKS.md` (items 1 through 9), adapted so every step targets k3d
locally. Explicitly park the production substrate (Terraform, cloud-init,
DigitalOcean node pools, Cloudflare Tunnel plus Access, real public DNS and certs)
and the Platform LLM tier (item 10, DavidBot) for later cycles.

Nothing has been built yet. The repository currently holds architecture and
process documents (`README.md`, `ARCHITECTURE.html`, `ROUTING.md`,
`DEVELOPMENT.md`, `GETTING_STARTED.md`), a task tracker
(`docs/developer/TASKS.md`), two committed bats suites (`tests/preflight.bats`,
`tests/agrippa.bats`), a placeholder CI workflow (`.github/workflows/watch.yml`),
and two out-of-scope research notes staged for the Platform LLM cycle. There is no
`mise.toml`, no `charts/`, no `terraform/`, no `.sops.yaml`, and no `.forgejo/`.
An earlier session (2026-06-10) produced the architecture and then ran cleanup,
which deleted its `design.md` by feature-loop convention; `ARCHITECTURE.html` plus
the docs are that design's durable residue and the authoritative Prior Art for
this project.

## Search/Expand

General-lens findings on what a from-scratch, k3d-only Kubernetes GitOps platform
requires. Each roadmap component was checked for whether it runs on k3d as
written, needs a local adaptation, or is fundamentally a cloud-only concern that
should be deferred.

**k3d substrate and load balancing.** k3d runs k3s inside Docker containers. A
stock k3d node image ships Traefik as ingress and ServiceLB (Klipper) as the
LoadBalancer controller. Agrippa uses Istio Gateway as its ingress, so Traefik is
redundant, and `README.md` states dev uses metallb for LoadBalancer IPs. metallb
and ServiceLB both try to own external IPs and conflict, so ServiceLB must be
disabled when metallb is installed. metallb Layer-2 in k3d needs an address pool
inside a k3d Docker network subnet, not a real LAN range. Cluster creation
therefore carries `--k3s-arg --disable=servicelb` and typically also disables
Traefik, plus a metallb install and an `IPAddressPool` scoped to the Docker
network. [1][2]

**Istio ambient plus Gateway API on k3d.** Confirmed viable. Install with the
ambient profile, install the Gateway API CRDs first (they are not bundled), and
set `global.platform=k3d` on the Istio CNI and control-plane charts so ztunnel and
the CNI tolerate k3d's containerized nodes. Istio publishes an explicit k3d
platform-setup page. [3][4]

**cert-manager without real DNS.** Production issues public certs by Cloudflare
DNS-01 ACME. That challenge cannot run against a laptop with no public DNS zone.
The standard local substitute is a SelfSigned `ClusterIssuer` used to bootstrap a
CA `ClusterIssuer` (a self-signed root, then a CA issuer that signs leaf certs for
in-cluster and dev hostnames). Local TLS is then valid but not publicly trusted,
so probes use `curl -k` or trust the local CA out of band. [5]

**ExternalDNS and cloudflared are cloud-edge concerns.** ExternalDNS reconciles
Cloudflare DNS from HTTPRoute annotations, and cloudflared tunnels public traffic
with no open inbound ports. Neither has a job on a single-host k3d cluster with no
public zone and no edge. Local name resolution is handled instead by an
`/etc/hosts` entry, a `*.nip.io` wildcard, or `*.localhost` combined with a k3d
port mapping. Both components are deferred entirely for the local build.

**Longhorn does not run on stock k3d.** This is the sharpest finding. Longhorn
requires `open-iscsi` (the `iscsiadm` binary and a running `iscsid`) on every
node. The k3d node image is deliberately minimal and does not include it, so the
Longhorn manager fails its environment check. Documented workarounds are a custom
k3d node image with `open-iscsi` baked in, running k3d nodes inside a VM that has
`open-iscsi`, or simply not running Longhorn locally and using k3s's built-in
`local-path` provisioner as the dev storage class. This directly stresses the
platform's parity guarantee and is an open decision below. [6][7]

**ArgoCD app-of-apps bootstrap.** The core layer is applied once by hand (helm or
kubectl), after which ArgoCD's root app-of-apps reconciles every subsequent layer,
including itself. Ordering across layers uses the `argocd.argoproj.io/sync-wave`
annotation: CRDs at a low wave, controllers next, custom resources last, so that,
for example, Gateway API and cert-manager CRDs exist before any resource that
references them. `ServerSideApply=true` and `SkipDryRunOnMissingResource=true`
are the usual options for large CRD sets. [8]

**Secrets trust root differs on k3d.** Per `DEVELOPMENT.md`, KSOPS runs as a
repo-server init-container plus sidecar and decrypts sops-encrypted manifests
during `kustomize build`, keyed by an `age` private key mounted from a `sops-age`
Secret in the `argocd` namespace. In production that Secret is injected by
Terraform or cloud-init. On k3d there is no Terraform, so a local bootstrap task
must create the `sops-age` Secret (pulling `agrippa-age-dev` from Bitwarden per
`DEVELOPMENT.md`'s key custody policy) before ArgoCD's first sync. KSOPS with age
in ArgoCD is a well-trodden pattern. [9]

**Postgres-backed platform services are portable.** Keycloak, Forgejo plus
forgejo-runner, and Flagsmith are all ordinary Helm charts backed by the single
Postgres instance. They run on k3d unchanged once storage exists, subject only to
the reduced-replica dev overlay. The LGTM observability stack (Loki, Grafana,
Tempo, Mimir) plus a Alloy DaemonSet likewise runs on k3d; its Rook-Ceph object
backend is explicitly deferred in the architecture until block volumes are
outgrown, so locally the signal stores stay on the dev storage class.

**Cloudflare Access (Tier-1) has no local equivalent.** Edge auth happens at
Cloudflare before traffic reaches the cluster. On k3d there is no edge, so Tier-1
gated apps (trips, ArgoCD UI, Grafana) cannot be edge-gated locally. This has a
concrete consequence for the committed test suite, recorded under Falsification
and Resolved Decisions.

## Libraries & Skills

**Before doing any work in this project, load these skills via the active
harness's skill-loading mechanism:**

- **`developer:initialize`** for the "Initialize mise" prerequisite. TASKS.md
  itself names it ("Consider `developer:initialize`") for standing up `mise.toml`,
  tool pins, and the `setup` and `test:*` tasks.
- **`developer:ailly` project shape** references
  (`shapes/project/project-cycle.md`, `closing-bell.md`, `release-flags.md`) for
  the Design phase, since this is a multi-feature project with a Closing Bell and a
  release gate.
- **`research:public`** and **`research:codebase`** for the per-component design
  research each roadmap feature-step will still need.

**No library-shipped agentic skill exists for the infrastructure this project
touches.** A deliberate check of the relevant tools (k3d, k3s, Helm, ArgoCD,
Istio, Gateway API, metallb, cert-manager, Longhorn, Postgres, Valkey, Keycloak,
Forgejo, Flagsmith, the Grafana LGTM stack, SOPS or KSOPS, kubeconform,
helm-unittest, conftest, chainsaw, bats, mise) surfaced no `SKILL.md`, MCP server,
or `skills/` directory shipped by any of them. This omission is recorded as a
finding so downstream phases do not assume one is missing by accident. The
authoritative in-repo contracts stand in for a framework skill: `DEVELOPMENT.md`
(## Testing and ## Secrets) fixes the test tooling, per-component test contract,
CI lanes, and the SOPS plus age wiring; `ROUTING.md` fixes the domain-versus-path
policy; `ARCHITECTURE.html` fixes the component topology and overlays.

Primary library docs that matter for the build, with the closest worked examples,
are cited in Sources: Istio's own k3d setup page and ambient install [3][4], the
k3d and k3s issues documenting the Longhorn or iscsi limitation [6][7], the
metallb-on-k3s conflict guidance [1][2], cert-manager's SelfSigned and CA issuer
docs [5], ArgoCD sync-waves [8], and KSOPS-with-age-in-ArgoCD [9].

## Falsification/Refine

Specific-lens right-sizing.

**Size: project, not a feature or a bug.** The deliverable is a working platform
composed of many interdependent components that deliver value only as a whole, run
over days, and each warrant their own design-plan-build cycle. This is the Project
Shape by definition, matching TASKS.md's existing "build in order, each item gets
its own design to plan to implement cycle" framing.

**Off-the-shelf: rejected, on purpose.** A managed cluster (DOKS, GKE, EKS) or a
prebuilt platform (a full Rancher or an OpenShift Local) would each stand up
faster, but the project's whole intent is a self-managed, cloud-portable k3s
platform whose local and production substrates share Helm charts and manifests.
An off-the-shelf platform would defeat the parity guarantee that is the point.
k3d is itself the off-the-shelf choice at the substrate layer: it is the sanctioned
local equivalent of production k3s.

**Smallest version that still meets the intent.** The smallest honest slice is not
one component. It is the foundation plus enough of the GitOps spine to prove the
parity model works locally: the tooling and test harness, a k3d cluster, a working
ingress and local TLS, ArgoCD managing itself and at least one storage-backed
service, and one workload reachable through the Istio Gateway. Everything past that
is repetition of the same pattern per component. The refine pass therefore keeps
all of items 1 through 9 in scope but reorders them so the cross-cutting
prerequisites (mise, test harness) and the GitOps spine land before the leaf
services.

**Claims falsified against reality.** Two "same charts everywhere" assumptions did
not survive contact:

1. Longhorn does not run on stock k3d (no `open-iscsi`), so the storage layer's dev
   form is not merely a replica-count overlay. It needs a real decision (see
   Resolved Decisions). [6][7]
2. The committed `tests/agrippa.bats` gestalt cannot pass on k3d as written. Its
   trips test asserts a 302 redirect to `cloudflareaccess.com`, which requires the
   Cloudflare edge that does not exist locally, and it has no dev branch. Separately,
   its observability test's dev branch keys off a `GESTALT_ENV` variable that
   `setup()` never sets (setup sets `ENV`), so the dev path is currently unreachable.
   The local build needs either a dev-aware gestalt or a separate local suite. This
   is a latent inconsistency in an already-committed artifact, not a new design gap.

## Scope

### In scope (local, k3d target)

Cross-cutting prerequisites, landed first:

- **Initialize mise.** `mise.toml` pinning kubeconform, helm, kubectl, k3d,
  chainsaw, conftest, bats (and terraform plus tflint as inert pins, see open
  question 6); a `setup` task installing the helm-unittest Helm plugin; and the
  `test:*` tasks.
- **Testing harness.** `test:static` (kubeconform plus conftest, including the
  plaintext-Secret guard from `DEVELOPMENT.md` ## Secrets), `test:chart`
  (helm-unittest), `test:policy` (conftest Rego), and `test:feature` (k3d up, apply
  the component, chainsaw plus bats probes, k3d down), plus the `test:push`
  umbrella.

Roadmap items 1 through 9, in their k3d form:

1. **Cluster core.** A `k3d` cluster definition (config file plus a mise task) in
   place of Terraform, cloud-init, and DigitalOcean provisioning. Single node,
   ServiceLB and Traefik disabled, metallb installed with a Docker-network address
   pool. No GPU pool.
2. **Networking.** Istio ambient plus Gateway API with `global.platform=k3d`;
   cert-manager with a SelfSigned-to-CA local issuer. cloudflared and ExternalDNS
   excluded; local hostname resolution via hosts entries, `nip.io`, or
   `*.localhost` plus port mapping.
3. **Storage.** Postgres and Valkey Helm charts. Longhorn's local form is an open
   decision (below); the dev storage class is either `local-path` or a Longhorn
   made to work through a custom node image or VM. DR tiers (pg_dump and Longhorn
   backups to off-cluster S3) deferred; local DR is GitOps-only (RPO 0 for
   declarative state).
4. **GitOps.** ArgoCD app-of-apps, core layer applied manually once then
   self-managed, sync-waves for CRD ordering, KSOPS repo-server sidecar, and a
   local `sops-age` bootstrap task in place of Terraform's Secret injection.
   `overlays/dev` versus `overlays/prod`.
5. **Git hosting.** Forgejo plus forgejo-runner, Postgres-backed. GitHub
   push-mirror works from k3d if outbound is available; treat mirroring as optional
   locally.
6. **Observability.** LGTM stack plus Alloy, reduced replicas, signal stores on the
   dev storage class. Rook-Ceph deferred. This is what the dev gestalt's Grafana
   probe exercises.
7. **Auth.** Keycloak (Tier-2 OIDC), Postgres-backed. Cloudflare Access (Tier-1)
   excluded locally; dev workloads are public or Keycloak-gated.
8. **Feature flags.** OpenFeature plus Flagsmith, Postgres-backed.
9. **Workloads.** davidsouther.com, /blog, agathon, ailly.dev, and a local trips,
   deployed on k3d with dev hostnames and reachable through the Istio Gateway.
   Trips' Cloudflare Access policy port to Terraform and its CI port to Forgejo
   Actions are prod or post-git-hosting concerns and are deferred for the local
   build.

### Out of scope

- **Item 10, Platform LLM and DavidBot**, entirely. The two staged research notes
  under `ailly/developer/research/` belong to that later cycle.
- **All cloud and Terraform provisioning**: DigitalOcean node pools, the
  `elastic-node-pool` autoscaling seam, cloud-init user-data, the GPU pool.
- **Cloudflare edge**: Tunnel, Access (Tier-1), real public DNS, public ACME certs.
- **Off-cluster S3 disaster recovery** and Rook-Ceph object storage.
- **Home lab substrate**, staging and production environments, and the post-sync
  `test:gestalt` and `test:tf` CI lanes (no deployed target, no `terraform/` to
  validate yet).

### Feature-step decomposition (for the Design phase)

Sequential and parallel relationships the project plan will formalize. Step 0 is
the shared contract every later step depends on.

- **Step 0, prerequisites (land first):** mise init plus testing harness. Shared
  contract for every feature-step's tests and tooling.
- **Cluster core.** No dependencies, can start after Step 0.
- **GitOps (ArgoCD).** Depends on: Cluster core. Becomes the delivery mechanism for
  every layer after it.
- **Networking (Istio, Gateway API, cert-manager local).** Depends on: Cluster
  core; applied by GitOps. Shared contract: the Gateway and HTTPRoute conventions
  and the local hostname or TLS scheme every workload consumes.
- **Storage (Postgres, Valkey, storage-class decision).** Depends on: Cluster core,
  GitOps. Shared contract: the storage class and the per-app DB naming that Auth,
  Git hosting, Flags, and Observability all consume.
- **Auth (Keycloak)**, **Git hosting (Forgejo)**, **Feature flags (Flagsmith)**.
  Each Depends on: Storage. Parallel with each other (all Postgres-backed, no
  ordering between them).
- **Observability (LGTM plus Alloy).** Depends on: Storage (signal stores need
  PVCs). Parallel with the three Postgres services.
- **Workloads.** Depends on: Networking and Auth (and Feature flags where used).

**Closing Bell candidate.** The nearest existing statement of done is
`tests/agrippa.bats` run against the local k3d ingress with `PUBLIC_HOST`,
`TRIPS_HOST`, and `DASHBOARD_HOST` overrides and a dev environment. It needs the
Tier-1 adaptation noted above before it can serve as the local Closing Bell. The
Design phase should record the Closing Bell's exact form and path.

## Resolved Decisions

Answered by this research:

- The project is Project Shape; roadmap 1 through 9 are its feature-steps; item 10
  is out of scope.
- Istio ambient plus Gateway API, cert-manager (local CA issuer), Keycloak,
  Forgejo, Flagsmith, LGTM, Postgres, and Valkey all run on k3d. Their local form
  is primarily the reduced-replica dev overlay plus the local issuer and hostname
  scheme.
- cloudflared, ExternalDNS, Cloudflare Access, public DNS and certs, Terraform and
  cloud-init and DigitalOcean, the GPU pool, off-cluster S3 DR, and Rook-Ceph are
  all deferred for the local build, with the seams (overlays, the
  `elastic-node-pool` seam, the S3 "one Terraform var") preserved so production can
  slot in later.
- The GitOps spine (ArgoCD app-of-apps, sync-waves, KSOPS) is the load-bearing
  local pattern; the cross-cutting prerequisites (mise, test harness) land before
  it.
- Note only, no halt: the two staged research notes and the TASKS.md item 10 both
  postdate the original architecture and confirm the Platform LLM tier is a
  separate future cycle, which reinforces this session's out-of-scope boundary
  rather than reframing it.

### Resolved by the long-loop reviewer (2026-07-06)

Each item below was researched against the repo, the in-repo contracts, and public
documentation, and decided to the conservative default. No escalation trigger
(irreversible, out of recorded scope, or underdetermined) fired for any item, so the
draft gate is cleared.

**1. Longhorn on k3d. Decided: adopt k3s `local-path` as the dev storage class, and
keep Longhorn declared in the app-of-apps but scoped out of the `overlays/dev`
layer.** Verified the constraint independently rather than on the research's word:
Longhorn's manager fails its environment check unless `open-iscsi` (`iscsiadm` plus a
running `iscsid`) is present on every node, and the k3d/rancher k3s node image is
deliberately minimal and cannot install it (longhorn/longhorn #5693, k3d #719 and
#478, k3s #9987). `local-path` is a documented, reversible fallback needing no custom
node image or VM. It matches the parity-seam pattern the repo already uses (metallb
replaces cloudflared, reduced replicas, Rook-Ceph deferred): production storage stays
Longhorn, only the dev overlay differs. Reversible, inside the artifact's storage
scope, and determined by the docs, so the conservative default holds. A custom-node-
image or VM path stays available if a later cycle wants Longhorn parity locally.

**2. Local ingress and DNS scheme. Decided: wildcard `nip.io` hostnames resolving to
loopback, reached through a k3d host port-map of the Istio gateway (for example
`-p "443:443@loadbalancer"`), with metallb still installed for in-cluster LoadBalancer
IPs.** Weighed the three candidates against the operator's macOS target (Darwin,
Docker Desktop). `/etc/hosts` entries mutate the host and need root per hostname;
`*.localhost` resolution is inconsistent across resolvers and the curl path. `*.nip.io`
needs no host-file edits and no root, resolves arbitrary subdomains, and matches the
subdomain-shaped host overrides the committed `tests/agrippa.bats` already assumes
(`trips.`, `dashboard.` prefixes). On macOS the metallb IP inside the Docker network is
not routable from the host, so the k3d loadbalancer port-map (a separate proxy,
independent of the disabled ServiceLB) carries host `:443` to the gateway and
`127.0.0.1.nip.io` subdomains resolve there. This is the least host-mutating,
cross-platform default and fixes how the bats host overrides are populated. Reversible
and in scope.

**3. Local TLS trust. Decided: cert-manager issues real certs from a local
SelfSigned-to-CA issuer, probes use `curl -k`, and the local gestalt asserts TLS is
present but does not assert public trust.** The SelfSigned-to-CA mechanism is already
fixed by the research and cert-manager docs. Between `curl -k` and importing the CA
into the host trust store, `-k` is the conservative default: importing a CA mutates
system trust, which is invasive and the closest thing here to hard to reverse, whereas
`-k` is a per-probe flag that leaves the host untouched. The committed suite already
probes over `https://`, so adding `-k` on the local path is the minimal change. Keeping
TLS terminated at the gateway preserves request-path parity without host trust-store
changes. mkcert or CA-import stays an opt-in for an operator who wants a green browser
lock.

**4. sops-age dev trust root. Decided: a mise bootstrap task creates the `sops-age`
Secret in the `argocd` namespace from Bitwarden item `agrippa-age-dev` before ArgoCD's
first sync.** This confirms the documented analog, not a new design: `DEVELOPMENT.md`
(## Secrets) fixes that Terraform or cloud-init injects the `sops-age` Secret as "the
whole in-cluster trust root," pulled from Bitwarden at apply time with no standing local
key file (`bw get notes agrippa-age-<env>`). No Terraform runs locally, so the mise task
is the only creator on the local path. It is idempotent and reversible, in scope (GitOps
plus secrets), and fully determined by the repo's key-custody policy.

**5. Gestalt adaptation (existing-artifact bug). Decided: fix and extend the committed
`tests/agrippa.bats` in place rather than fork a separate local suite; the edit itself
is build-phase work, recorded here as direction.** Confirmed both defects against the
file: `setup()` sets `ENV` (line 33) while the observability test branches on
`GESTALT_ENV` (line 51), which nothing sets, so the dev path is dead code; and the trips
test unconditionally asserts a `302` to `cloudflareaccess.com` (lines 69-76) with no dev
branch, which cannot pass without the Cloudflare edge that does not exist on k3d. Fixing
in place is the conservative default because `DEVELOPMENT.md` (## Probers, repo layout)
prescribes one bats suite per feature, the file's own header states its targets are
overridable "so the same test can run against a local K3d ingress," and a parallel suite
would duplicate the public-site and observability probes and drift out of step. Build-
phase direction inside this decision: collapse the environment switch onto the single
`ENV` variable `setup()` already sets (retire `GESTALT_ENV`), and give the trips test a
dev branch asserting local gating appropriate to k3d (Keycloak/OIDC or plain
reachability) instead of the absent Cloudflare Access redirect. The exact dev-mode trips
assertion is a Design-phase detail. Reversible under git, in scope (this suite is the
Closing Bell candidate).

**6. mise terraform and tflint pins. Decided: omit the terraform and tflint pins and the
`test:tf` lane for the local build; they land with the deferred cloud cycle.** Low
stakes and reversible either way, so the tie-breaker is the artifact's own recorded
Scope, which lists cloud and Terraform provisioning and the `test:tf` CI lane as out of
scope ("no `terraform/` to validate yet"). Pinning tools that have nothing to operate on
locally is speculative, and omitting them keeps the mise manifest to what the local build
actually exercises. Adding them the day cloud work starts is a one-line change, so
nothing is foreclosed. This resolves the item toward the smaller, scope-consistent
footprint the research invited.

**7. Dangling TASKS.md references. Decided: fold the still-live testing-harness
decisions into the project design doc, do not recreate the missing note files, and let
the synthetic-monitoring note's decisions defer with the cloud cycle.** Confirmed both
files are absent: `TASK-NOTES-testing-harness.md` and
`ailly/developer/research/prober-synthetic-monitoring.md` exist only as citations in
`TASKS.md` and this research, never as files. Folding into the design doc is the
conservative default because the long-loop reference (section 3) records decisions in
place and warns that a separate decision log splits the audit trail, which is exactly the
failure these orphaned citations already show. The testing-harness note's locally-
relevant open items (bootstrap-ordering trigger, snapshot-test breadth) belong in the
project design doc that item 8 and Step 0 feed; its cloud or policy items (kyverno,
terraform-apply-based e2e) defer with the out-of-scope cloud work, as does the entire
synthetic-monitoring note, which probes a real Cloudflare edge the Scope excludes and for
which `.github/workflows/watch.yml` already stands as an inert placeholder. Recommend the
Design or cleanup phase also repoint or drop the two dangling citations in `TASKS.md`;
that edit sits outside this reviewer's artifact.

**8. Manual bootstrap boundary. Decided: the hand-applied core is the minimum that gets a
decrypting ArgoCD running, and everything else is ArgoCD-reconciled via sync-waves.** The
manual set is: k3d cluster create (ServiceLB and Traefik disabled), the `sops-age` Secret
(decision 4), ArgoCD itself with its KSOPS-enabled repo-server, then the root app-of-apps
applied once. metallb, the Gateway API CRDs, Istio, cert-manager, storage, and workloads
all move under ArgoCD at their sync-waves. This matches the app-of-apps statement the
research verified ("core layer applied once by hand, then ArgoCD reconciles every
subsequent layer, including itself") and `DEVELOPMENT.md`'s wiring, where Terraform or
cloud-init inject only `sops-age` and the repo-server init-container. Keeping the
imperative surface minimal maximizes the GitOps parity that is the project's whole intent,
so ArgoCD is reached by `kubectl port-forward` until ingress exists. This is a build
sequence and fully reversible. The one dependency nuance (metallb sits inside the
"Cluster core" feature-step yet is GitOps-managed here) is resolvable in the design, and
if a chicken-and-egg surfaces during build, metallb moves into the manual step with no
rework elsewhere. Encode this boundary as the `bootstrap` mise task.

## Sources

- [1] "How to Install MetalLB on K3s and Fix ServiceLB Conflicts," OneUptime Blog,
  2026-02-20. https://oneuptime.com/blog/post/2026-02-20-metallb-k3s-servicelb-conflicts/view
- [2] "How to Disable Traefik in K3s," OneUptime Blog, 2026-03-20.
  https://oneuptime.com/blog/post/2026-03-20-k3s-disable-traefik/view
- [3] "Istio / k3d," Istio Documentation, platform-setup.
  https://istio.io/latest/docs/setup/platform-setup/k3d/
- [4] "Istio / Get Started with Ambient Mesh" and "Platform-Specific
  Prerequisites," Istio Documentation.
  https://istio.io/latest/docs/ambient/getting-started/ ,
  https://istio.io/latest/docs/ambient/install/platform-prerequisites/
- [5] "SelfSigned" and "CA" issuer configuration, cert-manager Documentation.
  https://cert-manager.io/docs/configuration/selfsigned/
- [6] "Using Longhorn in k3d," k3d-io/k3d Discussion #478, and "[FEATURE] Support
  Longhorn / iscsi," k3d-io/k3d Issue #719.
  https://github.com/k3d-io/k3d/discussions/478 ,
  https://github.com/k3d-io/k3d/issues/719
- [7] "iscsiadm / open-iscsi setup (for longhorn)," k3s-io/k3s Discussion #9987, and
  Longhorn install prerequisites (open-iscsi on every node).
  https://github.com/k3s-io/k3s/discussions/9987
- [8] "Sync Phases and Waves," Argo CD Documentation.
  https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/
- [9] "KSOPS," viaduct-ai/kustomize-sops, and "A Guide to GitOps and Secret
  Management with ArgoCD and SOPS," Red Hat Blog.
  https://github.com/viaduct-ai/kustomize-sops ,
  https://www.redhat.com/en/blog/a-guide-to-gitops-and-secret-management-with-argocd-operator-and-sops

In-repo Prior Art (authoritative, not external): `ARCHITECTURE.html`, `README.md`,
`ROUTING.md`, `DEVELOPMENT.md`, `GETTING_STARTED.md`, `docs/developer/TASKS.md`,
`tests/preflight.bats`, `tests/agrippa.bats`.
