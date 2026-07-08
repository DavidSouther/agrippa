#!/usr/bin/env bats
#
# Feature test for Cluster core (local k3d substrate, roadmap item 1).
#
# Primary user story (Given / When / Then):
#   Given a clean checkout with the Step 0 toolchain installed (k3d, kubectl,
#         docker) and a running Docker daemon,
#   When an operator runs `mise run cluster:up`,
#   Then a single-node local k3d cluster named `agrippa-dev` is running with a
#        Ready node, with k3s ServiceLB (Klipper) and Traefik BOTH disabled so
#        neither races metallb for LoadBalancer IPs nor competes with the Istio
#        Gateway for ingress, and with host port 443 published through the k3d
#        loadbalancer so `https://<host>` reaches the in-cluster gateway once
#        Networking lands.
#
# This is roadmap item 1 (Cluster core) in its k3d-only form: it stands in for
# the production cloud-init/Terraform/DigitalOcean node provisioning, which is
# out of scope for the local build. metallb and its IPAddressPool are declared
# part of this concern but are delivered by the GitOps bootstrap at a sync-wave
# (research decision 8), so they are NOT asserted here -- this test is bounded to
# what `mise run cluster:up` itself delivers.
#
# EXPECTED TO FAIL until Cluster core lands `k3d/agrippa-dev.yaml` and the
# `cluster:up` mise task. Before that, `mise run cluster:up` errors (no such
# task). That red state defines "done" for this feature-step.
#
# NOTE: this suite deliberately does NOT tear the cluster down. `agrippa-dev` is
# the long-lived local dev cluster every later feature-step builds on. Running
# `cluster:up` is idempotent, so re-running this suite is safe. Use
# `mise run cluster:down` to remove the cluster when finished for the day.
#
# Run:  bats tests/cluster-core.bats
#
# Requires: bats-core, mise, k3d, kubectl, docker.

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

  # THEN 2: Traefik is disabled -- k3s did not deploy its bundled Traefik, so it
  # cannot compete with the Istio Gateway for ingress. No traefik pods.
  run kubectl --context "$CONTEXT" -n kube-system get pods --no-headers
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi traefik

  # THEN 3: ServiceLB (Klipper) is disabled -- the k3s server was started with
  # --disable=servicelb, so it will not race metallb for LoadBalancer IPs.
  run docker inspect --format '{{json .Args}}' "k3d-${CLUSTER}-server-0"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--disable=servicelb"

  # THEN 4: host port 443 is published through the k3d loadbalancer proxy, so
  # host :443 reaches the in-cluster gateway once Networking (Istio) lands.
  run docker port "k3d-${CLUSTER}-serverlb"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "443"
}
