# Agrippa Platform Architecture

Self-managed k3s · zero open inbound ports · GitOps-managed · cloud-portable.

The interactive deck lives in [`ARCHITECTURE.html`](./ARCHITECTURE.html)
(open it in a browser; arrow keys or the menu navigate the eight views). Inside
the deck, third-party service names link out to their docs (↗) while section
labels and request-path stages cross-link to the relevant slide.

## Request Path

Every public request follows one path, and unauthenticated traffic for gated
routes never reaches the cluster:

Public requests route through CloudFlare's edge network. Protected routes are blocked immediately by CloudFlare authentication. cloudflared then tunnels the traffic into the cluster proper. Once the traffic is in the cluster, istio will route it directly to pod ztunnels. Workloads finally receive the traffic, and interact with Keycloak OIDC for fine-grained permissions.

```text
🌍 Internet
   ↓
☁️ Cloudflare Edge — WAF · DDoS · TLS
   🔒 Tier 1 — Cloudflare Access (trips.davidsouther.com · ArgoCD · Grafana)
   ↓  encrypted tunnel · no open inbound ports
⚡ cloudflared (Deployment)
   ↓
🔀 Istio Gateway — Gateway API · HTTPRoutes
   ↓  mTLS · ambient mesh (ztunnel)
🌐 Workloads
   🔒 Tier 2 — Keycloak OIDC (ailly.dev · /agathon)
```

## Cluster Infrastructure (ArgoCD app-of-apps)

| Layer | Purpose | Components |
| --- | --- | --- |
| **Workloads** | David's applications, deployed on this cluster. | davidsouther.com · ailly.dev · `trips.davidsouther.com` · `/agathon` · `/blog` · DavidBot |
| **Platform** | Off the shell services for workloads' dependencies. | [ArgoCD] · [Keycloak] · [Flagsmith] · [Forgejo] · Platform LLM *(future)* |
| **Observability** | A unified Otel stack for combined service and cluster monitoring. | [Loki] · [Grafana] · [Tempo] · [Mimir] · [Alloy] |
| **Storage** | Foundational storage services, with disaster recovery policies. | [Longhorn] · [Postgres] · [Valkey] |
| **Cluster Core** | Foundational Node & Cluster managaement. | [k3s] · [cloud-init] · [istio] · [cloudflared] · [metallb] |

Workloads mix domains and paths for various reasons. See [`ROUTING.md`](./ROUTING.md) for when an app
gets its own domain versus a path under `davidsouther.com`.

## Environments

- **Production** — k3s on cloud VMs, [Terraform]-provisioned. 3 HA servers, Core +
  GPU node pools, public TLS terminated at the Cloudflare edge.
- **Development ([K3d])** — the same [Helm] charts and manifests. [metallb] replaces
  [cloudflared] for local LoadBalancer IPs; no GPU pool; reduced-replica overlay.
- **Home lab (future)** — self-hosted on-prem hardware, researched as a third
  substrate but not yet in scope. Node provisioning stays at the Terraform
  `elastic-node-pool` seam and shares the same Helm charts and manifests as
  Production and Development, so it can slot in later without a redesign.

---

<!-- Third-party documentation links (verified 2026-06-10) -->
[ArgoCD]: https://argo-cd.readthedocs.io/
[Keycloak]: https://www.keycloak.org/documentation
[Flagsmith]: https://docs.flagsmith.com/
[Forgejo]: https://forgejo.org/docs/latest/
[Loki]: https://grafana.com/docs/loki/latest/
[Grafana]: https://grafana.com/docs/grafana/latest/
[Tempo]: https://grafana.com/docs/tempo/latest/
[Mimir]: https://grafana.com/docs/mimir/latest/
[Alloy]: https://grafana.com/docs/alloy/latest/
[Longhorn]: https://longhorn.io/docs/
[Postgres]: https://www.postgresql.org/docs/
[Valkey]: https://valkey.io/topics/
[K3s]: https://docs.k3s.io/
[cloud-init]: https://docs.cloud-init.io/
[Terraform]: https://developer.hashicorp.com/terraform/docs
[k3d]: https://k3d.io/
[metallb]: https://metallb.io/
[cloudflared]: https://developers.cloudflare.com/tunnel/
[helm]: https://helm.sh/docs/
