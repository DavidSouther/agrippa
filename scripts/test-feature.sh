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

# apps/ is the GitOps app-of-apps tree (GitOps feature-step onward): six
# ArgoCD Application CRs, each pointing at its own <layer>/overlays/dev path.
# This throwaway cluster never installs ArgoCD's CRDs -- only `bootstrap`
# does that, against the long-lived agrippa-dev cluster (tests/gitops.bats
# covers apps/ end-to-end there) -- so a bare `kubectl apply -k apps` here
# would just fail with "no matches for kind Application". Skip it; a later
# feature-step's real component manifests land under its own
# <layer>/overlays/dev path instead, which is a plain kustomize/manifest
# directory this loop can apply once that convention has real content.
if [ -d apps ]; then
  echo "test:feature: apps/ is GitOps-owned (ArgoCD Applications); covered by tests/gitops.bats against the long-lived cluster, skipping here"
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
# own runner rather than this throwaway feature cluster; networking.bats ->
# drives the GitOps-reconciled `core` layer (Istio Gateway/HTTPRoute/TLS)
# against the long-lived agrippa-dev cluster via ArgoCD, not this throwaway
# feature cluster; storage.bats -> drives the GitOps-reconciled `storage` layer
# (CloudNativePG Cluster/Database, Valkey, sops-encrypted credentials) against
# the long-lived agrippa-dev cluster via ArgoCD, not this throwaway feature
# cluster; git-hosting.bats -> drives the GitOps-reconciled `platform` layer (the
# Forgejo server, its Postgres database/role, its sealed admin+DB credentials, and
# its Gateway HTTPRoute) against the long-lived agrippa-dev cluster via ArgoCD, not
# this throwaway feature cluster; auth.bats -> drives the GitOps-reconciled `platform` layer (the
# Keycloak Operator + Keycloak/KeycloakRealmImport CRs, reached through the shared
# Istio Gateway) against the long-lived agrippa-dev cluster via ArgoCD, not this
# throwaway feature cluster; observability.bats -> drives the GitOps-reconciled `observability`
# layer (the Grafana LGTM stack + Alloy, reached through the shared Istio
# Gateway) against the long-lived agrippa-dev cluster via ArgoCD, not this
# throwaway feature cluster; feature-flags.bats -> drives the GitOps-reconciled
# `platform` layer (the Flagsmith Helm release + its HTTPRoute/Database/
# sops-encrypted credentials, reached through the shared Istio Gateway) against
# the long-lived agrippa-dev cluster via ArgoCD, not this throwaway feature
# cluster; rotate-keys.bats -> a standalone sops/age mechanism
# check with a stubbed Bitwarden, needs no cluster at all).
probe_suites=()
for f in tests/*.bats; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in
    agrippa.bats|harness.bats|preflight.bats|cluster-core.bats|gitops.bats|networking.bats|storage.bats|git-hosting.bats|auth.bats|observability.bats|feature-flags.bats|rotate-keys.bats) continue ;;
  esac
  probe_suites+=("$f")
done
if [ -n "${probe_suites[*]:-}" ]; then
  bats "${probe_suites[@]}" || rc=1
else
  echo "test:feature: no component bats probes yet, skipping (green-on-empty)"
fi

exit $rc
