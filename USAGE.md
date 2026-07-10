# Usage: exploring a running local deployment

This covers day-to-day commands for poking around an already-running `agrippa-dev`
k3d cluster: reaching the deployed sites, checking ArgoCD, reading logs, querying
the database, and browsing observability. For first-time setup see
`GETTING_STARTED.md`; for the test suites and secrets model see `DEVELOPMENT.md`.

Every command below assumes the cluster is up (`mise run cluster:up`) and
bootstrapped (`mise run bootstrap`). Point `kubectl` at it once per shell:

```bash
export KUBECONFIG="$(k3d kubeconfig write agrippa-dev)"
kubectl config use-context k3d-agrippa-dev
```

## Sites and dashboards at a glance

Every host below is served through the shared Istio Gateway at `https://<host>`
via the k3d `:443` port-map. The local CA is deliberately not in your system
trust store, so `curl` needs `-k` and a browser will warn once per host (the
`agrippa-dev` root CA is TLS-real, just not publicly trusted). A plain
`https://<host>/` in a browser works after clicking through the warning once.

| Site | Host | Notes |
| --- | --- | --- |
| Personal site | `https://davidsouther.com.127.0.0.1.nip.io/` | real `resume` content; `/blog` and `/healthz` also served |
| Trips | `https://trips.davidsouther.com.127.0.0.1.nip.io/` | real `trips` content |
| ArgoCD | `https://argocd.127.0.0.1.nip.io/` | admin UI; see below for the password |
| Grafana | `https://dashboard.davidsouther.com.127.0.0.1.nip.io/` | `admin` / `admin` (local dev only) |
| Keycloak | `https://auth.127.0.0.1.nip.io/` | admin console at `/admin/`; realm `agrippa` |
| Forgejo | `https://git.davidsouther.com.127.0.0.1.nip.io/` | see below for the admin credential |
| Flagsmith | `https://flagsmith.127.0.0.1.nip.io/` | see below for the admin credential |

```bash
curl -sk https://davidsouther.com.127.0.0.1.nip.io/          # personal site
curl -sk https://trips.davidsouther.com.127.0.0.1.nip.io/    # trips
```

## ArgoCD: the source of truth for what's running

Every layer (`core`, `storage`, `platform`, `observability`, `workloads`) is
one ArgoCD `Application`, all managed by a self-syncing `root` app-of-apps.

```bash
# One-line health check for the whole platform
kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# Why is an app not Synced/Healthy?
kubectl -n argocd get application <name> -o jsonpath='{.status.conditions}' | jq .
kubectl -n argocd get application <name> -o jsonpath='{.status.operationState.message}'

# Force a re-sync/refresh (useful right after a git push)
kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite
```

The ArgoCD admin password is auto-generated at install and stored in a Secret
(bcrypt hashed, so read it once and reuse it, don't try to print the hash as a
password):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d | pbcopy
# log in at https://argocd.127.0.0.1.nip.io/ as `admin`
```

Or skip the UI entirely with the ArgoCD CLI (`argocd` isn't `mise`-pinned; install
separately if you want it) against a port-forward:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
argocd login localhost:8080 --username admin --insecure
```

## Namespaces, one per component

```bash
kubectl get ns
```

| Namespace | What's there |
| --- | --- |
| `argocd` | ArgoCD itself (server, repo-server, application-controller) |
| `cnpg-system` | the CloudNativePG Postgres operator |
| `storage` | the shared `postgres` Cluster and `valkey` |
| `istio-system` | `istiod`, `ztunnel`, the CNI node agent |
| `istio-ingress` | the shared Gateway (`agrippa-gateway`) and its TLS Certificate |
| `cert-manager` | the local CA issuer chain |
| `metallb-system` | the LoadBalancer IP allocator |
| `keycloak` | the Operator, the `Keycloak` CR/pod, the realm import |
| `forgejo` | the Forgejo server |
| `flagsmith` | the Flagsmith API + frontend |
| `observability` | Loki, Grafana, Tempo, Mimir, Alloy |
| `resume`, `trips` | the two workload sites |

```bash
# Everything in a namespace at a glance
kubectl -n <namespace> get pods,svc,httproute

# All HTTPRoutes across the cluster, and the hosts they answer to
kubectl get httproute -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOSTNAMES:.spec.hostnames
```

