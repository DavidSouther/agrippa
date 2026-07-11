#!/usr/bin/env bash
set -euo pipefail
CLUSTER="agrippa-dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

for workload in resume trips; do
  echo "workloads:build: [$workload] stage 1/3 -- materializing the submodule"
  # Fail loud here (not a cryptic in-container npm error) if the submodule was never initialized.
  git -C "$REPO_ROOT" submodule update --init "workloads/$workload"
  if [ ! -f "$REPO_ROOT/workloads/$workload/package.json" ]; then
    echo "workloads:build: [$workload] submodule not initialized -- workloads/$workload/package.json is missing after 'git submodule update --init'" >&2
    exit 1
  fi

  echo "workloads:build: [$workload] stage 2/3 -- docker build -> $workload:dev"
  docker build \
    -f "$REPO_ROOT/workloads/$workload.Dockerfile" \
    -t "$workload:dev" \
    "$REPO_ROOT/workloads/$workload"

  echo "workloads:build: [$workload] stage 3/3 -- k3d image import (direct mode)"
  # `direct` mode copies straight from the host Docker daemon into the k3s
  # node's containerd -- no intermediate tools-container hop needed on this
  # single-node cluster.
  k3d image import "$workload:dev" --mode direct --cluster "$CLUSTER"

  echo "workloads:build: [$workload] done"
done

echo "workloads:build: resume:dev and trips:dev built and imported into $CLUSTER"
