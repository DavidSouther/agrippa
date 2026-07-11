# Runbook: bumping a chart version

How to safely update one of the platform's pinned upstream Helm chart
versions. Every component in this repo is composed via kustomize's
`helmCharts:` inflation of an upstream chart, pinned to an exact `version:`
in that component's `kustomization.yaml`. There is no `Chart.lock` and no
`helm dependency update` step -- the pin lives directly in the kustomization
file, and bumping it is a one-line edit followed by a render check.

For the general command surface (cluster access, ArgoCD, logs, mise tasks)
see `USAGE.md` at the repo root. This runbook only covers the chart-bump
workflow itself.

## 1. The current chart inventory

| Component | Chart file | Repo | Version |
| --- | --- | --- | --- |
| Istio `base` | `core/overlays/dev/istio-base/kustomization.yaml` | `https://istio-release.storage.googleapis.com/charts` | `1.30.2` |
| Istio `istiod` | `core/overlays/dev/istio-control/kustomization.yaml` | `https://istio-release.storage.googleapis.com/charts` | `1.30.2` |
| Istio `cni` | `core/overlays/dev/istio-control/kustomization.yaml` | `https://istio-release.storage.googleapis.com/charts` | `1.30.2` |
| Istio `ztunnel` | `core/overlays/dev/istio-control/kustomization.yaml` | `https://istio-release.storage.googleapis.com/charts` | `1.30.2` |
| CloudNativePG operator (`cloudnative-pg`) | `storage/overlays/dev/cnpg-operator/kustomization.yaml` | `https://cloudnative-pg.github.io/charts` | `0.29.0` |
| Valkey | `storage/overlays/dev/valkey/kustomization.yaml` | `https://valkey.io/valkey-helm/` | `0.10.0` |
| Forgejo | `platform/overlays/dev/forgejo/chart/kustomization.yaml` | `oci://code.forgejo.org/forgejo-helm` | `17.1.1` |
| Flagsmith | `platform/overlays/dev/flagsmith/helm/kustomization.yaml` | `https://flagsmith.github.io/flagsmith-charts/` | `0.82.0` |
| Loki | `observability/overlays/dev/loki/kustomization.yaml` | `https://grafana-community.github.io/helm-charts` | `18.4.2` |
| Tempo | `observability/overlays/dev/tempo/kustomization.yaml` | `https://grafana-community.github.io/helm-charts` | `2.2.3` |
| Grafana | `observability/overlays/dev/grafana/kustomization.yaml` | `https://grafana-community.github.io/helm-charts` | `12.7.2` |
| Mimir (`mimir-distributed`) | `observability/overlays/dev/mimir/kustomization.yaml` | `https://grafana.github.io/helm-charts` | `6.1.0` |
| Alloy | `observability/overlays/dev/alloy/kustomization.yaml` | `https://grafana.github.io/helm-charts` | `1.10.0` |

The four Istio charts release in lockstep and are pinned to the same
version across both files; bump all four together, not one at a time.

**Keycloak is not a chart.** It ships as raw pinned upstream Operator
manifests (a manifest URL and image tag), not a `helmCharts:` entry --
there is no `version:` field to edit. Its pin lives in
`platform/overlays/dev/keycloak/kustomization.yaml` (via the manifests
under `operator/`). Bumping Keycloak means updating that manifest
reference and image tag directly; the render-check and diff steps below
still apply, but "check the chart's changelog" becomes "check the
Keycloak Operator's release notes."

## 2. The update procedure

### Step 1: read the chart's own changelog first

Manual research step, no shortcut. Before touching the `version:` field,
read the chart's own changelog / release notes for every version between
the current pin and the target, looking specifically for:

- Renamed, removed, or restructured `values.yaml` keys.
- New defaults that turn on additional subcharts, replicas, or components
  (see the callout below -- this bit the Mimir bump this session).
- Any migration notes for persisted state (PVCs, CRDs, schema versions).

Chart source, ArtifactHub, or (for OCI charts like Forgejo)
`helm show chart oci://<repo>/<chart> --version <version>` are the usual
places to look. Diffing the chart's own `values.yaml` between the current
and target version is often more informative than the changelog prose --
`helm show values <repo>/<chart> --version <old>` vs `--version <new>`.

### Step 2: edit the `version:` field

Edit the `version:` under `helmCharts:` in the component's
`kustomization.yaml` (see the inventory table above for the file). For the
Istio charts, update all four `version:` fields together.

### Step 3: render-check locally, before committing anything

This alone catches most schema-incompatible value changes -- a chart that
removed or renamed a key this repo's `valuesInline:` still sets will fail
here, not later in ArgoCD.

```bash
eval "$(mise activate bash)"
kustomize build --enable-helm <path-to-overlay-dir>
```

For example:

```bash
eval "$(mise activate bash)"
kustomize build --enable-helm storage/overlays/dev/valkey
```

If this errors, fix the `valuesInline:` block to match the new chart's
schema before moving on. Do not commit a version bump that doesn't render.

### Step 4: diff the new render against the previous one

Look for unexpected new or removed resources -- an extra Deployment, a
StatefulSet that split into three, a webhook that wasn't there before are
exactly the kind of surprise the callout below describes.

