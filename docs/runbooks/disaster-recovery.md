# Disaster recovery: rebuild `agrippa-dev` from scratch

The whole point of a GitOps-managed cluster is that it doesn't need to be
precious. If `agrippa-dev` gets into a state you don't trust, you can delete
it and get it back, byte-for-byte, from `origin/main`. This runbook is that
procedure.

## 1. When to reach for this instead of `./rollback.md` or `./incident-response.md`

Those two runbooks assume you know roughly what's wrong: a bad commit
(`./rollback.md`) or a specific broken component you're diagnosing
(`./incident-response.md`). Reach for a full rebuild instead when:

- You don't know what's wrong anymore. You've made several live changes,
  tried a couple of things, and you're no longer sure what state the cluster
  is actually in versus what git says it should be.
- Multiple things seem broken at once, in ways that don't obviously share a
  root cause, and untangling them individually would take longer than
  starting over.
- You've spent real time debugging without making progress, and the cost of
  a clean rebuild (real, but bounded and well understood, see section 4) is
  now lower than the cost of continuing to dig.
- You want a clean slate on purpose. Periodically deleting `agrippa-dev` and
  rebuilding it from nothing is a useful exercise in its own right, not just
  a last resort. It's the only way to prove the GitOps model actually works
  end to end rather than merely looking correct on a cluster that's been
  incrementally patched by hand for months. See section 4.

If neither of those apply, whatever change you're diagnosing, `./rollback.md`
or `./incident-response.md` will probably get you there faster.

## 2. The rebuild procedure

Run these in order from the repo root. Each `mise run` task is idempotent, so
if you're picking this up partway through (the cluster is already gone, or
`bootstrap` already ran), skip ahead to wherever you actually are.

### Step 1: delete the cluster

```bash
mise run cluster:down
```

Skip this step if the cluster is already gone or unreachable, there's
nothing to delete.

### Step 2: recreate the cluster

```bash
mise run cluster:up
```

This creates a single-node k3d cluster (`k3d/agrippa-dev.yaml`) with k3s's
bundled ServiceLB and Traefik disabled, so metallb owns LoadBalancer IPs and
the Istio Gateway owns `:80`/`:443` without either fighting a built-in
equivalent. The task waits for the node to actually be `Ready` before
returning.

### Step 3: bootstrap the GitOps trust root

```bash
mise run bootstrap
```

This requires an **unlocked Bitwarden session** holding `agrippa-age-dev`.
If your session isn't set up, unlock one first:

```bash
echo BW_SESSION="$(bw unlock --raw)" > .env
```

