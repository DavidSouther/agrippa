#!/usr/bin/env bash
set -euo pipefail
if [ ! -d charts ]; then
  echo "test:chart: no charts/ directory yet, skipping helm-unittest (green-on-empty)"
  exit 0
fi
found=0
rc=0
for chart in charts/*/; do
  [ -d "$chart" ] || continue
  if [ -d "${chart}tests" ]; then
    found=1
    helm unittest "$chart" || rc=1
  fi
done
if [ "$found" -eq 0 ]; then
  echo "test:chart: no chart has a tests/ suite yet, skipping helm-unittest (green-on-empty)"
fi
exit $rc
