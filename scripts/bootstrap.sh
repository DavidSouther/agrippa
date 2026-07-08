#!/usr/bin/env bash
set -euo pipefail
CTX="k3d-agrippa-dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Stage 1: require bw present and unlocked -----------------------------
# The sops-age trust root's private key is read from Bitwarden only, never a
# committed or plaintext file (DEVELOPMENT.md custody). Fail loud, name the
# missing prerequisite, no plaintext fallback -- this is a human-resolved
# blocker (`bw login` / `bw unlock`), not something this task works around.
PREFIX="bootstrap"
# shellcheck source=lib/bw-status.sh
source "$SCRIPT_DIR/lib/bw-status.sh"

# --- Stage 2: the argocd namespace and the sops-age Secret (the trust root) -
# Namespace and Secret both use the apply-not-create pattern so re-running
# bootstrap is idempotent -- neither errors nor duplicates on a second run.
kubectl --context "$CTX" create namespace argocd --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -

# The decrypted key is piped directly from `bw` into `kubectl`'s stdin --
# never assigned to a shell variable and never a command-line argument, so it
# never appears in a temp file, in argv, or in `ps`/`/proc/<pid>/cmdline`.
bw get notes agrippa-age-dev \
  | kubectl --context "$CTX" create secret generic sops-age -n argocd \
      --from-file=key.txt=/dev/stdin --dry-run=client -o yaml \
  | kubectl --context "$CTX" apply -f -

echo "bootstrap: sops-age trust root ready in namespace argocd"
# stages 3-4 (KSOPS-enabled ArgoCD install, root app-of-apps apply) are not
# yet implemented.
