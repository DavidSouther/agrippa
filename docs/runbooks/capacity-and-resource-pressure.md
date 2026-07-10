# Capacity and resource pressure on agrippa-dev

Something on `agrippa-dev` won't schedule, or a pod keeps dying with
`OOMKilled`. This runbook is the deep-dive `../runbooks/incident-response.md`
points to for both symptoms. It has happened more than once already during
this cluster's own build -- Keycloak's Operator default couldn't schedule,
and Flagsmith's API container got OOMKilled on startup -- so this document
leads with what actually happened, not a hypothetical.

Point `kubectl` at the cluster once per shell before anything below:

```bash
export KUBECONFIG="$(k3d kubeconfig write agrippa-dev)"
kubectl config use-context k3d-agrippa-dev
```

---

## 1. Why this happens on this cluster specifically

`agrippa-dev` is a **single k3d node**, hosted inside one Docker Desktop VM
on a laptop. There is no separate node pool, no cluster autoscaler, and
nowhere for an over-large pod to overflow to -- every one of Istio,
cert-manager, metallb, CloudNativePG, Valkey, Keycloak, Forgejo, Flagsmith,
and the full Grafana LGTM stack (Loki, Grafana, Tempo, Mimir, Alloy) plus
ArgoCD itself has to fit, simultaneously, inside whatever CPU and memory
Docker Desktop hands that one node. That is a deliberate dev/local tradeoff:
production runs the same charts and manifests across multiple cloud VMs with
room to add more; this cluster's entire ceiling is one number set in Docker
Desktop's **Settings > Resources** panel.

That panel is the hard outer limit. Nothing inside Kubernetes -- no request,
no limit, no priority class -- can make more CPU or memory exist than Docker
Desktop was told to give the k3d node. `kubectl describe node` and `kubectl
top nodes` (section 2) both report *against that ceiling*, not against the
laptop's own physical RAM.

`GETTING_STARTED.md` currently states a minimum of **4 CPUs / 8GB memory**.
That number was written before the platform was built out -- it predates
Keycloak, Forgejo, Flagsmith, and the full LGTM stack, all of which now run
concurrently. Don't take that minimum as still accurate; the live numbers in
section 2 below (captured 2026-07-10, full platform running, 46 pods, zero
restarts) show actual steady-state memory usage already sitting above the
documented 8GB floor. Docker Desktop on this machine is currently configured
for 8 CPUs / ~15.6GiB (~16.7GB), double the documented minimum on both axes
-- and that is what it currently takes to keep the node healthy with any
headroom at all. Treat `GETTING_STARTED.md`'s "4 CPUs / 8GB" as stale and
due for a bump, not as a validated floor.

One more pattern worth internalizing before section 2: on this cluster,
**memory is the scarce resource, not CPU**. Every real incident so far
(Keycloak's scheduling failure, Flagsmith's OOMKill, Mimir's whole-footprint
tuning) was a memory problem. Live CPU usage sits at a few percent even at
full platform load. When triaging a new incident, look at memory numbers
first.

---

## 2. The two-command diagnostic

Two commands answer "is this a capacity problem" faster than anything else:

```bash
kubectl describe node k3d-agrippa-dev-server-0
```

Skip to the **Allocated resources** section near the bottom -- it shows
what every pod on the node has *declared* it needs (`requests`) and the most
it's *allowed* to use (`limits`), as a percentage of the node's allocatable
capacity.

```bash
kubectl top nodes
kubectl top pods -A --sort-by=memory | head -20
```

These show what's *actually* being used right now, live, regardless of what
was declared. The two views can disagree substantially -- see the callout
below.

### Baseline snapshot: 2026-07-10, full platform running, cluster healthy

Captured against the real `agrippa-dev` cluster, all 46 pods `Running`, zero
restarts at capture time. Use this as the "healthy" reference point for
comparison during a future incident.

**Node capacity / allocatable** (`kubectl describe node`):

| Resource | Capacity / Allocatable |
| --- | --- |
| CPU | 8 |
| Memory | 16355772Ki (~15.6Gi / ~16.7GB) |

