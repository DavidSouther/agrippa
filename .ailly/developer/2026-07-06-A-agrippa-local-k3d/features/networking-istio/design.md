# Feature Design: Networking (Istio ambient + Gateway API + cert-manager + metallb)

*Reviewed 2026-07-08*

> Feature-step design (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is **Feature 3: Networking (Istio +
> cert-manager)** of that project's plan: the ingress substrate and the shared
> Gateway/HTTPRoute/hostname/TLS contract every later UI-exposed feature-step
> consumes. It has its own feature test (recorded below). The project as a whole
> is measured by `closing-bell.md`, not by this test.
>
> This is a **larger, ensemble** feature-step (four distinct upstream sources —
> metallb, the Gateway API CRDs, cert-manager, and Istio ambient — plus a shared
> contract later features bind to), so it runs longer than the one-page norm, per
> `design.md`'s "confirm before making a larger doc." Its research (`research.md`,
> `research/public.md`) is Reviewed; a separately dispatched long-loop reviewer
> cleared this draft gate on 2026-07-08 — its decisions (this design's own Open
> Artifact Decisions plus the seven falsifiable questions the design-intent review
> left open) are in the *Resolved by the long-loop reviewer* block under Summary,
> and no escalation trigger fired.

## Libraries & Skills (carry forward to plan and build)

Per the project's cleared `research.md` (§ Libraries & Skills), this feature-step's
own `research.md` (§ Libraries & Skills), and the project `design.md`, the plan and
build phases MUST load these skills via the harness's skill-loading mechanism before
working:

- **`developer:initialize`** — for any residual `mise` tool-pin work. This feature
  adds **no** new mise-managed CLI: metallb, the Gateway API CRDs, cert-manager, and
  Istio are all in-cluster Kubernetes resources reconciled by ArgoCD, not local CLIs.
  `istioctl` stays **optional and not pinned** — the install path is Helm-direct
  (research Resolved item 3, since the `istioctl`/IstioOperator flow ignores the
  `cniConfDir`/`cniBinDir` overrides this k3s version needs, per open Istio issue
  #58203). An operator may install `istioctl` locally for `istioctl analyze`/debugging,
  but the build does not depend on it.
- **`research:public`** and **`research:codebase`** — for any per-tool detail the
  build hits (an Istio ambient Helm value, a Gateway API listener field, a metallb CRD
  key, a cert-manager issuer field).

**No library-shipped agentic skill exists for Istio, Gateway API, cert-manager, or
metallb** (both the project research and this feature's research recorded a deliberate
per-tool check). Build to the in-repo contracts: `ARCHITECTURE.html` (the Cluster Core
layer and the Request Path view — `cert-manager` + `Istio Ambient` + `ztunnel` +
`metallb`), `ROUTING.md` (host-vs-path policy and the Gateway API HTTPRoute precedence
findings), and `DEVELOPMENT.md` (test tooling, repo layout, SOPS/KSOPS wiring).

## Purpose

Stand up the local ingress substrate that is the k3d-only equivalent of roadmap item 3
(Networking), and — the load-bearing deliverable — **define the shared Gateway +
HTTPRoute + local-hostname + TLS contract** that every later UI-exposed feature-step
(Auth, Observability, Workloads) consumes. Production terminates TLS with public ACME
certs behind the Cloudflare edge and resolves public DNS; both are cloud-only and out
of scope here, so this step replaces them with a local CA (real certificates, not
publicly trusted, probed with `curl -k`) and `*.nip.io` loopback hostnames reached
through the k3d gateway port-map (`research.md` decisions 2, 3).

The deliverable is four upstream pieces plus one contract, all reconciled by ArgoCD
into the already-Synced `core` layer:

1. **metallb** — the LoadBalancer-IP controller the `cluster-core-k3d` step disabled
   ServiceLB in favor of, deferred to "the GitOps step that populates `core`," which is
   this one (research Resolved decision, confirmed live: `metallb-system` is absent).
2. **Gateway API CRDs** — the standard channel, installed ahead of everything that
   references them.
3. **cert-manager** — its controller and a SelfSigned→CA local `ClusterIssuer` chain
   that issues this step's Gateway certificate and every later workload's certificate.
4. **Istio ambient** (`istio-base`, `istiod`, `istio-cni`, `ztunnel`) with
   `global.platform=k3d` **and** the explicit k3s-version-specific CNI path overrides.
5. **The shared Gateway contract** — one Istio `Gateway` terminating TLS on `:443`,
   host-reachable from the macOS host, plus the hostname scheme and the CA-issuer
   pattern later features bind to.

The value is narrow but load-bearing: no user's real workload is exposed yet (that is
Feature 9), but nothing UI-facing can be reached without this substrate, and this step
proves the in-cluster request path (host `:443` → k3d port-map → Istio Gateway →
HTTPRoute → backend, TLS terminated with a local-CA cert) end-to-end against a backend
that already exists — the ArgoCD UI itself.

Out of scope, kept as seams for the deferred cloud cycle: **cloudflared and
ExternalDNS** (cloud-edge, declared in `core` but excluded from `overlays/dev`),
**per-workload HTTPRoutes and Certificates** (Feature 9 consumes this contract, it does
not create it), **`overlays/prod`** (a seam, not built), and **importing the local CA
into the host trust store** (an opt-in operator action; probes use `curl -k`).

## Prior Art

