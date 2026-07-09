#!/usr/bin/env bash
set -euo pipefail
CLUSTER="agrippa-dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Builds resume:dev and trips:dev from the workloads/{resume,trips} git
# submodules and imports both into the k3d node's containerd, so the
# imagePullPolicy: Never Deployments ArgoCD reconciles (workloads/overlays/dev)
# have something to schedule against. Idempotent -- safe to re-run (rebuild +
# re-import) any number of times, matching bootstrap.sh's own discipline.

for workload in resume trips; do
  echo "workloads:build: [$workload] stage 1/3 -- materializing the submodule"
  # A plain local build context never auto-populates a submodule -- a fresh
  # clone (or an explicitly deinitialized submodule) leaves
  # workloads/<workload> empty. Fail loud here, before ever invoking docker,
  # rather than surfacing as a cryptic "no package.json" npm error three
  # layers deep inside the build stage.
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
