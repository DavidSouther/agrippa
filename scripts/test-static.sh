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
if [ -z "${manifests[*]:-}" ]; then
  echo "test:static: no manifests to check yet, skipping kubeconform/conftest (green-on-empty)"
  exit 0
fi
# -ignore-missing-schemas: kubeconform ships no schema for CRDs like ArgoCD's
# argoproj.io Application, so a resource kubeconform can't find a schema for is
# Skipped rather than an Error; built-in Kubernetes kinds are still validated.
rc=0
kubeconform -strict -ignore-missing-schemas -summary "${manifests[@]:-}" || rc=1
conftest test --policy tests/policy --all-namespaces "${manifests[@]:-}" || rc=1
exit $rc
