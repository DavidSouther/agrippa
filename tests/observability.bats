#!/usr/bin/env bats
#
# Feature test for Observability (Loki, Tempo, Mimir, Grafana, Alloy),
# Feature 8 of the local k3d project.
#
# Primary user story (Given / When / Then):
#   Given the bootstrapped long-lived `agrippa-dev` cluster with this
#         Observability content committed and reconciled by ArgoCD into the
#         `observability` layer -- Loki, Tempo, Mimir, Grafana (with its
#         Loki/Mimir/Tempo datasources provisioned), and Alloy,
#   When an operator reaches
#        https://dashboard.davidsouther.com.127.0.0.1.nip.io/ through the k3d
#        `:443` host port-map, authenticates to Grafana with the dev admin/admin
#        credential, and lists its configured datasources,
#   Then the observability layer is Synced/Healthy, Grafana answers through the
#        shared Gateway, the dev credential authenticates and renders the home
#        dashboard API, and Grafana's Loki/Mimir/Tempo datasources are
#        registered and returned by its own datasources API -- proving the
#        stack is wired together, not merely that Grafana itself is up.
#
# NOTE: this suite deliberately does NOT tear the cluster, ArgoCD, or the
# observability stack down. All are long-lived and GitOps-managed; this suite
# only reads, so re-running it is safe.
#
# Run:  bats tests/observability.bats
#
# Requires: bats-core, mise, curl, jq, kubectl, and (for green) the running
# bootstrapped `agrippa-dev` cluster with the Observability `observability`
# content reconciled by ArgoCD.
#
# DASH_HOST overrides the target host so the same test could point at another
# dev nip.io host if this ever moves. GRAFANA_USER/GRAFANA_PASSWORD are the
# same local-only dev credentials tests/agrippa.bats already uses for this
# exact endpoint shape -- Grafana's documented defaults, never valid in
# production.

CTX="k3d-agrippa-dev"
NS="argocd"
DASH_HOST="${DASH_HOST:-dashboard.davidsouther.com.127.0.0.1.nip.io}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  cd "$REPO_ROOT" || return 1
  # Trust the repo mise.toml so `mise run`/`mise x` are non-interactive.
  mise trust >/dev/null 2>&1 || true
}

# Echoes "<sync> <health>" for an ArgoCD Application, e.g. "Synced Healthy".
app_status() {
  mise x kubectl -- kubectl --context "$CTX" -n "$NS" get application "$1" \
    -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null
}

# Waits up to ~5 min for an Application to reach Synced + Healthy.
wait_for_synced_healthy() {
  for _ in $(seq 1 60); do
    if [ "$(app_status "$1")" = "Synced Healthy" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

@test "Grafana serves the observability contract: observability Synced/Healthy, reachable through the Gateway, dev credential auth, and Loki/Mimir/Tempo datasources registered" {
  # THEN 0: ArgoCD has reconciled Observability into the observability layer.
  run wait_for_synced_healthy observability
  [ "$status" -eq 0 ]

  # THEN 1: Grafana answers through the shared Gateway at its nip.io host. -k
  # tolerates the local CA (same convention as networking.bats).
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${DASH_HOST}/"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(2[0-9][0-9]|3[0-9][0-9])$ ]]

  # THEN 2: the dev admin/admin credential authenticates and a dashboard
  # actually renders -- the same pattern tests/agrippa.bats's gestalt dev-path
  # assertion already uses against this exact endpoint shape.
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" "https://${DASH_HOST}/api/dashboards/home"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  # THEN 3: Grafana's own datasources API reports a non-empty list including
  # Loki, Mimir, and Tempo -- the exact names configured by
  # observability/overlays/dev/grafana/kustomization.yaml's `datasources:`
  # block -- proving those datasources are actually registered, not just that
  # Grafana itself answers. Split across two calls (status, then body) so the
  # status check can't be fooled by an error body's own JSON shape.
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" "https://${DASH_HOST}/api/datasources"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  run curl -k -sS --max-time 5 \
    -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" "https://${DASH_HOST}/api/datasources"
  [ "$status" -eq 0 ]
  count="$(echo "$output" | mise x jq -- jq 'length')"
  [ "$count" -gt 0 ]
  names="$(echo "$output" | mise x jq -- jq -r '[.[].name] | join(",")')"
  [[ "$names" == *"Loki"* ]]
  [[ "$names" == *"Mimir"* ]]
  [[ "$names" == *"Tempo"* ]]
}