This exactly matches Docker Desktop's own VM allocation (`docker info
--format '{{.NCPU}} CPUs, {{.MemTotal}} bytes mem'` reports `8 CPUs,
16748310528 bytes` on this machine) -- confirming the single k3d node
consumes the entire Docker Desktop VM, with no slack reserved outside it.

**Declared (Allocated resources, from `kubectl describe node`):**

| Resource | Requests | Limits |
| --- | --- | --- |
| CPU | 2970m (37%) | 2700m (33%) |
| Memory | 7492Mi (46%) | 4716Mi (29%) |

**Actual live usage (`kubectl top nodes`):**

| Resource | Used | Percent |
| --- | --- | --- |
| CPU | 397m | 4% |
| Memory | 9232Mi | 57% |

Note the gap: live memory usage (9232Mi, 57%) is **higher** than total
*declared requests* (7492Mi, 46%). That is not a measurement error --
several components on this cluster (`argocd-application-controller`, Loki,
Grafana, Tempo, postgres, Valkey) currently run with no memory request set
at all, so the scheduler's bin-packing math treats them as needing zero
memory while they actually consume tens to hundreds of `Mi` each. `kubectl
describe node`'s Allocated resources section tells you what the scheduler
*thinks* is committed; `kubectl top` tells you what's *really* there. Trust
`top` for "is the node actually under pressure right now," and trust
`describe node` for "would a new pod's declared request fit." A pod can
fail to schedule on paper-thin allocatable headroom even while `kubectl top`
shows the node mostly idle, and vice versa -- a node can be genuinely
memory-starved live while `describe node` still shows plenty of
undeclared headroom.

**Top memory consumers** (`kubectl top pods -A --sort-by=memory | head -10`):

| Pod | Namespace | Memory (live) |
| --- | --- | --- |
| `flagsmith-api-*` | flagsmith | 651Mi |
| `argocd-application-controller-0` | argocd | 610Mi |
| `keycloak-0` | keycloak | 548Mi |
| `keycloak-operator-*` | keycloak | 271Mi |
| `alloy-*` | observability | 249Mi |
| `loki-0` | observability | 223Mi |
| `mimir-ingester-0` | observability | 190Mi |
| `postgres-1` | storage | 183Mi |
| `grafana-*` | observability | 149Mi |
| `argocd-repo-server-*` | argocd | 127Mi |

If your own `kubectl top pods -A --sort-by=memory | head -20` looks
substantially worse than this (higher percentages, less headroom, a new
top consumer far outside this list), you have a real regression to chase,
not just normal day-to-day variance.

---

## 3. Diagnosing a specific stuck pod

Once section 2 shows node-level pressure (or even if it doesn't -- always
check the specific pod, don't assume), the pod's own Events tell you
definitively what's wrong:

```bash
kubectl describe pod <pod> -n <namespace>
```

Read the **Events** section at the very bottom. It disambiguates a resource
problem from anything else (image pull failure, volume mount failure,
admission webhook rejection) instantly:

- **`0/1 nodes are available: 1 Insufficient memory`** (or `Insufficient
  cpu`) -- this pod's declared `resources.requests` is larger than what's
  currently free on the node's allocatable capacity. The pod is stuck
  `Pending` and will stay that way until either something else is trimmed
  or freed, or the request is lowered. This is a **scheduling-time**
  failure -- the container never started.

  This is exactly what happened with Keycloak: the Operator's own default
  Keycloak CR requests 1700Mi of memory, and by the time the Keycloak
  feature-step built, the node's allocatable was already close to fully
  requested by everything else live (istiod alone requests 2Gi; the
  concurrently-building Observability layer's Loki cache alone requested
  close to 10Gi at the time). The scheduler's own Events message named it
  outright.

- **`OOMKilled`** -- this is a *different* failure mode, and it shows up in
  a different place. The pod scheduled and started fine; the container
  then exceeded its own `resources.limits.memory` ceiling at runtime and
  the kernel's cgroup OOM killer terminated it (`exitCode: 137`). Check the
  container status directly, not just Events:

  ```bash
  kubectl -n <namespace> get pod <pod> -o jsonpath='{.status.containerStatuses[*].lastState}'
  ```

  This is exactly what happened with Flagsmith: the API container's memory
  *limit* was too tight for the memory spike during its own startup
  (gunicorn worker fan-out on top of the migrate-db/bootstrap
  initContainers), even though its steady-state usage afterward sat
  comfortably under the limit. `kubectl -n flagsmith get pods` showed
  `lastState.terminated.reason: OOMKilled` on a container that then came
  back up fine on retry, restarted, and OOMKilled again -- a `Pending`-style
  Events message never appeared, because scheduling itself was never the
  problem.

The distinction matters for the fix: `Insufficient memory` in Events means
lower (or make room for) the pod's **request**. `OOMKilled` in
`lastState.terminated` means raise the container's **limit** (or find and
fix a real leak, if steady-state usage is also near the limit, not just a
startup spike).

If Events shows neither of these -- an image pull error, a volume mount
failure, a webhook rejection -- this is not a capacity problem. Go back to
[`./incident-response.md`](./incident-response.md) and pick the matching
symptom there instead.

---

## 4. The fix pattern, with real precedent

Both directions of this fix have already happened on this exact cluster:
scaling **down** an over-provisioned default (Keycloak), and scaling **up**
an under-provisioned one (Flagsmith). Reproduce the same shape, don't invent
a new one.

### Scaling down: Keycloak's CR (`spec.resources` on a raw manifest)

Keycloak isn't a Helm chart in this repo -- it's a raw Keycloak Operator
custom resource, so the fix lives directly in the CR's `spec`, not in a
`valuesInline` block. Current state,
`platform/overlays/dev/keycloak/keycloak.yaml`:

```yaml
spec:
  instances: 1
  # BUILD-TIME FINDING (live-verified): the Operator's own default request
  # (1700Mi memory) could not schedule on the single-node k3d-agrippa-dev
  # cluster -- its 16Gi allocatable is ~99% requested by everything else
  # already live (istiod alone requests 2Gi; the concurrently-building
  # Observability layer's Loki chunks-cache alone requests ~9.8Gi). Scoped
  # down to a dev-appropriate footprint, matching this CR's other dev
  # sizing (spec.instances: 1, a single minimal proof realm).
  resources:
    requests:
      memory: 512Mi
      cpu: 250m
    limits:
      memory: 1Gi
