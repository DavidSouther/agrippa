# Public: Istio ambient + Gateway API + cert-manager + metallb on k3d (Networking feature-step)

## Findings

**Istio ambient on k3d needs more than `global.platform=k3d`.** The official k3d
platform-setup page's own cluster-create example does not disable ServiceLB, only
Traefik (`--k3s-arg '--disable=traefik@server:*'`), and its Istio install commands
carry no `global.platform=k3d` flag at all [1]. The `global.platform=k3d` value is
a separate, additional override documented on Istio's ambient platform-prerequisites
page to handle k3s's nonstandard CNI binary/config locations [2]. More recent k3s
releases (v1.31.7+ and v1.32.3+) moved the CNI plugin directory again, to
`/var/lib/rancher/k3s/agent/etc/cni/net.d`, breaking `istio-cni`'s discovery even
with `global.platform=k3d` set; the tracking issue was closed as stale with no
documented fix version, and the closest working recommendation is an **explicit**
Helm-time override on the `istio-cni` chart, `--set
cniConfDir=/var/lib/rancher/k3s/agent/etc/cni/net.d --set
cniBinDir=/var/lib/rancher/k3s/data/current/bin/`, installed via the Helm chart
directly rather than through `istioctl`/IstioOperator, since a separate, currently
open Istio issue reports the operator flow ignoring these overrides on `cni.enabled=true`
installs [3][4][5]. Agrippa's committed `k3d/agrippa-dev.yaml` pins
`rancher/k3s:v1.35.5-k3s1` (cluster-core-k3d feature-step), which is well past both
break points, so this is a **near-certain** hit, not a hypothetical: install-time
verification and the explicit `cniConfDir`/`cniBinDir` overrides are load-bearing
for this feature-step, not optional hardening.

