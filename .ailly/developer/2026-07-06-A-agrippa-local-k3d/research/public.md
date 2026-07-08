# research:public findings — Agrippa local k3d

Task-scoped notes for `ailly/developer/2026-07-06-A-agrippa-local-k3d/research.md`.
General-lens web research verifying the k3d-only adaptation of each roadmap
component. Only the load-bearing, uncertain claims were checked externally; the
component topology and decisions themselves are fixed in-repo by `ARCHITECTURE.html`
and `DEVELOPMENT.md`.

## Verified claims

1. **metallb versus ServiceLB or Klipper on k3d.** k3s ships ServiceLB (Klipper),
   which conflicts with metallb over external IP assignment. Disable ServiceLB
   (`--k3s-arg --disable=servicelb`) before installing metallb; the metallb L2 pool
   must fall inside a k3d Docker network subnet. Traefik is separately disabled
   because Istio Gateway is the ingress. [1][2]
2. **Istio ambient plus Gateway API runs on k3d.** Install Gateway API CRDs first,
   use the ambient profile, set `global.platform=k3d` on the CNI and control plane.
   Istio ships an explicit k3d platform-setup page. [3][4]
3. **cert-manager local issuer.** No public DNS on a laptop means no DNS-01 ACME.
   Bootstrap a SelfSigned `ClusterIssuer`, then a CA `ClusterIssuer` that signs leaf
   certs for dev hostnames and in-cluster names. TLS is valid but not publicly
   trusted. [5]
4. **Longhorn does not run on stock k3d.** Longhorn needs `open-iscsi` (`iscsiadm`
   plus `iscsid`) on every node; the k3d node image omits it, so the manager fails
   its environment check. Workarounds: custom node image with open-iscsi, k3d nodes
   in a VM, or fall back to k3s `local-path` for dev. [6][7]
5. **ArgoCD app-of-apps ordering.** `argocd.argoproj.io/sync-wave` sequences CRDs
   (low wave), then controllers, then custom resources, so CRDs exist before the
   resources that reference them. `ServerSideApply=true` and
   `SkipDryRunOnMissingResource=true` for large CRD sets. [8]
6. **KSOPS with age in ArgoCD.** repo-server init-container plus sidecar installs
   KSOPS; `SOPS_AGE_KEY_FILE` points at an age key mounted from a `sops-age` Secret;
   `kustomize.buildOptions` enables the exec plugin. On k3d the `sops-age` Secret
   has no Terraform creator, so a local bootstrap task must inject it. [9]

## Sources (IEEE)

- [1] OneUptime, "How to Install MetalLB on K3s and Fix ServiceLB Conflicts,"
  2026-02-20. https://oneuptime.com/blog/post/2026-02-20-metallb-k3s-servicelb-conflicts/view
- [2] OneUptime, "How to Disable Traefik in K3s," 2026-03-20.
  https://oneuptime.com/blog/post/2026-03-20-k3s-disable-traefik/view
- [3] Istio, "k3d" platform setup. https://istio.io/latest/docs/setup/platform-setup/k3d/
- [4] Istio, "Get Started with Ambient Mesh" and "Platform-Specific Prerequisites."
  https://istio.io/latest/docs/ambient/getting-started/
- [5] cert-manager, "SelfSigned" issuer configuration.
  https://cert-manager.io/docs/configuration/selfsigned/
- [6] k3d-io/k3d, Discussion #478 and Issue #719.
  https://github.com/k3d-io/k3d/discussions/478
- [7] k3s-io/k3s, Discussion #9987 (open-iscsi for Longhorn).
  https://github.com/k3s-io/k3s/discussions/9987
- [8] Argo CD, "Sync Phases and Waves."
  https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/
- [9] viaduct-ai/kustomize-sops (KSOPS); Red Hat, "GitOps and Secret Management with
  ArgoCD and SOPS." https://github.com/viaduct-ai/kustomize-sops
