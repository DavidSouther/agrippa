# Incident response for agrippa-dev

Something on `agrippa-dev` is broken and you want it fixed. This is the front
door: start here for any live symptom, then jump to the sibling runbook a
section points you to once you know what you're dealing with.

You are a solo operator. There is no team, no on-call rotation, no one to
page. "Escalation" in this document means **stop guessing and do something
more drastic** -- an ArgoCD-level rollback, a git revert, or a full rebuild --
not "call someone else."

---

## 0. The 60-second global health check

Run this **first, always**, before jumping to a specific symptom below. It
answers three questions at once: is GitOps itself healthy, is anything
crash-looping or stuck Pending, and is the node out of capacity.

```bash
export KUBECONFIG="$(k3d kubeconfig write agrippa-dev)"
kubectl config use-context k3d-agrippa-dev

kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
kubectl get pods -A | grep -v -E 'Running|Completed'
kubectl top nodes
```

Read the output like this:

- **Any `Application` not `Synced`/`Healthy`** -- go to
  [§2 ArgoCD Application stuck OutOfSync, Progressing, or Degraded](#2-an-argocd-application-is-stuck-outofsync-progressing-or-degraded).
- **Any pod not `Running` or `Completed`** -- note its phase.
  `CrashLoopBackOff` goes to [§3](#3-a-pod-is-crashloopbackoff); `Pending`
  goes to [§4](#4-a-pod-is-stuck-pending).
- **`kubectl top nodes` near 100% on either CPU or memory** -- this is very
  likely the root cause of any Pending pod you just saw. Go straight to
  [`./capacity-and-resource-pressure.md`](./capacity-and-resource-pressure.md).

If all three come back clean and something still seems wrong (a site won't
load, a login fails), go to [§1](#1-a-siteui-returns-5xx-times-out-or-wont-load-at-all)
and work top-down from there -- the global check only catches
cluster-level breakage, not an application-level bug that still returns
`200`.

---

## 1. A site/UI returns 5xx, times out, or won't load at all

**Trigger:** `curl` or a browser against a `*.127.0.0.1.nip.io` host returns
a 5xx, hangs, or refuses to connect, for one specific site while the rest of
the platform looks fine.

### Quick check

```bash
# 1. Is the ArgoCD Application that owns this layer healthy?
kubectl -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# 2. Are the pod and its HTTPRoute actually there and ready?
kubectl -n <ns> get pods,httproute

# 3. What does the pod itself say?
kubectl -n <ns> logs <pod>
```

`<ns>` is the app's namespace (`forgejo`, `flagsmith`, `keycloak`,
`observability`, `resume`, `trips`, etc.); find it from the failing hostname
if you don't already know it.

### Likely causes, ranked

Routing (the shared Gateway, the `HTTPRoute`) rarely regresses once it's
built -- once an `HTTPRoute` has an explicit `matches:` block and is
`Synced`, it tends to stay that way. In practice, almost every 5xx or
timeout traces back to one of the next two symptoms instead:

1. **The pod itself is crash-looping.** Far and away the most common cause.
   Go to [§3](#3-a-pod-is-crashloopbackoff).
2. **The pod is stuck `Pending`** (never got scheduled at all, so there's
   nothing to route to). Go to [§4](#4-a-pod-is-stuck-pending).
3. **The Gateway/routing layer itself is broken.** Rare. Only chase this if
   #1 and #2 both come back clean -- pods are `Running`/`Ready` but traffic
   still doesn't land. Check the shared Gateway directly:

   ```bash
   kubectl -n istio-ingress get gateway,httproute
   kubectl -n istio-system logs deploy/istiod
   ```

### Fix

Depends entirely on which of the three causes above it turns out to be --
follow that symptom's own section.

### Escalation

If you've confirmed the pod is healthy, the `HTTPRoute` is `Synced`, and it
still doesn't work: **stop poking at the live cluster** and figure out what
actually changed recently before you guess further. See
[`./testing-changes.md`](./testing-changes.md) for how to confirm what
changed and re-test it deliberately, rather than trial-and-error against a
running target. If you already know the offending commit, go straight to
[`./rollback.md`](./rollback.md).

---

## 2. An ArgoCD Application is stuck OutOfSync, Progressing, or Degraded

**Trigger:** `kubectl -n argocd get applications` (from §0) shows a layer
that isn't `Synced`/`Healthy`, or has been `Progressing` for much longer than
a normal sync takes (a couple of minutes).

### Quick check

```bash
kubectl -n argocd get application <name> -o jsonpath='{.status.conditions}' | jq .
kubectl -n argocd get application <name> -o jsonpath='{.status.operationState.message}'
```

`<name>` is one of `root`, `core`, `storage`, `platform`, `observability`,
`workloads-resume`, `workloads-trips`, or `argocd`.

Before assuming it's actually broken versus just stale, force a hard
refresh and re-check:

```bash
kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get application <name> -o jsonpath='{.status.sync.status} {.status.health.status}'
```

### Likely causes, ranked

1. **A `HTTPRoute` missing an explicit `matches:` rule.** The single most
   common real cause hit in this cluster's own build history. ArgoCD's diff
   does not replicate the Gateway API CRD's own nested-array default for
   `spec.rules[].matches`, so an `HTTPRoute` authored without an explicit
   `matches:` block goes permanently `OutOfSync` -- ArgoCD sees a live
   default it can never reconcile away. Check:

   ```bash
   kubectl -n <ns> get httproute <name> -o yaml | grep -A5 'rules:'
   ```

   Fix: add an explicit `matches:` block to the `HTTPRoute` manifest in git
   (see `platform/overlays/dev/forgejo/httproute.yaml` or
   `platform/overlays/dev/keycloak/keycloak-httproute.yaml` for the pattern
   already in use), commit, push.

2. **`syncOptions: [ServerSideApply=true]` without the paired
   `compare-options: ServerSideDiff=true` annotation.** Any CRD whose
   webhook injects its own defaults (Gateway API resources are the recurring
   case here) needs *both* set together on the ArgoCD `Application`, or the
   diff engine and the apply engine disagree about what "in sync" means and
   the Application flaps or sticks `OutOfSync` forever. This is
   argoproj/argo-cd#22151. Check the `Application` manifest under `apps/`.
   For the five single-file layers (`root`, `core`, `storage`, `platform`,
   `observability`) that's `apps/<layer>.yaml`:

   ```bash
   grep -A2 'compare-options\|ServerSideApply' apps/<layer>.yaml
   ```

   The `workloads` and `argocd` layers live elsewhere: `apps/workloads/resume.yaml`
   and `apps/workloads/trips.yaml` for the two workloads, and
   `platform/overlays/dev/argocd.yaml` for ArgoCD itself.

   Both `argocd.argoproj.io/compare-options: ServerSideDiff=true` (an
   annotation) and `syncOptions: [ServerSideApply=true]` (a spec field) must
   be present together. Fix: add whichever one is missing, commit, push.

3. **A sync-wave ordering deadlock.** A resource that depends on another
   resource is scheduled to sync *before* the thing it depends on. The
   common shape: a `Database` CR scheduled after the `Deployment` that
   consumes it. Most app runtimes crash-loop rather than gracefully retry
   against a database that doesn't exist yet, so the `Application` sits
   `Progressing`/`Degraded` indefinitely. Check sync-wave annotations across
   the layer:

   ```bash
   kubectl -n argocd get application <name> -o yaml | grep -B5 'sync-wave'
   ```

   Fix: move the dependency (credentials, `Database` CRs) to an earlier
   `argocd.argoproj.io/sync-wave` than its consumer. Worked precedent in
   this repo: `platform/overlays/dev/keycloak/keycloak-database.yaml` and
   `platform/overlays/dev/flagsmith/database.yaml` both moved to sync-wave
   `-5`, ahead of the Deployments that need them.

### Fix

Whatever the root cause above resolves to, the delivery mechanism is always
the same: edit the manifest in git, commit, push, then force a hard refresh
(command above) rather than waiting out the default ~3 minute polling
interval.

### Escalation

If the Application is still not `Synced`/`Healthy` after a hard refresh and
none of the three causes above match what you're seeing, check
`.status.operationState.message` again for the actual apply error text --
it usually names the offending resource directly. If you can't make sense of
it after a few minutes, this is exactly the kind of stuck state
[`./rollback.md`](./rollback.md)'s ArgoCD-level rollback (§2 there) is for:
roll the Application back to its last known-good revision to stop the
bleeding, then work out the git-level fix without the pressure of a broken
cluster.

---

## 3. A pod is CrashLoopBackOff

**Trigger:** `kubectl get pods -A` shows a pod cycling through
`CrashLoopBackOff`.

### Quick check

```bash
# The crashed instance's own last words -- NOT the current restart's
# near-empty log, which is often just starting up again
kubectl -n <ns> logs <pod> --previous

# The Events tail at the bottom of describe, for scheduler/kubelet-level context
kubectl -n <ns> describe pod <pod>
```

Always reach for `--previous` first. The *current* container is often only
seconds old and hasn't logged the actual failure yet -- the crash reason
lives in the instance that just died.

### Likely causes, ranked

1. **A missing or misconfigured credential Secret reference.** The pod's
   env or volume references a Secret key that doesn't exist, or exists with
   a value the app rejects at startup. Check:

   ```bash
   kubectl -n <ns> get secret <name> -o jsonpath='{.data}' | jq 'keys'
   ```

   Compare the keys against what the pod's env/volume spec expects.

2. **A config value the chart's own schema rejects under ArgoCD's strict
   server-side apply.** This class of failure is found live, not caught by
   static rendering (`kubeconform`/`helm-unittest` validate the manifest
   shape, not runtime-rejected values) -- it only surfaces once the pod
   actually tries to start with the bad value. The `--previous` log
   almost always names the rejected field directly.

3. **Mimir specifically: memberlist/ring convergence issues after a config
   change.** If it's a Mimir component, check the ingester ring state before
   anything else:

   ```bash
   kubectl -n observability logs <mimir-pod> --previous | grep -i 'ring\|memberlist\|replication'
   ```

   Worked precedent in this repo: the ingester ring's
   `replication_factor` defaulted to `3` against a single ingester replica,
   silently failing every metric write for about 13 hours before it was
   caught (every `remote_write` failed distributor-side with "at least 2
   live replicas required, could only find 1"). Fixed by pinning
   `replication_factor: 1` explicitly in
   `observability/overlays/dev/mimir/kustomization.yaml`, matching the
   single-ingester, single-node reality of this cluster.

### Fix

Edit the manifest or values in git to correct the Secret reference, config
value, or ring setting; commit; push. Do not `kubectl edit` the live
resource to patch around it -- `selfHeal: true` will revert it, and even if
it didn't, the fix needs to live in git to survive a rebuild. See
[`./rollback.md`](./rollback.md) if this crash loop started right after a
change you can point to.

### Escalation

If `--previous` logs don't explain it and `describe`'s Events tail is
uninformative (e.g. `OOMKilled` with no further detail), suspect a resource
limit rather than a logic bug -- check the container's actual memory ceiling
against what it needs during startup:

```bash
kubectl -n <ns> get pod <pod> -o jsonpath='{.spec.containers[*].resources}'
```

Worked precedent: Flagsmith's API container was OOMKilled at a `512Mi`
limit specifically during its own startup migrate/bootstrap init containers
(steady-state usage was fine; the spike was at boot). Fixed by raising the
limit to `1Gi` in `platform/overlays/dev/flagsmith/helm/kustomization.yaml`.
If you're raising a limit, also check
[`./capacity-and-resource-pressure.md`](./capacity-and-resource-pressure.md)
first -- a bigger limit for one pod can starve another on this single-node
cluster.

---

## 4. A pod is stuck Pending

**Trigger:** `kubectl get pods -A` shows a pod stuck in `Pending`, not
progressing to `ContainerCreating` or `Running`.

### Quick check

One command confirms this is specifically a scheduling failure (as opposed
to, say, an image pull problem or an admission webhook rejection):

```bash
kubectl -n <ns> describe pod <pod> | grep -A5 Events
```

If the Events tail says something like `0/1 nodes are available: 1
Insufficient memory` or `Insufficient cpu`, this is node resource pressure.

### Likely causes, ranked

On this single-node dev cluster, once every layer is live, a `Pending` pod
is almost always node resource pressure, not anything specific to the pod
itself. This runbook does not duplicate that diagnosis and fix -- see
[`./capacity-and-resource-pressure.md`](./capacity-and-resource-pressure.md)
for the full triage (what's consuming the node, what's safe to trim, how to
size a request correctly). Worked precedent there: Keycloak's Operator
default memory request (`1700Mi`) could not schedule once every layer was
live and the node's allocatable was nearly fully requested; scoped down to
`512Mi` request / `1Gi` limit in
`platform/overlays/dev/keycloak/keycloak.yaml`.

### Escalation

If capacity genuinely isn't the issue (the node has headroom and the pod
still won't schedule), it's more likely a scheduling constraint
(`nodeSelector`, taint/toleration, PVC binding). That's outside this
runbook's scope -- treat it as an unknown-cause incident per
[§7](#7-when-to-give-up-on-incremental-fixes-and-do-something-bigger) below.

---

## 5. TLS/certificate errors, or curl failing without -k

**Trigger:** `curl` against a `*.127.0.0.1.nip.io` host fails with a
certificate trust error unless you pass `-k`, or a browser shows a
certificate warning.

**This is expected, not a bug.** The local CA (`CN=Agrippa Local Dev CA`) is
deliberately not installed in your system trust store. Every plain `curl`
(no `-k`) and every browser will warn once per host -- that's normal on this
platform and not something to fix.

### Quick check

Only worth investigating further if:

```bash
# Does even curl -k fail? (not just a trust warning, but a real failure)
curl -sk https://<host>.127.0.0.1.nip.io/

# What CA actually issued the cert being presented?
openssl s_client -connect <host>.127.0.0.1.nip.io:443 -servername <host>.127.0.0.1.nip.io </dev/null 2>/dev/null | openssl x509 -noout -issuer
```

### Likely causes, ranked

1. **`curl -k` also fails** (connection refused, timeout, protocol error).
   This isn't a TLS/cert problem at all -- go to
   [§1](#1-a-siteui-returns-5xx-times-out-or-wont-load-at-all) or
   [§6](#6-nothing-resolves-at-127001nipio-at-all-every-host) depending on
   whether it's one host or every host.
2. **The issuer is not `CN=Agrippa Local Dev CA`.** This means the
   cert-manager issuer chain itself is broken -- a real problem. Check the
   `ClusterIssuer` and `Certificate` resources:

   ```bash
   kubectl get clusterissuer
   kubectl -n cert-manager get certificate agrippa-local-ca -o jsonpath='{.status.conditions}' | jq .
   ```

### Fix

If the issuer chain is broken, treat it as an `Application` sync problem
(the `core` layer owns cert-manager and the issuers) -- go to
[§2](#2-an-argocd-application-is-stuck-outofsync-progressing-or-degraded).

### Escalation

A plain trust warning with the correct issuer needs no fix at all -- that's
the platform working as designed. Don't spend time on it.

---

## 6. Nothing resolves at *.127.0.0.1.nip.io at all, every host

**Trigger:** Every `*.127.0.0.1.nip.io` host fails the same way
(connection refused, hangs, DNS failure) -- not just one site.

### Quick check

```bash
docker port k3d-agrippa-dev-serverlb    # expect: 443/tcp -> 0.0.0.0:443
```

### Likely causes, ranked

If `443/tcp` is not listed as mapped to `0.0.0.0:443`, **this is Docker/k3d
itself, not the platform.** No amount of `kubectl` diagnosis inside the
cluster will fix a port that Docker never exposed on the host. Every layer
inside the cluster could be perfectly healthy and every request would still
fail to arrive.

### Fix

See `GETTING_STARTED.md` at the repo root for the preflight checks
(`bats tests/preflight.bats`) that verify Docker is reachable, sized
correctly, and can actually stand up a cluster with its port-maps intact.
If the cluster was created with a stale or half-torn-down state, recreating
it (see `GETTING_STARTED.md`'s troubleshooting section) is usually faster
than debugging Docker's networking by hand.

### Escalation

If the port-map is present and correct but hosts still don't resolve, this
narrows back down to a single-workload or Gateway problem -- go to
[§1](#1-a-siteui-returns-5xx-times-out-or-wont-load-at-all).

---

## 7. When to give up on incremental fixes and do something bigger

Two decision points, in order:

**"I've tried the fix for my specific symptom above and it's still
broken."** If you know what changed recently (a commit, a chart bump, a
manual edit), stop iterating on live fixes and go to
[`./rollback.md`](./rollback.md). A `git revert` plus ArgoCD's `selfHeal` is
almost always faster and more reliable than continuing to hand-patch a live
resource that ArgoCD will just revert anyway.

**"I don't know what's wrong anymore, I've been poking at this for 30+
minutes."** Stop debugging blind. Go to
[`./disaster-recovery.md`](./disaster-recovery.md) for a full rebuild from
git. This is deliberately **cheap** on this platform -- git plus ArgoCD
parity means a from-scratch rebuild reproduces the same desired state as the
cluster you're currently fighting, without carrying forward whatever
half-applied manual state you've accumulated while debugging. Thirty minutes
of continued guessing costs more than a rebuild.

Don't treat a rebuild as a last resort reserved for catastrophe. On a
GitOps-managed dev cluster, it's a normal, low-cost tool -- reach for it as
soon as incremental debugging stops paying off.