- **`gitops-argocd` (Feature 2), `apps/platform/argocd/kustomization.yaml`.** The
  authoritative in-repo pattern for a GitOps-reconciled kustomization that consumes an
  upstream install artifact: pull the pinned upstream manifest as a `resources:` entry
  (a raw URL), apply strategic-merge `patches:`, and let the KSOPS-enabled repo-server
  `kustomize build` it under one ArgoCD Application. It also holds the exact
  ConfigMap patch this step extends: `argocd-cm`'s `kustomize.buildOptions:
  "--enable-alpha-plugins --enable-exec"` (added for KSOPS) — this step appends
  `--enable-helm` there, the one repo-server wiring change the composition needs.
- **`gitops-argocd`, `apps/core.yaml`.** The `core` layer Application already exists,
  sync-wave `0`, `source.path: core/overlays/dev`, with `ServerSideApply=true` and
  `SkipDryRunOnMissingResource=true` already set on its `syncPolicy.syncOptions` (a
  forward seam its own comment names "for cert-manager/Gateway API/Istio CRDs in a
  later feature-step" — this one). Its comment reads "Core owns metallb, Gateway API
  CRDs, cert-manager & istio" verbatim.
- **`core/overlays/dev/kustomization.yaml`.** The empty-but-valid `resources: []`
  placeholder this step replaces with real content; its comment already names "a later
  feature-step (cert-manager, Gateway API, Istio, metallb)."
- **`cluster-core-k3d` (Feature 1).** Left the long-lived `agrippa-dev` cluster running
  with ServiceLB and Traefik disabled and host `:80`/`:443` published through the k3d
  loadbalancer — the substrate this step's Gateway sits behind. The k3s image is pinned
  `rancher/k3s:v1.35.5-k3s1`, which fixes the CNI-path override values below.
- **`gitops-argocd`'s deferred item.** Its design deferred "ArgoCD UI ingress and
  Tier-1 gating" to Networking ("reached by `kubectl port-forward` locally; the
  Istio-Gateway HTTPRoute … are Networking / cloud concerns"). This step resolves it:
  the ArgoCD UI is the zero-new-workload reachability proof for the shared contract.
- **`ROUTING.md`.** Fixes host-based routing as the operationally-simpler,
  lower-blast-radius default (each host its own HTTPRoute), and the Gateway API
  precedence/tie-break rules this contract inherits.
- **External worked examples** (full citations in `research/public.md`): Istio's own
  k3d and ambient-prerequisites pages; the k3s CNI-path issues (#57264, #58203, k3s
  #10869); the Gateway API standard-channel install; cert-manager's SelfSigned and CA
  issuer docs; metallb's IPAddressPool/L2Advertisement config; and the k3d-proxy
  passthrough / Klipper-DNAT mechanism that motivates the `externalIPs` fix.

## User Journey and Metrics

**The operator's flow, from the bootstrapped `agrippa-dev` cluster (Features 1–2), with
this Networking content committed and ArgoCD reconciling `core`:**

1. ArgoCD syncs the `core` layer: metallb, the Gateway API CRDs, cert-manager, and Istio
   ambient come up in fine-grained sync-wave order (CRDs, then controllers, then the
   cluster config CRs and the Gateway). The operator runs
   `kubectl -n argocd get application core` and sees it **Synced/Healthy**.
2. cert-manager's SelfSigned→CA chain issues the shared Gateway a certificate from the
   local CA; the Istio `Gateway` in `istio-ingress` reports **Programmed**; metallb
   assigns its Service a LoadBalancer IP from the k3d Docker-network pool, and the
   supplemental `externalIPs` Service makes the k3d server node's own IP DNAT to the
   gateway pods.
3. The operator opens `https://argocd.127.0.0.1.nip.io/` in a browser (or `curl -k`):
   the request goes host `:443` → k3d loadbalancer port-map → node IP → gateway pods →
   HTTPRoute → `argocd-server`, TLS terminated at the gateway with the local-CA cert.
   The ArgoCD UI renders. The browser shows an untrusted-CA warning by design (the CA
   is not in the host trust store); `curl -k` accepts it. This simultaneously resolves
   `gitops-argocd`'s deferred "ArgoCD UI ingress" item.
4. Every later UI feature-step now reaches the browser by (a) creating one `HTTPRoute`
   with `parentRefs` to the shared Gateway at its own `<prod-host>.127.0.0.1.nip.io`
   dev host, and (b) appending that dev host to the shared Gateway certificate's
   `dnsNames`. It never edits the Gateway object itself.

**Metrics / measures of done for this feature-step:**

- The feature test (`tests/networking.bats`) is green: `curl -k
  https://argocd.127.0.0.1.nip.io/` through the k3d `:443` port-map returns a UI
  response served through the Istio Gateway, presenting a TLS certificate **issued by
  the local CA** (not Istio's built-in self-signed default) — proving the Gateway +
  HTTPRoute + hostname + TLS contract end-to-end.
- `kubectl -n argocd get application core` is **Synced/Healthy** with the four upstream
  sources reconciled.
- Adding this step does not regress earlier harness: `mise run test:push`,
  `mise run test:feature`, `bats tests/cluster-core.bats`, and `bats tests/gitops.bats`
  stay green (the `networking.bats` `test:feature` exclusion lands with the test).

**Per-component SLO (defined here, watched in Grafana once Observability lands; not a CI
step, per `DEVELOPMENT.md`).** The ingress path is the platform's front door, so its
error budget is the tightest of the infrastructure layers. Target: **99.5% of gateway
HTTP requests succeed** (non-5xx) and **99.5% of TLS handshakes complete**, measured over
a rolling 28-day window from Istio's gateway telemetry (`istio_requests_total`,
`istio_request_duration_milliseconds`). Burn-rate alert at 2% budget consumed in 1h.
This SLO is recorded here and instrumented when Feature 8 (Observability) provides the
Prometheus/Grafana stack; it is not asserted by the feature test.

**Failure modes to design against.**

- **Istio CNI silently not installing** because `global.platform=k3d` alone does not
  cover this k3s version's CNI paths — the near-certain hit this feature's research
  flagged. Mitigated by the explicit, live-verified `cniConfDir`/`cniBinDir` overrides
  (Specification); re-verify against the node if the k3s image pin ever moves.
- **The Gateway Service unreachable from the macOS host.** k3d's static port-map alone
  does not reach a Service once ServiceLB/Klipper is gone (research negative control,
  live-confirmed: "Empty reply from server"). Mitigated by `spec.externalIPs` set to the
  k3d server node's own container IP (research positive control, live-confirmed HTTP
  200), which coexists with the metallb-assigned LoadBalancer IP with no conflict.
- **A CR syncing before its CRD or its controller.** metallb config before its
  controller; a `ClusterIssuer` before cert-manager's webhook; the `Gateway` before the
  Gateway API CRDs or istiod. Mitigated by the fine-grained intra-`core` sync-wave
  scheme plus the `ServerSideApply`/`SkipDryRunOnMissingResource` already on the `core`
  Application.
- **The node IP drifting on cluster recreate.** `172.18.0.3` and the pool CIDR are
  assigned per cluster-create. Committed as documented defaults with a re-derivation
  step, not treated as permanent (Specification, Challenges).

## Specification

### Composition: one `core` Application, one KSOPS+Helm `kustomize build`

The four upstream sources compose under the **single, already-existing `core`
Application** (sync-wave 0) as a Kustomize overlay at `core/overlays/dev/`, following
`gitops-argocd`'s `apps/platform/argocd/` precedent (upstream pulled into a kustomization
that the KSOPS-enabled repo-server builds), extended with `helmCharts:` for the one
source that has no raw-manifest form. Concretely, `core/overlays/dev/kustomization.yaml`
carries:

