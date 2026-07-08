# Research: Networking (Istio + cert-manager)

*Reviewed 2026-07-08*

> Feature-step research (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 3: Networking (Istio +
> cert-manager)** of that project's plan. Long-loop: the draft gate below is
> cleared by a separately dispatched research-and-decide reviewer, so the open
> items below are surfaced and, where research determines a clear answer,
> resolved — not left as unresolved questions for a human to pick up mid-session.
>
> A separately dispatched long-loop reviewer cleared this research draft gate on
> 2026-07-08. The three still-open items are resolved to the conservative default
> in the *Resolved by the long-loop reviewer* block under Resolved Decisions; the
> highest-risk item (the Gateway `Service` host-reachability) was validated by an
> empirical spike on the live `k3d-agrippa-dev` cluster, then the cluster was
> returned to its pristine pre-spike state. No escalation trigger fired.

## Topic and Intent

Original request, verbatim (from the dispatching coordinator's task framing for
this feature-step):

> "Feature 3: **Networking (Istio + cert-manager)**. Read these existing
> artifacts first for full context (all already-cleared, Reviewed, not draft)"

and, the specific open question this research was asked to resolve, verbatim:

> "does metallb's actual installation land as part of THIS feature-step's own
> scope (most likely, since it's a `core`-layer, Gateway-adjacent prerequisite
> with no other owner), or does it belong to a different feature-step?"

Loosely stated goal, in the project's own framing (`plan.md` § Feature 3): stand
up Istio ambient plus Gateway API with `global.platform=k3d` (Gateway API CRDs
installed first), and cert-manager with a SelfSigned→CA local `ClusterIssuer`
chain, applied through the GitOps spine (Feature 2) into the `core` layer's
`overlays/dev`. cloudflared and ExternalDNS are excluded; local name resolution
is `*.nip.io` loopback plus the k3d port-map; local TLS is real-but-not-publicly-
trusted, probed with `curl -k`. This feature-step **defines the shared contract**
every later UI-exposed service and workload consumes: the Gateway + HTTPRoute +
local-hostname + TLS scheme (`design.md` § Shared Contracts;
`plan.md` § Shared Contracts).

## Search/Expand

General-lens findings on what a local, GitOps-managed Istio ambient + Gateway API
+ cert-manager + metallb stack requires on this specific k3d cluster. Full
citations and the falsification pass are in
`research/public.md`; this section synthesizes the findings that bear on scope
and design.

**Istio ambient on k3d needs more than `global.platform=k3d`.** That flag handles
k3s's nonstandard CNI paths in general, but k3s releases after v1.31.6/v1.32.2
moved the CNI plugin directory again (to
`/var/lib/rancher/k3s/agent/etc/cni/net.d`), and the upstream tracking issue was
closed stale with no fix. The documented mitigation is an **explicit** Helm
override on the `istio-cni` chart —
`--set cniConfDir=/var/lib/rancher/k3s/agent/etc/cni/net.d --set
cniBinDir=/var/lib/rancher/k3s/data/current/bin/` — applied via the Helm chart
directly (a separate, open Istio issue reports the `istioctl`/IstioOperator
install path ignoring these overrides). Agrippa's committed
`k3d/agrippa-dev.yaml` pins `rancher/k3s:v1.35.5-k3s1` — confirmed live this
session (`kubectl get nodes` reports `v1.35.5+k3s1`) — well past both break
points, so this is a near-certain hit for this feature-step's build, not a
hypothetical hardening step.

**Gateway API CRDs are plain manifests, no official Helm chart yet** (open
upstream feature request). The standard channel (`GatewayClass`, `Gateway`,
`HTTPRoute`, `ReferenceGrant`) is sufficient for this feature's contract and
installs via a single `kubectl apply --server-side` against a pinned release
tag's `standard-install.yaml`.

**cert-manager's SelfSigned→CA bootstrap is a fixed, three-object pattern**,
confirmed against the primary docs: a `SelfSigned` `ClusterIssuer` issues a
self-signed root `Certificate` (`isCA: true`) into a Secret, and a second `CA`
`ClusterIssuer` references that Secret to sign every downstream leaf
`Certificate`. This matches the project's already-settled decision 3 (local TLS,
`curl -k`); only the concrete manifests are this feature-step's own work.

