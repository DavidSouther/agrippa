# Implementation Plan: Networking (Istio ambient + Gateway API + cert-manager + metallb)

*Reviewed 2026-07-08*

> A separately dispatched long-loop reviewer cleared this feature plan's draft
> gate on 2026-07-08. The plan transcribes the already-cleared feature
> `design.md`'s Specification (and its `Resolved by the long-loop reviewer`
> block), so the review's job was to verify that transcription, verify the
> plan's claims about current repo state against the committed files, and decide
> the two net-new mechanism items the plan's own Step 4 surfaced and deferred to
> build: (a) how Istio ambient re-originates TLS to the HTTPS `argocd-server:443`
> backend, decided to an **Istio `DestinationRule` (`SIMPLE` + `insecureSkipVerify`)**
> rather than a `BackendTLSPolicy`; and (b) the `agrippa-gateway-external`
> selector label, paper-resolved to the documented Istio Gateway-injection
> convention `gateway.networking.k8s.io/gateway-name: agrippa-gateway`. Both
> decisions are folded into Step 4 (and Step 0's file layout) below and recorded
> in full in the *Resolved by the long-loop reviewer* block at the end. No
> escalation trigger fired; the gate is cleared.

**Feature test:** `tests/networking.bats`
**User story:** Given the bootstrapped, GitOps-managed `agrippa-dev` cluster (Features 1-2) with this Networking content committed, when an operator requests `https://argocd.127.0.0.1.nip.io/` through the k3d `:443` host port-map, then the request is served through the shared Istio Gateway to `argocd-server` with a TLS certificate issued by the local CA (`CN=Agrippa Local Dev CA`), proving the Gateway + HTTPRoute + local-hostname + local-CA-TLS contract every later UI feature-step consumes.

**Libraries & Skills (carried forward from `design.md`/`research.md`; load before each build step):**

- `developer:initialize` — carried forward per convention, but this feature-step exercises no residual `mise` work: it adds **no** new mise-managed CLI (metallb, the Gateway API CRDs, cert-manager, and Istio ambient are all in-cluster resources ArgoCD reconciles, not local tools; `istioctl` stays optional/unpinned per the design's Libraries & Skills). Nothing in `mise.toml` changes across any step below.
- `research:public` and `research:codebase` — for the per-tool detail each step below explicitly defers to build time: the exact pinned release tag for the Gateway API standard-install manifest and the cert-manager static manifest, the exact Istio Helm chart `version:` for all four charts, and (Step 4) the Istio ambient / Gateway API mechanism for re-originating TLS to an HTTPS backend (`argocd-server:443`).
- No library-shipped agentic skill exists for Istio, Gateway API, cert-manager, or metallb (reconfirmed by `research.md` and `design.md`). Build to `ARCHITECTURE.html` (Cluster Core layer, Request Path view), `ROUTING.md` (host-based routing, HTTPRoute precedence), and `DEVELOPMENT.md` (test tooling, SOPS/KSOPS wiring) directly.

**Patterns beat (`patterns:using-patterns` consulted):** No domain-object pattern applies, matching both completed siblings' conclusion. This feature-step has no typed application code — only GitOps infrastructure config (Kustomize kustomizations, `helmCharts:` inflation, authored Kubernetes CRs, one bats suite). `newtype`, `domain-objects`, `builder`, `visibility`, `parse-dont-validate`, `type-states`, `repository`, `aggregate`, `unit-of-work`, and `bootstrap-and-service` all require a typed domain model that does not exist here, so none are invoked. Two patterns shape *how* the surface and its tests are written, not the surface itself: **`arrange-act-assert`** for the one bats `@test` (the existing `run`/assert shape `tests/networking.bats` and its sibling suites already follow), and **`errors-typed-untyped`**, resolved to the untyped side — an ArgoCD `Application`'s `sync`/`health` status and a `kubectl`/`curl` exit code are the correct, sufficient failure signals here, consumed only by an operator's shell, `bats`, and ArgoCD's own reconcile loop; no in-process caller needs to match distinct typed failure modes. One pressure specific to this feature: unlike the two siblings' single flat resource list, this feature-step's surface is a **composition of four independently-versioned upstream sources plus one authored contract**, ordered by sync-wave — the closest analogy is not a missing domain pattern but a deployment-ordering concern, which the design's own intra-`core` sync-wave scheme (not a catalog pattern) already resolves.

**Steps:**
- [x] Step 0: API surface area
- [x] Step 1: Wave `-10` — CRDs (Gateway API standard channel, Istio base)
- [x] Step 2: Wave `-5` — controllers and data plane (metallb, cert-manager, istiod/istio-cni/ztunnel)
- [x] Step 3: Wave `0` — cluster config CRs (metallb pool, cert-manager SelfSigned→CA chain)
- [x] Step 4: Wave `5` — the shared Gateway, its certificate, the `externalIPs` reachability fix, the ArgoCD HTTPRoute
- [ ] Step 5: Feature-test issuer-check correction (Q6), full GREEN, and the regression sweep

## Step 0: API surface area

Fix every file path, directory layout, and object name before any has real content, mirroring both siblings' Step 0 convention (fixed identifiers, honest inert stubs, no logic). Two changes land here:

**1. The one repo-server wiring change** (must roll out before Step 1 renders any `helmCharts:` content — Q4's sequencing caveat):

```diff
# apps/platform/argocd/kustomization.yaml
      data:
-       kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"
+       kustomize.buildOptions: "--enable-alpha-plugins --enable-exec --enable-helm"
```

This is additive only (does not touch the KSOPS flags `gitops.bats` asserts on), reconciled by the self-managed `argocd` Application inside `platform/overlays/dev`. Land and let it roll out (`kubectl -n argocd rollout status deployment/argocd-repo-server`) before committing Step 1.

**2. The `core/overlays/dev/` directory layout**, fixing every file and object name the Specification already resolved. Each nested kustomization gets its sync-wave fixed now via `commonAnnotations` (applies uniformly to every object that source produces, regardless of `kind` — the one mechanism that reaches raw multi-document upstream manifests without a per-`kind` patch list); each authored CR gets an apiVersion/kind/metadata-only stub (no `spec:`, mirroring `gitops-argocd`'s `spec: {}` stub convention). **The top-level `core/overlays/dev/kustomization.yaml` stays the existing `resources: []`** — none of these new files are referenced yet, so `core` stays trivially Synced/Healthy exactly as today (Q5) and nothing new is applied to the live cluster this step:

```text
core/overlays/dev/
├── kustomization.yaml                # UNCHANGED this step: resources: []
├── gateway-api/
│   └── kustomization.yaml            # wave -10; resources: [] (URL lands Step 1)
├── istio-base/
│   ├── kustomization.yaml            # wave -10; helmCharts: [] (base chart lands Step 1)
│   └── namespace.yaml                # Namespace istio-system stub (helm template
│                                      #   does not create namespaces; static
│                                      #   manifests below do, via their own
│                                      #   bundled Namespace object -- this is the
│                                      #   one gap only Helm-sourced Istio needs
│                                      #   filled by hand)
├── metallb/
│   └── kustomization.yaml            # wave -5; resources: [] (URL lands Step 2)
├── cert-manager/
│   └── kustomization.yaml            # wave -5; resources: [] (URL lands Step 2)
├── istio-control/
│   └── kustomization.yaml            # wave -5; helmCharts: [] (istiod/cni/ztunnel land Step 2)
├── metallb-config.yaml               # wave 0; IPAddressPool agrippa-pool, L2Advertisement agrippa-l2 (Step 3)
├── cert-issuers.yaml                 # wave 0; ClusterIssuer selfsigned, Certificate
│                                      #   agrippa-local-ca, ClusterIssuer agrippa-ca (Step 3)
├── istio-ingress-namespace.yaml      # wave 5; Namespace istio-ingress (Step 4)
├── gateway.yaml                      # wave 5; Gateway agrippa-gateway (Step 4)
├── gateway-cert.yaml                 # wave 5; Certificate agrippa-gateway-tls (Step 4)
├── gateway-external-svc.yaml         # wave 5; Service agrippa-gateway-external (Step 4)
├── argocd-httproute.yaml             # wave 5; HTTPRoute argocd (Step 4)
└── argocd-destinationrule.yaml       # wave 5; DestinationRule argocd-server-tls
                                      #   (Step 4; backend-TLS re-origination,
                                      #   reviewer-decided mechanism -- see the
                                      #   Resolved block)
```

Representative stubs (every other authored-CR file follows the same shape — `apiVersion`/`kind`/`metadata.name` [and `namespace` where namespaced], no `spec:`):

```yaml
# core/overlays/dev/gateway-api/kustomization.yaml -- Step 0 skeleton
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
commonAnnotations:
  argocd.argoproj.io/sync-wave: "-10"
resources: []   # pinned Gateway API standard-install.yaml URL lands Step 1
```

```yaml
# core/overlays/dev/cert-issuers.yaml -- Step 0 skeleton (name-only stub, no spec)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: agrippa-local-ca
  namespace: cert-manager
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: agrippa-ca
  annotations:
    argocd.argoproj.io/sync-wave: "0"
```

This fixes: the directory layout (Open Decision A, flat `overlays/dev`, confirmed), every shared-contract object name (Open Decision B), and the four-tier sync-wave scheme (`-10`/`-5`/`0`/`5`) as constants every later step reuses. `tests/networking.bats` is a `design.md` artifact and already exists (RED baseline: "Empty reply from server" / `SSL_ERROR_SYSCALL`); Step 0 does not touch it. After Step 0, the feature test still fails identically — `core`'s top-level `resources:` list is unchanged — but every name and file the remaining steps fill in now exists and is fixed.

## Step 1: Wave `-10` — CRDs (Gateway API standard channel, Istio base)

**Enables:** no feature-test assertion flips yet (`core` was already trivially Synced/Healthy on empty resources — Q5 — and stays Synced/Healthy on inert CRDs; THEN 1/THEN 2 still fail, nothing serves `:443`). Substrate-only: this step exists so wave `-5`'s controllers have their CRDs to watch at startup, per the design's own wave grouping ("CRDs that other resources watch at startup: the Gateway API standard-install CRDs and `istio-base`").

Wire `gateway-api/` and `istio-base/` into the top-level `core/overlays/dev/kustomization.yaml`'s `resources:` list (the first real content this feature-step applies to the live cluster). Fill `gateway-api/kustomization.yaml`'s `resources:` with the pinned `standard-install.yaml` URL for the Gateway API standard channel (`research:public` at build time for the exact release tag — same deferral `gitops-argocd`'s Step 2 used for ArgoCD's own install manifest). Fill `istio-base/kustomization.yaml`'s `helmCharts:` with the `base` chart (`repo: https://istio-release.storage.googleapis.com/charts`, `name: base`, pinned `version:` — build-time lookup), `valuesInline: {global: {platform: k3d}, profile: ambient}`, target namespace `istio-system`; fill in `istio-base/namespace.yaml`'s stub with a real (trivial) `Namespace: istio-system` object — required because `helmCharts:` inflation runs `helm template`, which (unlike `helm install --create-namespace`) never emits a `Namespace` object on its own.

**Tests**

```bash
test "Gateway API and Istio CRDs land, core stays Synced/Healthy":
  run kubectl --context k3d-agrippa-dev -n argocd get application core \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"
  run kubectl --context k3d-agrippa-dev get crd
  assert output contains "gatewayclasses.gateway.networking.k8s.io"
  assert output contains "httproutes.gateway.networking.k8s.io"
  assert output contains "wasmplugins.extensions.istio.io"   # a base-chart CRD
  run kubectl --context k3d-agrippa-dev get namespace istio-system
  assert status == 0
```

- Edge case: the `--enable-helm` flag from Step 0 must have finished rolling out to `argocd-repo-server` before this commit syncs, or `kustomize build` fails "helm is disabled" (Q4's sequencing caveat) — verify `kubectl -n argocd rollout status deployment/argocd-repo-server` first.
- Edge case: `commonAnnotations` on the `gateway-api/` kustomization must not collide with any annotation the standard-install manifest itself already sets (checked live, not assumed).
- Edge case: the Gateway API CRDs must be `v1` (`GA`) channel resources or the later `Gateway`/`HTTPRoute` CRs may target a stale `apiVersion` — confirm the standard-channel release matches the API version this step's later authored CRs use.

**Implementation Outline**

```text
core/overlays/dev/kustomization.yaml:
  resources:
    - gateway-api/
    - istio-base/

core/overlays/dev/gateway-api/kustomization.yaml:
  resources:
    - https://github.com/kubernetes-sigs/gateway-api/releases/download/<tag>/standard-install.yaml

core/overlays/dev/istio-base/kustomization.yaml:
  resources:
    - namespace.yaml
  helmCharts:
    - name: base
      repo: https://istio-release.storage.googleapis.com/charts
      version: <pinned; research:public at build>
      releaseName: istio-base
      namespace: istio-system
      valuesInline:
        global: {platform: k3d}
        profile: ambient
```

## Step 2: Wave `-5` — controllers and data plane (metallb, cert-manager, istiod/istio-cni/ztunnel)

**Enables:** no feature-test assertion flips yet, but `core`'s Synced/Healthy check (THEN 0) now genuinely discriminates empty from populated `core` for the first time (Q5's concern) — five real controller workloads must reach Ready. This is also the step carrying the design's near-certain-hit risk: the k3s-version-specific CNI path overrides.

Wire `metallb/`, `cert-manager/`, and `istio-control/` into the top-level `resources:` list. Fill `metallb/kustomization.yaml`'s `resources:` with the pinned `metallb-native.yaml` manifest URL (current stable v0.16.1 per `research.md`; re-check at build). Fill `cert-manager/kustomization.yaml`'s `resources:` with the pinned static `cert-manager.yaml` install manifest URL (bundles its own CRDs, controller, and webhook — build-time tag lookup). Fill `istio-control/kustomization.yaml`'s `helmCharts:` with `istiod`, `cni`, and `ztunnel` (same repo, pinned versions, `namespace: istio-system`, `valuesInline: {global: {platform: k3d}, profile: ambient}` on all three) — the `cni` chart *additionally*, as **top-level** values (not nested under a `cni:` key, matching design's explicit correction): `cniConfDir: /var/lib/rancher/k3s/agent/etc/cni/net.d`, `cniBinDir: /var/lib/rancher/k3s/data/cni` (both live-verified against the pinned `rancher/k3s:v1.35.5-k3s1` node this session; re-verify if that image pin ever moves).

**Tests**

```bash
test "metallb, cert-manager, and istiod/istio-cni/ztunnel are all Ready":
  run kubectl --context k3d-agrippa-dev -n argocd get application core \
    -o jsonpath='{.status.sync.status} {.status.health.status}'
  assert output == "Synced Healthy"
  run kubectl --context k3d-agrippa-dev -n metallb-system get pods --no-headers
  assert output does not contain "CrashLoopBackOff|Pending"
  run kubectl --context k3d-agrippa-dev -n cert-manager get pods --no-headers
  assert output contains "Running" for controller, webhook, cainjector
  run kubectl --context k3d-agrippa-dev -n istio-system get pods -l app=istiod --no-headers
  assert output contains "Running"
  run kubectl --context k3d-agrippa-dev -n istio-system get daemonset ztunnel \
    -o jsonpath='{.status.numberReady}'
  assert output == desired count (all nodes)
```

- Edge case (the design's flagged near-certain hit): if the CNI override values are wrong or absent, `ztunnel`/workload pods lose networking or `istio-cni` node-agent CrashLoops — verify live with `kubectl -n istio-system logs -l k8s-app=istio-cni-node` and `docker exec k3d-agrippa-dev-server-0 ls /var/lib/rancher/k3s/data/cni` before trusting green. **Hit during build**: exactly this — the `cni` chart's own `platform: k3d` values profile silently re-promoted its hardcoded `/bin` over this file's explicit `cniBinDir` (a later template, `zzy_descope_legacy.yaml`, merges the profile's `cni:`-nested values back to top level, sorted to run after the profile-flatten template). Fixed by omitting `platform: k3d` from the `cni` chart's own `valuesInline` (istiod/ztunnel keep it); verified via the rendered DaemonSet's actual hostPath volumes before touching the live cluster.
- Edge case found during build, not anticipated in the design/plan: istiod self-patches its own `ValidatingWebhookConfiguration`s' `caBundle` (with its self-signed CA) AND `failurePolicy` (`Ignore` at chart default -> `Fail` once istiod considers itself ready) at startup and on every cert-rotation reconcile, leaving `core` permanently `OutOfSync` against the git-sourced manifest even though every resource applied cleanly. Fixed with a narrowly-scoped `spec.ignoreDifferences` on `apps/core.yaml` (two named `ValidatingWebhookConfiguration`s, `jqPathExpressions: [.webhooks[].clientConfig.caBundle, .webhooks[].failurePolicy]`) rather than a blanket `admissionregistration.k8s.io` ignore, so cert-manager's and metallb's webhook configs stay diffed normally.
- Edge case: cert-manager's webhook must be Ready before wave `0` applies any `ClusterIssuer`/`Certificate` — the wave gate should prevent a premature apply, but the webhook's own readiness probe (not just pod `Running`) is what actually gates admission.
- Edge case: `metallb-native.yaml` must not conflict with the `cluster-core-k3d`-disabled ServiceLB (already off) — confirm no duplicate `LoadBalancer`-class controller fights over IPs.
- Edge case: re-verify the CNI paths against the live node if `k3d/agrippa-dev.yaml`'s `image:` pin has moved since this plan was written (the exact reason upstream issue #57264 exists).

**Implementation Outline**

```text
core/overlays/dev/kustomization.yaml:
  resources:
    - gateway-api/
    - istio-base/
    - metallb/
    - cert-manager/
    - istio-control/

core/overlays/dev/istio-control/kustomization.yaml:
  helmCharts:
    - name: istiod
      repo: https://istio-release.storage.googleapis.com/charts
      version: <pinned>
      namespace: istio-system
      valuesInline: {global: {platform: k3d}, profile: ambient}
    - name: cni
      repo: https://istio-release.storage.googleapis.com/charts
      version: <pinned>
      namespace: istio-system
      valuesInline:
        global: {platform: k3d}
        profile: ambient
        cniConfDir: /var/lib/rancher/k3s/agent/etc/cni/net.d
        cniBinDir: /var/lib/rancher/k3s/data/cni
    - name: ztunnel
      repo: https://istio-release.storage.googleapis.com/charts
      version: <pinned>
      namespace: istio-system
      valuesInline: {global: {platform: k3d}, profile: ambient}
```

## Step 3: Wave `0` — cluster config CRs (metallb pool, cert-manager SelfSigned→CA chain)

**Enables:** no feature-test assertion flips yet (still nothing on `:443`), but this step makes the CA chain and the LoadBalancer IP pool live — the direct prerequisite Step 4's Gateway certificate (THEN 2) needs.

Fill `metallb-config.yaml`'s stub with a real `IPAddressPool` **`agrippa-pool`** (`addresses: [172.18.255.200-172.18.255.250]`, derived from `docker network inspect k3d-agrippa-dev`'s live `172.18.0.0/16` — re-derive at build per Open Decision C) and `L2Advertisement` **`agrippa-l2`** referencing it. Fill `cert-issuers.yaml`'s three stubs with real specs: `ClusterIssuer` **`selfsigned`** (`spec.selfSigned: {}`), `Certificate` **`agrippa-local-ca`** in `cert-manager` (`isCA: true`, `issuerRef: {name: selfsigned, kind: ClusterIssuer}`, `commonName: "Agrippa Local Dev CA"`, `secretName: agrippa-local-ca-tls`), `ClusterIssuer` **`agrippa-ca`** (`spec.ca.secretName: agrippa-local-ca-tls`, resolved in `cert-manager`'s own namespace per cert-manager's CA-issuer resolution rule).

**Tests**

```bash
test "the metallb pool and the CA issuer chain are both Ready":
  run kubectl --context k3d-agrippa-dev -n metallb-system get ipaddresspool agrippa-pool
  assert status == 0
  run kubectl --context k3d-agrippa-dev -n metallb-system get l2advertisement agrippa-l2
  assert status == 0
  run kubectl --context k3d-agrippa-dev get clusterissuer selfsigned \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  assert output == "True"
  run kubectl --context k3d-agrippa-dev -n cert-manager get certificate agrippa-local-ca \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  assert output == "True"
  run kubectl --context k3d-agrippa-dev get clusterissuer agrippa-ca \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  assert output == "True"
```

- Edge case: the `agrippa-pool` CIDR slice must not collide with any address Docker or another container on the `k3d-agrippa-dev` network already uses — re-check `docker network inspect` at build time, not just trust this plan's committed literal.
- Edge case: `agrippa-ca`'s `spec.ca.secretName` must resolve inside the `cert-manager` namespace specifically (cert-manager's CA issuer looks up the Secret in the `ClusterIssuer`'s own configured namespace, which for a CA issuer defaults to the cert-manager controller's own namespace) — confirm this is not silently namespace-mismatched.
- Edge case: `agrippa-local-ca`'s `Certificate` must actually reach `Ready` (self-signed root issuance can fail quietly if the `selfsigned` issuer's own `Ready` condition is not yet true — wave ordering should prevent this, but verify live).