(`mise` picks up `.env` automatically, per this repo's convention.) Without
that unlocked session, `bootstrap` fails loudly, naming the missing
prerequisite (`bw login` / `bw unlock`), it never falls back to a plaintext
key or silently skips the step.

`bootstrap` does three things, in order: writes the `sops-age` Secret into
the `argocd` namespace (the decrypted key is piped straight from `bw` into
`kubectl`, never touching disk or a shell variable), installs a
KSOPS-enabled ArgoCD, and applies the root app-of-apps once. That third
action is the last manual step for the platform's own layers. From here,
ArgoCD reconciles everything else itself, straight from `origin/main`.

### Step 4: watch ArgoCD rebuild the platform

```bash
kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

Poll this every 10-15 seconds until all eight Applications
(`root`, `argocd`, `core`, `storage`, `platform`, `observability`,
`workloads-resume`, `workloads-trips`) show `Synced`/`Healthy`. They come up
in sync-wave order, `core` (0) then `storage` (1) then `platform` (2) then
`observability` (3) then `workloads-resume` and `workloads-trips` (4), because
each layer depends on the one below it.

Give this real time. This is a from-scratch install of Istio, cert-manager,
CloudNativePG, Keycloak, Forgejo, Flagsmith, and the full LGTM observability
stack, not an incremental sync against an already-warm cluster. Expect
something in the range of 10+ minutes of wall clock before every layer
settles, `platform` and `observability` are the slow ones. Don't read a
still-`Progressing` Application after 5 minutes as stuck, and don't read
`Synced` on a lower layer as "safe to stop watching," a later layer can
still surface a problem that traces back to one underneath it.

### Step 5: build and import the workload images

```bash
mise run workloads:build
```

This is the **one manual step that does not happen automatically** from
`bootstrap` or ArgoCD reconciliation. The `resume` and `trips` images are
built locally with `docker build` and imported directly into the k3d node's
containerd, they are never pushed to or pulled from a registry. That image
content lived only on the old cluster's node and was deleted along with it.
Skip this step and the `resume`/`trips` Deployments will reconcile
correctly (ArgoCD has no trouble applying the manifests) but sit in
`ErrImageNeverPull`, referencing tags that simply don't exist on the new
node.

### Step 6: verify

Run the full suite:

```bash
bats tests/
```

Or, for the fastest cross-cutting proof that the rebuild actually worked
end to end:

```bash
ENV=dev \
  PUBLIC_HOST=davidsouther.com.127.0.0.1.nip.io \
  TRIPS_HOST=trips.davidsouther.com.127.0.0.1.nip.io \
  DASHBOARD_HOST=dashboard.davidsouther.com.127.0.0.1.nip.io \
  bats tests/agrippa.bats
```

A clean pass across every suite is the actual definition of "the rebuild
worked," not "every Application says Healthy." Healthy proves ArgoCD applied
the manifests; the bats probes prove the platform behaves.

## 3. What you get back, and what you don't

Everything declared in git comes back exactly as git says it should:
every chart pin, every manifest, every kustomize overlay, every sops-encrypted
credential (re-decrypted fresh from the same Bitwarden-held `agrippa-age-dev`
key). There is no drift to reconcile and nothing to reconstruct by hand,
this is what GitOps parity buys you.

What does **not** come back automatically is any runtime data that existed
only in the old cluster's PVCs. That data splits into two categories with
different exposure, and the distinction matters before you tear anything down.

Postgres row data has a real automated backup and point-in-time recovery
path. Keycloak users and sessions beyond the declaratively-imported realm,
Flagsmith flag values set at runtime through the admin UI, Forgejo's metadata,
and database rows in general are all captured by CloudNativePG's continuous WAL
archiving and scheduled base backups to a dedicated `minio-backup` MinIO
instance. A clean rebuild does not replay that data for you, but the archive is
there to recover from. See
[`./backup-restore.md`](./backup-restore.md) sections 2 and 4 for how it is
configured and how to restore a cluster from it.

Two things have no backup at all: Forgejo's git content (the
`gitea-shared-storage` PVC, holding every commit, branch, blob, and LFS
object, entirely separate from the Postgres metadata) and Valkey's cached
state. Nothing backs either one up, so no rebuild, however clean, restores it.

The catch this runbook cannot skip: `minio-backup` is itself a `local-path`
PVC on the same single node as everything else. `mise run cluster:down`
destroys the backup store along with the Postgres primary it protects. The
archive only helps you if you recover from it, or copy it off-node, **before**
you tear the cluster down, not after. If the cluster is in trouble because of
bad data rather than a broken deploy, read `./backup-restore.md` and act on
`minio-backup` before you run `mise run cluster:down`.

## 4. Why this is cheap here

This is the entire point of the platform's "parity" design goal (see
`ARCHITECTURE.html` and `README.md`'s Environments section): local k3d and
the production cloud VMs run the identical Helm charts and manifests, only
overlay values diverge. A full local rebuild isn't a break-glass procedure
bolted on after the fact, it's the same reconciliation path this cluster
already runs continuously via `selfHeal`, just starting from empty instead
of from a small drift.

That's also why it's worth doing on purpose sometimes, not only when things
break. Running this procedure periodically is a live test that the platform
genuinely rebuilds from nothing, rather than a claim that's only ever been
true on paper. If a from-scratch rebuild ever fails somewhere `selfHeal`
alone wouldn't have caught, that's a real gap in the GitOps model worth
fixing, and this is the cheapest way to find it.