**metallb is CRD-configured** (`IPAddressPool` + `L2Advertisement`, current
stable v0.16.1), and every practical k3d+metallb worked example sizes the pool
from the cluster's own Docker network subnet. Verified live this session:
`k3d-agrippa-dev`'s Docker network is `172.18.0.0/16`, and the sole server node
(`k3d-agrippa-dev-server-0`) sits at `172.18.0.3`. A high, unlikely-to-collide
slice such as `172.18.255.200-172.18.255.250` follows the documented pattern.

**Newly surfaced, load-bearing risk: k3d's host port-map and metallb's floating
IP do not obviously compose.** This is the most significant finding of this
research pass and is not addressed by any prior artifact in this project.
k3d's built-in loadbalancer (`k3d-proxy`) is a **static, per-node TCP
passthrough** — a port mapped with `nodeFilters: [loadbalancer]` is "proxied to
the same ports on all server nodes," with no awareness of Kubernetes Service
objects or metallb. Istio's own official k3d guide works with this passthrough
only because it leaves **ServiceLB (Klipper) enabled** (disabling only Traefik);
Klipper's actual mechanism is a per-node iptables rule that DNATs *any* packet
addressed to that node's own IP on the Service's port to the Service's
ClusterIP — i.e., Klipper is what makes "the same port on every node" resolve to
something real. Agrippa's already-cleared `cluster-core-k3d` feature-step
deliberately disabled ServiceLB in favor of metallb (to avoid the two
LoadBalancer controllers fighting over IPs). metallb's Layer2 mode does not
perform Klipper's "any traffic on my own node IP" trick; it answers ARP for, and
kube-proxy DNATs traffic addressed to, a specific floating IP — not the node's
own primary address. No source found in this research states "ServiceLB
disabled + metallb Layer2 + k3d's static port-map" as a verified working
combination; the worked examples that do reach a metallb IP from a macOS host
instead bypass k3d's port-map with OS-level routing hacks (a TunTap bridge plus
manual route-table edits), which the project's own cleared design does not use
and which its own source describes as a "hack."

The most promising fix, inferred (not found stated verbatim as a named
k3d+metallb recipe) from standard Kubernetes Service semantics plus how Klipper
is documented to work internally: set the Istio Gateway `Service`'s
`spec.externalIPs` to the k3d server node's own container IP (`172.18.0.3` on
the current live cluster) alongside its `type: LoadBalancer` /
`gatewayClassName: istio`. `externalIPs` is a standard field kube-proxy honors
identically to a LoadBalancer ingress IP: it DNATs any packet addressed to that
IP on the Service's port to the Service's endpoints — functionally the same
trick Klipper performs, without re-enabling ServiceLB or touching the already-
cleared cluster substrate. This needs an empirical spike early in this
feature-step's build, before the Gateway `Service` shape is finalized. Fallbacks
if it does not verify: `hostNetwork`/`hostPort` on the ingress-gateway pod, or
(least preferred, re-litigates a cleared decision) re-enabling Klipper for the
Gateway Service specifically.

## Libraries & Skills

**Before doing any work in this feature, load these skills via the active
harness's skill-loading mechanism:** none — carried forward unchanged from the
project's own `research.md` and `design.md` § Libraries & Skills:
`developer:initialize` (for any residual `mise` tool-pin work — this feature
adds no new mise-managed CLI beyond what's already pinned, since Istio,
cert-manager, Gateway API, and metallb are all installed as in-cluster
Kubernetes resources via ArgoCD, not as local CLIs; `istioctl` stays optional/
not pinned per the finding above that the Helm-direct install path is preferred
over `istioctl`/IstioOperator for this exact k3s-version risk), `research:public`
and `research:codebase` (already exercised by this document), and the
`developer:ailly` project-shape references.

