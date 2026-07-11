#!/usr/bin/env bash
set -euo pipefail
# Regenerate the Web Analytics dashboard from its Grafonnet source: restore the
# pinned grafonnet vendor tree, compile main.jsonnet, and splice the JSON into
# grafana's kustomization. Helm inlines dashboards via `json:` (a file: ref can't
# resolve through helmCharts inflation), so the compiled output lives in-place.
src=observability/overlays/dev/grafana/dashboards/web-analytics
kust=observability/overlays/dev/grafana/kustomization.yaml

# Restore vendor/ from jsonnetfile.lock.json (gitignored, like the helm cache).
(cd "$src" && jb install)

compiled="$(jsonnet -J "$src/vendor" "$src/main.jsonnet")"
COMPILED="$compiled" yq -i \
  '.helmCharts[0].valuesInline.dashboards.default.web-analytics.json = strenv(COMPILED)' \
  "$kust"
