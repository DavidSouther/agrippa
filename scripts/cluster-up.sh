#!/usr/bin/env bash
set -euo pipefail
CLUSTER="agrippa-dev"
CONFIG="k3d/agrippa-dev.yaml"
GATEWAY_SVC="core/overlays/dev/gateway-external-svc.yaml"
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

# gateway-external-svc.yaml's externalIPs is a committed, GitOps-managed value
# that drifts across cluster:down/up (the node's docker-network IP isn't
# stable across recreates). Detect drift here rather than silently rewriting
# a git-tracked manifest from this script -- ArgoCD's selfHeal would just
# fight a live-only patch, so the fix has to land in git.
if [ -f "$GATEWAY_SVC" ]; then
  actual_ip="$(docker inspect "k3d-${CLUSTER}-server-0" \
    --format "{{ (index .NetworkSettings.Networks \"k3d-${CLUSTER}\").IPAddress }}" 2>/dev/null || true)"
  committed_ip="$(yq '.spec.externalIPs[0]' "$GATEWAY_SVC" 2>/dev/null || true)"
  if [ -n "$actual_ip" ] && [ -n "$committed_ip" ] && [ "$actual_ip" != "$committed_ip" ]; then
    echo "cluster:up: WARNING -- $GATEWAY_SVC's externalIPs ($committed_ip) no longer matches this node's actual IP ($actual_ip)." >&2
    echo "cluster:up: update it and commit so ArgoCD reconciles: yq -i '.spec.externalIPs[0] = \"$actual_ip\"' $GATEWAY_SVC" >&2
  fi
fi
