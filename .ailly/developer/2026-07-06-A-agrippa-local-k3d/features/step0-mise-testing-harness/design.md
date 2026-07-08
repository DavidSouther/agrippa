# Feature Design: Step 0, mise + testing harness

*Reviewed 2026-07-07*

> A separately dispatched long-loop reviewer cleared this feature design's draft
> gate on 2026-07-07. It resolved the three **Open Artifact Decisions** surfaced
> under Summary, confirming each to its proposed conservative default, in the
> *Resolved by the long-loop reviewer* block there; no escalation trigger fired.
>
> Feature-step design (feature-loop shape) inside the Project-Shape session
> `2026-07-06-A-agrippa-local-k3d`. This is Feature 0 of that project's plan: the
> cross-cutting prerequisite every later feature-step's build and tests depend on.
> It has its own feature test (recorded below). The project as a whole is measured
> by `closing-bell.md`, not by this test.

## Libraries & Skills (carry forward to plan and build)

Per the project's cleared `research.md` (§ Libraries & Skills) and `design.md`, the
plan and build phases MUST load these skills via the harness's skill-loading
mechanism before working:

- **`developer:initialize`** (its `references/abilities/initialize/mise.md` reference).
  This feature is the mise initialization for the repo: it fixes the root
  `mise.toml` shape (`[tools]`, named `[tasks.*]`, `mise trust`) that later steps
  extend.
- **`research:public`** and **`research:codebase`** for any residual per-tool
  question the build hits, such as a mise backend string or a `conftest verify` /
  `helm-unittest` invocation detail.

**No library-shipped agentic skill exists for mise, kubeconform, conftest,
helm-unittest, chainsaw, or bats.** The project research recorded a deliberate
check. Build to the in-repo contracts instead: `DEVELOPMENT.md` (its **## Testing**
and **## Secrets** sections) fixes the tools, the CI-lane names, the repo layout,
and the SOPS+age wiring the plaintext-`Secret` guard defends.

## Purpose

Stand up the repo's tooling and testing harness so every later feature-step has a
pinned toolchain and a set of `mise run test:*` tasks to build and check against.
Concretely, this feature lands a `mise.toml` that pins the platform toolchain to
reproducible versions, a `setup` task that installs the helm-unittest Helm plugin,
and the `test:*` tasks `DEVELOPMENT.md`'s Testing section names: kubeconform
conformance, a conftest plaintext-`Secret` guard, helm-unittest chart unit tests,
and a k3d feature-probe lane. The tasks are wired so they are green on the mostly
empty repo and light up as later steps add charts, manifests, and policies. This
feature-step also fixes a confirmed bug in the committed `tests/agrippa.bats`
gestalt so the project's automated backstop is logically correct on the local
(`ENV=dev`) path.

Value is delivered as the harness as a whole. A lone `mise.toml` with no working
`test:push` proves nothing. "Done" is an operator running the per-push lane from a
clean checkout and getting green.

## Prior Art

- **`DEVELOPMENT.md`, the authoritative contract.** Its **## Testing** table fixes
  the four styles (kubeconform, helm-unittest, SLOs, probers), the CI lanes
  (`test:push`, `test:feature`, `test:gestalt`), the per-push (< 90s) and feature
  (< 10 min) budgets, and the repo layout (`tests/<feature>.bats`, `tests/policy/`
  conftest Rego, `charts/<chart>/tests/` helm-unittest, `mise.toml` at root). Its
  **## Secrets** mandates "a conftest/CI guard in `test:static` that fails if any
  committed `kind: Secret` carries plaintext `data`/`stringData`."
- **`docs/developer/TASKS.md`.** The *Initialize mise* and *Testing harness*
  cross-cutting items enumerate the task list and name `developer:initialize`.
- **The project's cleared `research.md` and `design.md`.** Long-loop decisions this
  feature-step consumes as settled inputs: **decision 5** (fix `tests/agrippa.bats`
  in place, not a fork), **decision 6** (omit terraform/tflint pins and the
  `test:tf` lane for the local build), **decision 7** (fold the still-live
  testing-harness notes into the design, and do not recreate the missing
  `TASK-NOTES-testing-harness.md`), and the design's **long-loop decision 3** (local
  trips is served publicly, so the gestalt's dev branch asserts plain reachability
  with no Keycloak gating).
