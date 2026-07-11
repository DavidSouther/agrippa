# Testing a change to an application

How to safely test a change to any component of `agrippa-dev` before and after
it lands. This is a solo-operator, single dev cluster with no staging
environment. The safety net is local render-checking before push, a reviewed
pull request, then a component's own bats probe after ArgoCD reconciles.

Point `kubectl` at the cluster once per shell before anything below:

```bash
export KUBECONFIG="$(k3d kubeconfig write agrippa-dev)"
kubectl config use-context k3d-agrippa-dev
```

For the day-to-day command surface (secret lookups, mise tasks, log/shell
access, dashboard URLs) see `USAGE.md` at the repo root. This runbook only
covers the test-a-change loop.

## The generic pattern

Every component follows the same loop: edit, render-check, statically test,
push a feature branch, open a PR, merge, watch ArgoCD reconcile, run the
acceptance probe.

1. Edit files under `<layer>/overlays/dev/<component>/`.

2. Render-check locally before pushing anything. This needs `mise activate`
   first so the pinned kustomize/helm versions are on `PATH`:

   ```bash
   eval "$(mise activate bash)"   # or `mise activate fish | source` etc.
   kustomize build --enable-helm <layer>/overlays/dev
   ```

   Read the output. A kustomize error here is the cheapest place to catch a
   typo, a bad patch target, or a missing chart values file, before it ever
   reaches git or ArgoCD.

3. Run the per-push static lane (kubeconform schema validation + the
   plaintext-Secret conftest guard):

   ```bash
   mise run test:static
   ```

4. Commit on a feature branch, push it, and open a pull request into `main`.
   Use Conventional Commits (`fix`/`feat`/`chore`, scoped `core`/`store`/
   `otel`/`plat`/`work` per `DEVELOPMENT.md`).

   ```bash
   git checkout -b fix/<component>-<short-description>
   git add <layer>/overlays/dev/<component>
   git commit -m "fix(<scope>): <what and why>"
   git push -u origin fix/<component>-<short-description>
   gh pr create --base main --fill
   ```

   ArgoCD only reconciles the change once the pull request is reviewed and
   merged into `main`. Merge the reviewed pull request into `main` before
   moving on to step 5.

5. Watch ArgoCD reconcile the layer:

   ```bash
   kubectl -n argocd get applications \
     -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
   ```

   ArgoCD polls git on its own interval. To force an immediate reconcile
   instead of waiting:

   ```bash
   kubectl -n argocd annotate application <layer> argocd.argoproj.io/refresh=hard --overwrite
   ```

6. Once the layer is `Synced`/`Healthy`, run that component's own bats
   feature test as the acceptance check (see the component sections below for
   which suite and what "verified working" actually means):

   ```bash
   bats tests/<component>.bats
   ```

Sync-wave order, so a lower layer's change should settle before a higher one
that depends on it: `core` (0) -> `storage` (1) -> `platform` (2) ->
`observability` (3) -> `workloads-resume`/`workloads-trips` (4, independent
of each other). All of them sit under a self-managing `root` app-of-apps;
`argocd` itself is also a self-managed Application.

