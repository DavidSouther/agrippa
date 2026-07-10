#!/usr/bin/env bats
#
# Feature test for Cluster core.
#
# Primary user story (Given / When / Then):
#   Given a clean checkout with the toolchain installed (mise, docker) and a running Docker daemon,
#   When an operator runs `mise run cluster:up`,
#   Then a single-node local k3d cluster named `agrippa-dev` is running with a
#        Ready node, with k3s ServiceLB (Klipper) and Traefik BOTH disabled
#        and with host port 443 published through the k3d
#        loadbalancer so `https://<host>` reaches the in-cluster gateway once
#        Networking lands.
#
# NOTE: this suite deliberately does NOT tear the cluster down. `agrippa-dev` is
# the long-lived local dev cluster every later feature-step builds on. Running
# `cluster:up` is idempotent, so re-running this suite is safe. Use
# `mise run cluster:down` to remove the cluster when finished for the day.
#
# Run:  bats tests/cluster-core.bats
#
# Requires: bats-core, mise, docker.

CLUSTER="agrippa-dev"
CONTEXT="k3d-agrippa-dev"

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  cd "$REPO_ROOT" || return 1
  # Trust the repo mise.toml so `mise run` is non-interactive.
  mise trust >/dev/null 2>&1 || true
}

wait_for_node_ready() {
  for _ in $(seq 1 30); do
    if kubectl --context "$CONTEXT" get nodes --no-headers 2>/dev/null | grep -qw Ready; then
      return 0
    fi
    sleep 2
  done
  return 1
}

@test "cluster:up yields a ready agrippa-dev substrate: Ready node, ServiceLB+Traefik disabled, host :443 mapped" {
  # WHEN: the operator brings the cluster up. Idempotent -- succeeds whether or
  # not agrippa-dev already exists.
  run mise run cluster:up
  [ "$status" -eq 0 ]

  # THEN 1: the cluster exists and its single node reaches Ready.
  run wait_for_node_ready
  [ "$status" -eq 0 ]

  # THEN 2: Traefik is disabled
  run mise x kubectl --context "$CONTEXT" -n kube-system get pods --no-headers
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi traefik

  # THEN 3: ServiceLB (Klipper) is disabled
  run mise x docker inspect --format '{{json .Args}}' "k3d-${CLUSTER}-server-0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--disable=servicelb"

  # THEN 4: host port 443 is published through the k3d loadbalancer proxy, so
  # host :443 reaches the in-cluster gateway once Networking (Istio) lands.
  run mise x docker port "k3d-${CLUSTER}-serverlb"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "443"
}