- **The committed test suites.** `tests/preflight.bats` already gates the local
  toolchain and a throwaway k3d up/down. It ran green on this machine during design
  (**9 of 9 on 2026-07-07**, including a real k3d create and delete). `tests/agrippa.bats`
  is the committed gestalt to be fixed here.
- **`developer:initialize`'s `mise.md` reference.** The mise-monorepo layout and the
  development hooks mapped onto `mise run` tasks.
- **`.github/workflows/watch.yml`.** The inert synthetic-monitoring placeholder. Its
  future wiring to a real `bats tests/agrippa.bats` run is out of scope here.

## User Journey and Metrics

**The operator's flow, from a clean checkout on macOS with Docker Desktop:**

1. `mise install` reads `mise.toml` and installs the pinned toolchain (kubeconform,
   helm, kubectl, k3d, chainsaw, conftest, bats, plus the sops/age/kustomize
   supporting tools later steps use).
2. `mise run setup` installs the helm-unittest Helm plugin (idempotent) and trusts
   the repo config, one time.
3. `mise run test:push`, the **per-push** lane, runs green. It runs kubeconform plus
   the plaintext-`Secret` conftest guard (`test:static`), the conftest Rego
   self-tests (`test:policy`), and helm-unittest (`test:chart`). Each leg is
   empty-safe, so the lane is green whether the repo has no manifests yet or (as
   later steps land) real ones to check with no task changes.
4. `mise run test:feature`, the **per-PR** lane, stands up a throwaway k3d cluster,
   applies the component under test, runs chainsaw resource-reconcile assertions and
   bats probes, then tears the cluster down. It is empty-safe until a component
   supplies manifests and probes.
5. When a later step commits a plaintext `kind: Secret`, `mise run test:static` (and
   therefore `test:push`) **fails**. The guard is the harness earning its keep.

**Metrics / measures of done for this feature-step:**

- The feature test (`tests/harness.bats`) is green: `mise run test:push` exits 0.
  Verified on the current tree: `test:push` exits 0 (test:static 6/6 over the
  `apps/` Application manifests, test:policy 5/5, test:chart green-on-empty).
- Per-push budget honored: `test:push` completes in **under 90s** (`DEVELOPMENT.md`);
  observed well under a second on the current tree.
- The plaintext-`Secret` guard, exercised by `test:policy`'s conftest `_test.rego`
  cases, **denies** a plaintext `Secret` and **allows** a SOPS-encrypted one, so the
  green push lane is real proof rather than green-on-empty. Verified: 5 self-tests,
  5 passed.
- `tests/agrippa.bats` parses and its `ENV=dev` branch is reachable (the bug fix
  below). Verified: `bats --count tests/agrippa.bats` = 3, and no `GESTALT_ENV`
  reference remains. Its *true* green — real sites reachable — is deferred to
  Feature 9.
- `tests/preflight.bats` is green on the operator's machine. Verified 9/9 on
  2026-07-07, including a real k3d create and delete.

**Failure modes to design against.** A `test:*` task that errors (non-zero) on the
empty repo instead of being green-on-empty blocks every later step from starting
green. An untrusted `mise.toml` makes `mise run` prompt interactively in CI and
tests. A pinned tool with no mise short-name (chainsaw) fails to resolve. The
existing `tests/agrippa.bats` bugs (a dead `GESTALT_ENV` branch and an unpassable
`cloudflareaccess.com` assertion) silently keep the local gestalt path broken.

## Specification