**New layer-level Application gotcha.** `syncOptions: [ServerSideApply=true]`
alone silently enables ArgoCD's Structured Merge Diff, which mispredicts
CRD-webhook-defaulted fields and leaves the resource permanently `OutOfSync`
even when `spec` matches byte-for-byte (argoproj/argo-cd#22151). Every
existing Application manifest under `apps/` already carries the fix,
`argocd.argoproj.io/compare-options: ServerSideDiff=true`, alongside
`ServerSideApply=true`. This only bites when adding a brand new layer-level
Application, not a normal component change inside an existing layer, but if
you ever do add one, carry both settings together or you'll chase a phantom
diff.

## Cluster core / k3d substrate

Files: `k3d/`. Feature test: `tests/cluster-core.bats`.

This is the one layer outside GitOps: it's the substrate ArgoCD itself runs
on, brought up imperatively with `mise run cluster:up`, not reconciled by
ArgoCD. A change here (node config, disabled components, port mappings) needs
a cluster recreate to take effect, not a git push.

Verified working is not "the node is Ready." It's that k3s's bundled
ServiceLB and Traefik are disabled (so they don't fight metallb and Istio for
the LoadBalancer IP and ingress path) and that host port 443 is actually
published through the k3d loadbalancer container, so nothing upstream can
route once Networking lands.

```bash
mise run cluster:up
kubectl get nodes
docker inspect --format '{{json .Args}}' k3d-agrippa-dev-server-0 | grep -- --disable=servicelb
docker port k3d-agrippa-dev-serverlb | grep 443
bats tests/cluster-core.bats
```

## Networking (Istio, cert-manager, metallb, the shared Gateway)

Files: `core/overlays/dev/`. Feature test: `tests/networking.bats`.

Verified working is not "core Application Healthy." It's that the shared
Gateway actually serves TLS signed by the local CA and routes a real request
to a known backend (the ArgoCD UI is the zero-new-workload reachability
proof this suite uses).

```bash
curl -k -sS -o /dev/null -w '%{http_code}\n' --max-time 10 https://argocd.127.0.0.1.nip.io/
openssl s_client -connect 127.0.0.1:443 -servername argocd.127.0.0.1.nip.io </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer   # must read CN=Agrippa Local Dev CA
bats tests/networking.bats
```

A 2xx/3xx with the wrong issuer (or no issuer at all) means the Gateway
answered but cert-manager's SelfSigned -> CA chain isn't wired to that
listener. A connection failure means nothing is routing at all, before TLS
even enters into it.

## GitOps / ArgoCD itself

Files: `apps/` (the app-of-apps tree) and `platform/overlays/dev/argocd/`
(ArgoCD's own reconciled install lives here post-bootstrap). ArgoCD's KSOPS
repo-server patch lives in `apps/platform/argocd/kustomization.yaml`. Feature
test: `tests/gitops.bats`.

This is the layer that reconciles every other layer, so verified working is
stricter than "Synced/Healthy": `mise run bootstrap` must stay idempotent
(safe to re-run against an already-bootstrapped cluster), the root app-of-apps
must report Synced/Healthy on its own reconcile of itself, and every layer
Application must actually be registered, not just present in git.

```bash
mise run bootstrap   # idempotent; requires an unlocked Bitwarden session
kubectl -n argocd get application root -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
for layer in core storage platform observability workloads-resume workloads-trips; do
  kubectl -n argocd get application "$layer" >/dev/null && echo "$layer: registered"
done
bats tests/gitops.bats
```

## Storage (Postgres via CloudNativePG, Valkey)

Files: `storage/overlays/dev/`. Feature test: `tests/storage.bats`.

Verified working is not "Cluster status Healthy." A CNPG `Cluster` can be
Healthy while a specific database/role never actually got provisioned, or a
sealed credential never actually got wired to the role. The real check is a
live `psql`/`valkey-cli` connection using a sealed credential, run from
inside the datastore pod itself (over TCP, so it exercises the real
`scram-sha-256` auth rule, not the trust/peer local-socket shortcut):

```bash
pod=$(kubectl -n storage get pods -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
pgpw=$(kubectl -n storage get secret smoke-db -o go-template='{{ index .data "password" | base64decode }}')
kubectl -n storage exec "$pod" -c postgres -- env PGPASSWORD="$pgpw" \
  psql -h 127.0.0.1 -U smoke -d smoke -tAc 'select current_database()'

vpod=$(kubectl -n storage get pods -l app.kubernetes.io/name=valkey -o jsonpath='{.items[0].metadata.name}')
vkpw=$(kubectl -n storage get secret smoke-valkey -o go-template='{{ index .data "smoke" | base64decode }}')
kubectl -n storage exec "$vpod" -- valkey-cli --no-auth-warning --user smoke -a "$vkpw" set smoke:probe ok

bats tests/storage.bats
```

The permanent `smoke` database/role and `smoke` Valkey ACL user exist
specifically as this always-on health-check fixture; they're not throwaway
test data and ArgoCD's selfHeal will recreate them if deleted.

## Auth (Keycloak)

Files: `platform/overlays/dev/keycloak/`. Feature test: `tests/auth.bats`.

Verified working is the realm's OIDC discovery endpoint returning a correct
issuer, proving the realm was actually imported and is being served (not just
that the Keycloak pod is up with no realm behind it):

```bash
curl -k -sS --max-time 15 https://auth.127.0.0.1.nip.io/realms/agrippa/.well-known/openid-configuration \
  | grep -o '"issuer":"[^"]*"'
# expect: "issuer":"https://auth.127.0.0.1.nip.io/realms/agrippa"
bats tests/auth.bats
```

A wrong issuer (an internal Service address, or plain `http://`) means
Keycloak's proxy/hostname settings are misconfigured behind the Gateway, even
if the discovery document otherwise returns 200. That breaks every
downstream OIDC client's redirect flow, so don't treat a 200 alone as green.

## Git hosting (Forgejo)

Files: `platform/overlays/dev/forgejo/`. Feature test: `tests/git-hosting.bats`.

Verified working is not the UI loading. It's an authenticated API call
succeeding with the sealed admin credential, and a real repository being
created, pushed to over HTTPS, and read back:

```bash
admin_user=$(kubectl -n forgejo get secret forgejo-admin -o go-template='{{ index .data "username" | base64decode }}')
admin_pw=$(kubectl -n forgejo get secret forgejo-admin -o go-template='{{ index .data "password" | base64decode }}')
auth=$(printf '%s:%s' "$admin_user" "$admin_pw" | base64 | tr -d '\n')
curl -k -sS -H "Authorization: Basic $auth" https://git.davidsouther.com.127.0.0.1.nip.io/api/v1/user | grep -o '"login":"[^"]*"'

bats tests/git-hosting.bats   # exercises create -> clone -> push -> read-back end to end
```

The bats suite is the real proof here: it creates a probe repo, clones it,
commits, pushes over HTTP, and reads the pushed file back through the
contents API, then deletes the probe repo. Reasonable to run standalone
rather than hand-driving those steps every time.

## Feature flags (Flagsmith)

Files: `platform/overlays/dev/flagsmith/`. Feature test:
`tests/feature-flags.bats`.

Verified working is `/health` returning 200, which transitively proves the
Django API's connection to the shared Postgres `flagsmith` database is
live (not just that the pod is Running), plus the admin UI actually loading:

```bash
curl -k -sS -o /dev/null -w '%{http_code}\n' --max-time 15 https://flagsmith.127.0.0.1.nip.io/
curl -k -sS -o /dev/null -w '%{http_code}\n' --max-time 15 https://flagsmith.127.0.0.1.nip.io/health
bats tests/feature-flags.bats
```

The suite deliberately doesn't touch admin-credential auth or a flag read;
the admin password bootstrap is a manual browser reset-link flow, out of
scope for an automated probe. Gateway reachability + local-CA TLS + API
`/health` 200 is the bar.

## Observability (Loki, Grafana, Tempo, Mimir, Alloy)

Files: `observability/overlays/dev/`. Feature test:
`tests/observability.bats`.

Verified working is not "datasource registered." Grafana can list a
`prometheus`/`loki`/`tempo` datasource and still return zero data for every
one of them if the ingest path is broken upstream. The bar is Grafana
authenticating and its datasources actually returning data on query, not
merely existing in the provisioning list:

```bash
curl -k -sS -o /dev/null -w '%{http_code}\n' --max-time 10 https://dashboard.davidsouther.com.127.0.0.1.nip.io/api/dashboards/home   # anonymous: expect 401
curl -k -sS -o /dev/null -w '%{http_code}\n' --max-time 10 -u admin:admin https://dashboard.davidsouther.com.127.0.0.1.nip.io/api/dashboards/home   # expect 200
bats tests/observability.bats
```

The bats suite itself stops at "datasources provisioned" (robust to store
warm-up timing right after a fresh sync); it does not query them for live
data. For actually confirming a datasource is returning data, not just
registered, see `./interpreting-dashboards.md`.

This gap is not theoretical. This session, Mimir's ingester ring came up
with no explicit `replication_factor` in the chart values, so it fell back
to Mimir's binary default of 3, impossible to satisfy against this
feature-step's single ingester replica. Every `remote_write` from Alloy
failed with "at least 2 live replicas required, could only find 1," visible
only in the distributor's own logs, for roughly 13 hours before it was
caught. `observability` reported Synced/Healthy the entire time. The
datasource was registered in Grafana the entire time. Nothing about the
GitOps or provisioning state signaled a problem; only an actual query
against the Mimir datasource (or `mimirtool`/PromQL against a known metric)
surfaced the silent write failure. Treat "Synced/Healthy" and "datasource
provisioned" as necessary, never sufficient, for this layer.

## Workloads (resume, trips static sites)

Files: `workloads/overlays/dev/`, plus the git submodules under
`workloads/resume/` and `workloads/trips/`. Feature test:
`tests/workloads.bats`.

This is the one component whose build step is **not** GitOps-triggered.
Pushing a Deployment change that bumps an image tag does nothing by itself;
the image has to exist in the k3d node's containerd first. Run the build
and import *before* pushing any manifest change that references a new tag:

```bash
mise run workloads:build   # docker build + k3d image import for both resume:dev and trips:dev
```

Then follow the generic pattern (render-check, `test:static`, push, open a
PR, merge, watch ArgoCD) for the manifest change itself.

Verified working is not "pod is Running." It's real rendered content coming
back for each site, not just an nginx 200:

```bash
curl -k -sS https://davidsouther.com.127.0.0.1.nip.io/ | grep -qi 'david' && echo "resume content OK"
curl -k -sS -o /dev/null -w '%{http_code}\n' --max-time 10 https://davidsouther.com.127.0.0.1.nip.io/healthz
curl -k -sS https://trips.davidsouther.com.127.0.0.1.nip.io/ | grep -qi 'trip' && echo "trips content OK"
bats tests/workloads.bats
```

If a Deployment change went out but the site still serves old content,
suspect a stale image (forgot `mise run workloads:build`, or the Deployment
still points at a cached tag) before suspecting the Gateway or route.

## If a test fails after it merges

Since every merge to `main` reconciles onto the only cluster this platform
has, with no staging environment to catch a bad change first, a failing
acceptance probe after a sync means the failure is live. Don't iterate
blind:

- For diagnosing what's actually broken, see `./incident-response.md`.
- For getting back to a known-good state while you investigate, see
  `./rollback.md`.
