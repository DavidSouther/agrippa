# Closing Bell: Agrippa Local (k3d)

*Draft 2026-07-06*

> Project Shape exit criterion. Written once, at the start of the project, before
> the feature-steps are designed. Run once, near completion, as a summative
> usability study. It is not code and does not gate every build; the automated
> gestalt (`tests/agrippa.bats`) is the regression backstop that accompanies it,
> not a substitute for it. This document fixes the definition of "done" for the
> whole project up front.

## What the Finished Project Should Let a User Do

A developer who has never been walked through Agrippa should be able to take a
clean checkout of this repository on a macOS laptop, follow the repository's own
documentation, and stand up a working local copy of the Agrippa platform on k3d:
GitOps-managed, ingress-fronted, observable, with David's real personal site and
trips site actually running inside the cluster and reachable in a browser. The
platform they get locally is the same one production runs, differing only in the
declared dev overlay (local-path storage, metallb, reduced replicas, a local CA
instead of the Cloudflare edge).

## Participant Profile

- **Who.** A software developer competent with the surrounding system: comfortable
  with a shell, `git`, `kubectl`, Helm, Docker Desktop on macOS, and the general
  idea of GitOps and Kubernetes ingress. This is the profile the repository's
  `GETTING_STARTED.md` and `DEVELOPMENT.md` already assume.
- **Assumed prior knowledge.** General Kubernetes and Helm literacy; how to read a
  `mise` task list; how to run a `bats` suite; that Docker Desktop must be running
  and sized (>= 4 CPU / 8 GB, per `tests/preflight.bats`).
- **Must NOT have.** No prior walkthrough of Agrippa's bootstrap sequence, no
  memorized command list, no author over the shoulder, no access to a private
  runbook beyond what is committed in the repository. The committed docs are part
  of the deliverable and are fair game; a human explaining the steps is not.

## Setup and Materials

- **Starting state.** A macOS machine (Apple Silicon or Intel) with Docker Desktop
  running and sized to the preflight bar, `mise` installed, and a fresh clone of
  the `agrippa` repository at the completed project commit. No cluster exists yet.
- **Provided.** The repository and everything committed in it: `GETTING_STARTED.md`,
  `DEVELOPMENT.md`, `docs/developer/TASKS.md`, `README.md`, `ROUTING.md`, the
  `mise.toml` tasks, the `charts/`, the `apps/` (ArgoCD app-of-apps), and the
  `tests/` suites. Read access to the Bitwarden item `agrippa-age-dev` for the dev
  `age` key.
- **Deliberately withheld.** No outside walkthrough, no author present, no
  screen-share guidance, no commands dictated. The participant works from the
  committed documentation alone.

## Task Scenarios

Stated as outcomes the operator wants, not as the controls to operate.

1. **Bring the platform up from nothing.** Starting from the clean checkout, get a
   local Agrippa platform running end to end.
2. **Visit the personal site and its blog.** Open the running personal site and its
   blog in a browser and see real content render.
3. **Visit the trips site.** Open the running trips site in a browser and see a real
   trip itinerary render.
4. **Check platform health.** Open the observability dashboard, sign in with the
   local dev credentials, and see a dashboard that shows the platform is healthy.
5. **Confirm the platform manages itself.** Satisfy yourself that the platform is
   GitOps-managed: that a git-declared change is what drives the cluster, not
   hand-applied `kubectl`.
6. **Confirm it is done, objectively.** Run the repository's own end-to-end check
   against your local cluster and see it pass.

## Acceptance Criteria

Predefined before the study runs. Each names correct completion plus pass
thresholds (completion, time ceiling, error ceiling, ease floor on a 1-7
single-question ease scale).

| # | Correct completion | Time ceiling | Error ceiling | Ease floor | Tier |
|---|---|---|---|---|---|
| 1 | `mise` bootstrap brings up a k3d cluster with ArgoCD reporting the app-of-apps Synced/Healthy for every in-scope layer. | 30 min (excl. first-run image pulls) | <= 2 recoverable missteps; 0 undocumented dead ends | >= 5 | Critical |
| 2 | The personal-site dev host serves `200` at `/` and `/blog` and renders David's real resume/blog content. | 3 min | 0 | >= 5 | Critical |
| 3 | The trips dev host renders the trip index and at least one real trip detail page. | 3 min | 0 | >= 5 | Critical |
| 4 | Grafana at the dashboard dev host authenticates with the documented local dev credentials and renders a dashboard. | 5 min | <= 1 | >= 5 | Critical |
| 5 | Participant can point to the ArgoCD UI (or CLI) showing every app Synced from git, and articulate that git is the source of truth. | 5 min | <= 1 | >= 4 | Secondary |
| 6 | `ENV=dev bats tests/agrippa.bats` (with the documented local host overrides) passes green against the local cluster. | 5 min | 0 | >= 5 | Critical |

- **Critical tasks (1, 2, 3, 4, 6) must all pass for the project to land.** They are
  the platform's user-visible contract: it comes up, David's real sites are served
  through the Istio Gateway, health is observable, and the automated gestalt agrees.
- **Secondary task (5) informs the result without blocking it.** It probes the
  parity/GitOps intent, which is architecturally central but not something a first
  run must demonstrate flawlessly to call the platform usable.

## Running the Study

Run against a build with the project release flag enabled for the participant (see
the design doc's release-flag note). One participant, one sitting. The evaluator
records completion, time on task, error count, and the post-task ease rating per
scenario, and judges the run against the table above. The agent drafts and scripts
the study and records the outcome; the agent does not pass it on the operator's
behalf. A passing Closing Bell is evidence from this human run, not from the
automated suite alone.