## Logs and shells

```bash
kubectl -n <namespace> logs deploy/<name> -f          # follow logs
kubectl -n <namespace> logs deploy/<name> --previous   # last crash's logs
kubectl -n <namespace> exec -it deploy/<name> -- sh    # shell in (alpine-based images: sh, not bash)

# Every non-Running/Completed pod across the whole cluster
kubectl get pods -A | grep -v -E 'Running|Completed'
```

## The database: Postgres and Valkey

One shared CNPG `Cluster` named `postgres` in the `storage` namespace, with a
per-app database and role (`smoke`, `keycloak`, `forgejo`, `flagsmith`), and one
shared `valkey` (Redis-compatible) instance.

```bash
# Cluster health
kubectl -n storage get cluster postgres

# psql into the primary as any app's own role, using its sealed credential
POD=$(kubectl -n storage get cluster postgres -o jsonpath='{.status.currentPrimary}')
PASS=$(kubectl -n storage get secret keycloak-db -o jsonpath='{.data.password}' | base64 -d)
kubectl -n storage exec -it "$POD" -- env PGPASSWORD="$PASS" psql -h localhost -U keycloak -d keycloak

# Or via the in-cluster read-write Service from any debug pod
kubectl -n storage run psql-debug --rm -it --image=postgres:17-alpine --restart=Never -- \
  psql "postgresql://keycloak:$PASS@postgres-rw.storage.svc:5432/keycloak"

# Valkey
kubectl -n storage exec -it deploy/valkey -- valkey-cli
```

`kubectl -n storage get secrets` lists every sealed credential
(`<app>-db`, basic-auth type: `username`/`password` keys). The plaintext never
touches disk outside the cluster; the committed files under `secrets/dev/` are
sops-encrypted (`DEVELOPMENT.md` § Secrets).

## Observability: Grafana, Loki, Mimir, Tempo

Log in at `https://dashboard.davidsouther.com.127.0.0.1.nip.io/` with
`admin` / `admin` (a literal, intentionally-weak local-dev credential; never
valid anywhere else). Three datasources are pre-provisioned:

- **Loki** (logs), uid `P8E80F9AEF21F6940`. Explore → Loki, a LogQL query like
  `{namespace="forgejo"}`.
- **Mimir** (metrics, Prometheus-compatible), uid `PAE45454D0EDB9216`. Explore
  → Mimir, a PromQL query like
  `sum(rate(istio_requests_total{reporter="source"}[5m])) by (destination_service_name)`.
- **Tempo** (traces), uid `P214B5B846CF3925F`. Explore → Tempo, search by
  service name.

These uids are pinned explicitly in `observability/overlays/dev/grafana/
kustomization.yaml` (Grafana auto-derives one otherwise, but won't let a
later config change reassign it against already-persisted state, so once a
dashboard references one, treat it as fixed).

Everything is collected by one Alloy DaemonSet via Kubernetes self-discovery
(no Prometheus Operator/ServiceMonitor CRDs in this cluster):

```bash
kubectl -n observability get pods
kubectl -n observability logs ds/alloy -c alloy -f   # collector's own logs
```

### The "Web Analytics (Istio Gateway)" dashboard

Provisioned automatically (Dashboards → Web Analytics (Istio Gateway), or
`/d/web-analytics/`). Covers the shared Gateway's traffic, sourced from
Istio's own `istio_requests_total`/`istio_request_duration_milliseconds`
telemetry (every request through `agrippa-gateway` reports here, regardless
of which workload/platform-service it hit):

- Total requests, current request rate, error rate (5xx), and p95 latency as
  headline stats.
- Request rate over time, broken out by destination service.
- Requests by status code over time.
- Top destinations by request volume.
- Latency percentiles (p50/p95/p99) across all traffic.
- Error rate broken out by destination.
- Request/response bytes transferred.
- A detail table: source workload, destination, status code, request count.

The dashboard definition lives in that same `kustomization.yaml` (a
`dashboardProviders`/`dashboards` block using the chart's sidecar-free
provisioning path, the same mechanism as the datasources above), so it's
GitOps-managed like everything else. Edit the JSON there and push to change
it; changes reconcile the next time ArgoCD syncs the `observability`
Application.