```

### Scaling up: Flagsmith's API container (`valuesInline` on a Helm chart)

Flagsmith is a chart, so its fix lives in the `helmCharts: valuesInline`
block. Current state,
`platform/overlays/dev/flagsmith/helm/kustomization.yaml`:

```yaml
      api:
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 1Gi
```

The kustomization's own build-time comment records why: the chart's
commented-out example (`limits.memory: 500Mi`) OOMKilled the API container
(`exitCode: 137`) seconds after its first successful startup, confirmed via
`lastState.terminated.reason: OOMKilled` alongside a steady-state usage
(~245Mi) sitting well under that limit -- meaning the kill hit a transient
startup spike, not a sustained leak. Raised to `1Gi`, since the node had
ample headroom (46% memory requested pre-fix), and re-verified stable
afterward.

### The general procedure

1. **Edit the resources block.** For a chart-based component, that's the
   relevant `helmCharts: valuesInline` block in the component's
   `kustomization.yaml` (Flagsmith's shape above). For a raw manifest like
   Keycloak's Operator CR, that's `spec.resources` directly on the CR
   (Keycloak's shape above).

2. **Render-check locally before committing anything:**

   ```bash
   eval "$(mise activate bash)"
   kustomize build --enable-helm <path-to-overlay-dir>
   ```

   For example, `kustomize build --enable-helm platform/overlays/dev/flagsmith`.
   This catches a malformed values block before it ever reaches ArgoCD.

3. **Commit and push** with a Conventional Commit, scope matching the
   component's layer (`plat` for Keycloak/Flagsmith, `otel` for
   Mimir/Loki/Grafana/Tempo/Alloy -- see `DEVELOPMENT.md`):

   ```bash
   git add <path>
   git commit -m "fix(plat): raise flagsmith API memory limit to 1Gi"
   git push origin main
   ```

4. **Watch the pod restart with the new values:**

   ```bash
   kubectl -n argocd annotate application platform argocd.argoproj.io/refresh=hard --overwrite
   kubectl -n <namespace> get pods -w
   ```

5. **Confirm the fix actually landed** -- it schedules (no more `Pending`
   with `Insufficient memory`/`cpu` Events), or it stops OOMKilling (no
   further restarts after a few minutes; `kubectl -n <namespace> get pods`
   shows a stable `RESTARTS` count and `kubectl top pods -n <namespace>`
   shows steady-state usage comfortably under the new limit, not right up
   against it).

If it breaks in a new way, [`./rollback.md`](./rollback.md) covers reverting
the commit.

---

## 5. When shrinking a component isn't enough

Trimming every component's requests downward has a floor. If a component
genuinely needs more memory than the node can ever provide -- even after
every other component on the cluster has already been trimmed to a sane
minimum -- the fix is **raising Docker Desktop's own allocation**, not
endlessly re-tuning requests/limits in a losing game of musical chairs.

Docker Desktop: **Settings > Resources**, raise CPUs and/or Memory, apply
and restart. The k3d node's `Capacity`/`Allocatable` in `kubectl describe
node` will reflect the new ceiling as soon as Docker Desktop restarts the
VM (no cluster recreate needed).

The assumption that a fixed floor is "enough" is encoded in
`tests/preflight.bats`, which checks Docker's allocation against a minimum
before letting a k3d cluster stand up:

```bash
: "${MIN_DOCKER_CPU:=4}"
: "${MIN_DOCKER_MEM_GB:=8}"
```

`GETTING_STARTED.md` documents overriding these when the real minimum is
higher than the default:

```bash
MIN_DOCKER_CPU=6 MIN_DOCKER_MEM_GB=12 bats tests/preflight.bats
```

Given section 1's finding that live steady-state usage already exceeds the
default 8GB floor with the full platform running, raising both the
preflight defaults and `GETTING_STARTED.md`'s stated minimum is overdue --
treat that as a standing follow-up, not something to keep rediscovering
per-incident.

---

## 6. What's already been tuned on this cluster

A running list, so a future incident doesn't waste time rediscovering a fix
that already happened. Check here before assuming a component's sizing is
untouched.

| Component | Direction | What changed | Where |
| --- | --- | --- | --- |
| Keycloak | Scoped **down** | Operator default 1700Mi memory request cut to 512Mi request / 1Gi limit, plus a 250m CPU request | `platform/overlays/dev/keycloak/keycloak.yaml` |
| Flagsmith API | Scoped **up** | Memory limit raised 500Mi (chart's own commented-out example) to 1Gi after a startup OOMKill; requests set to 100m CPU / 256Mi memory | `platform/overlays/dev/flagsmith/helm/kustomization.yaml` |
| Mimir (whole footprint) | Scoped **down**, extensively | Ingester and store-gateway replica counts forced to 1 with `zoneAwareReplication.enabled: false` (the chart's default zone-awareness was silently rendering 3 StatefulSets per component instead of 1); the bundled `rollout_operator` subchart disabled entirely (its admission webhooks blocked ArgoCD's dry-run diff while not coordinating anything meaningful without zone-aware replication); several memcached-backed caches left at the chart's own disabled default. See `observability/overlays/dev/mimir/kustomization.yaml`'s own inline comments for the full, canonical record -- don't re-derive this, it's already documented in detail at the source. | `observability/overlays/dev/mimir/kustomization.yaml` |

---

## See also

- [`./incident-response.md`](./incident-response.md) -- front door for any
  live symptom; points here specifically for `Pending` pods and node-level
  pressure.
- [`./rollback.md`](./rollback.md) -- reverting a resource-sizing commit
  that made things worse instead of better.
- [`./deploying-chart-updates.md`](./deploying-chart-updates.md) -- a chart
  version bump can change a component's default resource footprint (Mimir's
  6.x bump did); check this runbook as part of any bump's validation.
- [`GETTING_STARTED.md`](../../GETTING_STARTED.md) -- Docker Desktop's
  resource allocation and the `MIN_DOCKER_CPU`/`MIN_DOCKER_MEM_GB` preflight
  override.