```bash
# stash the version bump so the working tree renders the OLD chart
git stash

eval "$(mise activate bash)"
kustomize build --enable-helm <path-to-overlay-dir> > /tmp/chart-render-old.yaml

# bring the version bump back
git stash pop

kustomize build --enable-helm <path-to-overlay-dir> > /tmp/chart-render-new.yaml

diff /tmp/chart-render-old.yaml /tmp/chart-render-new.yaml
```

For a smaller bump, eyeballing the `kustomize build` output for unexpected
`kind:`/`metadata.name` entries is often enough and the stash dance can be
skipped.

### Step 5: commit, push a feature branch, and open a pull request

Use a Conventional Commit with the scope matching the chart's layer
(`core` for Istio, `store` for CloudNativePG/Valkey, `plat` for
Forgejo/Flagsmith/Keycloak, `otel` for Loki/Tempo/Grafana/Mimir/Alloy --
see `DEVELOPMENT.md`).

```bash
git checkout -b chore/bump-<chart>-<new-version>
git add <path-to-overlay-dir>/kustomization.yaml
git commit -m "chore(<scope>): bump <chart> to <new-version>"
git push -u origin chore/bump-<chart>-<new-version>
gh pr create --base main --fill
```

Merge the reviewed pull request into `main` before moving on to step 6.

### Step 6: watch the owning ArgoCD layer Application reconcile

```bash
export KUBECONFIG="$(k3d kubeconfig write agrippa-dev)"
kubectl config use-context k3d-agrippa-dev

# force a re-sync check right after the push, rather than waiting for
# ArgoCD's own polling interval
kubectl -n argocd annotate application <layer-name> argocd.argoproj.io/refresh=hard --overwrite

kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

`<layer-name>` is one of `core`, `storage`, `platform`, `observability`,
`workloads` -- whichever owns the chart you bumped.

### Step 7: run that component's bats feature test

```bash
bats tests/<feature>.bats
```

### Step 8: if it breaks

Follow [`./rollback.md`](./rollback.md).

## 3. Real chart-upgrade surprises this session already hit

These are the class of thing to watch for on any bump, not just "it might
break":

- **A chart's default architecture can change out from under you.**
  Mimir 6.x's default moved from the classic distributor/ingester path to
  a Kafka-backed "ingest storage" mode (`kafka.enabled: true` by default),
  silently adding a Kafka broker and a zone-awareness requirement that no
  prior version needed. There was no supported way to layer an extra
  values file through `helmCharts: valuesInline`, so the chart's own
  `classic-architecture.yaml` escape hatch had to be inlined by hand:
  `kafka.enabled: false` plus several `mimir.structuredConfig` overrides
  (`ingest_storage.enabled: false`, nulled Kafka address/topic, an
  explicit ingester ring `replication_factor`). See
  `observability/overlays/dev/mimir/kustomization.yaml` for the exact
  shape. Read the changelog for architecture-level defaults, not just
  renamed keys.

- **A chart's own "sane default" can silently multiply a real replica
  count.** Mimir's `ingester` and `store_gateway` both default
  `zoneAwareReplication.enabled: true` (three logical zones). With that
  on, a top-level `replicas: 1` doesn't mean one pod -- it renders three
  separate StatefulSets, one per zone, each carrying its own replica
  count. Confirmed live this session. If a component's stated `replicas:`
  value is supposed to be the literal pod count, check for a
  `zoneAwareReplication`-shaped toggle and disable it explicitly.

- **`helm template` is what actually runs here, not `helm install`.**
  kustomize's `helmCharts:` inflation shells out to `helm template`, which
  renders every `helm.sh/hook`-annotated resource (test Pods, pre-install
  Jobs) as a permanent object instead of running it once and discarding
  it the way `helm install`/`helm test` would. ArgoCD then plain-applies
  whatever kustomize handed it, hook annotations and all -- it doesn't run
  a hook lifecycle either. Two mitigations, both already in use across
  this repo's charts:
  - `skipTests: true` on the `helmCharts:` entry excludes the chart's own
    `helm.sh/hook: test` resources (Valkey's `valkey-test-auth-existing`
    Pod, Forgejo's `templates/tests/` Pod, Mimir's `mimir-smoke-test` Job).
  - Some charts ship a Job that is *not* a `test` hook and so isn't
    touched by `skipTests` -- Mimir's bundled minio subchart runs its own
    post-install bucket-creation Job (`mimir-minio-post-job`) that
    duplicates a non-hook Job the parent chart already creates. That one
    needed an explicit `patches:` block using the `$patch: delete` idiom,
    scoped to just that resource. Check for this class of duplicate
    whenever a chart bundles a subchart with its own init/setup Job.

## 4. See also

- [`./testing-changes.md`](./testing-changes.md) -- how to validate a
  change beyond the render check and the one feature test named above.
- [`./rollback.md`](./rollback.md) -- what to do when a bump reconciles
  but breaks the component, or won't reconcile at all.
- [`./capacity-and-resource-pressure.md`](./capacity-and-resource-pressure.md)
  -- what to do if the new version needs more CPU/memory than the old one
  fit on the single-node dev cluster.
