# Implementation Plan: Step 0, mise + testing harness

*Reviewed 2026-07-07*

> A separately dispatched long-loop reviewer cleared this feature plan's draft
> gate on 2026-07-07. This plan carries no net-new "Open Artifact Decision"
> section of its own (that gate already ran and cleared at the feature design,
> per its Summary's *Resolved by the long-loop reviewer (2026-07-07)* block), so
> the review's job was to verify the plan's steps against the cleared
> `design.md` and against the actually-committed, actually-running repo state
> (`mise.toml`, `scripts/*.sh`, `tests/policy/*.rego`, `tests/agrippa.bats`,
> `tests/harness.bats`) by executing the real toolchain (`mise run test:push`,
> `mise run setup` run twice, `bats tests/harness.bats`, `bats --count
> tests/agrippa.bats`, `grep -c GESTALT_ENV`, `mise run test:feature`, `k3d
> cluster list`). Everything in this plan's own recorded scope checked out with
> no change needed. One cross-feature observation surfaced live (Step 4's
> `test:feature` fails once the separately-scoped `gitops-argocd` feature's
> `apps/`/`tests/gitops.bats` content is present, because that content needs a
> human-gated `mise run bootstrap` — an unlocked Bitwarden session — this
> environment cannot perform) and is recorded below as out of this artifact's
> own scope, not a step0 defect. No escalation trigger fired against step0's own
> scope; the full record is in the *Resolved by the long-loop reviewer* block at
> the end of this document.

**Feature test:** `tests/harness.bats`
**User story:** Given a clean checkout with `mise` installed, when an operator runs `mise run test:push`, then the per-push lane (kubeconform + the plaintext-`Secret` conftest guard, the conftest Rego self-tests, and helm-unittest) runs green end-to-end.

**Libraries & Skills (carried forward from `design.md`; load before each build step):**

- `developer:initialize`, specifically its `references/abilities/initialize/mise.md` reference — read directly during this plan (no standalone `developer:initialize` skill is independently invocable outside the `developer:ailly` coordinator). Its root-`mise.toml` shape (`[tools]`, named `[tasks.*]`, `mise trust`) is the template this plan adapts; the concrete tool set and task bodies are fixed by `DEVELOPMENT.md` and `design.md`, not the reference's own generic node/python/rust template task names (`format`/`check`/`test`/`lint`).
- `research:public` and `research:codebase` for any residual per-tool question the build hits (a mise backend string, a `conftest verify` or `helm-unittest` invocation flag). Verified during this plan: `kubeconform`, `helm`, `kubectl`, `k3d`, `conftest`, `bats` all resolve by mise short-name (`mise registry`); `chainsaw` does not and needs the `aqua:kyverno/chainsaw` backend-qualified pin; the `helm-unittest` Helm plugin's actively-maintained install source is `https://github.com/helm-unittest/helm-unittest` (the older `quintush/helm-unittest` fork is archived).
- No library-shipped agentic skill exists for mise, kubeconform, conftest, helm-unittest, chainsaw, or bats. Build to `DEVELOPMENT.md`'s Testing and Secrets sections directly.

**Patterns beat (`patterns:using-patterns` consulted):** no object-modeling pattern applies — this feature-step has no typed application code, only infrastructure config (TOML tasks, Rego policy, bash/bats). `newtype`, `domain-objects`, `type-states`, `parse-dont-validate`, `aggregate`, and the persistence patterns all require a typed domain model that does not exist here, so none are invoked. Two patterns do shape *how the tests in each step are written*, not the surface itself: **`arrange-act-assert`** for each new bats/conftest case (setup fixtures, one `run`, focused assertions — the convention the existing `tests/*.bats` files already follow) and **`errors-typed-untyped`**, resolved deliberately to the untyped side: a task's process exit code is the correct, sufficient failure signal for CLI tooling consumed by `mise run`, bats, and CI — there is no in-process caller needing to match distinct typed failure modes, so no error hierarchy is introduced.

**Steps:**
- [x] Step 0: API surface area
- [x] Step 1: Tool pins, `setup`, and the kubeconform leg of `test:static`
- [x] Step 2: The plaintext-`Secret` guard and `test:policy`
- [x] Step 3: `test:chart` and the `test:push` umbrella (feature test goes green)
- [x] Step 4: `test:feature`, `test:gestalt`, and the `tests/agrippa.bats` bug fix

## Step 0: API surface area

Establish the file layout and the task/dependency graph before any task has real logic, mirroring `developer:initialize`'s mise-monorepo shape adapted to this repo's actual toolchain. Every task body is an honest "not implemented" stub (not a silent no-op), so `mise run test:push` stays RED for a legible reason instead of turning green on empty stubs before the harness does anything real.

```toml
# mise.toml (repo root) -- Step 0 skeleton, stub bodies only

[tools]
kubeconform = "latest"   # exact SemVer pinned in Step 1
helm        = "latest"
kubectl     = "latest"
k3d         = "latest"
conftest    = "latest"
bats        = "latest"
chainsaw    = "aqua:kyverno/chainsaw"  # no mise short-name; backend-qualified

[tasks.setup]
description = "Install the helm-unittest plugin and trust this repo's mise config"
run = "echo 'not implemented: setup' >&2; exit 1"

[tasks."test:static"]
description = "kubeconform schema-validation + plaintext-Secret conftest guard over committed manifests"
run = "echo 'not implemented: test:static' >&2; exit 1"

[tasks."test:policy"]
description = "conftest verify over tests/policy/*_test.rego self-tests"
run = "echo 'not implemented: test:policy' >&2; exit 1"

[tasks."test:chart"]
description = "helm-unittest over charts/*/tests"
run = "echo 'not implemented: test:chart' >&2; exit 1"

[tasks."test:feature"]
description = "k3d up, apply component, chainsaw + bats probes, k3d down"
run = "echo 'not implemented: test:feature' >&2; exit 1"

[tasks."test:gestalt"]
description = "bats tests/agrippa.bats honoring ENV and *_HOST overrides"
run = "echo 'not implemented: test:gestalt' >&2; exit 1"

[tasks."test:push"]
description = "Per-push lane: test:static, test:policy, test:chart"
depends = ["test:static", "test:policy", "test:chart"]
run = "true"
```

```text
tests/policy/
  secrets.rego         # Step 0: `package secrets` only, no rules yet
  secrets_test.rego    # Step 0: `package secrets` only, no test_ rules yet
```

This fixes the names and shape every later step fills in: the six task IDs, the `test:push` dependency edge, and the two policy file names/package (`package secrets`, per the design's already-resolved artifact decision). Nothing here is tested directly by `tests/harness.bats` yet — it still fails, now for the legible reason that `test:static`/`test:policy`/`test:chart` each exit 1 rather than "no tasks defined."

## Step 1: Tool pins, `setup`, and the kubeconform leg of `test:static`

**Enables:** moves `tests/harness.bats`'s one assertion from "no tasks defined" toward its dependency chain resolving; `test:push` still fails (via the `test:policy` and `test:chart` stubs), but `test:static` now does real work.

Pin `[tools]` to concrete SemVers, cross-checked against the installed globals `design.md` records (helm 4.x, k3d 5.9, kubectl 1.36, bats 1.13). Implement `setup`: idempotent `helm plugin install https://github.com/helm-unittest/helm-unittest` (skip if already listed in `helm plugin list`; pass `--verify=false` since the plugin ships no `.prov` signature for helm 4's default plugin-signature verification to check), then `mise trust`. Implement `test:static`'s kubeconform leg: glob every committed manifest under `apps/` and rendered `charts/` output with `find` (macOS ships bash 3.2, no `globstar`), excluding `kustomization.yaml` (kustomize config, not a `kind`), run `kubeconform -strict -ignore-missing-schemas -summary` over the set, and treat an empty glob as success (exit 0), not a shell error. The conftest half of `test:static` is not wired yet — that is Step 2's guard.

**Tests**

```bash
test "setup is idempotent":
  run mise run setup
  assert status == 0
  run mise run setup   # second run, plugin already present
  assert status == 0
  run helm plugin list
  assert output contains "unittest"

test "test:static kubeconform leg is green on an empty manifest set":
  run mise run test:static
  assert status == 0
```

- Edge case: `mise trust` must not prompt interactively in a non-TTY CI shell.
- Edge case: a manifest kubeconform has no schema for (e.g. an `argoproj.io` `Application`) must be `Skipped` under `-ignore-missing-schemas`, not treated as an `Error`.
- Edge case: `helm plugin install` must not error when the plugin is already installed (idempotent re-run on a warm checkout).

**Implementation Outline**

```text
task setup:
  if helm plugin list does not contain "unittest":
    helm plugin install --verify=false https://github.com/helm-unittest/helm-unittest
  mise trust

task test:static:
  manifests <- find(apps/**/*.yaml, charts/**/rendered/*.yaml) excluding kustomization.yaml
  if manifests is empty: exit 0
  kubeconform -strict -ignore-missing-schemas -summary manifests
```

## Step 2: The plaintext-`Secret` guard and `test:policy`

**Enables:** the `test:policy` leg of `test:push` goes green; `test:push` overall still fails only on `test:chart`. This is the step that gives the harness a real proof (not green-on-empty): the guard denies a plaintext `Secret` and allows a SOPS-encrypted one, exercised by its own fixtures.

Write `tests/policy/secrets.rego` (`package secrets`): a `deny` rule that fires when `input.kind == "Secret"` and either `input.data` or `input.stringData` is a non-empty object, and does not fire when the object instead carries a `sops:` block (ciphertext), has no `data`/`stringData` at all, or has them present-but-empty. Write `tests/policy/secrets_test.rego` with `test_`-prefixed rules over inline fixtures covering all five directions: deny plaintext, allow SOPS-encrypted, allow metadata-only, allow empty `data`/`stringData`, and leave a non-`Secret` kind (e.g. `ConfigMap`) with a `data` field untouched. Wire `test:policy` to `conftest verify --policy tests/policy tests/policy`. Wire `test:static`'s conftest leg to run `conftest test --policy tests/policy --all-namespaces` over the same manifest glob as Step 1's kubeconform leg (empty glob still exits 0).

**Tests**

```bash
test "policy self-tests prove both directions":
  run conftest verify --policy tests/policy tests/policy
  assert status == 0
  # asserts internally: test_deny_plaintext_secret passes,
  # test_allow_sops_encrypted_secret passes

test "test:policy leg is green":
  run mise run test:policy
  assert status == 0
```

- Edge case: a `Secret` with no `data`/`stringData` keys at all (metadata-only) must be allowed, not denied.
- Edge case: a `Secret` with `data: {}` and/or `stringData: {}` (present but empty) must be allowed.
- Edge case: a non-`Secret` kind carrying a `data` field (e.g. a `ConfigMap`) must never be evaluated by this rule.
- Edge case: deliberately breaking a self-test assertion (e.g. flipping `count(msgs) > 0` to `== 0`) must make `conftest verify` — and therefore `test:policy` — fail, proving the task is not a hollow always-green check.

**Implementation Outline**

```rego
package secrets

deny contains msg if {
  input.kind == "Secret"
  is_plaintext(input)
  msg := sprintf("Secret %s carries plaintext data", [input.metadata.name])
}

is_plaintext(secret) if {
  not secret.sops
  count(object.union(
    object.get(secret, "data", {}),
    object.get(secret, "stringData", {})
  )) > 0
}
```

## Step 3: `test:chart` and the `test:push` umbrella (feature test goes green)

**Enables:** the remaining leg of `tests/harness.bats`'s one assertion. After this step, `mise run test:push` exits 0 on the empty repo and the feature test is GREEN.

Wire `test:chart` to run the helm-unittest plugin (installed by Step 1's `setup`) over every `charts/<chart>/tests/` suite; a missing `charts/` directory, or a chart with no `tests/` subdirectory, exits 0. The `test:push` umbrella's `depends` edge is already correct from Step 0, so once `test:chart` has a real body, the umbrella runs its three real legs in order and surfaces the first failure — no further edit needed there.

**Tests**

```bash
test "test:chart is green on a chart-less repo":
  run mise run test:chart
  assert status == 0

test "the feature test: per-push lane is green end-to-end":
  run mise run test:push
  assert status == 0
```

- Edge case: `test:chart` must not error when `charts/` does not exist at all (today's repo state) versus exists-but-empty (once a later step adds the directory before its first chart).
- Edge case: `test:push`'s three legs must run in the order that gives the fastest, cheapest failure first (`test:static` before `test:chart`), and the whole umbrella must still finish inside the 90s per-push budget (`DEVELOPMENT.md`).

**Implementation Outline**

```text
task test:chart:
  if not exists(charts/): exit 0
  for chart in charts/*/:
    if exists(chart/tests/):
      helm unittest chart

task test:push:
  depends: [test:static, test:policy, test:chart]
```

## Step 4: `test:feature`, `test:gestalt`, and the `tests/agrippa.bats` bug fix

**Enables:** no further `tests/harness.bats` assertion — that suite has exactly one assertion and it is already green after Step 3. This step completes the rest of `design.md`'s Specification and Metrics scope for this feature-step: the per-PR k3d-probe lane, the local gestalt wrapper, and the confirmed `tests/agrippa.bats` bug fix. Each is verified by its own direct check below rather than by `tests/harness.bats`, and none may regress `test:push`'s green state.

Implement `test:feature` as the k3d-up / apply / chainsaw+bats-probe / k3d-down task shell, teardown wired through an `EXIT` trap so it runs unconditionally, structured so a later component step supplies only its manifests and probe suite (no task edit): `apps/` is the apply target, every `tests/<feature>/` directory other than `tests/policy/` is a chainsaw suite, and every `tests/<feature>.bats` other than the cross-cutting suites (`agrippa`, `harness`, `preflight`, `cluster-core`) is a component probe. Implement `test:gestalt` as a thin wrapper: `bats tests/agrippa.bats`, honoring `ENV` and the `PUBLIC_HOST`/`TRIPS_HOST`/`DASHBOARD_HOST` overrides already read from the environment by the suite. Apply the three-edit fix to the existing `tests/agrippa.bats`: (a) collapse the dead `GESTALT_ENV` branch onto the `ENV` variable `setup()` already sets; (b) give the trips test a `dev` branch asserting plain local reachability (2xx/redirect from `${TRIPS_HOST}`), keeping the `cloudflareaccess.com` assertion on the `prod` branch only; (c) add `-k` to the dev-path `curl` probes (public-site healthz, observability, trips dev) to tolerate the local, untrusted-by-design CA, leaving the prod-path calls unchanged.

**Tests**

```bash
test "test:feature is defined and empty-safe with no component to apply":
  run mise run test:feature
  assert status == 0

test "tests/agrippa.bats parses after the fix":
  run bats --count tests/agrippa.bats
  assert status == 0
  assert output == 3

test "the fixed observability test branches on ENV, not GESTALT_ENV":
  run grep -c GESTALT_ENV tests/agrippa.bats
  assert status == 1   # grep: no matches
```

- Edge case: `ENV=prod` (the default) must be unaffected by the fix — no `-k`, and the trips test must still require the `cloudflareaccess.com` redirect unconditionally.
- Edge case: `test:feature` must delete its throwaway k3d cluster even when an earlier step in the task shell fails partway (teardown via an `EXIT` trap, mirroring `tests/preflight.bats`'s `teardown_file`).
- Edge case: `test:gestalt` must pass host overrides through unset-by-default (falls back to the bats file's own `${VAR:-default}` handling) rather than forcing empty strings.

**Implementation Outline**

```text
task test:feature:
  trap 'k3d cluster delete <throwaway-name>' EXIT
  k3d cluster create <throwaway-name> --wait
  kubectl apply -k apps/                       # empty-safe
  for dir in tests/*/ except tests/policy/:
    chainsaw test dir
  for f in tests/*.bats except {agrippa,harness,preflight,cluster-core}.bats:
    bats f

task test:gestalt:
  bats tests/agrippa.bats     # ENV, PUBLIC_HOST, TRIPS_HOST, DASHBOARD_HOST
                              # already read from the environment by the suite
```

```bash
# tests/agrippa.bats, illustrative diff shape (re-derive exact edit during build)
- if [ "${GESTALT_ENV}" = "dev" ]; then
+ if [ "${ENV}" = "dev" ]; then
    ...curl -k ... dashboard...

+ if [ "${ENV}" = "dev" ]; then
+   run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 5 "https://${TRIPS_HOST}/"
+   assert 2xx or redirect
+ else
    run curl -sS -D - -o /dev/null --max-time 5 "https://${TRIPS_HOST}/"
    assert 302 to cloudflareaccess.com
+ fi
```

## Resolved by the long-loop reviewer (2026-07-07)

This plan carries no net-new "Open Artifact Decision" section of its own (that
gate already ran and cleared at the feature design, per its Summary's *Resolved
by the long-loop reviewer (2026-07-07)* block, which decided the three concrete
artifact choices this feature invents: omitting terraform/tflint, the
`test:gestalt` thin-wrapper shape, and the `tests/policy/secrets{,_test}.rego`
file/package names). So this review's job was to verify this plan's steps
against the cleared `design.md` and, because this is the one feature-step whose
build has already materialized and landed on the working tree, against the
live repo and the real toolchain directly. Researched via `research:codebase`
(direct inspection of `mise.toml`, `scripts/*.sh`, `tests/policy/*.rego`,
`tests/harness.bats`, `tests/agrippa.bats`, `docs/developer/TASKS.md`) and
direct execution against the installed toolchain (`mise 2026.6.14`, `bats
1.13.0`, `helm`, `k3d`, `docker`) — the equivalent of `research:public` for
this feature-step, since every claim to verify is "does this committed
config/task/script actually do what the plan says against the real tool," not
a question answered by external docs. No escalation trigger (irreversible, out
of recorded scope, underdetermined) fired against this plan's own recorded
scope.

**1. Does Step 0's task/file inventory and each step's Implementation Outline
match what is actually committed and running? Decided: yes — no change.**
`mise.toml` carries all six task IDs (`setup`, `test:static`, `test:policy`,
`test:chart`, `test:feature`, `test:gestalt`) plus the `test:push` umbrella
with the `depends` edge exactly as Step 0 fixes, and the tool pins
(`kubeconform 0.8.0`, `helm 4.2.2`, `kubectl 1.36.2`, `k3d 5.9.0`, `conftest
0.68.2`, `bats 1.13.0`, `aqua:kyverno/chainsaw 0.2.15`) match Step 1's
cross-checked versions. `scripts/setup.sh`, `scripts/test-static.sh`, and
`scripts/test-chart.sh` implement exactly the guard/glob/idempotency logic
Steps 1–3's Implementation Outlines describe (bash 3.2-safe `find`-based glob
excluding `kustomization.yaml`, `-ignore-missing-schemas`, `--verify=false`
plugin install, green-on-empty `charts/` handling). `tests/policy/secrets.rego`
and `secrets_test.rego` implement the exact `deny`/`is_plaintext` predicate and
all five fixture directions Step 2 specifies. Preserving the plan's own
decomposition verbatim is the conservative default; nothing needed correcting.

**2. Do the plan's steps actually work end-to-end, not just read correctly?
Decided: yes — live-verified for step0's own scope, no change needed.**
`mise run test:push` runs green (`test:static` 6 resources found, 0 invalid, 6
skipped for missing-schema CRDs as designed; `test:policy` 5/5 self-tests;
`test:chart` green-on-empty `charts/`), finishing in ~0.12s, far inside the 90s
per-push budget. `bats tests/harness.bats` passes (`ok 1`), confirming the
feature test itself is GREEN. `mise run setup` is idempotent (ran twice
cleanly; `helm plugin list` shows `unittest` installed) and `mise trust`
printed "No untrusted config files found" with no interactive prompt, matching
Step 1's non-interactive-CI edge case. `bats --count tests/agrippa.bats` = 3
and `grep -c GESTALT_ENV tests/agrippa.bats` matched zero lines (grep exit 1),
confirming Step 4's three-edit bug fix landed exactly as described, including
the dev-branch trips assertion and the `-k` flags, with the prod branches left
textually unchanged.

**3. Step 3's edge case states `test:push`'s three legs "must run in the order
that gives the fastest, cheapest failure first (test:static before
test:chart)." Decided: no change — the substantive requirement (the 90s
budget) is what's verified; the literal ordering is not a guarantee this
plan's own task graph can make, and no test depends on it.** `mise run
test:push`'s `depends = ["test:static", "test:policy", "test:chart"]` runs
under `mise`'s own default of `--jobs 4` (confirmed via `mise run --help`,
which documents that dependent tasks run in parallel by default), and the
observed log interleaving during a live run bore this out — legs do not
execute in strict listed order. Rewriting this to force serial execution
(`--jobs 1`, or chaining the legs with explicit task-to-task `depends`) is a
`mise.toml` behavior change outside a plan-review's mandate to make
speculatively, and no code in this plan (nor `tests/harness.bats`, which only
asserts the umbrella's exit status) depends on the literal ordering — the
budget it exists to protect is met by two orders of magnitude of margin
(observed ~0.12s against a 90s ceiling). Conservative default: record the
discrepancy for the audit trail and leave the working `mise.toml` as is, rather
than churn already-verified, already-green task wiring to match a
developer-experience aspiration that no test enforces.

**4. Live-running Step 4's `test:feature` against the current tree surfaced a
failure. Decided: out of this plan's recorded scope, not a step0 defect — no
change to this artifact.** `mise run test:feature` created the throwaway
`agrippa-feature` cluster, then failed applying `apps/` (`no matches for kind
"Application" in version "argoproj.io/v1alpha1"`, since no ArgoCD CRDs are
installed on that ephemeral cluster) and failed `tests/gitops.bats`'s own
`bootstrap yields a self-managing...ArgoCD` assertion (which targets the
separate, long-lived `k3d-agrippa-dev` context, unrelated to the throwaway
cluster `test:feature` just created). Both failures trace to the same root
cause: the `gitops-argocd` feature-step's `mise run bootstrap` has not been run
against either cluster, because it requires an unlocked Bitwarden session
holding `agrippa-age-dev` (`DEVELOPMENT.md`'s custody policy) — a human-gated
precondition this automated review cannot and must not fake or substitute
around. This is squarely outside step0's own recorded scope: `design.md`'s
Specification already states `test:feature`'s script is a shared task shell
"structured so a component step supplies only its manifests and probes...their
component logic is exercised by the Cluster core and GitOps feature-steps, not
by this step's feature test," and `gitops-argocd/plan.md` is itself a separate,
already-`Reviewed` artifact. Deciding anything about `gitops-argocd`'s or
`cluster-core-k3d`'s own bootstrap sequencing here would trip escalation
trigger (b) (out of this artifact's recorded scope). The one part of this
finding that **is** in step0's scope — `test:feature`'s teardown running even
on a partial failure — held: `k3d cluster list` afterward showed no leftover
`agrippa-feature` cluster, confirming the `EXIT`-trap edge case from Step 4
works as designed. This finding does not block step0's own gate: step0's
feature test (`tests/harness.bats` → `mise run test:push`) remains green and
is unaffected.

**5. Does the plan carry any other net-new open decision needing escalation?
Decided: no — the gate clears.** No irreversible, out-of-scope, or
underdetermined item remains for this artifact's own recorded scope. The
`*Draft*` marker is removed (changed to *Reviewed*).