- **`resources:` — raw upstream manifests (the `gitops-argocd` precedent) for the three
  sources that publish one:**
  - Gateway API standard-channel CRDs, pinned URL
    (`…/gateway-api/releases/download/v1.x.y/standard-install.yaml`).
  - metallb native manifest, pinned URL (`…/metallb/…/config/manifests/metallb-native.yaml`).
  - cert-manager static install manifest, pinned URL (`…/cert-manager/releases/…/cert-manager.yaml`),
    which bundles its CRDs, controller, and webhook.
- **`helmCharts:` — Istio ambient, the only source with no single-manifest form**
  (istio is Helm-only, and the CNI-path overrides *must* go through Helm values on the
  `istio-cni` chart). Four charts from `repo:
  https://istio-release.storage.googleapis.com/charts`, pinned `version:`:
  `base`, `istiod`, `cni`, `ztunnel`. Load-bearing `valuesInline`:
  - all four: `global.platform: k3d`, and the ambient profile (`profile: ambient`).
  - `cni` additionally, as **top-level** chart values — matching the research's
    `--set cniConfDir=… --set cniBinDir=…` form on the standalone `cni` chart, *not*
    nested under a `cni:` key: `cniConfDir: /var/lib/rancher/k3s/agent/etc/cni/net.d`
    and `cniBinDir: /var/lib/rancher/k3s/data/cni` — the **live-verified** values for
    the pinned `rancher/k3s:v1.35.5-k3s1` node (research Resolved item 3; the research's
    original `…/data/current/bin/` was corrected against the actual node's containerd
    config). **Re-verify the exact values-key nesting against the pinned `cni` chart,
    and the paths against the node, at build time; re-verify if the k3s image pin moves.**
- **Authored local CR files** (this feature-step's own manifests, in `core/overlays/dev/`
  or a `core/base/` the overlay references — see Open Artifact Decisions): the
  cert-manager issuer chain, the metallb config, the shared Gateway + its certificate +
  the reachability Service, and the ArgoCD reachability route. Detailed below.
- **`patches:`** — sync-wave annotations on the upstream resources so ordering holds
  (below), and any namespace/label tweaks.

**The one repo-server wiring change:** append `--enable-helm` to the `argocd-cm`
`kustomize.buildOptions` in `apps/platform/argocd/kustomization.yaml`, so it reads
`"--enable-alpha-plugins --enable-exec --enable-helm"`. This is exactly parallel to how
that patch added the KSOPS flags, and it lands where `bootstrap` applies it at install
time, so there is no first-sync chicken-and-egg (the repo-server has Helm enabled before
`core` first renders). This is a cross-step touch to `gitops-argocd`'s file.

Why this composition over the alternatives is argued in **Alternatives**; in short, it
keeps one Application, one KSOPS-compatible build, and hard per-resource sync-wave
ordering, at the cost of one anticipated config flag.

### Intra-`core` sync-wave scheme (this feature-step defines it)

`gitops-argocd` fixed the cross-layer waves (`core=0 … workloads=4`) and left the
ordering *inside* `core` to this step. All resources here carry
`argocd.argoproj.io/sync-wave` annotations (added by kustomize `patches:` for
upstream resources, inline for authored CRs). A starting scheme, refinable:

- **wave `-10` — CRDs that other resources watch at startup:** the Gateway API
  standard-install CRDs and `istio-base` (Istio's CRDs). (The metallb and cert-manager
  static manifests bundle their own CRDs; ArgoCD applies CRDs before other kinds
  *within* a wave, and the cross-wave gate below guarantees controllers are Healthy
  before any CR that needs them, so those two need no separate CRD wave.)
- **wave `-5` — controllers and data plane:** metallb (native manifest), cert-manager
  (static manifest), `istiod`, `istio-cni`, `ztunnel` (Helm-inflated).
- **wave `0` — cluster config CRs that need only their controller Healthy:** the
  metallb `IPAddressPool` + `L2Advertisement`; the cert-manager SelfSigned
  `ClusterIssuer`, the CA root `Certificate`, and the CA `ClusterIssuer`.
- **wave `5` — the ingress objects that need istiod + the Gateway API CRDs + the CA
  issuer:** the shared `Gateway`, its leaf `Certificate`, the supplemental `externalIPs`
  Service, and this feature's ArgoCD `HTTPRoute` (+ its host, carried on the shared
  cert).

ArgoCD syncs waves in ascending order and waits for each wave Healthy before the next,
so a `ClusterIssuer` never applies before cert-manager's webhook is up, and the
`Gateway` never applies before istiod and the Gateway API CRDs exist.

### The cert-manager SelfSigned→CA issuer chain

The fixed three-object pattern (`research/public.md` [8][9]), all cluster-scoped so
every namespace's later `Certificate` can reference it:

1. `ClusterIssuer` **`selfsigned`** — `spec.selfSigned: {}`.
2. `Certificate` **`agrippa-local-ca`** in the `cert-manager` namespace —
   `isCA: true`, `issuerRef: selfsigned` (ClusterIssuer), `commonName: "Agrippa Local
   Dev CA"`, `secretName: agrippa-local-ca-tls`.