**Implementation Outline**

```text
core/overlays/dev/kustomization.yaml:
  resources:
    - gateway-api/
    - istio-base/
    - metallb/
    - cert-manager/
    - istio-control/
    - metallb-config.yaml
    - cert-issuers.yaml

core/overlays/dev/metallb-config.yaml:
  IPAddressPool agrippa-pool:
    addresses: ["172.18.255.200-172.18.255.250"]
  L2Advertisement agrippa-l2:
    ipAddressPools: [agrippa-pool]

core/overlays/dev/cert-issuers.yaml:
  ClusterIssuer selfsigned: {selfSigned: {}}
  Certificate agrippa-local-ca (ns cert-manager):
    isCA: true, issuerRef: selfsigned, commonName: "Agrippa Local Dev CA"
    secretName: agrippa-local-ca-tls
  ClusterIssuer agrippa-ca:
    ca: {secretName: agrippa-local-ca-tls}
```

## Step 4: Wave `5` — the shared Gateway, its certificate, the `externalIPs` reachability fix, the ArgoCD HTTPRoute

**Enables:** WHEN + THEN 1 (`curl -k https://argocd.127.0.0.1.nip.io/` returns 2xx/3xx) and THEN 2 (the served certificate is issued by the local CA) — the two assertions that actually exercise the request path. This is the step the design flags as carrying "the one spike this design does not pre-empt": the two-Service `externalIPs` shape and the exact gateway-pod selector label.