### `mise.toml`, pinned tools

`[tools]` pins the platform toolchain to reproducible versions, cross-checked
against the installed globals (helm 4.x, k3d 5.9, kubectl 1.36, bats 1.13):

- `kubeconform`, `helm`, `kubectl`, `k3d`, `conftest`, `bats` all resolve by mise
  short-name (verified against `mise registry`).
- `chainsaw` has **no mise short-name**. Pin it backend-qualified as
  `"aqua:kyverno/chainsaw"` (verified resolvable; `ubi:kyverno/chainsaw` is an
  equivalent fallback).
- Supporting tools later feature-steps need land here too so the pin set is one
  reproducible manifest: `sops` and `age` (the SOPS+age secrets trust root),
  `kustomize` (KSOPS/kustomize build), and `jq`/`yq` (task glue, `.sops.yaml`
  editing). A `bitwarden` (`bw`) pin saves the operator installing the CLI by hand;
  the age **key** still lives only in Bitwarden per `DEVELOPMENT.md`'s custody
  policy — the pin is only about which tool installs the client.
- **Omitted, per research decision 6:** `terraform` and `tflint`. They pin nothing
  the local build exercises (there is no `terraform/` to operate on) and land with
  the deferred cloud cycle. Surfaced as an Open Artifact Decision, since the step
  prompt named them.

`helm-unittest` is a **Helm plugin**, not a registry tool, so the `setup` task
installs it rather than `[tools]` pinning it.

An `[env]` block sources a gitignored `.env` (if present) so an operator's
already-scoped `bw unlock` session token (`BW_SESSION`) reaches every `mise run`
task without each bootstrap/keygen task re-implementing its own sourcing. A missing
`.env` is not an error.

### `mise.toml`, tasks

Every `test:*` leg is **empty-safe**. It exits 0 when there is nothing of its kind
to check, so the whole harness is green and lights up as content arrives. Each
task's required behavior:

- **`setup`** runs `helm plugin install` for the helm-unittest plugin if absent
  (idempotent, skipped when already installed) and `mise trust` for the repo config.
  This is the one task with a side effect and network access. Run it once per
  checkout. (helm-unittest ships no `.prov` signature, so the install passes
  `--verify=false` under helm 4's default plugin signature verification.)
- **`test:static`** runs kubeconform to schema-validate every committed Kubernetes
  manifest (under the GitOps tree — `apps/` and rendered `charts/` output), and runs
  conftest with the **plaintext-`Secret` guard** against those manifests. macOS ships
  bash 3.2 with no `globstar`, so the glob walks with `find`, not `**`;
  `kustomization.yaml` is kustomize config (no `kind`) and is excluded from both
  globs. kubeconform runs `-ignore-missing-schemas` so a CRD it has no schema for
  (e.g. ArgoCD's `argoproj.io` Application) is Skipped, not an Error, while built-in
  kinds are still validated. An empty manifest set exits 0. This is the `test:static`
  `DEVELOPMENT.md`'s Secrets section requires the guard to live in.
- **`test:policy`** runs `conftest verify --policy tests/policy tests/policy` over
  the Rego policy **self-tests** (`_test.rego`) under `tests/policy/`. This is where
  the guard's correctness is proven with fixtures, so a broken guard turns the
  per-push lane red.
- **`test:chart`** runs helm-unittest over `charts/<chart>/tests/` suites. A missing
  `charts/` directory, or charts with no `tests/` suite, exits 0.
- **`test:feature`** is the per-PR lane: create a throwaway k3d cluster, apply the
  component under test, run chainsaw resource-reconcile assertions plus the
  component's bats probes, then delete the cluster (teardown runs unconditionally via
  an `EXIT` trap). It is structured so a component step plugs its manifests and probes
  in with no task edit — `apps/` is the apply target, every `tests/<feature>/`
  directory other than `tests/policy/` is a chainsaw suite, and every
  `tests/<feature>.bats` other than the cross-cutting suites (agrippa, harness,
  preflight, cluster-core) is a component probe. It is not part of `test:push`.
- **`test:gestalt`** is a thin wrapper running `bats tests/agrippa.bats`, honoring
  `ENV` and the `PUBLIC_HOST`/`TRIPS_HOST`/`DASHBOARD_HOST` overrides. This is the
  local invocation of `DEVELOPMENT.md`'s post-sync lane and the exact command
  Closing-Bell task 6 runs (`ENV=dev bats tests/agrippa.bats`). It wires to no
  staging or live target. Surfaced as an Open Artifact Decision.
- **`test:push`** is the per-push umbrella: `test:static`, `test:policy`, and
  `test:chart` (via `depends`). It **omits `test:tf`** (decision 6).
  `DEVELOPMENT.md`'s table lists `test:static` + `test:chart` + `test:tf` under this
  lane; this design substitutes the fast, cluster-free `test:policy` self-tests for
  the omitted `test:tf`, keeping the per-push lane meaningful and inside its 90s
  budget. This is what the feature test drives.

Additional operational tasks land here because they share the same pinned toolchain
and are named by later feature-steps' contracts: **`cluster:up`** / **`cluster:down`**
(create/delete the long-lived `agrippa-dev` k3d cluster) and **`bootstrap`** /
**`keygen`** (the GitOps/secrets trust-root tasks, `research.md` decisions 4 and 8).
They are wired here as the shared task surface; their component logic is exercised by
the Cluster core and GitOps feature-steps, not by this step's feature test.

### Conftest plaintext-`Secret` guard (`tests/policy/`)

A Rego policy (`package secrets`) that **denies** any manifest with `kind: Secret`
carrying a non-empty `data` or `stringData` (plaintext), while **allowing** a
SOPS-encrypted secret manifest (whose sensitive fields are ciphertext under a `sops:`
block), a metadata-only `Secret`, and a `Secret` with present-but-empty `data: {}` /
`stringData: {}`. It never evaluates non-`Secret` kinds (a `ConfigMap` with a `data`
field is untouched). It ships with `_test.rego` fixtures proving all five directions,
so `test:policy` fails if the guard regresses. Package and file names
(`tests/policy/secrets.rego`, `tests/policy/secrets_test.rego`) are a minor artifact
choice surfaced below.

### helm-unittest scaffolding

The `setup` task installs the plugin. The `charts/<chart>/tests/` convention
(`DEVELOPMENT.md` repo layout) is where suites live. No chart exists yet, so this
feature-step ships the wiring (the `test:chart` task plus the plugin install), not a
chart suite. `test:chart` is green-on-empty until a later step adds a chart.

### k3d feature-probe wiring

`test:feature` encodes the k3d-up, apply, chainsaw + bats, k3d-down loop as a task
shell, so each component step supplies only its manifests and probes. The loop is
feasible on this machine: `tests/preflight.bats` stood up and tore down a real
throwaway k3d cluster during this design (9 of 9 green on 2026-07-07).

### `tests/agrippa.bats` bug fix (three edits, in place)

Fixing the committed gestalt per research decision 5 and design long-loop decision 3.
The edits do **not** make the suite pass now, because no cluster or sites exist until
Feature 9. They make it *logically correct* on the `ENV=dev` path:

- **(a) Retire the dead `GESTALT_ENV` branch.** The observability test branched on
  `GESTALT_ENV`, which nothing sets, while `setup()` sets `ENV`. Collapse the switch
  onto the single `ENV` variable so the dev path is reachable.
- **(b) Give the trips test a dev branch.** The trips test unconditionally asserted a
  `302` to `cloudflareaccess.com`, which requires the Cloudflare edge that does not
  exist on k3d. Keep that assertion on the `prod` branch, and add a `dev` branch
  asserting **plain local reachability** (a 2xx or redirect from the local ingress at
  `${TRIPS_HOST}`), matching design long-loop decision 3 (local trips is served
  publicly, with no Keycloak gating).
- **(c) Tolerate the local CA on the dev path with `curl -k`.** On `ENV=dev` the dev
  hostnames (the `nip.io` host overrides) present real certs from the local CA that is
  deliberately not in the host trust store (research decision 3). The plain `curl`
  HTTPS probes (public-site healthz, observability, trips dev) would fail TLS
  verification without `-k`. Add `-k` on the dev path only, leaving the prod path
  unchanged.

Verified on the current tree: the suite parses (`bats --count` = 3), carries no
`GESTALT_ENV` reference, and each dev branch uses `-k`; the prod branches are
unchanged.

### Challenges

- **Empty-safety.** Each glob-driven task must treat "no matches" as success, not a
  shell error, so the harness is green from day one.
- **Non-interactive `mise run`.** The feature test and CI must not stall on an
  untrusted-config prompt, so `setup` and the test's own `setup()` run `mise trust`.
- **`chainsaw` backend.** It has no short-name, so pin `aqua:kyverno/chainsaw`.
- **macOS bash 3.2.** No `globstar`; task shells walk manifests with `find`.

## Alternatives

- **A separate local bats suite instead of fixing `tests/agrippa.bats`.** Rejected
  (research decision 5). `DEVELOPMENT.md` prescribes one suite per feature, the file's
  own header says its targets are overridable "so the same test can run against a
  local K3d ingress," and a parallel suite would duplicate probes and drift.
- **Make, just, or npm scripts instead of mise.** Rejected. `DEVELOPMENT.md` and
  `TASKS.md` fix mise as the task runner and version pinner (`mise.toml` at repo root),
  and mise version-pins the toolchain for prod/dev parity, which a bare Makefile does
  not.
- **Relying on brew-installed global tools instead of mise pins.** Rejected.
  `GETTING_STARTED.md` brew-installs them for the preflight bootstrap, but
  `DEVELOPMENT.md` states they are "pinned via mise once initialized." Pinning is what
  makes a checkout reproducible across machines and matches production.
- **Including `terraform`, `tflint`, and `test:tf` now, as the step prompt names.**
  Rejected as the default per research decision 6, since nothing local exists for them
  to operate on and a `test:tf` lane would be a hollow always-green noop. Surfaced as
  an Open Artifact Decision so the human can override.

## Summary

This feature-step lands `mise.toml` (pinned toolchain plus supporting sops/age/
kustomize/jq/yq/bw tools), a `setup` task (helm-unittest plugin plus `mise trust`),
and the `test:static`, `test:policy`, `test:chart`, `test:feature`, and
`test:gestalt` tasks plus the `test:push` umbrella, alongside the operational
`cluster:up`/`cluster:down`/`bootstrap`/`keygen` task surface later steps drive. Each
`test:*` task is empty-safe, so the harness is green and lights up as later steps add
content. It also lands the conftest plaintext-`Secret` guard with self-tests, the
helm-unittest and k3d-probe wiring, and the three-edit fix to `tests/agrippa.bats`.
The one feature test asserts the operator's per-push experience end-to-end.

### Deferred decisions (park to `TASKS.md` at cleanup)

- **`terraform`/`tflint` pins and the `test:tf` lane.** Deferred to the cloud cycle
  (research decision 6). A one-line addition when cloud work starts.
- **`test:gestalt` CI wiring to a staging or live target.** The local task runs the
  bats suite against whatever `ENV` and host overrides point to. The post-sync CI lane
  and `.github/workflows/watch.yml`'s real assertions land with staging.
- **chainsaw assertion breadth and snapshot-test breadth.** The `test:feature` loop is
  wired here. The actual chainsaw `.yaml` assertions and helm-unittest snapshot suites
  are authored per-component in each later feature-step.
- **Repoint or drop the two dangling `TASKS.md` citations**
  (`TASK-NOTES-testing-harness.md`, `prober-synthetic-monitoring.md`). They name files
  that do not exist (research decision 7). This is a docs cleanup, not code.

### Resolved by the long-loop reviewer (2026-07-07)

The three Open Artifact Decisions below (concrete artifact choices this feature
invents that no skill template, project convention, or the cleared
`research.md`/`design.md` prescribes verbatim) were each researched against the repo,
the in-repo contracts (`DEVELOPMENT.md`), the cleared project `research.md` and
`design.md`, the `closing-bell.md` definition of done, conftest's own convention, and
the already-landed working tree, then decided to the conservative default. No
escalation trigger (irreversible, out of recorded scope, or underdetermined) fired,
so this feature design's draft gate is cleared. Each proposed default was confirmed.

**1. `terraform`/`tflint` `[tools]` pins and a `test:tf` lane. Decided: omit both for
the local build.** The step prompt names them, but research `decision 6`, the project
`design.md` Step 0, `research.md` § Scope (which lists cloud/Terraform provisioning
and the `test:tf` CI lane out of scope, "no `terraform/` to validate yet"), and this
session's own local-only mandate all agree. Pinning tools with nothing to operate on,
plus an always-green noop lane, would add hollow surface; omitting is the in-scope
conservative default, and re-adding both is a one-line change the day cloud work
starts (reversible). Including them instead would trip escalation trigger (b), out of
recorded scope. Confirmed against the working tree: `mise.toml` carries no
terraform/tflint pin and `test:push` omits `test:tf`.

**2. `test:gestalt` task. Decided: provide the thin local wrapper
(`run = "bats tests/agrippa.bats"`, honoring `ENV` and the `*_HOST` overrides, wired
to no deployed target).** `DEVELOPMENT.md`'s Testing table names `test:gestalt`, and
`closing-bell.md` task 6 runs exactly `ENV=dev bats tests/agrippa.bats` as a Critical
definition-of-done step, so the wrapper is the runner the project's own exit criterion
depends on. It builds none of the deployed-target post-sync CI wiring that `research.md`
§ Scope defers, so it stays inside recorded scope. Omitting it and making operators
call raw `bats` would only drop a named, in-scope convenience. Confirmed against the
working tree: `[tasks."test:gestalt"]` is the thin wrapper.

**3. Conftest policy file and package names. Decided: `tests/policy/secrets.rego` and
`tests/policy/secrets_test.rego` under `package secrets`.** `DEVELOPMENT.md`
prescribes `tests/policy/`; only the file and package spelling were open. This follows
conftest's own `<name>.rego` / `<name>_test.rego` convention (self-tests discovered by
`conftest verify`), named after the guard's subject. Reversible and low-stakes.
Confirmed against the working tree: both files exist with these names under `package
secrets`, and `test:policy` runs `conftest verify --policy tests/policy tests/policy`
over them.

## Feature Test

**Path:** `tests/harness.bats` (following `DEVELOPMENT.md`'s `tests/<feature>.bats`
convention, where the feature is the testing "harness").

**User story (Given / When / Then):** *Given* a clean checkout with `mise`
installed, *When* an operator runs `mise run test:push`, *Then* the per-push lane runs
green (kubeconform plus the plaintext-`Secret` guard, the conftest Rego self-tests,
and helm-unittest all pass), proving the harness is installed and working. Because
`test:push` includes `test:policy`, a green run transitively proves the guard denies a
plaintext `Secret` and allows an encrypted one, so this is not merely green-on-empty.

**Current state.** The test is **RED on a checkout without the harness** — with no
`mise.toml`, `mise run test:push` exits 1 (`no tasks defined`). That red state is what
defines "done" for this feature-step. On the current working tree, where this
feature-step's harness has already landed, the test is verified **GREEN**
(`mise run test:push` exits 0), confirming the acceptance criterion is met.
