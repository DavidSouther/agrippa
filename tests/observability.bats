#!/usr/bin/env bats
#
# Feature test for Observability (Grafana LGTM stack -- Loki, Grafana, Tempo,
# Mimir -- plus a Grafana Alloy DaemonSet), roadmap item 8 / Feature 8 of the
# local k3d project. This feature-step's own direct target is Closing Bell
# critical task 4: "Grafana at the dashboard dev host authenticates with the
# documented local dev credentials and renders a dashboard."
#
# Primary user story (Given / When / Then):
#   Given the bootstrapped long-lived `agrippa-dev` cluster (Features 1-7) with
#         this Observability content committed and reconciled by ArgoCD into the
#         `observability` layer -- Loki (monolithic), Tempo (monolithic), Mimir
#         (mimir-distributed at one replica per component), Grafana (embedded
#         SQLite on a local-path PVC), and an Alloy DaemonSet self-discovering the
#         cluster and forwarding metrics->Mimir, logs->Loki, traces->Tempo,
#   When an operator requests https://dashboard.davidsouther.com.127.0.0.1.nip.io/
#        through the k3d `:443` host port-map and signs in to Grafana with the
#        documented local dev credentials (admin/admin),
#   Then the `observability` layer is Synced/Healthy, an anonymous Grafana API
#        call is CHALLENGED (proving auth is enforced, not anonymous), the
#        documented credential AUTHENTICATES and the home dashboard renders
#        (/api/dashboards/home -> 200), and the three LGTM datasources (loki,
#        prometheus/Mimir, tempo) are PROVISIONED (/api/datasources -> 200
#        enumerating them) -- proving authenticate-and-render with real signal
#        sources behind it, the exact bar of Closing Bell critical task 4.
#
# The request path is host `:443` -> k3d loadbalancer port-map -> node IP via the
# shared Gateway's externalIPs -> gateway pods -> the `grafana` HTTPRoute -> the
# Grafana Service (plain HTTP :3000), TLS terminated at the gateway with the
# local-CA cert. `-k` tolerates the local CA that is deliberately not in the host
# trust store (research decision 3). This mirrors and sharpens the dev-path
# Grafana assertion in the gestalt `tests/agrippa.bats` (which sends admin:admin
# to /api/dashboards/home and asserts 200), scoped to this feature-step's layer.
#
# EXPECTED TO FAIL until Observability lands the `observability/overlays/dev`
# composition (the five charts, the datasource provisioning, the admin/admin dev
# credential, the `grafana` HTTPRoute, and the appended Gateway-cert SAN) and
# ArgoCD reconciles it. Before that, `observability/overlays/dev` is the empty
# `resources: []` placeholder: the `observability` Application is already
# trivially Synced/Healthy (so THEN 0 passes even now, exactly as storage.bats'
# and networking.bats' THEN 0 passed on their empty layers), but no
# `observability` namespace and no Grafana route/backend exist -- so the shared
# Istio Gateway answers every Grafana probe with 404 (no route matched), and the
# suite fails at the first Grafana probe (THEN 1). That red state defines "done"
# for this feature-step.
#
# NOTE: this suite deliberately does NOT tear the cluster, the datastores, or the
# observability stack down. All are long-lived and GitOps-managed: ArgoCD's
# prune/selfHeal would re-create anything torn down. Re-running is safe.
#
# Run:  bats tests/observability.bats
#
# Requires: bats-core, curl, kubectl, and (for green) the running bootstrapped
# `agrippa-dev` cluster with the Observability `observability` content reconciled
# by ArgoCD. The build phase re-verifies the Grafana Service name/port, the LGTM
# store Service names/ports, and the chart pins against the pinned versions; this
# suite is RED until then regardless.

CTX="k3d-agrippa-dev"