Fill `istio-ingress-namespace.yaml` with a real `Namespace: istio-ingress`. Fill `gateway.yaml` with the shared `Gateway` **`agrippa-gateway`** in `istio-ingress`, `gatewayClassName: istio`, an `https` listener on `:443` (`tls.mode: Terminate`, `certificateRefs: [agrippa-gateway-tls]`, `allowedRoutes.namespaces.from: All`) and an `http` listener on `:80` (same `allowedRoutes`, no redirect route yet — deferred per design). Creating this `Gateway` object causes istiod's Gateway API controller to auto-provision a Deployment + Service for the gateway data plane in the same namespace (`istio-ingress`) — that auto-provisioned Service is **not** authored here. Fill `gateway-cert.yaml` with `Certificate` **`agrippa-gateway-tls`** in `istio-ingress` (`issuerRef: agrippa-ca`, `secretName: agrippa-gateway-tls`, `dnsNames: [argocd.127.0.0.1.nip.io]`). Fill `gateway-external-svc.yaml` with the supplemental Service **`agrippa-gateway-external`** in `istio-ingress` (`spec.externalIPs: ["172.18.0.3"]`, `ports: [80, 443]`, `selector: {gateway.networking.k8s.io/gateway-name: agrippa-gateway}` — the **documented** Istio Gateway-injection label the auto-provisioned gateway Deployment/Pods/Service carry, reviewer-confirmed against Istio's Gateway API docs, so this is no longer an unconfirmed spike; keep the cheap `kubectl -n istio-ingress get pods --show-labels` belt-and-suspenders check after the `Gateway` first syncs, and fall back per design's documented options — a gateway-service annotation, a manual Istio gateway, or `hostNetwork`/`hostPort` — only in the unlikely event the pinned Istio version diverges from that documented label). Fill `argocd-httproute.yaml` with `HTTPRoute` **`argocd`** in the `argocd` namespace, `parentRefs: [{name: agrippa-gateway, namespace: istio-ingress, sectionName: https}]`, `hostnames: [argocd.127.0.0.1.nip.io]`, `backendRefs: [{name: argocd-server, port: 443}]` (backend-TLS route, per design's Q1 resolution — no `server.insecure` patch to `gitops-argocd`'s ArgoCD config). A bare `backendRefs` to port `443` does not itself originate TLS, so fill `argocd-destinationrule.yaml` with an Istio **`DestinationRule`** `argocd-server-tls` in the `argocd` namespace (host `argocd-server.argocd.svc.cluster.local`, `spec.trafficPolicy.tls.mode: SIMPLE`, `insecureSkipVerify: true`) — the **reviewer-decided** re-origination mechanism (see the Resolved block: a Gateway API `BackendTLSPolicy` cannot skip verification of `argocd-server`'s self-signed, install-regenerated cert, so it is rejected in favor of the one-CR Istio-native DestinationRule that tolerates it).

