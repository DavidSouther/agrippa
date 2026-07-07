#!/usr/bin/env bats
#
# Gestalt feature test for the Agrippa platform.
#
# One black-box, end-to-end smoke test of the whole deployed platform, probed
# from outside the cluster. It encodes the platform's user-visible contract from
# ailly/developer/2026-06-10-A-agrippa/design.md:
#
#   1. Public site is alive      -> davidsouther.com/healthz returns 2xx within 1s
#   2. Authenticated route gated  -> trips.davidsouther.com is challenged by
#                                    Cloudflare Access before traffic reaches the app
#   3. Observability reachable    -> dashboard.davidsouther.com (Grafana):
#                                      dev  -> authenticate with local-only test
#                                              credentials and a dashboard renders
#                                      prod -> liveness only (endpoint is reachable)
#
# This test is EXPECTED TO FAIL until the platform is implemented and deployed.
# That is the point: it defines "done" for the platform before any code exists.
#
# Run:    bats tests/agrippa.bats     (or: bats tests/  to run every suite)
# Prod:   ENV=prod bats tests/agrippa.bats   (default)
# Dev:    ENV=dev  bats tests/agrippa.bats
#
# Targets are overridable so the same test can run against a local K3d ingress:
#   PUBLIC_HOST, TRIPS_HOST, DASHBOARD_HOST
#
# Requires: bats-core, curl.

setup() {
  PUBLIC_HOST="${PUBLIC_HOST:-davidsouther.com}"
  TRIPS_HOST="${TRIPS_HOST:-trips.davidsouther.com}"
  DASHBOARD_HOST="${DASHBOARD_HOST:-dashboard.davidsouther.com}"
  ENV="${ENV:-prod}"

  # Local-only Grafana credentials for the dev path. These are Grafana's
  # documented defaults and must NEVER be valid in production. The prod path
  # sends no credentials.
  GRAFANA_USER="${GRAFANA_USER:-admin}"
  GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"
}

@test "public site is alive: davidsouther.com/healthz returns 2xx within 1s" {
  run curl -sS -o /dev/null -w '%{http_code}' --max-time 1 \
    "https://${PUBLIC_HOST}/healthz"
  # curl exits 0 only if the whole exchange finished inside the 1s liveness budget.
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^2[0-9][0-9]$ ]]
}

@test "observability is reachable: dashboard.davidsouther.com (dev=authenticated render, prod=liveness)" {
  if [ "${GESTALT_ENV}" = "dev" ]; then
    # DEV: authenticate with local-only hardcoded test credentials and confirm a
    # Grafana dashboard actually renders for the operator.
    run curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
      -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
      "https://${DASHBOARD_HOST}/api/dashboards/home"
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]
  else
    # PROD: liveness only -- the observability endpoint answers (reachable),
    # without sending any credentials.
    run curl -sS -o /dev/null -w '%{http_code}' --max-time 2 \
      "https://${DASHBOARD_HOST}/api/health"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[23][0-9][0-9]$ ]]
  fi
}

@test "authenticated route is gated: trips.davidsouther.com challenges anonymous users via Cloudflare Access" {
  run curl -sS -D - -o /dev/null --max-time 5 "https://${TRIPS_HOST}/"
  [ "$status" -eq 0 ]
  # The edge must redirect to the Access login, not serve the app (never a 2xx).
  echo "$output" | grep -Eqi '^HTTP/[0-9.]+ 302'
  # And the challenge must be Cloudflare Access specifically, not any other redirect.
  echo "$output" | grep -Eqi '^location:[[:space:]]*https?://[^[:space:]]*cloudflareaccess\.com'
}