**Gateway API CRDs install as plain manifests, not a Helm chart.** The standard
channel (GatewayClass, Gateway, HTTPRoute, ReferenceGrant — the GA/beta-graduated
subset, sufficient for this feature's Gateway + HTTPRoute contract) installs via
`kubectl apply --server-side -f
https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml`
[6]. No official Helm chart exists yet (an open upstream feature request) [7], so
in a GitOps/Kustomize world these CRDs are either vendored as a raw-manifest
resource or fetched by URL in the `core` kustomization — a concrete artifact
decision for this feature's own design.

**cert-manager's SelfSigned→CA bootstrap is a fixed, three-object pattern**, confirmed
directly from the primary docs: a `SelfSigned` `ClusterIssuer` issues a
self-signed root `Certificate` (`isCA: true`) into a Secret, and a second `CA`
`ClusterIssuer` references that Secret to sign every downstream leaf `Certificate`
[8][9]. This matches decision 3 already settled by the project's top-level research
and needs no new decision here, only the concrete manifests.

**metallb Layer2 mode is CRD-configured** (`IPAddressPool` + `L2Advertisement`,
replacing the old ConfigMap scheme), installable via plain manifests, Kustomize, or
Helm; current stable is v0.16.1 [10][11]. Every practical k3d+metallb worked
example pulls the pool's CIDR from the **k3d Docker network's own subnet**
(`docker network inspect k3d-<cluster>`), picking a high, unlikely-to-collide slice
(e.g., `172.19.255.1-172.19.255.250` inside a `172.19.0.0/16` network) [12][13].
Agrippa's live `k3d-agrippa-dev` network is `172.18.0.0/16` (verified this session),
so an equivalent slice (e.g. `172.18.255.200-172.18.255.250`) is the pattern to
follow.

**Load-bearing risk, newly surfaced by this research: k3d's host port-map and
metallb's floating IP do not obviously compose.** k3d's built-in loadbalancer
(`k3d-proxy`, an nginx image driven by `confd` templates) is a **static, per-node
TCP passthrough**: a port mapped with `nodeFilters: [loadbalancer]` is "proxied to
the same ports on all server nodes in the cluster" [14][15] — it has no
Kubernetes-API awareness of Service objects, LoadBalancer status, or metallb at
all [15][16]. That static passthrough terminates a **new** connection addressed to
each server node's own container IP, not to whatever floating IP metallb assigned.
The reason the same construct works in Istio's own official k3d guide is that the
guide leaves **ServiceLB (Klipper) enabled** (only Traefik is disabled) [1], and
Klipper's actual mechanism is to run a per-node iptables rule that DNATs *any*
packet addressed to that node's own IP on the Service's port to the Service's
ClusterIP [16][17] — i.e., Klipper is what makes "the same port on every node"
resolve to something real. Agrippa's `cluster-core-k3d` feature-step already
shipped `--disable=servicelb`, deliberately trading Klipper for metallb (to avoid
the two LoadBalancer controllers fighting over IPs, per the project's own prior
research). metallb's Layer2 mode does not perform Klipper's "any traffic on my own
node IP" trick; it ARPs for and answers to a specific floating IP, and kube-proxy's
DNAT rule for a LoadBalancer Service matches packets addressed to *that* IP, not
to the node's primary address. **No source found in this pass documents the
specific combination "ServiceLB disabled + metallb Layer2 + k3d's static
`<port>@loadbalancer` passthrough" as a working, verified recipe.** The closest
metallb+k3d worked examples that do reach the host from macOS either (a) keep the
Docker network unroutable and instead use OS-level routing hacks (a `TunTap`
kernel-extension bridge plus manual macOS route-table edits) to make the metallb
IP itself reachable from the host, bypassing k3d's port-map entirely [12], or (b)
don't attempt host-from-macOS reachability at all. Both contradict the
already-cleared `cluster-core-k3d` design's stated mechanism ("the k3d loadbalancer
port-map... is how host `:443` reaches the Istio Gateway").

The most promising fix that keeps everything else in the already-cleared design
intact: set the Istio Gateway `Service`'s `spec.externalIPs` to the k3d server
node's own container IP (the same address k3d-proxy's static passthrough already
targets). `externalIPs` is a standard Service field kube-proxy honors identically
to a LoadBalancer ingress IP — it tells kube-proxy to DNAT any packet addressed to
that IP on the Service's port to the Service's endpoints, which is functionally
the same trick Klipper performs internally, without re-enabling ServiceLB. This is
inferred from how Klipper is documented to work [16][17] plus the standard
Kubernetes `externalIPs` Service field semantics; it was **not** found stated
verbatim as a k3d+metallb recipe in any fetched source, so it is a reasoned
recommendation, not a confirmed pattern, and needs an empirical spike before this
feature-step's design finalizes the Gateway `Service` shape. Fallbacks if it does
not verify: hostNetwork/hostPort on the ingress-gateway pod (bypasses Services for
the exposed port), or reintroducing Klipper for the Gateway Service specifically
(logically re-litigates the ServiceLB-vs-metallb question `cluster-core-k3d` and
the project's own research already settled, so least preferred).

**No SKILL.md, MCP server, or `skills/` directory found for Istio, Gateway API,
cert-manager, or metallb.** This reconfirms, at the per-component level, the
project's already-recorded top-level finding — nothing new surfaced in this pass
for these four tools specifically.

## Falsification pass

Restated claim: "the k3d `<port>:<port>@loadbalancer` port-map, combined with
metallb, reaches an Istio Gateway Service on macOS with no other component
changes." Searched specifically for confirming recipes (k3d + metallb + Istio
gateway, several phrasings) and found none that both (a) disable ServiceLB and
(b) rely solely on the static k3d port-map without an additional Docker-network
routing step. The k3d design docs [14][15] and the Klipper-mechanism source [16]
are Tier 1/Tier 3 respectively and agree on the passthrough being static and
Service-unaware, which is what refutes the unqualified claim. This is reported as
an open risk, not a blocker, because a same-effect workaround (`externalIPs`) is
implied by first-party Kubernetes Service semantics even though no source states
it as a named k3d+metallb pattern.

## Sources

- [1] "Istio / k3d," Istio Documentation, platform-setup.
  https://istio.io/latest/docs/setup/platform-setup/k3d/
