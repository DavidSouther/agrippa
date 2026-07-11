# Runbooks

Practical, copy-pasteable operations procedures for the Agrippa local platform
(`agrippa-dev`, a k3d cluster). These assume the cluster is already up and
bootstrapped (`GETTING_STARTED.md`). For general exploration commands
(hostnames, credentials, `kubectl`/`mise` basics) see `USAGE.md` at the repo
root first; these runbooks link to it rather than repeating it.

Written for a solo operator. "Escalation" here never means "page someone
else." It means "stop guessing and do something more decisive," usually one
of: revert the git commit, roll back in ArgoCD, or rebuild the cluster from
scratch. All three are cheap on this platform because it is GitOps-managed
end to end.

## When something is actually wrong

Start at **[incident-response.md](./incident-response.md)**. It opens with a
60-second global health check and then branches by symptom (a site is down,
an ArgoCD Application is stuck, a pod is crash-looping or pending, TLS looks
wrong, nothing resolves at all). It links out to the other runbooks as each
symptom needs them.

## By task

| Runbook | Use it when... |
| --- | --- |
| [testing-changes.md](./testing-changes.md) | You're about to change a component and want to know the generic GitOps test loop, plus what "verified working" actually means for that specific component (not just "pod is Running"). |
| [deploying-chart-updates.md](./deploying-chart-updates.md) | You're bumping a pinned Helm chart version. Has the current chart inventory (every version, file, and repo URL) and the real surprises this project's own chart upgrades have already hit. |
| [rollback.md](./rollback.md) | A change made things worse and you need to undo it. Explains why `kubectl edit`/`kubectl patch` never works here (ArgoCD's `selfHeal` reverts it), and the two real mechanisms: `git revert` (the correct one) and ArgoCD's own app-history rollback (a stopgap that must be followed by a git revert). |
| [feature-flags.md](./feature-flags.md) | You want to flip a flag in Flagsmith, or understand this project's own (designed-but-not-yet-built) release-flag concept. Documents a real open gap: no confirmed working admin-credential path into Flagsmith exists yet. |
| [interpreting-dashboards.md](./interpreting-dashboards.md) | You're looking at the Grafana "Web Analytics" dashboard, or Loki/Tempo Explore, and want to know what healthy looks like versus an anomaly, and what to do about each. Includes a hard-won warning: an empty panel can mean "healthy and idle" or "the pipeline itself is broken," and looks identical either way. |
| [secret-rotation.md](./secret-rotation.md) | You need to rotate the `age` keypair, or (more commonly) you're tempted to run `rotate-keys` to fix a placeholder value in `.sops.yaml` -- don't; read this first. The rotation script orders its stages correctly and its test suite passes. |
| [backup-restore.md](./backup-restore.md) | You want to know what's actually protected against data loss. Declarative config: yes, RPO 0 via git. Postgres row data: yes, automated (CNPG continuous WAL archiving + daily base backups to a dedicated MinIO, with point-in-time recovery). Not covered: Forgejo git-repo content, Valkey cache, and off-cluster durability of the MinIO backup store itself. |
| [capacity-and-resource-pressure.md](./capacity-and-resource-pressure.md) | A pod won't schedule, or got OOMKilled. This single-node dev cluster runs the entire platform with no headroom to spare; this runbook has the live baseline numbers and the real fix pattern (with two worked examples already in the codebase). |
| [disaster-recovery.md](./disaster-recovery.md) | You want to stop debugging and just rebuild. Short, because this platform's whole design point is that a full rebuild from git is cheap and reliable -- the honest caveat is that it's also a data-loss event for anything not declared in git (see backup-restore.md). |

## Conventions these runbooks share

- Every change to the platform's own configuration goes through git:
  `edit -> render-check locally -> commit -> push a feature branch -> open a
  pull request -> review -> merge into main -> ArgoCD reconciles`. Changes
  land through a reviewed pull request, not a direct commit to `main`.
- `export KUBECONFIG="$(k3d kubeconfig write agrippa-dev)"` and
  `kubectl config use-context k3d-agrippa-dev` are assumed at the top of
  every command block below; they're not repeated in each runbook.
- Conventional Commits (`DEVELOPMENT.md`): types `fix`/`feat`/`chore`, scopes
  `core`/`store`/`otel`/`plat`/`work`.
- No em dashes in these documents (house style, matching `USAGE.md`).

## Known gaps these runbooks surface, not hide

Writing these runbooks against the live cluster (rather than from memory)
surfaced a few real, previously undocumented issues, recorded in the
relevant runbook:

- **Flagsmith has no confirmed working admin login path** (`feature-flags.md`).
- **`pg_dumpall` doesn't work today** (only per-database `pg_dump`, since no
  Postgres superuser credential is exposed); for a whole-cluster capture, use
  the automated physical backup instead. Postgres row data has automated
  CNPG backup and point-in-time recovery to a dedicated MinIO; the remaining
  gap is that MinIO's own store is single-node local-path, not
  off-cluster (`backup-restore.md`).
- **Live memory usage on the dev node exceeds `GETTING_STARTED.md`'s
  documented 4 CPU / 8GB minimum** (`capacity-and-resource-pressure.md`) --
  worth updating that document's stated floor.
- **`USAGE.md`'s example Loki query wouldn't return anything live**, since
  this deployment's logs carry no `namespace`/`pod` labels, only `instance`
  (`interpreting-dashboards.md` has the corrected query).
