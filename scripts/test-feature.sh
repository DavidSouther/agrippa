#!/usr/bin/env bash
set -uo pipefail
CLUSTER="${AGRIPPA_FEATURE_CLUSTER:-agrippa-feature}"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() {
  k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Delete any same-named cluster left behind by a run that skipped the EXIT
# trap (e.g. SIGKILL, OOM, CI runner crash), so create below always starts clean.
k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
if ! k3d cluster create "$CLUSTER" --wait --timeout 120s; then
  exit 1
fi

rc=0

# Apply the component under test. Convention: apps/ is the GitOps tree a
# component step commits its manifests into (kustomize if present, else plain
# manifests). Empty/missing apps/ is a no-op, not an error, so this stays
# green-on-empty until a component ships.
if [ -f apps/kustomization.yaml ]; then
  kubectl apply -k apps || rc=1
elif [ -d apps ]; then
  manifests=()
  while IFS= read -r -d '' f; do manifests+=("$f"); done \
    < <(find apps -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
  if [ -n "${manifests[*]:-}" ]; then
    kubectl apply -f "${manifests[@]}" || rc=1
  fi
fi

# chainsaw resource-reconcile assertions. Convention (DEVELOPMENT.md repo
# layout): every tests/<feature>/ directory other than tests/policy (reserved
# for conftest Rego) is a chainsaw suite.
chainsaw_dirs=()
if [ -d tests ]; then
  for d in tests/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    [ "$name" = "policy" ] && continue
    chainsaw_dirs+=("${d%/}")
  done
fi
if [ -n "${chainsaw_dirs[*]:-}" ]; then
  chainsaw test "${chainsaw_dirs[@]}" || rc=1
else
  echo "test:feature: no tests/<feature>/ chainsaw suite yet, skipping (green-on-empty)"
fi

# Component bats probes. Convention: every tests/<feature>.bats other than the
# cross-cutting suites already owned by their own tasks/uses (agrippa.bats ->
# test:gestalt; harness.bats -> this harness's own feature test, run via
# test:push; preflight.bats -> a standalone machine check, not a probe of the
# component-under-test's cluster; cluster-core.bats -> the Cluster core feature
# test, which drives `cluster:up`/`cluster:down` against the long-lived
# agrippa-dev cluster, not this throwaway feature cluster; gitops.bats -> also
# drives the long-lived agrippa-dev cluster via `mise run bootstrap`, needs its
# own runner rather than this throwaway feature cluster; rotate-keys.bats ->
# a standalone sops/age mechanism check with a stubbed Bitwarden, needs no
# cluster at all).
probe_suites=()
for f in tests/*.bats; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in
    agrippa.bats|harness.bats|preflight.bats|cluster-core.bats|gitops.bats|rotate-keys.bats) continue ;;
  esac
  probe_suites+=("$f")
done
if [ -n "${probe_suites[*]:-}" ]; then
  bats "${probe_suites[@]}" || rc=1
else
  echo "test:feature: no component bats probes yet, skipping (green-on-empty)"
fi

exit $rc