**No library-shipped agentic skill exists for Istio, Gateway API, cert-manager,
or metallb.** This reconfirms, per-component, the project's already-recorded
top-level finding (`research.md` § Libraries & Skills: "A deliberate check of
the relevant tools... surfaced no `SKILL.md`, MCP server, or `skills/` directory
shipped by any of them"). Nothing new surfaced in this feature-scoped pass.
`ARCHITECTURE.html` (the app-of-apps view and the Request Path view), `ROUTING.md`
(the Gateway API `HTTPRoute` precedence and multi-namespace-attachment findings
already cited there — §3, already sourced to the Gateway API spec and two Istio
issues), and `DEVELOPMENT.md` remain the authoritative in-repo contracts this
feature-step builds to.

**Per-library docs review**, closest worked examples included, full citations in
`research/public.md`:

- **Istio (ambient + Gateway API + CNI).** Getting-started:
  `istio.io/latest/docs/setup/platform-setup/k3d/` and
  `istio.io/latest/docs/ambient/install/platform-prerequisites/`. Closest worked
  recipe for the CNI-path risk: the Helm `--set cniConfDir=... --set
  cniBinDir=...` override pattern (public.md [4]). No skill.
- **Gateway API.** Getting-started: `gateway-api.sigs.k8s.io/guides/getting-started/introduction/`.
  Closest worked example for the Gateway/HTTPRoute shape: Istio's own
  `istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/`, already
  cited by `ROUTING.md`. No skill.
- **cert-manager.** Getting-started: `cert-manager.io/docs/configuration/selfsigned/`
  and `cert-manager.io/docs/configuration/ca/`. Closest worked example: the
  three-object SelfSigned→root-Certificate→CA-ClusterIssuer chain quoted
  verbatim in `research/public.md`. No skill.
- **metallb.** Getting-started: `metallb.universe.tf/installation/` and
  `metallb.universe.tf/configuration/`. Closest worked examples: the two k3d+
  metallb blog walkthroughs cited in `research/public.md` (pool CIDR sizing from
  `docker network inspect`). No skill.

## Falsification/Refine

Specific-lens right-sizing.

**Size: one feature-step, already fixed by the project plan.** `plan.md` names
this Feature 3 with an explicit scope (Istio ambient + Gateway API +
cert-manager) and an explicit deliverable (the Gateway/HTTPRoute/hostname/TLS
shared contract). Nothing in this research pass argues for splitting it further
or merging it with an adjacent feature; the metallb question (below) is the one
genuine boundary question this research was asked to settle, and it settles
inside this feature-step, not as a reason to resize it.

**Off-the-shelf: already decided upstream, not re-litigated here.** Istio
ambient, Gateway API, cert-manager, and metallb are the project's own prior
selections (`README.md`, `ARCHITECTURE.html`, the project `research.md`); this
feature-step's job is landing them locally, not choosing among alternatives. No
new off-the-shelf substitute surfaced in this pass that would change that.

**Smallest version that still meets the intent.** The shared contract this
feature owes (Gateway + HTTPRoute + hostname + TLS) only needs: one shared Istio
Gateway listener terminating TLS on `:443` (SNI or per-host `Certificate`s), the
SelfSigned→CA `ClusterIssuer` chain producing that TLS material, metallb
providing the Gateway `Service`'s LoadBalancer IP, and the Gateway API CRDs
installed ahead of all of it. It does **not** need per-workload `HTTPRoute`s or
`Certificate`s — those are Feature 9's (Workloads) job, consuming this
feature-step's contract. **A concrete, low-cost feature-test target already
exists and is worth calling out for the design phase to pick up**: the
`gitops-argocd` feature-step's own design explicitly deferred "ArgoCD UI ingress
and Tier-1 gating" to Networking ("reached by `kubectl port-forward` locally;
the Istio-Gateway HTTPRoute... are Networking / cloud concerns" —
`gitops-argocd/design.md` § Deferred decisions). Routing ArgoCD's own UI through
the new Gateway + a cert-manager `Certificate` gives this feature-step an
end-to-end reachability proof using a service that already exists, at zero new
workload cost, and simultaneously resolves that deferred item. This is a
recommendation for the design phase, not a decision made here.

**Claims falsified against reality.** Two assumptions carried forward from the
project's top-level research did not fully survive contact at this
feature-scoped depth:

1. `global.platform=k3d` alone does not guarantee Istio CNI works on this
   cluster's pinned k3s version; an additional, explicit `cniConfDir`/
   `cniBinDir` Helm override is needed (see Search/Expand).