3. `ClusterIssuer` **`agrippa-ca`** — `spec.ca.secretName: agrippa-local-ca-tls`
   (resolved in cert-manager's own namespace).

Every leaf certificate on the platform — this step's Gateway cert, and every Feature-9
workload cert — sets `issuerRef: {kind: ClusterIssuer, name: agrippa-ca}`. This is the
**TLS half of the shared contract**.

### metallb configuration and the Gateway Service reachability fix

- **metallb** in `metallb-system`, `IPAddressPool` **`agrippa-pool`** with
  `addresses: [172.18.255.200-172.18.255.250]` (a high, unlikely-to-collide slice of the
  live `172.18.0.0/16` k3d Docker network), and an `L2Advertisement` **`agrippa-l2`**.
  **Derive the CIDR at build time** (`docker network inspect k3d-agrippa-dev`); it is
  assigned per cluster-create.
- **The reachability fix (research's highest-risk item; the mechanism live-verified,
  the exact topology to confirm at build).** The Istio Gateway's auto-provisioned
  Service gets a metallb LoadBalancer IP (prod-parity), but that in-Docker IP is not
  host-routable on macOS, and k3d's static port-map alone does not reach it once Klipper
  is gone. The mechanism that fixes this is `spec.externalIPs` set to the k3d server
  node's own container IP — the address k3d's loadbalancer port-map already targets — so
  kube-proxy DNATs any packet to that IP on `:80`/`:443` to the endpoints, functionally
  the same trick Klipper performed. The research A/B spike verified this mechanism **on a
  single Service** live (HTTP 200 with `externalIPs`, "Empty reply" without) and verified
  the external-IP DNAT rule and the metallb-ingress-IP DNAT rule coexist on that one
  object with no conflict.
- Because the Gateway's Service is **auto-provisioned by istiod** — not authored here, so
  not directly patchable in GitOps — this step attaches `externalIPs` via a
  **supplemental Service** `agrippa-gateway-external` in `istio-ingress` that selects the
  same gateway pods:
  - `spec.externalIPs: ["172.18.0.3"]`, `ports: [80, 443]`.
  - `selector:` the labels istiod puts on the auto-provisioned gateway pods (expected
    `gateway.networking.k8s.io/gateway-name: agrippa-gateway`).
  - **The one spike this design does not pre-empt.** The research spike proved
    `externalIPs` on a *single* Service; the two-Service shape (a supplemental
    externalIPs Service selecting the same pods the generated LoadBalancer Service also
    fronts) and the exact gateway-pod selector label are this design's inference from
    standard kube-proxy/Service semantics, to confirm live early in the build. Fallbacks
    if it does not hold: patch the generated Service through an Istio gateway-service
    annotation, put `externalIPs` on a manually-authored gateway data plane's own Service
    (Istio ambient supports a manual gateway), or `hostNetwork`/`hostPort` on the gateway
    pod.
  - **Derive `172.18.0.3` at build/sync time** (`docker inspect
    k3d-agrippa-dev-server-0`); it may drift on `cluster:down`/`up`. Committed as the
    documented default with a re-derivation note (Challenges; Open Artifact Decisions).

This keeps everything in the already-cleared substrate intact — ServiceLB stays
disabled, the port-map is unchanged, no OS-level routing hack — and re-litigates no
prior decision. Fallbacks retained only as documented contingencies:
`hostNetwork`/`hostPort` on the gateway pod, or a manually-authored gateway data plane
whose own Service directly carries `externalIPs`.

### The shared Gateway/HTTPRoute/hostname contract (defined here, consumed later)

The whole point of this feature-step, per the parent plan's Shared Contracts. Settled
spelling:

- **Hostname scheme:** `<prod-host>.127.0.0.1.nip.io` (parent design's resolved decision
  6), resolving to `127.0.0.1` and reached through the k3d `:443` port-map. Mirrors:
  `davidsouther.com.127.0.0.1.nip.io`, `trips.davidsouther.com.127.0.0.1.nip.io`,
  `dashboard.davidsouther.com.127.0.0.1.nip.io`. This feature's own reachability proof
  uses `argocd.127.0.0.1.nip.io` (ArgoCD has no named prod host; the scheme's suffix is
  applied to the service name directly).
- **The shared `Gateway`** `agrippa-gateway` in namespace `istio-ingress`,
  `gatewayClassName: istio`, with two listeners:
  - `https` on `:443`, `protocol: HTTPS`, `tls.mode: Terminate`, a single
    `certificateRefs: [agrippa-gateway-tls]` (a Secret in `istio-ingress`), and
    `allowedRoutes.namespaces.from: All` so any later feature's HTTPRoute in its own
    namespace may attach.
  - `http` on `:80`, `protocol: HTTP`, `allowedRoutes.namespaces.from: All` — the
    conventional listener for an HTTP→HTTPS redirect (implemented by a small redirect
    HTTPRoute; optional for the `curl -k` local path, which hits `:443` directly).
- **The shared Gateway certificate** `Certificate` **`agrippa-gateway-tls`** in
  `istio-ingress`, `issuerRef: agrippa-ca`, `secretName: agrippa-gateway-tls`, and a
  `dnsNames:` list enumerating every dev host. Because the mirrored hosts are multiple
  labels deep, no single wildcard covers them (the `ROUTING.md` §2 wildcard-label rule),
  so the contract uses **one shared certificate with explicit SANs**. Seeded here with
  `argocd.127.0.0.1.nip.io`; later UI features append their host — a one-line edit to
  this single file, never a change to the `Gateway` object.
- **The consumption contract for later UI feature-steps** (Auth's Keycloak, Observability's
  Grafana, Workloads' resume/trips): (1) create one `HTTPRoute` in your component's
  namespace with `parentRefs: [{name: agrippa-gateway, namespace: istio-ingress,
  sectionName: https}]`, `hostnames: [<your-dev-host>]`, and a same-namespace
  `backendRefs`; (2) append `<your-dev-host>` to `agrippa-gateway-tls`'s `dnsNames`. No
  ReferenceGrant is needed (the cert Secret is in the Gateway's own namespace; backends
  are same-namespace as their routes; cross-namespace *attachment* is governed by the
  listener's `allowedRoutes`, not a ReferenceGrant). Host-based routing per `ROUTING.md`
  keeps each feature's blast radius to its own host.

### This feature's reachability proof: the ArgoCD UI route

To prove the contract end-to-end at zero new-workload cost (research recommendation) and
resolve `gitops-argocd`'s deferred ArgoCD-UI-ingress item, this step authors:

- `HTTPRoute` **`argocd`** in the `argocd` namespace, `parentRefs` to `agrippa-gateway`,
  `hostnames: [argocd.127.0.0.1.nip.io]`, `backendRefs: [argocd-server:80]`.
- `argocd.127.0.0.1.nip.io` added to `agrippa-gateway-tls`'s `dnsNames`.
- **Backend TLS wrinkle:** `argocd-server` serves HTTPS by default; behind a
  TLS-terminating gateway routing to its `:80`, ArgoCD must run in insecure mode
  (`server.insecure: "true"` in `argocd-cmd-params-cm`). That is a one-line patch to
  `apps/platform/argocd/` (a cross-step touch, build-phase) or, alternatively, route to
  `argocd-server:443` with backend TLS. The plan phase picks the cleaner of the two; the
  contract and the feature test do not depend on which.

### Cross-step touches (summary)

- **`apps/platform/argocd/kustomization.yaml`** — append `--enable-helm` to the
  `argocd-cm` `kustomize.buildOptions` patch, and (if the insecure-backend route is
  chosen) a one-line `argocd-cmd-params-cm` `server.insecure` patch.
- **`core/overlays/dev/kustomization.yaml`** — replace `resources: []` with the real
  composition above.
- **`scripts/test-feature.sh`** — add `networking.bats` to the auto-discovery exclusion
  list (it drives the long-lived `agrippa-dev` cluster and the GitOps-reconciled `core`
  layer, not the throwaway `agrippa-feature` cluster), the same one-line,
  convention-consistent edit `cluster-core.bats` and `gitops.bats` already made. **This
  exclusion lands with the feature test in the design phase** (not deferred to build):
  the test file is committed now, so without the exclusion `mise run test:feature` would
  pick it up and loop ~5 min against a clusterless `core` before failing.
- **`mise.toml`** — no new tool pins (see Libraries & Skills). `test:static` optionally
  gains a `kustomize build core/overlays/dev | kubeconform` step, but that requires
  Helm/network at build time and would break the per-push <90s budget; the feature test
  plus ArgoCD's own sync are the validation of `core`'s rendered output, so a
  render-and-validate step for `core` is left as a build-phase judgement, not mandated.

### Challenges

- **Version-specific CNI paths.** The `cniConfDir`/`cniBinDir` values are correct only
  for the pinned `rancher/k3s:v1.35.5-k3s1`. The design records them and the reason;
  the build re-verifies against the live node and the plan notes to re-verify on any k3s
  pin bump (the very drift upstream issue #57264 exists for).
- **Machine-specific IPs in committed GitOps.** The node IP (`externalIPs`) and the pool
  CIDR are per-cluster-create values living in git. Committed as documented defaults for
  the current long-lived cluster, with a `docker inspect` / `docker network inspect`
  re-derivation note; acceptable because the cluster is recreated infrequently and the
  edit is a one-line, reversible seam (prod uses a real LoadBalancer with neither hack).
- **CRD-before-CR under one sync.** The intra-`core` sync-wave scheme plus the
  `ServerSideApply`/`SkipDryRunOnMissingResource` already on the `core` Application are
  what keep an all-at-once first reconcile from failing on not-yet-existing CRDs.
- **`helm template` semantics.** `helmCharts:` inflation runs `helm template` (no hooks,
  no cluster lookup) — the correct GitOps behavior; Istio's ambient charts render
  cleanly this way. Confirm during build that no chart relies on a `lookup`/hook the
  templated path drops.

## Alternatives

**Composition of the four sources under `core` (the open decision research handed to
this design):**

- **Recommended — one `core` Application, a single `kustomize build` with `resources:`
  (raw manifests, the `gitops-argocd` precedent) + `helmCharts:` (Istio only) +
  authored CRs, ordered by sync-wave annotations.** Keeps the existing single
  Application and one KSOPS-compatible build; gives **hard** per-resource sync-wave
  ordering within one sync; minimizes the Helm surface to the one source that requires
  it; matches the repo's established upstream-consuming-kustomization pattern. Cost: one
  anticipated `--enable-helm` flag on the repo-server (the session context and research
  Resolved item 2 both flagged this exact wiring). **Chosen.**
- **All-`helmCharts:` inflation (metallb + cert-manager + Istio all as Helm charts).**
  More uniform, and lets values flow through Helm for all three. Rejected as the default
  because it diverges from `gitops-argocd`'s raw-manifest precedent for the two sources
  that publish a perfectly good single manifest (metallb-native, cert-manager static),
  enlarging the Helm-template surface (and its `lookup`/hook caveats) for no gain. Stays
  available if a later need for metallb/cert-manager Helm values surfaces.
- **Nested app-of-apps — a child ArgoCD `Application` per component (native Helm
  sources), listed by `core/overlays/dev/kustomization.yaml`.** The closest runner-up:
  it matches `ARCHITECTURE.html`'s app-of-apps motif and needs **no** `--enable-helm`
  (ArgoCD's native Helm source is always available). Rejected because it proliferates
  ~8–10 Application CRs and a second app-of-apps level, and cross-`Application` ordering
  is softer (retry/health-gated across Applications) than per-resource sync-waves within
  one sync. Reversible to this if `core` later grows enough independent components to
  warrant per-component Applications.
- **A single multi-source ArgoCD Application (`spec.sources`).** Native, but ordering
  across sources is soft, KSOPS/kustomize does not apply per native-Helm source, and
  health is aggregated across sources — a heavier, less-ordered shape than the single
  kustomize build. Rejected.

**Other alternatives:**

- **`istioctl`/IstioOperator install instead of direct Helm.** Rejected on the research:
  the operator flow ignores the `cniConfDir`/`cniBinDir` overrides this k3s version
  needs (open issue #58203), and direct Helm matches how the other `core` components
  install. `istioctl` stays an optional debugging CLI, not the install path.
- **Re-enabling ServiceLB/Klipper for the Gateway Service to get host reachability.**
  Rejected: it re-litigates the ServiceLB-vs-metallb decision `cluster-core-k3d` and the
  project research already settled, and the `externalIPs` fix achieves the same DNAT
  without it (live-verified). Kept only as a last-resort fallback.
- **A wildcard Gateway certificate.** Rejected: the mirrored hosts are multiple labels
  deep, so no single wildcard covers `davidsouther.com.127.0.0.1.nip.io` *and*
  `trips.davidsouther.com.127.0.0.1.nip.io` (the `ROUTING.md` §2 rule). One shared cert
  with explicit SANs is the honest local-dev form.
- **A dedicated throwaway backend for the reachability proof instead of ArgoCD.**
  Rejected: ArgoCD's UI already exists and is Synced/Healthy, so routing it costs no new
  workload and resolves `gitops-argocd`'s deferred UI-ingress item at the same time
  (research recommendation).

## Summary

This feature-step lands the local ingress substrate into the already-Synced `core`
layer — metallb, the Gateway API CRDs, cert-manager (with a SelfSigned→CA local issuer
chain), and Istio ambient with the live-verified k3s CNI-path overrides — composed under
the **single existing `core` Application** as one KSOPS+Helm `kustomize build`
(`resources:` for the three raw-manifest sources, `helmCharts:` for Istio, authored CRs
for the config), ordered by a fine-grained intra-`core` sync-wave scheme this step
defines. It adds the one repo-server wiring change the composition needs
(`--enable-helm` on the `argocd-cm` build options) and one `test:feature` exclusion
line. Above all it **defines the shared Gateway/HTTPRoute/hostname/TLS contract** every
later UI feature-step consumes: the `agrippa-gateway` in `istio-ingress` terminating TLS
on `:443`, host-reachable via `spec.externalIPs` (the mechanism live-verified; the
supplemental-Service topology confirmed early in the build) plus the metallb IP,
the `<prod-host>.127.0.0.1.nip.io` hostname scheme, and the `agrippa-ca` local-CA issuer
with one shared explicit-SAN certificate. The one feature test proves the whole path by
reaching the ArgoCD UI through the Gateway with a local-CA cert, which also resolves
`gitops-argocd`'s deferred ArgoCD-UI-ingress item.

This Design-phase run does **not** deploy the Networking content: reconciling it requires
a full ArgoCD sync of newly-committed charts and CRs (build-phase work), and the CNI-path
and node-IP values want live re-verification against the running node at build time. The
feature test is therefore left **RED** (baseline recorded below); the build phase turns
it green after committing the `core` composition and letting ArgoCD reconcile it.

### Open Artifact Decisions

Concrete artifact choices this design invents that are not fixed by a skill template, an
existing project convention, or the cleared `research.md`. (The composition pattern, the
sync-wave scheme, the CNI-path values, the `externalIPs` mechanism, the hostname scheme,
and the SelfSigned→CA chain are all resolved above from the cleared research and the
parent design, so they are stated as conclusions, not surfaced here.)

**`core/overlays/dev/` internal layout — flat overlay vs. `core/base/` + overlay
patches:** whether the authored CRs and the `resources:`/`helmCharts:` list live
directly in `core/overlays/dev/kustomization.yaml`, or in a `core/base/` that
`overlays/dev` references and patches (mirroring the `<layer>/overlays/dev` shape the
other layer Applications use).
Proposed: a **flat `core/overlays/dev/`** for now (the `core` Application points straight
at it, there is no `overlays/prod` content to share a base with yet), with a `core/base/`
extraction deferred to whenever `overlays/prod` lands — the seam the project preserves
but does not build.

**The shared object names (`agrippa-gateway`, `istio-ingress`, `agrippa-ca`,
`selfsigned`, `agrippa-gateway-tls`, `agrippa-pool`, `agrippa-l2`,
`agrippa-gateway-external`, and the `argocd.127.0.0.1.nip.io` proof host):** the concrete
spellings of the shared contract's resources, which every later feature-step references.
Proposed: as named throughout the Specification. They follow the committed `agrippa-*`
naming family (`agrippa-dev`, `agrippa-age-dev`) and Istio's `istio-ingress` convention;
settle them here since the parent plan assigns the shared-contract spelling to this step.

**The `externalIPs` node IP and the metallb pool CIDR as committed values:** machine/
cluster-create-specific values living in a GitOps-committed manifest.
Proposed: commit `172.18.0.3` and `172.18.255.200-172.18.255.250` as the documented
defaults for the current long-lived `agrippa-dev` cluster, each with a re-derivation
comment (`docker inspect` / `docker network inspect`), and re-verify at build time.

### Resolved by the long-loop reviewer (2026-07-08)

This block resolves, in one pass per Ailly's Draft Gate Enforcement convention, both
this design's own Open Artifact Decisions (A–C) and the seven falsifiable questions the
separately dispatched design-intent review left OPEN
(`reviews/design-intent-review.md`, Q1–Q7). Each was researched against the in-repo
contracts (`ARCHITECTURE.html` § S8, `ROUTING.md`, `DEVELOPMENT.md`), the cleared parent
`design.md`/`plan.md` and this feature's cleared `research.md`, the committed sibling
artifacts (`apps/platform/argocd/kustomization.yaml`, `apps/core.yaml`,
`scripts/bootstrap.sh`, `scripts/test-feature.sh`), and — where cheap and
non-destructive — the live `k3d-agrippa-dev` cluster, then decided to the conservative,
reversible default. No escalation trigger (irreversible, out of recorded scope, or
underdetermined) fired, so this draft gate is cleared (marker now `*Reviewed
2026-07-08*`). The live cluster was **read only** (the `core` Application status, the
four absent namespaces, the RED-baseline curl, the node IP and Docker subnet) and left
in its clean pre-review state — nothing was installed.

**Q1. ArgoCD control-plane UI as the reachability proof. Decided: keep ArgoCD as the
zero-new-workload proof, and route to `argocd-server:443` with backend TLS rather than
patching `server.insecure: "true"`.** The contract this step proves (host `:443` → k3d
port-map → node IP via `externalIPs` → gateway pods → HTTPRoute → backend, TLS
terminated with the local-CA leaf) is workload-agnostic; the backend identity does not
change what the Gateway/HTTPRoute/TLS path exercises. ArgoCD is the conservative target
because it already exists Synced/Healthy (live-confirmed) at zero new-workload cost and,
decisively, Feature 2 (`gitops-argocd`) EXPLICITLY handed its deferred "ArgoCD UI
ingress" item to Networking (gitops design § Deferred decisions), so routing it fulfils
a recorded handoff, not scope creep. The intent review's two real costs are addressed:
(a) the prod Tier-1 CF-Access gating of ArgoCD (`ARCHITECTURE.html` § S8 lines 960/968)
is an EDGE concern explicitly out of local scope, and in prod traffic still transits the
same in-cluster Gateway after the edge — so the local proof exercises the same
in-cluster contract; the host-name divergence (argocd vs the three workload mirror
hosts) is immaterial to what the mechanism proves. (b) The induced SECOND mutation of
Feature 2's cleared `apps/platform/argocd/` config is ELIMINATED by choosing the
backend-TLS route (`argocd-server:443`) the design already offers as an equal
alternative — the Gateway re-originates TLS to argocd-server's native HTTPS, so no
`argocd-cmd-params-cm` `server.insecure` patch is needed, keeping Feature-2 blast radius
to the one unavoidable touch (Q4). Reversible (the test's `GW_HOST` override exists for
exactly this), in scope.

**Q2. One shared append-only Gateway certificate + `allowedRoutes.namespaces.from:
All`. Decided: keep both for this step, with a recorded watch-item to split to
per-feature `Certificate`s (multiple listener `certificateRefs` selected by SNI) if the
parallel band (Features 5–8) hits real merge contention or a per-host-independence
need.** `ROUTING.md` § 3's per-host independence governs ROUTES ("each subdomain is its
own HTTPRoute, independently owned"), which the design preserves — every consumer
authors its own HTTPRoute. It does not mandate per-host certificate OBJECTS; § 2/§ 6
treat certs as belonging with hosts under the assumption of a cheap wildcard, which does
not hold locally (multi-label nip.io hosts, `ROUTING.md` § 2). The shared cert has a
real, deliberate benefit the alternative loses: the Gateway object stays STABLE
(features edit only the `Certificate`'s `dnsNames`, never the Gateway listener), whereas
per-host certs registered on the shared listener would edit the Gateway itself. At
single-operator scale (`ROUTING.md`'s stated frame) an append to a `dnsNames` list is
append-only and rarely conflicts, and only ONE consumer (argocd) exists now, so the
coupling the intent review flags is entirely prospective and cannot be exercised here
(the same limit the design records for the append mechanism). Splitting to per-feature
`Certificate`s later is a mechanical refactor the first contending feature can make with
real evidence. `from: All` is confirmed because it AVOIDS a shared-mutable edit (features
need not register their namespace) and the local cluster is a single trust domain —
prod's tenant isolation is the CF-Access edge tier, out of scope. Interaction with Q7:
because all of this lives in `core/overlays/dev`, the shared cert is already
overlay-scoped. Reversible, in scope; the conventions do not mandate the alternative, so
no escalation.

**Q3 / Open Decision C. Committed machine-specific IPs (`externalIPs: 172.18.0.3`, pool
`172.18.255.200-.250`) vs the one-command-any-machine intent. Decided: commit them as
documented defaults with re-derivation comments AND a build-phase re-derivation step;
record the second-operator / cluster-recreate reproducibility LIMITATION explicitly; and
park GitOps-native machine-independent derivation to `TASKS.md`.** Live-confirmed the
literals are correct for the current cluster (node `172.18.0.3`, network
`172.18.0.0/16`). Committing a default and confirming at build time is the ESTABLISHED
project pattern, not a new sin: this feature's cleared `research.md` already sizes the
metallb pool "from the live cluster's Docker network subnet ... confirm at build time,
since it is assigned per cluster-create." The intent review's valid added point (a
second-operator clone, or the same operator's `cluster:down`/`up`, can draw a different
Docker subnet and silently break the request path) is real, but the "derive at apply
time" fix is genuinely non-trivial under GitOps: ArgoCD's repo-server runs `kustomize
build` in-cluster with no access to the operator's Docker daemon, so a
`docker inspect`-driven patch cannot run there — it must be a bootstrap/`mise`-time step
writing the value in, which is cross-cutting (Feature 0/2 territory) and scope creep to
build here. Conservative default: unblock the step with the literals (reversible one-line
edits), make the reproducibility gap EXPLICIT rather than resting on "the owner's
long-lived cluster," and track the machine-independent mechanism. In recorded scope (the
design surfaces it as Open Decision C), reversible; no escalation.

**Q4. Mutating Feature 2's cleared `apps/platform/argocd/kustomization.yaml` (append
`--enable-helm` to `argocd-cm` `kustomize.buildOptions`). Decided: sanction it, confined
to the additive flag, with a build-phase note that the repo-server rollout must complete
before `core` first renders its Helm charts on the already-bootstrapped cluster.**
Verified the committed file carries `"--enable-alpha-plugins --enable-exec"` (KSOPS) and
that `scripts/bootstrap.sh` stage 3 applies `apps/platform/argocd` at bootstrap — so
appending `--enable-helm` lands the flag before `core` renders on a fresh bootstrap (no
chicken-and-egg), exactly parallel to how the KSOPS flags were added to the SAME field.
The touch is additive (does not alter Feature 2's KSOPS assertions, so `gitops.bats`
stays green), reversible, necessary for the chosen composition, and flagged by this
feature's `research.md` (Resolved item 2). It differs from Feature 2's OWN escalated item
6: that touched a PROJECT-ALTITUDE, human-owned definition-of-done artifact
(`closing-bell.md`) to resolve a contradiction; this extends a feature-level infra CONFIG
the app-of-apps was explicitly built to "receive each later feature-step's manifests and
charts" (gitops design), and `apps/core.yaml` already carries a matching forward seam
(`ServerSideApply`/`SkipDryRunOnMissingResource` "for cert-manager/Gateway API/Istio CRDs
in a later feature-step"). Build-phase caveat: on the ALREADY-bootstrapped `agrippa-dev`
cluster, committing `--enable-helm` and the `core` `helmCharts:` content together
requires the argocd Application to roll out the repo-server change before `core` renders,
or the first `kustomize build core` fails "helm disabled" — sequence the repo-server
rollout first (or re-run `bootstrap`). Reversible, in this design's recorded scope; no
escalation. This is the one UNAVOIDABLE Feature-2 touch; the avoidable second one
(`server.insecure`) is dropped per Q1.

**Q5. Does the test encode the CONTRACT or one reachability instance? Decided: the
end-to-end curl + issuer + `core` Synced/Healthy is the correct core of the proof for the
single current consumer; the build phase SHOULD add cheap substrate assertions (Gateway
`Programmed`, a metallb-assigned ingress IP present, listener `AttachedRoutes >= 1`) to
localize failures and encode "ready to be shared."** A 2xx/3xx through the full path
transitively proves metallb IP, the `externalIPs` DNAT, gateway pods, the HTTPRoute, the
backend, and TLS all work — a stronger integration proof than isolated status checks. But the live
check surfaced a real gap the hardening closes: `core` is ALREADY `Synced/Healthy` as the
empty `resources: []` placeholder (live-confirmed), so the test's
`wait_for_core_synced_healthy` gate PASSES today and does NOT discriminate empty-core from
a fully-reconciled substrate — the only thing separating RED from GREEN is currently the
curl. Adding Gateway `Programmed` / metallb-IP / `AttachedRoutes` assertions makes
substrate-readiness explicit and diagnosable without waiting for Feature 9's second host
(the one thing genuinely un-exercisable now, as the intent review concedes). Recommended,
not a blocker: the current assertions correctly define "done." Also correct a minor
RED-baseline prose imprecision at build: the design says the suite "fails at its first
assertion" with curl returning "Empty reply from server," but live, `core` is already
Synced/Healthy so THEN 0 passes and the suite fails at the curl (THEN 1), which returns
`SSL_ERROR_SYSCALL`/exit 35 with nothing on `:443` — same RED verdict, imprecise prose.
Reversible, in scope.

**Q6. Grepping `curl -kv` stderr for the issuer. Decided: re-encode the TLS-issuer
assertion on the stable `openssl s_client -connect 127.0.0.1:443 -servername "$GW_HOST"
</dev/null | openssl x509 -noout -issuer` interface (keep `curl -k` for reachability);
pin `openssl` if target environments' backends vary.** LIVE-CONFIRMED the concern: the
operator's system `curl` here links **LibreSSL** (`curl: (35) LibreSSL SSL_connect ...`),
not OpenSSL — so `curl -v`'s human-readable, unversioned cert dump (an `issuer:` line that
varies by TLS backend) is exactly the brittle, unpinned interface the intent review names,
able to false-negative for reasons unrelated to whether cert-manager wired the Gateway
cert. `openssl x509 -noout -issuer` is a parseable, near-stable interface (a CN substring
match tolerates the LibreSSL-vs-OpenSSL `issuer=` formatting difference) and still hits the
SERVED cert via the same `127.0.0.1:443` port-map + SNI, so it proves the Gateway serves
the local-CA leaf, not merely that the Secret exists. Does not change what "done" means or
the RED baseline (nothing listens on `:443` today). Reversible, in scope.

**Q7 / interaction with the `overlays/prod` deferral. Decided: confirm the Gateway `:443`
local-CA leaf is the local STAND-IN FOR THE CLOUDFLARE EDGE's public-TLS termination, and
record that per-host public-cert bindings to the Gateway are `overlays/dev`-scoped —
`overlays/prod` (the preserved-not-built seam) terminates public TLS at the edge with the
Gateway carrying internal/mesh certs only.** The intent review's factual premise is correct
against `ARCHITECTURE.html` § S8 (line 916 "public TLS @ Cloudflare edge"; 967 "Cloudflare
Edge · TLS terminate"; 984 "CertManager · internal + mTLS certs. Public TLS terminates at
the Cloudflare edge"). But the resolution is a CLARIFICATION the repo already determines,
not a re-architecture: the parent `design.md` and this design both frame the local CA as
"replaces the Cloudflare edge" / the local stand-in for edge TLS, so the dev Gateway
PLAYING the edge's public-TLS-termination role is the intended parity mapping, not a
conflation. Parity stays clean because the entire dev cert topology lives in
`core/overlays/dev` (and, for Feature 9, in each workload chart's dev overlay): when the
deferred cloud cycle builds `overlays/prod`, it drops the per-host Gateway public certs in
favor of edge TLS + internal-only Gateway certs, and the per-host `overlays/dev` cert
material vanishes with the overlay — the seam the project preserves. The requirement this
makes explicit for later features: keep each host's Gateway public-cert binding
overlay-scoped (dev) so it does not leak into the prod topology. Determined by
`ARCHITECTURE.html` + the project's edge-stand-in framing; building `overlays/prod` stays
out of scope; reversible. No escalation.

**Open Decision A. `core/overlays/dev/` layout — flat vs `core/base/` + patches. Decided:
flat `core/overlays/dev/`.** Matches both sibling feature-steps' cleared decisions
(`gitops-argocd`'s flat `apps/<layer>.yaml`, `cluster-core`'s flat config) made on the
same ground — there is no `overlays/prod` content to share a base with yet — and the
`core/base/` extraction stays a reversible refactor deferred to when the prod seam is
built. Determined by sibling convention, reversible, in scope.

**Open Decision B. The shared object names (`agrippa-gateway`, `istio-ingress`,
`agrippa-ca`, `selfsigned`, `agrippa-gateway-tls`, `agrippa-pool`, `agrippa-l2`,
`agrippa-gateway-external`, proof host `argocd.127.0.0.1.nip.io`). Decided: as named.**
They follow the committed `agrippa-*` family (`agrippa-dev`, `agrippa-age-dev`), Istio's
conventional `istio-ingress` gateway namespace, cert-manager's issuer-naming norm, and the
parent design's resolved hostname scheme (item 6, `<prod-host>.127.0.0.1.nip.io`; ArgoCD
has no prod host so the scheme's suffix applies to the service name). The parent plan
assigns the shared-contract spelling to this step. Determined by convention, reversible (a
rename touches this step's own manifests + test in lockstep before any consumer binds), in
scope.

**Deferred decisions — confirmed correctly parked.** cloudflared/ExternalDNS,
`overlays/prod`, public ACME TLS, per-workload HTTPRoutes/Certificates (Feature 9),
host-trust-store CA import, and the HTTP→HTTPS redirect HTTPRoute all match the parent
design's scope boundaries and stay parked for `TASKS.md` at cleanup. Two items are ADDED to
that parked set so the cloud cycle inherits them: the Q7 overlay-scoping requirement (dev
Gateway public certs are a `overlays/prod` seam), and the Q3 GitOps-native
machine-independent IP-derivation gap.

### Deferred decisions (park to `TASKS.md` at cleanup)

- **cloudflared and ExternalDNS** (declared in `core`, excluded from `overlays/dev`),
  **`overlays/prod`**, and **public ACME TLS** — deferred to the cloud cycle; the local
  CA, `*.nip.io`, and the `externalIPs` reachability fix are the local stand-ins, seams
  preserved.
- **Per-workload HTTPRoutes and Certificates** — Feature 9 (Workloads) consumes this
  contract; Auth and Observability consume it for their own UIs. None is built here.
- **Importing the local CA into the host trust store** — an opt-in operator action;
  probes use `curl -k` (`research.md` decision 3).
- **HTTP→HTTPS redirect HTTPRoute** — the `:80` listener is provisioned; the redirect
  route itself is a convention later steps may add. The local `curl -k` path uses `:443`
  directly.

## Feature Test

**Path:** `tests/networking.bats` (following `DEVELOPMENT.md`'s `tests/<feature>.bats`
convention, feature = "networking"; the `-istio` tool qualifier is dropped just as
`cluster-core.bats` dropped `-k3d` and `gitops.bats` dropped `-argocd`).

**User story (Given / When / Then):** *Given* the bootstrapped long-lived `agrippa-dev`
cluster (Features 1–2) with this Networking content committed and reconciled by ArgoCD
into the `core` layer, *When* an operator requests
`https://argocd.127.0.0.1.nip.io/` through the k3d `:443` host port-map, *Then* the
request is served through the shared Istio Gateway (host `:443` → k3d loadbalancer →
node IP via `externalIPs` → gateway pods → the `argocd` HTTPRoute → `argocd-server`), the
response is a live UI status (`2xx`/`3xx`, not a connection failure), and the TLS
certificate presented is **issued by the local CA** (`CN=Agrippa Local Dev CA`), not
Istio's built-in self-signed default — proving the Gateway + HTTPRoute + local-hostname +
local-CA-TLS contract end-to-end. `curl -k` tolerates the deliberately-untrusted local CA
(`research.md` decision 3). Like `cluster-core.bats` and `gitops.bats` it deliberately
does **not** tear the cluster or ArgoCD down.

**Current state: RED (baseline captured this run).** With `core/overlays/dev` still the
empty `resources: []` placeholder, no Istio Gateway is listening: `curl -k
https://argocd.127.0.0.1.nip.io/` through the port-map returns "Empty reply from
server"/connection failure (the research-confirmed negative-control behavior) and the
suite fails at its first assertion. That red state defines "done" for this feature-step.
This Design-phase run does **not** turn it green: reconciling the `core` composition is a
full ArgoCD sync of newly-committed charts and CRs, and the CNI-path/node-IP values want
live re-verification against the running node — both build-phase work outside this
phase's write-only-the-test gate. The build phase turns it green after committing the
`core` content and letting ArgoCD reconcile it.
