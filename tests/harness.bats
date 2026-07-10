#!/usr/bin/env bats
#
# Primary user story (Given / When / Then):
#   Given a clean checkout of the agrippa repo with `mise` installed,
#   When an operator runs the per-push test lane `mise run test:push`,
#   Then the lane runs green end-to-end: kubeconform schema-validation plus the
#        plaintext-Secret conftest guard (test:static), the conftest Rego
#        self-tests (test:policy), and helm-unittest (test:chart) all pass,
#        proving the testing harness is installed and working.
#
# Run:  bats tests/harness.bats
#
# Requires: bats-core, mise. The harness tools (kubeconform, conftest, helm, and
# the helm-unittest plugin) are pinned by mise.toml and installed by
# `mise run setup`.

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