**Tests**

```bash
test "the feature test's own path: Gateway Programmed, HTTPRoute Accepted, reachable with a local-CA cert":
  run kubectl --context k3d-agrippa-dev -n istio-ingress get gateway agrippa-gateway \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'
  assert output == "True"
  run kubectl --context k3d-agrippa-dev -n argocd get httproute argocd \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
  assert output == "True"
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 https://argocd.127.0.0.1.nip.io/
  assert status == 0
  assert output matches ^(2[0-9][0-9]|3[0-9][0-9])$
  run bash -c 'openssl s_client -connect 127.0.0.1:443 -servername argocd.127.0.0.1.nip.io </dev/null 2>/dev/null | openssl x509 -noout -issuer'
  assert output contains "Agrippa Local Dev CA"
```

- Edge case: re-derive `172.18.0.3` (`docker inspect k3d-agrippa-dev-server-0`) immediately before committing this step — it drifts on `cluster:down`/`up`.
- Edge case: the `agrippa-gateway-external` selector `gateway.networking.k8s.io/gateway-name: agrippa-gateway` is the documented Istio Gateway-injection label (reviewer-confirmed); the live `--show-labels` check is now a cheap confirmation, not a blocking spike — proceed if it matches, fall back to a documented option only if the pinned Istio version diverges.
- Edge case: `argocd-server`'s port `443` serves a self-signed cert (ArgoCD's server runs HTTPS by default unless reconfigured); the reviewer-decided `DestinationRule` `argocd-server-tls` sets `insecureSkipVerify: true` precisely so the Gateway-to-backend hop tolerates that self-signed cert. Verify the DestinationRule is actually applied to the gateway proxy (the north-south Gateway pod is a full Envoy in ambient mode, so it honors DestinationRule TLS origination — unlike ztunnel) and that a `curl -k` through the front hop now also completes the back hop; a `503 UC`/upstream-connect error at the gateway means the DestinationRule did not take.
- Edge case: `agrippa-gateway-tls`'s `dnsNames` must include exactly `argocd.127.0.0.1.nip.io` (matching the `HTTPRoute`'s `hostnames` and the feature test's `GW_HOST`) or SNI-based cert selection fails even with a Programmed Gateway.
- Edge case: both the metallb-assigned LoadBalancer IP and the `externalIPs` DNAT rule must coexist on the same auto-provisioned Service with no conflict (research's own live-verified finding) — confirm again now that the *actual* two-Service topology (auto-provisioned + supplemental) is live, not the research spike's single-Service stand-in.
- Edge case found during build, not anticipated in the design/plan: `Gateway` and `HTTPRoute` both carry a registered `status` subresource that istiod's Gateway API controller populates (`Programmed`/`Accepted` conditions, addresses, `attachedRoutes`) — none of which the git-sourced, spec-only manifest ever sets, leaving `core` permanently `OutOfSync` once the Gateway landed. Two mechanisms were tried and, live-verified this session, did NOT clear it: `ignoreDifferences` with `jsonPointers: [/status]`, then `jqPathExpressions: [.status]` (both left the two resources OutOfSync against the live ServerSideApply-managed objects even right after a self-heal sync attempt succeeded). The actual fix: `managedFieldsManagers` (confirmed via `--show-managed-fields` as the correct owner set — `istio.io/gateway-controller` + `pilot-discovery` on `Gateway`'s `status`, `pilot-discovery` alone on `HTTPRoute`'s), the mechanism purpose-built for "ignore whatever another controller's field manager owns." A second, unrelated genuine diff was found alongside it: `HTTPRoute.spec.rules[0].matches` is API-schema-defaulted to `[{path: {type: PathPrefix, value: "/"}}]` when omitted, and ArgoCD's pre-sync diff does not replicate that particular nested-array default the way it replicates scalar defaults (e.g. `backendRefs[].group`/`kind`) — fixed by authoring `matches` explicitly in `argocd-httproute.yaml` rather than relying on ArgoCD to predict it. Neither fix affects the feature test's own live `kubectl get ... -o jsonpath='{.status...}'` reads.

**Implementation Outline**

```text
core/overlays/dev/kustomization.yaml:
  resources:
    - gateway-api/
    - istio-base/
    - metallb/
    - cert-manager/
    - istio-control/
    - metallb-config.yaml
    - cert-issuers.yaml
    - istio-ingress-namespace.yaml
    - gateway.yaml
    - gateway-cert.yaml
    - gateway-external-svc.yaml
    - argocd-httproute.yaml
    - argocd-destinationrule.yaml

core/overlays/dev/gateway.yaml:
  Gateway agrippa-gateway (ns istio-ingress):
    gatewayClassName: istio
    listeners:
      - {name: https, port: 443, protocol: HTTPS, tls: {mode: Terminate, certificateRefs: [agrippa-gateway-tls]}, allowedRoutes: {namespaces: {from: All}}}
      - {name: http, port: 80, protocol: HTTP, allowedRoutes: {namespaces: {from: All}}}

core/overlays/dev/gateway-external-svc.yaml:
  Service agrippa-gateway-external (ns istio-ingress):
    spec:
      externalIPs: ["172.18.0.3"]
      selector: {gateway.networking.k8s.io/gateway-name: agrippa-gateway}  # documented Istio label
      ports: [{port: 80}, {port: 443}]

core/overlays/dev/argocd-httproute.yaml:
  HTTPRoute argocd (ns argocd):
    parentRefs: [{name: agrippa-gateway, namespace: istio-ingress, sectionName: https}]
    hostnames: [argocd.127.0.0.1.nip.io]
    rules: [{backendRefs: [{name: argocd-server, port: 443}]}]

core/overlays/dev/argocd-destinationrule.yaml:
  # reviewer-decided TLS re-origination mechanism (see Resolved block)
  DestinationRule argocd-server-tls (ns argocd):
    host: argocd-server.argocd.svc.cluster.local
    trafficPolicy: {tls: {mode: SIMPLE, insecureSkipVerify: true}}
```

## Step 5: Feature-test issuer-check correction (Q6), full GREEN, and the regression sweep

**Enables:** no new substrate — the request path already works after Step 4 — but this step closes the two remaining items `design.md`'s Metrics names as measures of done: the feature test passing with its *cleared* assertion mechanism, and no regression to earlier harness.

The committed `tests/networking.bats` (THEN 2) still reads `run curl -kv ...; echo "$output" | grep -Eqi "issuer:.*${CA_CN}"` — the pre-review form. `design.md`'s cleared Q6 resolution decided to re-encode this on `openssl s_client -connect 127.0.0.1:443 -servername "$GW_HOST" </dev/null | openssl x509 -noout -issuer` instead (live-confirmed this session: the operator's system `curl` links LibreSSL, not OpenSSL, making `curl -v`'s human-readable cert dump a brittle, backend-dependent interface for this exact assertion), keeping `curl -k` only for the reachability check (THEN 1). That resolution was never applied back to the file. Apply it now — a test-definition correction inherited from the already-cleared design, not new test authorship — then run the corrected suite end-to-end, and re-run the full harness the design's Metrics section names as no-regression evidence.

**Tests**

```bash
test "tests/networking.bats passes end-to-end with the Q6-corrected issuer check":
  run bats tests/networking.bats
  assert status == 0

test "no regression to earlier harness":
  run mise run test:push
  assert status == 0
  run mise run test:feature
  assert status == 0
  run bats tests/cluster-core.bats
  assert status == 0
  run bats tests/gitops.bats
  assert status == 0
```

- Edge case: `scripts/test-feature.sh` already excludes `networking.bats` from its auto-discovery loop (verified committed this session, landed with the feature test at design time per `design.md`'s own note) — this step only needs to confirm that exclusion still holds, not add it.
- Edge case: the `openssl x509 -noout -issuer` output format includes a leading `issuer=` (no colon, unversioned across OpenSSL/LibreSSL builds of the `openssl` CLI itself, distinct from `curl`'s backend) — match on the `$CA_CN` substring, not the full line shape, exactly as Q6 specifies.
- Edge case: `test:static`'s kubeconform/conftest pass does not scan `core/` (confirmed this session — it only walks `apps/` and `charts/*/rendered/`), so this step's `core/overlays/dev/` content is validated only by ArgoCD's own live reconcile and this suite, not by `mise run test:push`; do not assume `test:push` exercises any of Steps 1-4's new YAML.
- Edge case: re-running `bats tests/networking.bats` a second time back-to-back must not error or re-trigger a disruptive resync — `core`'s `syncPolicy.automated.selfHeal` should leave an already-Synced/Healthy state alone.

**Implementation Outline**

```diff
# tests/networking.bats, THEN 2
- run curl -kv -sS -o /dev/null --max-time 10 "https://${GW_HOST}/"
- [ "$status" -eq 0 ]
- echo "$output" | grep -Eqi "issuer:.*${CA_CN}"
+ run bash -c "openssl s_client -connect 127.0.0.1:443 -servername '${GW_HOST}' </dev/null 2>/dev/null | openssl x509 -noout -issuer"
+ [ "$status" -eq 0 ]
+ [[ "$output" == *"${CA_CN}"* ]]
```

## Resolved by the long-loop reviewer (2026-07-08)

This plan is a paper plan against a cleared `design.md`; it has not been built.
The review's job, per the two completed siblings' precedent
(`cluster-core-k3d/plan.md` and `gitops-argocd/plan.md`), was three-fold: verify
the plan's step decomposition faithfully transcribes the cleared `design.md`
(no re-litigating design decisions), verify the plan's claims about current repo
state against the actually-committed files (`research:codebase`), and decide the
two net-new mechanism items the plan's own Step 4 surfaced and deferred to build.
Researched via `research:codebase` (direct inspection of
`apps/platform/argocd/kustomization.yaml`, `core/overlays/dev/kustomization.yaml`,
`scripts/test-feature.sh`, `tests/networking.bats`, `apps/core.yaml`) and
`research:public` (Istio Gateway API + DestinationRule docs, Gateway API
BackendTLSPolicy spec + the open skip-verify proposal). No escalation trigger
(irreversible, out of recorded scope, underdetermined) fired, so this plan's
draft gate is cleared (marker now `*Reviewed 2026-07-08*`).

**1. Does the plan's step decomposition faithfully transcribe the cleared feature
`design.md`? Decided: yes — no change needed.** The four-tier intra-`core`
sync-wave scheme (`-10` CRDs / `-5` controllers+data plane / `0` config CRs / `5`
ingress objects) maps one-for-one onto the design's Specification § "Intra-`core`
sync-wave scheme"; Steps 1–4 partition exactly along those waves. Every shared
object name (`agrippa-gateway`, `istio-ingress`, `agrippa-ca`, `selfsigned`,
`agrippa-gateway-tls`, `agrippa-local-ca`/`-tls`, `agrippa-pool`, `agrippa-l2`,
`agrippa-gateway-external`, proof host `argocd.127.0.0.1.nip.io`) matches the
design's Open Decision B verbatim. The SelfSigned→CA chain (Step 3), the
live-verified CNI-path overrides as *top-level* `cni`-chart values (Step 2), the
two-listener Gateway and the `externalIPs` supplemental-Service shape (Step 4),
and the four upstream sources' composition under the single `core` Application
all transcribe the design's Specification without alteration. One point of
fidelity worth naming: the plan correctly follows the design's **resolved Q1
decision** (route to `argocd-server:443` with backend TLS, no `server.insecure`
patch) rather than the design's pre-resolution body text (which still showed
`argocd-server:80` + an optional `server.insecure` patch) — the cleared
resolution supersedes the stale body, and the plan tracks the resolution. Faithful.

**2. Are the plan's claims about current repo state accurate? Decided: yes —
verified, no change needed.** `research:codebase` confirmed all four:
(a) `apps/platform/argocd/kustomization.yaml`'s `argocd-cm` patch currently reads
`kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"` exactly (line 82),
so Step 0's additive `--enable-helm` append is a correct pre-image and does not
disturb the KSOPS volume/init-container/env patch that `gitops.bats` asserts on.
(b) `core/overlays/dev/kustomization.yaml` is exactly `resources: []` (an
empty-but-valid placeholder), matching Step 0's "stays the existing `resources: []`"
claim and the design's Prior Art. (c) `scripts/test-feature.sh`'s probe-suite
exclusion `case` list already carries `networking.bats`
(`agrippa.bats|harness.bats|preflight.bats|cluster-core.bats|gitops.bats|networking.bats|rotate-keys.bats`),
confirming Step 5's "only needs to confirm that exclusion still holds, not add it";
the plan's design-time claim that the exclusion landed with the feature test is
correct. (d) `tests/networking.bats`'s committed THEN 2 reads exactly
`run curl -kv ...; [ "$status" -eq 0 ]; echo "$output" | grep -Eqi "issuer:.*${CA_CN}"`
(lines 109–111) — the precise pre-image Step 5's diff replaces — and THEN 1 is the
separate `curl -k ... -w '%{http_code}'` reachability check the plan keeps.
Additionally confirmed `apps/core.yaml` carries `path: core/overlays/dev`,
sync-wave `0`, and the `ServerSideApply`/`SkipDryRunOnMissingResource` forward
seam the design's Prior Art and sync-wave scheme depend on. Every repo-state claim
held; nothing needed correction.

**3. Step 4's flagged open mechanism risk (a): how Istio ambient re-originates TLS
to the HTTPS `argocd-server:443` backend on a plain Gateway API `HTTPRoute` —
`BackendTLSPolicy` vs `DestinationRule`. Decided: an Istio `DestinationRule`
`argocd-server-tls` (host `argocd-server.argocd.svc.cluster.local`,
`trafficPolicy.tls.mode: SIMPLE`, `insecureSkipVerify: true`), authored in the
`argocd` namespace at wave `5`; `BackendTLSPolicy` rejected.** The decisive
constraint is Step 4's own edge case: `argocd-server` serves a self-signed,
install-regenerated HTTPS cert, so whatever mechanism originates the back-hop TLS
must tolerate that cert without ongoing CA management. Researched both options
against current docs: the standard Gateway API `BackendTLSPolicy`
(`gateway-api.sigs.k8s.io`, GEP-1897) **requires** one of `caCertificateRefs` or
`wellKnownCACertificates` and validates the backend hostname/SAN — it has **no**
verification-skip; the "skip TLS verification" enhancement is an open, unmerged
proposal (kubernetes-sigs/gateway-api#3761). Using it here would force extracting
`argocd-server`'s CA into a same-namespace ConfigMap and keeping it in sync as the
cert rotates, plus SAN matching — brittle and high-maintenance for a local-dev
proof. Istio's `DestinationRule` with `tls.mode: SIMPLE` + `insecureSkipVerify:
true` is the documented, native, single-CR mechanism that originates one-way TLS
and tolerates a self-signed backend (Istio DestinationRule reference; Understanding
TLS Configuration). It is applied by the **gateway proxy**, which — for a
`gatewayClassName: istio` north-south Gateway — is a full Envoy deployment even in
ambient mode (the ambient ztunnel "no TLS origination to non-HBONE" limitation
applies to sidecarless workload traffic through ztunnel, not to the dedicated
gateway Envoy), so the DestinationRule takes effect on exactly the hop that needs
it. `insecureSkipVerify` on the back hop is consistent with the feature's declared
local-dev posture (the front hop is already `curl -k`; the local CA is
deliberately untrusted). This is the conservative default: fewest moving parts,
no CA lifecycle coupling, Istio-native, and reversible to a `BackendTLSPolicy` if
a later hardening pass wants real backend-cert verification. Recorded in Step 0's
file layout (`argocd-destinationrule.yaml`), Step 4's body, tests edge cases, and
Implementation Outline. Reversible (one authored CR this step owns), in the
design's recorded scope (Q1 already fixed "backend TLS to `:443`"; only the
mechanism was open), not underdetermined — the self-signed-tolerance constraint
plus the documented capabilities determine it. No escalation.

**4. Step 4's flagged open mechanism risk (b): the `agrippa-gateway-external`
Service's selector label — unconfirmed spike. Decided: paper-resolved to the
documented Istio Gateway-injection label `gateway.networking.k8s.io/gateway-name:
agrippa-gateway`; no live install needed, the plan's cheap `--show-labels` check
demoted from blocking spike to belt-and-suspenders.** Istio's official Gateway
API task documentation states that each `Gateway` automatically provisions a
Service and Deployment "generated with well-known labels
(`gateway.networking.k8s.io/gateway-name: <gateway name>`)," and explicitly names
that label as usable as a selector (for PodDisruptionBudgets/HPAs, and — the same
mechanism — a supplemental Service). The design's inferred label is therefore
exactly the documented convention, not a guess, so it is confirmable on paper
without standing up Istio/metallb to spike against (which are not installed yet).
This matches the review guidance: a paper resolution citing the documented
Gateway-injection convention is sufficient here. The auto-provisioned Service is
separately named `<gateway>-<gatewayclass>` (i.e. `agrippa-gateway-istio`), but
the supplemental Service selects the gateway **pods by label**, so it is robust
regardless of the generated Service's name. The cheap live `--show-labels` check
stays in Step 4 as confirmation (and the design's documented fallbacks stay as
contingencies) only against the remote chance the pinned Istio version diverges
from its own documented label. Reversible, in scope, not underdetermined. No
escalation.

**5. Build-time-deferred upstream pins (Gateway API `standard-install.yaml` tag,
cert-manager static-manifest tag, metallb `metallb-native.yaml` version, the four
Istio Helm chart `version:`s). Decided: correctly deferred to build-time
`research:public` — no change.** This matches the `gitops-argocd` plan reviewer's
own explicit distinction: `mise`-registry `[tools]` pins get decided at plan time
(cross-checked via `mise ls-remote`), but upstream **install-manifest tags and
chart versions** — which require reading the live upstream project's release/chart
docs for the exact pinned artifact — stay build-time `research:public`, exactly as
that sibling left the ArgoCD install-manifest tag deferred. None of these pins
enter `mise.toml` (the plan correctly states nothing in `mise.toml` changes across
any step), so they are not the tool-pin case the sibling decided early. metallb
already carries a concrete `v0.16.1` from the cleared `research.md` with a
re-check note, consistent with the design's committed-default-plus-re-derivation
pattern. Consistent with sibling precedent; not a net-new gap this gate must close.

**6. Any other net-new open item needing escalation? Decided: no — the gate
clears.** The two mechanism items (entries 3–4) are the only net-new opens the
plan surfaced beyond the cleared design; both decided conservatively above. The
machine-specific node IP / pool CIDR re-derivation, the CNI-path re-verification,
and the Q6 test-issuer correction are all inherited from the already-cleared
`design.md` (its Open Decision C / Q3, its Challenges, and its Q6 resolution
respectively), not net-new to this plan. No irreversible, out-of-recorded-scope,
or underdetermined item remains for this artifact. The `*Draft*` marker is removed
(changed to `*Reviewed 2026-07-08*`).
