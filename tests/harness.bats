#!/usr/bin/env bats
#
# Feature test for Step 0: the mise + testing harness.
#
# Primary user story (Given / When / Then):
#   Given a clean checkout of the agrippa repo with `mise` installed,
#   When an operator runs the per-push test lane `mise run test:push`,
#   Then the lane runs green end-to-end: kubeconform schema-validation plus the
#        plaintext-Secret conftest guard (test:static), the conftest Rego
#        self-tests (test:policy), and helm-unittest (test:chart) all pass,
#        proving the testing harness DEVELOPMENT.md (## Testing) describes is
#        installed and working.
#
# Why this is the one end-to-end acceptance: `mise run test:push` is the per-push
# CI lane an operator actually runs, and it transitively exercises every harness
# task. Its test:policy leg runs the guard's own conftest `_test.rego` cases (a
# plaintext Secret must be denied, an encrypted one allowed), so a green push lane
# is genuine proof the guard guards. It is not merely proof that empty input passed.
#
# EXPECTED TO FAIL until Step 0 lands `mise.toml` and the harness tasks. Today
# `mise run test:push` errors with "no tasks defined" (there is no mise.toml yet).
# That red state is the point. It defines "done" for this feature-step.
#
# Run:  bats tests/harness.bats
#
# Requires: bats-core, mise. The harness tools (kubeconform, conftest, helm, and
# the helm-unittest plugin) are pinned by mise.toml and installed by
# `mise run setup`. Run setup once before this suite on a fresh checkout.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  cd "$REPO_ROOT" || return 1
  # Trust the repo mise.toml so `mise run` is non-interactive once it exists.
  mise trust >/dev/null 2>&1 || true
}

@test "per-push lane is green: mise run test:push passes on a clean checkout" {
  run mise run test:push
  [ "$status" -eq 0 ]
}
