#!/usr/bin/env bash
set -euo pipefail
CTX="k3d-agrippa-dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Require bw present and unlocked. The sops-age trust root's private key is
# read from Bitwarden only, never a committed or plaintext file.
PREFIX="bootstrap"
# shellcheck source=lib/bw-status.sh
source "$SCRIPT_DIR/lib/bw-status.sh"

# Create the argocd namespace and the sops-age Secret as the trust root.
kubectl --context "$CTX" create namespace argocd --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -

# The decrypted key is piped directly from `bw` into `kubectl`'s stdin --
# by skipping shell variables and command-line arguments, it
# never appears in a temp file, in argv, or in `ps`/`/proc/<pid>/cmdline`.
bw get notes agrippa-age-dev \
  | kubectl --context "$CTX" create secret generic sops-age -n argocd \
      --from-file=key.txt=/dev/stdin --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -

echo "bootstrap: sops-age trust root ready in namespace argocd"

#  KSOPS-enabled ArgoCD install
kustomize build apps/platform/argocd \
  | kubectl --context "$CTX" apply --server-side --force-conflicts -f -

# Confirm the KSOPS-patched repo-server actually finished rolling out (not
# just accepted by the API server) before bootstrap reports success
kubectl --context "$CTX" -n argocd rollout status deployment/argocd-repo-server --timeout=300s

echo "bootstrap: KSOPS-enabled ArgoCD installed in namespace argocd"

# Apply root app-of-apps
kubectl --context "$CTX" apply -k apps

echo "bootstrap: root app-of-apps applied"
