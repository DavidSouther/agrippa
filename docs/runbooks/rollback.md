# Rolling back a bad change

You arrived here because something on `agrippa-dev` broke after a change, and
you want it un-broken. Read the next paragraph before you touch `kubectl`.

## The one fact that governs everything below

`agrippa-dev` is GitOps-managed by ArgoCD. Every layer -- `root`, `core`,
`storage`, `platform`, `observability`, `workloads`, and `argocd` itself -- is
an ArgoCD `Application` with:

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

`selfHeal: true` means ArgoCD continuously compares the live cluster against
`origin/main` and reverts any drift back to what git says, automatically. If
you `kubectl edit`, `kubectl patch`, or `kubectl delete` something to "fix" it
live, ArgoCD will silently undo your fix within seconds to a few minutes
(whenever it next reconciles, sooner if something nudges a refresh). You will
not get an error. Your change will just quietly disappear and the original
problem will come back.

**Git is the only durable rollback lever on this cluster.** Anything you do
directly against the live cluster is, at best, temporary. Keep that in mind
through all three sections below.

---

## 1. The correct rollback: revert the git commit

This is the mechanism to reach for in the overwhelming majority of cases. It
is both the fix and self-enforcing: once the revert lands on `origin/main`,
ArgoCD's own `selfHeal` picks it up on its own, typically within its default
polling interval (about 3 minutes), or immediately if you force a refresh.

### Find the bad commit

```bash
git log --oneline
```

Look for the commit (or range of commits) that introduced the problem. This
repo's commits are scoped with a Conventional Commits type and area, e.g.
`fix(otel): set Mimir's ingester ring replication_factor to 1` -- the scope
(`core`, `store`, `otel`, `plat`, `work`) tells you which ArgoCD layer to
watch for the fix to land in.

### Revert it

Start a feature branch for the revert, same as any other change:

```bash
git checkout -b revert/<short-description>
```

A single bad commit:

```bash
git revert <sha>
```

A range of bad commits (oldest good commit first, newest bad commit last):

```bash
git revert <old>..<new>
```

`git revert` creates a **new** commit that undoes the change, rather than
rewriting history. That matches this repo's git-safety posture: a revert
lands through a feature branch and a reviewed pull request like any other
change, and history is never force-pushed or rewritten once it's public.
`git reset` or a force-push would violate that -- don't use them for this.

If `git revert` produces a merge conflict (rare on a linear `main`, but
possible if later commits touched the same lines), resolve it by hand, then
`git revert --continue`.

### Push it

```bash
git push -u origin revert/<short-description>
gh pr create --base main --fill
```

Merge the reviewed pull request into `main` before moving to the next step.

### Confirm ArgoCD picked it up

Point `kubectl` at the cluster first if you haven't already this shell
session:

```bash
export KUBECONFIG="$(k3d kubeconfig write agrippa-dev)"
kubectl config use-context k3d-agrippa-dev
```

Then force a hard refresh on the affected layer's Application rather than
waiting out the polling interval:

```bash
kubectl -n argocd annotate application <layer> \
  argocd.argoproj.io/refresh=hard --overwrite
```

`<layer>` is one of `core`, `storage`, `platform`, `observability`,
`workloads`, `root`, or `argocd`. Watch it come back to `Synced`/`Healthy`:

```bash
kubectl -n argocd get application <layer> \
  -o jsonpath='{.status.sync.status} {.status.health.status}'
```

### Worked precedent from this repo

Commit `463a33f` (`fix(otel): set Mimir's ingester ring replication_factor to
1`) fixed a live Mimir misconfiguration by editing
`observability/overlays/dev/mimir/kustomization.yaml`. That wasn't a
rollback -- it was a forward fix -- but it's the exact same delivery
mechanism a rollback commit uses: edit (or revert), commit, push a feature
branch, open a pull request, get it reviewed and merged into `main`, then
let ArgoCD reconcile. If a revert isn't clean (the bad change is tangled up
with later, wanted changes), a hand-written forward-fix commit that
restores the old behavior is an equally valid use of this same mechanism.

---

## 2. The stopgap: ArgoCD's own app-level rollback

