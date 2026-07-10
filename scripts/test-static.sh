#!/usr/bin/env bash
set -euo pipefail
# macOS ships bash 3.2 (no `globstar`), so walk with `find` instead of `**`.
# kustomization.yaml is kustomize config, not a Kubernetes resource -- excluded
# from both globs so kubeconform/conftest never see it (it has no `kind`).
manifests=()
if [ -d apps ]; then
  while IFS= read -r -d '' f; do manifests+=("$f"); done \
    < <(find apps -type f \( -name '*.yaml' -o -name '*.yml' \) ! -name 'kustomization.yaml' -print0)
fi
if [ -d charts ]; then
  # rendered/ is populated by a chart-render step (helm template) not yet
  # implemented; this glob is a no-op until that step lands and charts/ exists.
  while IFS= read -r -d '' f; do manifests+=("$f"); done \
    < <(find charts -type f -path '*/rendered/*' \( -name '*.yaml' -o -name '*.yml' \) ! -name 'kustomization.yaml' -print0)
fi
# secrets/ is sops-encrypted ciphertext, so kubeconform can't validate it
# against a schema; skip kubeconform here but conftest's plaintext-Secret
# guard still applies (see secrets_manifests below).
secrets_manifests=()
if [ -d secrets ]; then
  while IFS= read -r -d '' f; do secrets_manifests+=("$f"); done \
    < <(find secrets -type f \( -name '*.yaml' -o -name '*.yml' \) ! -name 'kustomization.yaml' -print0)
fi
if [ -z "${manifests[*]:-}" ] && [ -z "${secrets_manifests[*]:-}" ]; then
  echo "test:static: no manifests to check yet, skipping kubeconform/conftest (green-on-empty)"
  exit 0
fi
rc=0
if [ -n "${manifests[*]:-}" ]; then
  # -ignore-missing-schemas: kubeconform ships no schema for CRDs like
  # ArgoCD's Application, so those are Skipped rather than Errors.
  kubeconform -strict -ignore-missing-schemas -summary "${manifests[@]}" || rc=1
  conftest test --policy tests/policy --all-namespaces "${manifests[@]}" || rc=1
fi
if [ -n "${secrets_manifests[*]:-}" ]; then
  conftest test --policy tests/policy --all-namespaces "${secrets_manifests[@]}" || rc=1
fi
exit $rc
