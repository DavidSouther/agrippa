# Long-Loop End-of-Run Report: Agrippa Local (k3d, no cloud)

*2026-07-09*

Per `developer/skills/ailly/references/shapes/long-loop.md` §7. This is a
supporting sub-page alongside `design.md`, `plan.md`, and `closing-bell.md`
(`project-cycle.md`'s Long-Lived Documentation convention) — kept, not deleted.

## Where it stopped

At the human merge/Closing-Bell gate, per the long-loop's never-auto-clear
invariants. Every feature-step (0-9) is built, tested, and live on the running
`agrippa-dev` cluster; every automated check passes, including the committed
gestalt (`ENV=dev bats tests/agrippa.bats`, Closing Bell critical task 6). The
Closing Bell itself — a human usability study — has not run. Per
`closing-bell.md` and long-loop.md §6, no reviewer or coordinator runs or passes
it on the operator's behalf; reaching this point is where the long loop
completes and hands back to the human.

**One real deviation from the written design, surfaced for the record, not
papered over:** `design.md` §Release Flag specifies feature-steps accumulating
on a long-lived integration branch, promoted to `main` only once the Closing
Bell passes, with half-built layers shipping dark. In practice, this run built
directly on `main` throughout — every feature-step's Application went live and
Synced/Healthy the moment it landed, none shipped dark, and there was never a
separate integration branch. This was the operator's own explicit, repeated,
real-time direction during the session (first when the `gitops-argocd` blocker
required a decision about the empty `origin` remote, confirmed again at the
Feature 9 cleanup gate), not a default the loop assumed on its own. The design
doc's Release Flag section is not yet reconciled with what actually happened;
worth a deliberate amend-or-accept pass rather than leaving it silently stale.

## What was done, per feature-step

Each ran its own research → design → plan → build → cleanup cycle
(project-cycle.md, "Plan Steps Are Features"), draft gates cleared by
separately dispatched long-loop reviewers, not the human, per this run's
opt-in mode. All ten folders under `features/` are retained as long-lived
records.

| # | Feature-step | Folder | Feature test | Status |
|---|---|---|---|---|
| 0 | Prerequisites (mise + test harness) | `step0-mise-testing-harness/` | `tests/harness.bats` | green |
| 1 | Cluster core (k3d) | `cluster-core-k3d/` | `tests/cluster-core.bats` | green |
| 2 | GitOps (ArgoCD) | `gitops-argocd/` | `tests/gitops.bats` | green |
| 3 | Networking (Istio + cert-manager) | `networking-istio/` | `tests/networking.bats` | green |
| 4 | Storage (Postgres + Valkey) | `storage-postgres-valkey/` | `tests/storage.bats` | green |
| 5 | Auth (Keycloak) | `auth-keycloak/` | `tests/auth.bats` | green |
| 6 | Git hosting (Forgejo) | `git-hosting-forgejo/` | `tests/git-hosting.bats` | green |
| 7 | Feature flags (Flagsmith) | `feature-flags-flagsmith/` | `tests/feature-flags.bats` | green |
| 8 | Observability (LGTM + Alloy) | `observability-lgtm/` | `tests/observability.bats` | green |
| 9 | Workloads (resume + trips) | `workloads-resume-trips/` | `tests/workloads.bats` | green |

Live cluster state at time of writing: all seven ArgoCD Applications
(`root`, `core`, `storage`, `platform`, `observability`, `workloads`, `argocd`
itself) Synced/Healthy. Full regression sweep (`mise run test:push`,
`mise run test:feature`, `mise run test:chart`, every `tests/*.bats` suite
except the pre-existing, unrelated `rotate-keys.bats`) green.

## What was decided, per draft gate

Each feature-step's own `research.md`/`design.md`/`plan.md` carries its dated
`### Resolved by the long-loop reviewer` block(s) in place — the full audit
trail lives there, not duplicated here. Escalations that required the
coordinator (not a reviewer) to resolve, because the fix crossed a
feature-step's own scope boundary:

- **KSOPS plugin-path gap** (`apps/platform/argocd/kustomization.yaml`):
  `gitops-argocd`'s KSOPS install never mounted `ksops` at kustomize's own
  exec-plugin path, only at `/usr/local/bin/`. First exercised — and fixed —
  by `storage-postgres-valkey`'s first-ever `kind: ksops` generator.
- **`Database` CR sync-wave deadlock**, found and fixed identically three
  times (`auth-keycloak`, `git-hosting-forgejo`, `feature-flags-flagsmith`):
  a per-app CNPG `Database` CR scheduled after its consuming Deployment's own
  wave deadlocks ArgoCD, because most app runtimes crash-loop rather than
  gracefully retry against a database that doesn't exist yet. General pattern
  recorded in `TASKS.md` for any future Postgres-backed feature-step.
  Storage's own `smoke` fixture was safe only because it has no consuming
  Deployment of its own.
- **ArgoCD repo-server submodule fetch** (`apps/platform/argocd/
  kustomization.yaml`): the private `trips` submodule `workloads-resume-trips`
  needed would have 401'd ArgoCD's default recursive submodule fetch on
  *every* Application sharing the repoURL, not just `workloads` — no
  per-Application disable exists upstream. Fixed with the repo-server's global
  `reposerver.enable.git.submodule: "false"` toggle, live-verified before the
  `.gitmodules` commit landed.
- **Local `helmCharts:` vs. plain `resources:`** (`workloads-resume-trips`):
  a live `kustomize build --enable-helm` smoke test settled that the
  `charts/<chart>/` convention's repo-root location collides with kustomize's
  load restrictor across the deep `overlays/dev` tree; the live render path
  uses plain kustomize YAML, with `charts/resume/`/`charts/trips/` kept as
  real, helm-unittest-tested packaging artifacts for a deferred registry path.

Two real, cross-cutting bugs found and left for later (recorded in
`TASKS.md`, not blocking anything live):

- **`tests/rotate-keys.bats`** fails on a genuine stage-ordering bug in
  `scripts/rotate-keys.sh` (re-encrypts before updating `.sops.yaml`'s
  recipient, not after) — pre-existing, unrelated to any feature-step's own
  build, does not touch the live `sops-age` trust root.
- **bats non-final `[[ ]]` doesn't gate** under this repo's pinned bats
  1.13.0 — `networking.bats` and `storage.bats` carry latent
  non-gating content assertions (currently green for the right underlying
  reason, live-verified, but a false-GREEN risk on a future regression).

## Deferred decisions

Extracted per feature-step into `.ailly/developer/TASKS.md`, one `##
Feature-step deferred decisions: <name>` section each — the authoritative,
non-duplicated record. Notable cross-project deferrals: `agathon` and
`ailly.dev` (scoped out of this project's build from the design phase
onward), forgejo-runner/Actions CI (deferred — the first privileged
container this project would have needed), Trips' Cloudflare Access →
Terraform and CI → Forgejo Actions ports (prod/post-git-hosting concerns),
and the production substrate itself (Terraform, cloud-init, DigitalOcean,
the GPU pool, public ACME TLS) — all out of this local-k3d project's stated
scope from the start.

## What the operator does next

1. **Run the Closing Bell** (`closing-bell.md`) — the human usability study
   this run cannot complete on its own. All six acceptance-criteria tasks
   have a live, automated proxy passing today (the per-feature bats suites
   plus the gestalt), but the Closing Bell is evidence from a human run, not
   from the automated suite alone.
2. **Reconcile the Release Flag section** — decide whether to amend
   `design.md` to reflect the direct-to-`main` reality, or treat it as a
   deliberate, retroactively-accepted deviation.
3. **When satisfied**, ask for the project's own Cleanup phase
   (`project-cycle.md`, "Cleanup for a Project"): flips `design.md`'s phase
   to `Completed`, stamps the date, and retires anything left conditional on
   the release flag.
