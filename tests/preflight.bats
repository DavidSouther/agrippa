#!/usr/bin/env bats
#
# Preflight check for local k3d development on macOS.
#
# Verifies the toolchain and Docker runtime the Development (K3d) environment
# needs are present, sized adequately, and that k3d can actually stand up and
# tear down a cluster on this machine -- not just that the binaries exist.
# Run this before the first `k3d cluster create` of a session, and again after
# any Docker Desktop update.
#
# Run:    bats tests/preflight.bats
#
# The final two tests create and delete a throwaway k3d cluster. On a machine
# that hasn't pulled the k3s node image before, that can take a minute or two.
#
# Requires: bats-core, docker, k3d, kubectl, helm. See GETTING_STARTED.md.

: "${PREFLIGHT_CLUSTER:=agrippa-preflight}"
: "${MIN_DOCKER_CPU:=4}"
: "${MIN_DOCKER_MEM_GB:=8}"
export PREFLIGHT_CLUSTER MIN_DOCKER_CPU MIN_DOCKER_MEM_GB

wait_for_node_ready() {
  local ctx="k3d-${PREFLIGHT_CLUSTER}"
  for _ in $(seq 1 30); do
    if kubectl --context "$ctx" get nodes --no-headers 2>/dev/null | grep -qw Ready; then
      return 0
    fi
    sleep 2
  done
  return 1
}

teardown_file() {
  if command -v k3d >/dev/null 2>&1; then
    k3d cluster delete "$PREFLIGHT_CLUSTER" >/dev/null 2>&1 || true
  fi
}

@test "docker is installed" {
  run command -v docker
  [ "$status" -eq 0 ]
}

@test "docker daemon is running and reachable" {
  run docker info
  [ "$status" -eq 0 ]
}

@test "docker has at least ${MIN_DOCKER_CPU} CPUs allocated" {
  run docker info --format '{{.NCPU}}'
  [ "$status" -eq 0 ]
  [ "$output" -ge "$MIN_DOCKER_CPU" ]
}

@test "docker has at least ${MIN_DOCKER_MEM_GB}GB memory allocated" {
  run docker info --format '{{.MemTotal}}'
  [ "$status" -eq 0 ]
  min_bytes=$(( MIN_DOCKER_MEM_GB * 1024 * 1024 * 1024 ))
  [ "$output" -ge "$min_bytes" ]
}

@test "k3d is installed" {
  run command -v k3d
  [ "$status" -eq 0 ]
}

@test "kubectl is installed" {
  run command -v kubectl
  [ "$status" -eq 0 ]
}

@test "helm is installed" {
  run command -v helm
  [ "$status" -eq 0 ]
}

@test "k3d can create a cluster and reach a Ready node" {
  run k3d cluster create "$PREFLIGHT_CLUSTER" --wait --timeout 120s
  [ "$status" -eq 0 ]

  run wait_for_node_ready
  [ "$status" -eq 0 ]
}

@test "k3d can delete the cluster cleanly" {
  run k3d cluster delete "$PREFLIGHT_CLUSTER"
  [ "$status" -eq 0 ]
}