**Known dev-cluster quirk:** Mimir's default per-tenant ingestion rate limit
and its ingester ring's `replication_factor` both needed correcting for a
single-ingester dev deployment (see the two `fix(otel):` commits touching
`observability/overlays/dev/mimir/kustomization.yaml`) before any metric
would actually ingest. If a fresh cluster's dashboard shows "No data" for a
while after `mise run bootstrap`, give Alloy a few minutes to start
scraping; if it never recovers, check `kubectl -n observability logs
deploy/mimir-distributor` for `push.go` errors first.

## The Keycloak realm

```bash
kubectl -n keycloak get keycloak,keycloakrealmimport
kubectl -n keycloak get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d; echo
```

Admin console at `https://auth.127.0.0.1.nip.io/admin/`, realm `agrippa`.
Realm metadata (issuer, endpoints) is public at
`https://auth.127.0.0.1.nip.io/realms/agrippa/.well-known/openid-configuration`.

## Forgejo and Flagsmith admin credentials

```bash
kubectl -n forgejo get secret forgejo-admin -o jsonpath='{.data.password}' | base64 -d; echo
# username is in the same secret's `username` key (or check plan.md for the fixed value)

kubectl -n flagsmith get secret flagsmith -o jsonpath='{.data}' | jq .
# Flagsmith's own bootstrap sends a one-time password-reset link to the admin
# email on first login rather than sealing a usable password directly -- see
# .ailly/developer/2026-07-06-A-agrippa-local-k3d/features/feature-flags-flagsmith/design.md
```

## mise tasks (the full command surface)

```bash
mise tasks                 # list everything with descriptions
mise run cluster:up        # create/start the k3d cluster
mise run cluster:down      # delete it
mise run bootstrap         # sops-age trust root + KSOPS ArgoCD + root app-of-apps
mise run workloads:build   # build+import the resume/trips container images
mise run rotate-keys       # rotate an environment's age keypair (see known issue below)
mise run test:push         # kubeconform + conftest + helm-unittest, no cluster
mise run test:feature      # throwaway k3d cluster, chainsaw + bats probes
mise run test:gestalt      # tests/agrippa.bats against the current ENV target
mise run test:chart        # helm-unittest across charts/*/tests
```

```bash
bats tests/                 # every probe suite against the long-lived cluster
bats tests/workloads.bats   # one suite
ENV=dev PUBLIC_HOST=davidsouther.com.127.0.0.1.nip.io \
  TRIPS_HOST=trips.davidsouther.com.127.0.0.1.nip.io \
  DASHBOARD_HOST=dashboard.davidsouther.com.127.0.0.1.nip.io \
  bats tests/agrippa.bats     # the committed gestalt, pointed at local hosts
```

## Troubleshooting

```bash
# A pod stuck Pending: almost always node resource pressure on the single-node
# dev cluster once every layer is live
kubectl describe node k3d-agrippa-dev-server-0 | sed -n '/Allocated resources/,/Events/p'
kubectl top nodes; kubectl top pods -A --sort-by=memory

# A pod stuck CrashLoopBackOff
kubectl -n <ns> logs <pod> --previous
kubectl -n <ns> describe pod <pod>   # check Events at the bottom

# An Application stuck OutOfSync or ComparisonError
kubectl -n argocd get application <name> -o jsonpath='{.status.conditions}' | jq .
# Diff what ArgoCD thinks vs. what's live
kubectl -n argocd exec deploy/argocd-repo-server -- kustomize build --enable-helm <path>

# Nothing resolves at a *.127.0.0.1.nip.io host
docker port k3d-agrippa-dev-serverlb    # confirm :443 is actually port-mapped
kubectl -n istio-ingress get gateway,httproute
```

`tests/rotate-keys.bats` is a known pre-existing failure (a stage-ordering bug
in `scripts/rotate-keys.sh`, unrelated to any live secret or the cluster's own
trust root) -- see `.ailly/developer/TASKS.md` § Secrets for the root cause.

## Tearing down

```bash
mise run cluster:down   # deletes the whole k3d cluster; mise run cluster:up rebuilds from git
```

Nothing here is destructive to the source repo. The cluster is fully
reconstructible from `mise run cluster:up` + `mise run bootstrap`, since every
layer past the manual bootstrap step is GitOps-managed from `main`.
