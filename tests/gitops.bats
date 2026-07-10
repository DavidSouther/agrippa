#!/usr/bin/env bats
#
# Feature test for GitOps (ArgoCD app-of-apps + KSOPS/age)
#
# Primary user story (Given / When / Then):
#   Given the running long-lived `agrippa-dev` k3d cluster, toolchain, and an
#         UNLOCKED Bitwarden session holding the dev age key item `agrippa-age-dev`,
#   When an operator runs `mise run bootstrap`,
#   Then the `sops-age` trust root exists in the `argocd` namespace, the ArgoCD
#        repo-server is KSOPS-enabled, the root
#        app-of-apps manages itself and reports Synced/Healthy, and the five-layer
#        skeleton (core, storage, platform, observability, workloads) is registered.
#
# SECRETS BOUNDARY: `bootstrap` reads the dev age key from Bitwarden only
# (`bw get notes agrippa-age-dev`), never from a committed or plaintext file. If
# `bw` is missing/locked, `bootstrap` fails loudly (non-zero exit) and so does this
# test -- that is a human-resolved blocker (`bw unlock`), NOT a reason to weaken the
# trust model. This suite never handles the key itself.
#
# NOTE: this suite deliberately does NOT tear ArgoCD or the cluster down. Both are
# long-lived: every later feature-step reconciles into this ArgoCD. `bootstrap` is
# idempotent, so re-running this suite is safe.
#
# Run:  bats tests/gitops.bats
#
# Requires: bats-core, mise, kubectl, and (for green) a running `agrippa-dev`
# cluster (`mise run cluster:up`) plus an unlocked Bitwarden session with
# `agrippa-age-dev`. The build tools (sops, age, kustomize, argocd) are pinned by
# mise.toml and used inside the `bootstrap` task.

CTX="k3d-agrippa-dev"
NS="argocd"

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  cd "$REPO_ROOT" || return 1
  # Trust the repo mise.toml so `mise run` is non-interactive.
  mise trust >/dev/null 2>&1 || true
}

# Echoes "<sync> <health>" for an ArgoCD Application, e.g. "Synced Healthy".
app_status() {
  mise x kubectl -- kubectl --context "$CTX" -n "$NS" get application "$1" \
    -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null
}

# Waits up to ~5 min for an Application to reach Synced + Healthy. First-run image
# pulls happen inside `bootstrap` (which --waits for ArgoCD), not here, so the
# skeleton's app-of-apps sync itself is quick.
wait_for_synced_healthy() {
  for _ in $(seq 1 60); do
    if [ "$(app_status "$1")" = "Synced Healthy" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

@test "bootstrap yields a self-managing, KSOPS-decrypting ArgoCD with the five-layer app-of-apps skeleton Synced/Healthy" {
  # WHEN: the operator bootstraps the GitOps spine. Idempotent -- succeeds whether
  # or not ArgoCD is already installed. Requires an unlocked Bitwarden session and
  # the running agrippa-dev cluster (see header).
  run mise run bootstrap
  [ "$status" -eq 0 ]

  # THEN 1: the sops-age trust root exists in the argocd namespace.
  run mise x kubectl -- kubectl --context "$CTX" -n "$NS" get secret sops-age
  [ "$status" -eq 0 ]

  # THEN 2: the repo-server is KSOPS-enabled (it mounts the sops-age key and
  # carries the ksops decrypt init-container). This proves a DECRYPTING ArgoCD,
  # not merely an ArgoCD.
  run mise x kubectl -- kubectl --context "$CTX" -n "$NS" get deployment argocd-repo-server -o yaml
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi ksops
  echo "$output" | grep -q sops-age

  # THEN 3: the root app-of-apps manages itself and reports Synced + Healthy.
  run wait_for_synced_healthy root
  [ "$status" -eq 0 ]

  # THEN 4: the five-layer app-of-apps skeleton is registered and ready to receive
  # later feature-steps' Applications.
  for layer in core storage platform observability workloads; do
    run mise x kubectl -- kubectl --context "$CTX" -n "$NS" get application "$layer"
    [ "$status" -eq 0 ]
  done
}