2. The composition "ServiceLB disabled (cluster-core-k3d) + metallb + k3d's
   static host port-map" is not a documented, verified pattern anywhere found in
   this pass; it needs either an `externalIPs` addition to the Gateway `Service`
   (this research's recommendation) or one of the fallbacks listed above, verified
   empirically early in the build.

## Scope

### In scope (this feature-step)

- **Gateway API CRDs** (standard channel), installed ahead of everything that
  references them (cert-manager's own CRDs also precede its controller;
  Istio's CRDs precede istiod).
- **metallb**, CRD-configured (`IPAddressPool` + `L2Advertisement`), with a pool
  sized from the live `k3d-agrippa-dev` Docker network (`172.18.0.0/16` at time
  of writing — confirm at build time, since it is assigned per cluster-create
  and could change if the cluster is recreated).
- **cert-manager**, its CRDs, controller, and the SelfSigned→CA `ClusterIssuer`
  chain that every later `Certificate` (this feature-step's own Gateway
  certificate, and every workload's certificate in Feature 9) issues from.
- **Istio ambient** (`istio-base`, `istiod`, `istio-cni` with the k3s-version-
  specific CNI path overrides, `ztunnel`), with `global.platform=k3d`.
- **One shared Istio `Gateway`** (Gateway API `Gateway` resource,
  `gatewayClassName: istio`) terminating TLS on `:443`, backed by a `Service`
  whose host-reachability mechanism (metallb-assigned IP, `externalIPs`, or a
  fallback) is this feature-step's own artifact decision, verified empirically.
- **The `*.nip.io` + `127.0.0.1` loopback hostname scheme** already fixed by the
  project's decision 2 and design's resolved item 6 — this feature-step
  finalizes the exact pattern (`<prod-host>.127.0.0.1.nip.io`) against the real
  Gateway.
- **Fine-grained `argocd.argoproj.io/sync-wave` annotations within `core`'s own
  resources** (CRDs lowest, controllers next, `ClusterIssuer`/`IPAddressPool`/
  `Gateway` last) — the `gitops-argocd` feature-step fixed only the
  cross-layer wave numbers (`core=0`, `storage=1`, ...); the ordering *inside*
  `core` is this feature-step's to define, per its own design's "starting
  scheme, refinable as layers land."
- **How `core/overlays/dev/kustomization.yaml` pulls in four separate upstream
  Helm charts (or raw manifests) under one ArgoCD Application** — a concrete
  artifact decision the design phase must make (a nested app-of-apps of
  per-component child Applications inside `core`, ArgoCD's multi-source
  Applications feature, or Kustomize's `helmCharts:` inflation generator are the
  three standard patterns; none is fixed by any existing cleared artifact).

### Out of scope (deferred, per already-cleared parent artifacts)

- **cloudflared and ExternalDNS** — cloud-edge concerns, excluded per the
  project's top-level research.
- **Per-workload `HTTPRoute`s and `Certificate`s** — Feature 9 (Workloads)
  consumes this feature-step's Gateway/HTTPRoute/TLS contract; it does not
  create it.
- **`overlays/prod`** — a seam, not built.
- **Importing the local CA into the host trust store** — stays an opt-in
  operator action (project decision 3); probes use `curl -k`.

## Resolved Decisions

Answered by this research:

- **The open question this research was dispatched to resolve: where does
  metallb's actual installation land? Decided: inside this feature-step
  (Networking / Feature 3), as part of `core/overlays/dev`, alongside the
  Gateway API CRDs, cert-manager, and Istio it already ships next to.**
  Rationale: `apps/core.yaml` (already committed by `gitops-argocd`) carries the
  comment "Core owns metallb, Gateway API CRDs, cert-manager & istio" verbatim,
  and its `source.path` (`core/overlays/dev`) is exactly the path this
  feature-step's Specification already targets — there is no *other* feature-step
  in the project plan that owns the `core` layer or has a Gateway-adjacent reason
  to touch it (Storage, Auth, Git hosting, Feature flags, and Observability are
  all later layers with no LoadBalancer-IP need of their own; Workloads consumes
  the Gateway, it does not provision its LoadBalancer). `cluster-core-k3d`'s own
  design explicitly deferred metallb out of its scope into "the GitOps
  bootstrap at a sync-wave" specifically because the manual-bootstrap boundary
  (research decision 8) keeps the hand-applied surface minimal — and once
  GitOps exists (Feature 2, already built), "the GitOps step" that inherits
  metallb is necessarily whichever feature-step actually populates the `core`
  layer's content, which is this one. The live cluster confirms the gap is real
  and unfilled: `kubectl get ns metallb-system` returns `NotFound`, and
  `core/overlays/dev/kustomization.yaml` is still the placeholder
  `resources: []` its own comment says "until a later feature-step (cert-manager,
  Gateway API, Istio, metallb) lands real content." No escalation trigger fires:
  this is reversible (a Kustomize resource list edit), fully inside this
  feature-step's already-recorded scope (`plan.md` and `design.md` both list
  Istio/Gateway API/cert-manager as this feature's content; metallb's `core`-layer,
  no-other-owner status is determined by the already-committed `apps/core.yaml`
  comment, not underdetermined), and the one alternative (moving metallb into
  the GitOps feature-step's own manual `bootstrap` task) was already
  considered and explicitly left open only as a *chicken-and-egg* escape hatch
  ("if a chicken-and-egg surfaces during build... with no rework elsewhere") —
  no such chicken-and-egg has surfaced (ArgoCD itself installed and synced
  cleanly with metallb absent, since ArgoCD's own image pulls use the node's own
  network, not a LoadBalancer IP, exactly as `gitops-argocd/design.md` predicted),
  so the conservative default (metallb ships where its declared content already
  says it ships) holds without needing the escape hatch.
- Gateway API CRDs install as plain manifests (standard channel), not a Helm
  chart; no official chart exists yet.
- The SelfSigned→CA cert-manager bootstrap is a fixed three-object pattern,
  already implied by the project's decision 3 and now confirmed against
  cert-manager's primary docs.
- metallb's `IPAddressPool` sizes from the live cluster's Docker network subnet
  (`172.18.0.0/16`, confirmed live this session); a high slice such as
  `172.18.255.200-172.18.255.250` follows the documented convention.

### Resolved by the long-loop reviewer (2026-07-08)

The three items below were the "still open, for this feature-step's own design
phase to settle" slot. A separately dispatched research-and-decide reviewer read
this artifact cold, researched each against the repo conventions
(`ARCHITECTURE.html`, `ROUTING.md`, `DEVELOPMENT.md`, the parent
`design.md`/`plan.md`/`research.md`, and the cleared `cluster-core-k3d` and
`gitops-argocd` feature designs) and — for the two empirically-checkable items —
against the live `k3d-agrippa-dev` cluster, then decided each to the
conservative, reversible default. No escalation trigger (irreversible, out of
recorded scope, or underdetermined) fired, so this research draft gate is cleared
(marker above now `*Reviewed 2026-07-08*`). These stay Design-phase artifact
commitments; what the reviewer settled is that the research is complete and its
recommendations are sound — with one live-verified correction — to carry into
Design. The live cluster was returned to its pristine pre-spike state after the
checks (metallb absent, no test namespace, host `:80` back to no-backend, all
seven ArgoCD Applications Synced/Healthy).

**1. The Gateway `Service`'s host-reachability mechanism (`externalIPs` set to
the node's own address vs. `hostNetwork`/`hostPort` vs. re-enabling Klipper).
Decided: `externalIPs` set to the k3d server node's own container IP is the
primary mechanism, empirically confirmed on the live cluster; carry it into
Design as the committed default, with the two fallbacks retained only as
documented contingencies.** This is the research's own highest-risk item, and the
reviewer ran the spike the research called for rather than deferring it to build.
The live serverlb `nginx.conf` was read first and confirms the static
passthrough: host `:80`/`:443` proxy to `k3d-agrippa-dev-server-0`'s own IP
`172.18.0.3` on the same port, with no Service/metallb awareness. A controlled
A/B test on that cluster (ServiceLB and Traefik disabled, kube-proxy active in
iptables mode):

- *Negative control* — an nginx-backed Service with **no** `externalIPs`: host
  `curl` through the port-map returned "Empty reply from server" on every
  attempt, confirming the research's core claim that the static port-map alone
  does **not** reach a Service once Klipper is gone.
- *Positive* — the same Service with `spec.externalIPs: ["172.18.0.3"]`:
  kube-proxy installed the exact `-d 172.18.0.3/32 ... "external IP" ... --dport
  80 -j KUBE-EXT-…` DNAT rule, and host `curl` returned HTTP 200 (nginx welcome)
  on every attempt — with no metallb, no Klipper, and no OS-level routing hack.
- *Full recommended shape* — `type: LoadBalancer` + `externalIPs: ["172.18.0.3"]`
  + metallb v0.16.1 with an `IPAddressPool` of `172.18.255.200-172.18.255.250`
  (sized from the live `172.18.0.0/16` Docker network, per this research's sizing
  finding): metallb assigned ingress `172.18.255.200`, the host stayed reachable
  via the `externalIPs` path, and kube-proxy carried **both** the external-IP and
  the loadbalancer-IP DNAT rules to the same endpoints with no conflict.
  `externalIPs` and the metallb-assigned ingress IP are independent kube-proxy
  rules; they compose cleanly.
This makes the recommendation not merely reasoned but verified on the exact
substrate, so Design can commit the Gateway `Service` manifest directly instead
of gating on a build-time spike. Conservative (reuses the already-cleared
substrate and the standard `externalIPs` Service field; re-litigates no cleared
decision), fully reversible (a Service-field edit), and squarely inside this
feature-step's recorded scope (Scope § lists the Gateway `Service`'s
host-reachability as this step's own artifact decision). It also fills a real gap
the cleared parent `design.md` left implicit ("host `:443` reaches the Istio
Gateway (the metallb IP is not host-routable on macOS)" never said *how*),
consistently with that parent's stated intent, so no out-of-scope trigger fires.
Note for Design: re-derive `172.18.0.3` (and the pool CIDR) at build time — both
are assigned per cluster-create and a `cluster:down`/`up` can change them.

**2. How `core/overlays/dev` composes the four upstream charts / manifest sets
under one ArgoCD Application (nested app-of-apps vs. multi-source Application vs.
Kustomize `helmCharts:` inflation). Decided: this stays a Design-phase artifact
decision; the research has adequately enumerated the three standard patterns and
none is foreclosed by any cleared artifact, so it is sound to carry into Design
unresolved.** Confirmed against the cleared `gitops-argocd` design: the
repo-server runs `kustomize build` with the KSOPS plugin, which is the one
relevant constraint Design must weigh — Kustomize `helmCharts:` inflation
additionally requires `--enable-helm` on that same repo-server (wired there for
KSOPS, not helm inflation), whereas a nested app-of-apps (matching the
layer-level app-of-apps `ARCHITECTURE.html` already uses) and a multi-source
Application (a native ArgoCD feature) impose no new repo-server wiring. This is a
genuine design-altitude composition choice, not a research-answerable fact; the
reviewer's conservative move is to leave it to Design rather than prematurely
commit a pattern (which would collapse Design into Research). Reversible, in
scope, and — at research altitude — determined (the option space is complete). No
escalation.

**3. The istio-cni Helm values for the `cniConfDir`/`cniBinDir` override, and
Helm-direct vs. `istioctl`/IstioOperator install. Decided: direct Helm chart
installs (`istio-base`, `istiod`, `istio-cni`, `ztunnel`) with
`cniConfDir=/var/lib/rancher/k3s/agent/etc/cni/net.d` and — corrected from this
research's stale value — `cniBinDir=/var/lib/rancher/k3s/data/cni`
(live-verified).** The research recommended
`cniBinDir=/var/lib/rancher/k3s/data/current/bin/`, but that path does **not
exist** on the pinned `rancher/k3s:v1.35.5-k3s1` node: `.../data/current` is
absent, and the live containerd config
(`/var/lib/rancher/k3s/agent/etc/containerd/config.toml`) scans `bin_dirs =
["/var/lib/rancher/k3s/data/cni"]` with `conf_dir =
"/var/lib/rancher/k3s/agent/etc/cni/net.d"`. The conf-dir value the research gave
is therefore confirmed live; the bin-dir value is corrected to
`/var/lib/rancher/k3s/data/cni` (a real directory holding
flannel/bridge/portmap/loopback/host-local, not a symlink). The legacy
`/etc/cni/net.d` and `/opt/cni/bin` paths that `global.platform=k3d`
historically assumed are both absent, reconfirming the finding that the flag
alone is insufficient on this k3s version. Direct Helm install remains the
conservative default (matches how cert-manager/metallb install in this same
layer, and dodges the open `istioctl`/IstioOperator override-ignoring issue
`#58203`). Reversible (Helm values), in scope, now determined by live inspection.
**Caveat for Design/build: these CNI paths are k3s-version-specific — re-verify
them against the node if the `k3d/agrippa-dev.yaml` k3s image pin ever moves**
(that version drift is the very reason upstream issue #57264 exists).

## Sources

IEEE-style citations for every external claim are in
`research/public.md` (17 numbered sources, plus the falsification pass). Summary
list, deduplicated:

- [1] "Istio / k3d," Istio Documentation. https://istio.io/latest/docs/setup/platform-setup/k3d/
- [2] "Istio / Platform-Specific Prerequisites," Istio Documentation (ambient). https://istio.io/latest/docs/ambient/install/platform-prerequisites/
- [3] "k3s versions > 1.31.6 and >1.32.2 no longer working (with k3d at least)," istio/istio Issue #57264. https://github.com/istio/istio/issues/57264
- [4] "Deterministic cni-bin-dir," k3s-io/k3s Issue #1434; "CNI bin dir changes with K3s version," k3s-io/k3s Issue #10869. https://github.com/k3s-io/k3s/issues/1434 , https://github.com/k3s-io/k3s/issues/10869
- [5] "istioctl/istiooperator does not correctly address hardware specific CNI path properties," istio/istio Issue #58203 (open). https://github.com/istio/istio/issues/58203
- [6] "Getting started with Gateway API," Gateway API Documentation. https://gateway-api.sigs.k8s.io/guides/getting-started/introduction/
- [7] "Provide an official Helm chart for Gateway API CRDs," kubernetes-sigs/gateway-api Issue #4809 (open). https://github.com/kubernetes-sigs/gateway-api/issues/4809
- [8] "SelfSigned," cert-manager Documentation. https://cert-manager.io/docs/configuration/selfsigned/
- [9] "CA," cert-manager Documentation. https://cert-manager.io/docs/configuration/ca/
- [10] "Installation," MetalLB Documentation. https://metallb.universe.tf/installation/
- [11] "Configuration" / "Advanced AddressPool configuration," MetalLB Documentation. https://metallb.universe.tf/configuration/ , https://metallb.universe.tf/configuration/_advanced_ipaddresspool_configuration/
- [12] "K3D Load Balancing — MetalLB on Mac," VHSblog. https://vhs.codeberg.page/post/kubernetes-macos-load-balancing-k3s-k3d-metallb/
- [13] "k3d + metalLB homelab k8s cluster," DevOps Crux. https://devops-crux.com/posts/09-2023-k3d-metallb-home-lab/
- [14] "Exposing Services," k3d Documentation. https://k3d.io/stable/usage/exposing_services/
- [15] "Load Balancer and Networking," k3d-io/k3d DeepWiki. https://deepwiki.com/k3d-io/k3d/5-load-balancer-and-networking
- [16] "Understanding K3d Ingress," Rob Mengert, Medium. https://rob-mengert.medium.com/understanding-k3d-ingress-b94697638f3b
- [17] "[QUESTION] Access Services From Host Without Mapping Ports to LoadBalancer," k3d-io/k3d Discussion #821. https://github.com/k3d-io/k3d/discussions/821

In-repo Prior Art (authoritative, not external): `ARCHITECTURE.html`,
`ROUTING.md`, `DEVELOPMENT.md`, project `design.md` (§ Specification §
Networking, § Shared Contracts), project `plan.md` (§ Feature 3), project
`research.md` (decisions 2, 3, 8), `apps/core.yaml`, `apps/root.yaml`,
`apps/kustomization.yaml`, `core/overlays/dev/kustomization.yaml`, `mise.toml`,
`features/cluster-core-k3d/design.md`, `features/gitops-argocd/design.md`. Live
cluster state (verified this session, 2026-07-08): `kubectl get ns
metallb-system` → NotFound; `kubectl get ns istio-system` → NotFound; `kubectl
get crd | grep gateway` → empty; `kubectl -n argocd get applications` → all six
(`root`, `core`, `storage`, `platform`, `observability`, `workloads`, `argocd`)
Synced/Healthy; `docker network inspect k3d-agrippa-dev` →
`172.18.0.0/16`; `kubectl get nodes -o wide` →
`k3d-agrippa-dev-server-0` at `172.18.0.3`, `v1.35.5+k3s1`.