# The Grafana dev host: the parent design's resolved `<prod-host>.127.0.0.1.nip.io`
# scheme applied to the `dashboard.davidsouther.com` prod host (parent design
# resolved decision 6; tests/agrippa.bats DASHBOARD_HOST). Overridable so the same
# suite can point at another local ingress.
DASHBOARD_HOST="${DASHBOARD_HOST:-dashboard.davidsouther.com.127.0.0.1.nip.io}"

# Local-only Grafana credentials for the dev path -- Grafana's documented
# defaults, which the dev overlay sets EXPLICITLY (the chart's own default is a
# random 40-char password). These must NEVER be valid in production.
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"

setup() {
  # Run from the repo root (standard bats hygiene); the assertions drive curl
  # through the k3d :443 port-map and kubectl against the long-lived cluster.
  cd "$(dirname "$BATS_TEST_FILENAME")/.." || return 1
}

# Echoes "<sync> <health>" for the `observability` ArgoCD Application, e.g.
# "Synced Healthy".
observability_app_status() {
  kubectl --context "$CTX" -n argocd get application observability \
    -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null
}

# Waits up to ~5 min for the `observability` layer to reach Synced + Healthy. The
# five charts' first reconcile (Mimir's ~10 pods + bundled minio are the
# slowest) happens inside this window, so allow generous time -- matching
# storage.bats.
wait_for_observability_synced_healthy() {
  for _ in $(seq 1 60); do
    if [ "$(observability_app_status)" = "Synced Healthy" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

@test "Grafana authenticates with the documented dev credentials and renders a dashboard with the LGTM datasources behind it (Closing Bell task 4)" {
  # THEN 0: ArgoCD has reconciled the Observability content into the observability
  # layer. This is the GitOps precondition -- the five charts are Synced/Healthy
  # under the single `observability` Application (sync-wave 3). (Passes even on the
  # empty placeholder; the RED baseline comes at THEN 1.)
  run wait_for_observability_synced_healthy
  [ "$status" -eq 0 ]

  # THEN 1: an ANONYMOUS request to a protected Grafana API is challenged with 401
  # through the shared Gateway at the dev host. This proves (a) the whole request
  # path resolves to a real Grafana (host :443 -> k3d port-map -> node IP -> gateway
  # pods -> the `grafana` HTTPRoute -> the Grafana Service) -- NOT the 404 the empty
  # placeholder's routeless Gateway returns -- and (b) Grafana enforces auth (it is
  # not serving anonymously), so THEN 2's 200 is genuinely earned by the credential.
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    "https://${DASHBOARD_HOST}/api/dashboards/home"
  [ "$status" -eq 0 ]
  [ "$output" = "401" ]

  # THEN 2: the documented local dev credentials (admin/admin) AUTHENTICATE and the
  # home dashboard renders -- /api/dashboards/home returns 200 for the authenticated
  # operator. This is the exact bar of Closing Bell critical task 4 ("authenticates
  # with the documented local dev credentials and renders a dashboard"), and mirrors
  # the gestalt tests/agrippa.bats dev-path assertion.
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
    "https://${DASHBOARD_HOST}/api/dashboards/home"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  # THEN 3: the three LGTM datasources are PROVISIONED in Grafana -- an
  # authenticated GET /api/datasources returns 200 and enumerates a `loki` source, a
  # `prometheus` source (Mimir speaks PromQL), and a `tempo` source. This is the
  # "shows the platform is healthy" half of task 4: a dashboard renders health only
  # if it has real signal stores wired behind it (the Alloy -> Loki/Mimir/Tempo ->
  # Grafana pipeline), so asserting the datasources exist proves the stack is wired
  # end-to-end, not merely that Grafana logs in. Checks provisioning (datasource
  # objects exist), not live query success, to stay robust to store warm-up timing.
  run curl -k -sS -w '\n%{http_code}' --max-time 10 \
    -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
    "https://${DASHBOARD_HOST}/api/datasources"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n'200 ]]
  [[ "$output" == *'"type":"loki"'* ]]
  [[ "$output" == *'"type":"prometheus"'* ]]
  [[ "$output" == *'"type":"tempo"'* ]]
}
