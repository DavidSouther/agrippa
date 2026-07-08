#!/usr/bin/env bash
set -euo pipefail
mise trust
if ! helm plugin list 2>/dev/null | grep -qw unittest; then
  # helm-unittest ships no .prov signature file, so helm 4's default plugin
  # signature verification has nothing to verify against; skip it explicitly.
  helm plugin install --verify=false https://github.com/helm-unittest/helm-unittest
fi
