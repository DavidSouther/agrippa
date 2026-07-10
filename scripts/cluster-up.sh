#!/usr/bin/env bash
set -euo pipefail
CLUSTER="agrippa-dev"
CONFIG="k3d/agrippa-dev.yaml"
if k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
  echo "cluster:up: $CLUSTER already exists; ensuring it is started"
  k3d cluster start "$CLUSTER"
else
  k3d cluster create --config "$CONFIG"
fi
# Point kubectl at the dev cluster for the operator's convenience.
kubectl config use-context "k3d-$CLUSTER" >/dev/null 2>&1 || true
# Confirm the cluster is actually reachable before reporting success.
kubectl --context "k3d-$CLUSTER" get nodes >/dev/null