Sometimes a clean `git revert` isn't fast enough to work out -- the bad
commit is tangled up with unrelated changes, or you need the cluster back to
a known-good state **this instant** and can sort out the git history after.
For that, ArgoCD keeps a deploy history per Application and can roll the live
resources back to a prior revision without you writing a commit first.

### Via the ArgoCD CLI

List revisions for the app:

```bash
argocd app history <app-name>
```

Roll back to a specific history entry:

```bash
argocd app rollback <app-name> <history-id>
```

`<app-name>` is the same layer name as above (`core`, `storage`, `platform`,
`observability`, `workloads`). If the CLI isn't installed, log in against a
port-forward:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
argocd login localhost:8080 --username admin --insecure
```

### Via the UI

Open `https://argocd.127.0.0.1.nip.io/` (the cluster's local CA isn't in your
system trust store, so a browser will warn once per host -- click through it,
or use `curl -k` for API calls). Log in as `admin`:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

Open the affected Application, then **History and Rollback** in the app
detail panel, and pick the last known-good revision.

### Critical caveat -- read this before you rely on step 2 alone

**An ArgoCD app rollback does not touch git.** It only changes what's applied
to the live cluster. The moment the next sync cycle runs, or the next
`git push` touches that Application's path, ArgoCD will pull `main` again --
which still has the bad commit on it -- and `selfHeal: true` will silently
undo your rollback, because as far as git is concerned nothing changed. You
will be right back where you started, possibly without noticing right away.

Treat an ArgoCD-level rollback as a **bridge, not a destination**. It buys
you a few minutes of a stable cluster while you work out the git-level fix.
The git revert from section 1 must follow **immediately**, not "eventually" --
ideally before you even declare the incident over.

---

## 3. What rollback does not cover

### Runtime data

Rolling back a Helm chart version or a manifest change puts the *desired
state* back to what it was. It does not undo what happened to *data* in the
meantime: Postgres rows written or changed, Forgejo repo content pushed,
Flagsmith flag values flipped by a user. None of that is stored in git, so no
git-level or ArgoCD-level rollback touches it. If bad data is the problem,
this document is the wrong runbook -- see
[`./backup-restore.md`](./backup-restore.md).

### Workload image changes (`workloads:build`)

Rolling back a Deployment manifest's image tag is **not enough** for the
`resume` and `trips` workloads. Their images are built locally with
`mise run workloads:build` and imported straight into the k3d node's
containerd -- they are never pushed to or pulled from a registry. That means
the image content behind a given tag lives only on this machine's local k3d
node, and a later `workloads:build` run can silently overwrite what a tag
used to point to, independent of anything the Deployment manifest's `image:`
field says.

So reverting a workload image change means:

1. Revert or fix the git commit as in section 1 (manifest, chart values,
   submodule pointer -- whatever changed).
2. Re-run `mise run workloads:build` against the **old** source (check out
   the old submodule commit first if the submodule pointer moved), or
   re-import a previously built image if you still have it, so the image tag
   in containerd actually matches what the manifest now claims again.

A git revert alone will leave the Deployment pointing at a tag that either no
longer means what it used to, or doesn't exist in the node's local image
cache at all. See the Workloads section of
[`./testing-changes.md`](./testing-changes.md) for the full build/import
cycle.

---

## 4. Quick-reference decision table

| Situation | Do this |
| --- | --- |
| Bad manifest/values/chart change, not yet causing an outage | `git revert`, push, force an ArgoCD refresh (section 1) |
| Active outage, need it fixed right now | `argocd app rollback` first to stop the bleeding (section 2), **then immediately** `git revert` and push (section 1) |
| Bad data written by a workload (wrong Postgres rows, corrupted Forgejo content, flipped Flagsmith flags) | Not a rollback problem -- see [`./backup-restore.md`](./backup-restore.md) |
| A `workloads:build`-driven image change went bad | `git revert` the manifest/source change AND re-run `mise run workloads:build` against the old source (section 3) |
| Whole cluster is a mess and you can't tell what's actually wrong anymore | Stop trying to roll back piecemeal -- see [`./disaster-recovery.md`](./disaster-recovery.md) for a full rebuild from git |

Every path above ends the same way: git on `main` matches what you want
running, and ArgoCD's `selfHeal` is what makes that true on the live cluster.
If you ever find yourself fighting ArgoCD instead of working with it, you're
probably editing the cluster instead of editing git.