- [2] "Istio / Platform-Specific Prerequisites," Istio Documentation (ambient).
  https://istio.io/latest/docs/ambient/install/platform-prerequisites/
- [3] "k3s versions > 1.31.6 and >1.32.2 no longer working (with k3d at least),"
  istio/istio Issue #57264 (closed, stale).
  https://github.com/istio/istio/issues/57264
- [4] "Deterministic cni-bin-dir," k3s-io/k3s Issue #1434; "CNI bin dir changes
  with K3s version," k3s-io/k3s Issue #10869.
  https://github.com/k3s-io/k3s/issues/1434 ,
  https://github.com/k3s-io/k3s/issues/10869
- [5] "istioctl/istiooperator does not correctly address hardware specific CNI
  path properties when encountering cni.enabled=true," istio/istio Issue #58203
  (open, reported against k3s v1.31.9+k3s1 / Istio 1.27.3).
  https://github.com/istio/istio/issues/58203
- [6] "Getting started with Gateway API," Gateway API Documentation (standard
  channel install command, v1.6.0).
  https://gateway-api.sigs.k8s.io/guides/getting-started/introduction/
- [7] "Provide an official Helm chart for Gateway API CRDs," kubernetes-sigs/
  gateway-api Issue #4809 (open).
  https://github.com/kubernetes-sigs/gateway-api/issues/4809
- [8] "SelfSigned," cert-manager Documentation.
  https://cert-manager.io/docs/configuration/selfsigned/
- [9] "CA," cert-manager Documentation.
  https://cert-manager.io/docs/configuration/ca/
- [10] "Installation," MetalLB Documentation (methods, current stable v0.16.1).
  https://metallb.universe.tf/installation/
- [11] "Configuration" and "Advanced AddressPool configuration," MetalLB
  Documentation (IPAddressPool / L2Advertisement CRDs).
  https://metallb.universe.tf/configuration/ ,
  https://metallb.universe.tf/configuration/_advanced_ipaddresspool_configuration/
- [12] "K3D Load Balancing — MetalLB on Mac," VHSblog (Docker-network CIDR
  selection for the metallb pool; TunTap/route-table workaround for macOS host
  reachability, noted as a "hack").
  https://vhs.codeberg.page/post/kubernetes-macos-load-balancing-k3s-k3d-metallb/
- [13] "k3d + metalLB homelab k8s cluster," DevOps Crux (pool CIDR taken from
  `docker network inspect`, high-numbered slice).
  https://devops-crux.com/posts/09-2023-k3d-metallb-home-lab/
- [14] "Exposing Services," k3d Documentation ("all ports exposed on the
  `serverlb` will be proxied to the same ports on all server nodes").
  https://k3d.io/stable/usage/exposing_services/
- [15] "Load Balancer and Networking," k3d-io/k3d DeepWiki (k3d-proxy is a static,
  confd/nginx-templated per-node passthrough; no Kubernetes Service or metallb
  awareness documented).
  https://deepwiki.com/k3d-io/k3d/5-load-balancer-and-networking
- [16] "Understanding K3d Ingress," Rob Mengert, Medium ("klipper uses iptables to
  forward any requests to the Service's port on that node to the Service's
  cluster ip and port" — the per-node-own-IP DNAT mechanism that makes the static
  k3d port-map resolve to something real when ServiceLB is enabled).
  https://rob-mengert.medium.com/understanding-k3d-ingress-b94697638f3b
- [17] "[QUESTION] Access Services From Host Without Mapping Ports to
  LoadBalancer," k3d-io/k3d Discussion #821 (container IPs are not routable from
  the macOS host; Docker Desktop networking constraint).
  https://github.com/k3d-io/k3d/discussions/821

In-repo Prior Art consulted (not external, cited for cross-reference only):
`apps/core.yaml`, `core/overlays/dev/kustomization.yaml`,
`.ailly/developer/2026-07-06-A-agrippa-local-k3d/features/cluster-core-k3d/design.md`,
`.ailly/developer/2026-07-06-A-agrippa-local-k3d/features/gitops-argocd/design.md`.
