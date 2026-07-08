#!/usr/bin/env bats
#
# Feature test for Feature flags (Flagsmith), roadmap item 7 / Feature 7 of the
# local k3d project. Flagsmith is a `platform`-layer, Postgres-backed service
# that CONSUMES two prior shared contracts: Storage's per-app DB/role naming
# (Feature 4) and Networking's Gateway/HTTPRoute/hostname/TLS (Feature 3).
#
# Primary user story (Given / When / Then):
#   Given the bootstrapped long-lived `agrippa-dev` cluster (Features 1-6) with
#         this Flagsmith content committed and reconciled by ArgoCD into the
#         `platform` layer -- the Flagsmith Helm release (`api` + `frontend`) in
#         the `flagsmith` namespace, wired via `databaseExternal` to the shared
#         CNPG `postgres` Cluster's own `flagsmith` database/role, its three
#         KSOPS-sealed credentials (flagsmith-db basic-auth, flagsmith-database-url
#         DSN, flagsmith-secret-key Django key), its `Database` CR, and its
#         hand-authored `HTTPRoute` at flagsmith.127.0.0.1.nip.io,
#   When an operator requests https://flagsmith.127.0.0.1.nip.io/ and .../health
#        through the k3d `:443` host port-map,
#   Then the admin UI is served through the shared Istio Gateway (host :443 -> k3d
#        loadbalancer -> node IP via the Service's externalIPs -> gateway pods ->
#        the `flagsmith` HTTPRoute -> the frontend/API Services), the response is a
#        live UI status (2xx/3xx, not a 404/connection failure), the TLS cert
#        presented is ISSUED BY THE LOCAL CA (CN=Agrippa Local Dev CA), and the API
#        /health endpoint returns 200 -- transitively proving the Django app is up
#        and its connection to the shared Postgres `flagsmith` database works.
#
# EXPECTED TO FAIL until Flagsmith lands the `platform/overlays/dev/flagsmith/`
# composition (the Helm release, the three sealed credentials, the Database CR, the
# HTTPRoute) plus the two shared-contract appends (the `flagsmith` managed.role +
# db secret in the storage layer, and flagsmith.127.0.0.1.nip.io on the shared
# Gateway cert's dnsNames) and ArgoCD reconciles it. Before that,
# `platform/overlays/dev` is `resources: [argocd.yaml]` only: the `platform`
# Application is already trivially Synced/Healthy (so THEN 0 passes even now,
# exactly as networking.bats/storage.bats' THEN 0 passed on their empty layers),
# and the shared Gateway is up (so the served cert's issuer is already the local
# CA), but no HTTPRoute claims the `flagsmith` host -- so `curl` to both `/` and
# `/health` returns 404. That red state defines "done" for this feature-step.
#
# This test deliberately does NOT assert a flag read or admin-credential auth: the
# admin password bootstrap is the chart's own manual browser password-reset-link
# flow (design decision 3), and coupling the test to that fragile, un-GitOps'd
# surface is out of scope (design decision 5). Gateway reachability + local-CA TLS
# + API /health-200 proves everything this feature-step lands.
#
# NOTE: this suite deliberately does NOT tear the cluster, the datastores, or
# Flagsmith down. All are long-lived and GitOps-managed; re-running is safe.
#
# Run:  bats tests/feature-flags.bats
#
# Requires: bats-core, curl, openssl, kubectl, and (for green) the running
# bootstrapped `agrippa-dev` cluster with the Flagsmith `platform` content
# reconciled by ArgoCD. The exact API health path (`/health` vs
# `/health/readiness/`, whichever the chart's readiness probe uses) is re-verified
# at build against the pinned chart; any difference is corrected there (this suite
# is RED until then regardless).
#
# FLAGSMITH_HOST overrides the target host so the same test could point at another
# dev nip.io host (e.g. a local k3d ingress) without editing the file.

CTX="k3d-agrippa-dev"
FLAGSMITH_HOST="${FLAGSMITH_HOST:-flagsmith.127.0.0.1.nip.io}"
# The API health endpoint, reached through the Gateway via the `flagsmith`
# HTTPRoute's `/health` -> API-Service rule. Returns 200 only when the Django app
# is up AND its shared-Postgres connection is live -- so it transitively proves
# the Storage DB-contract consumption without a separate DB check.
HEALTH_PATH="${FLAGSMITH_HEALTH_PATH:-/health}"
# The local CA's CommonName -- the cert-manager CA ClusterIssuer that signs every
# leaf cert on the platform (the shared Gateway cert included). Seeing this as the
# TLS issuer proves cert-manager wired the Gateway TLS, not Istio's default.
CA_CN="Agrippa Local Dev CA"

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  cd "$REPO_ROOT" || return 1
  # Trust the repo mise.toml so `mise run` is non-interactive (parity with the
  # sibling suites; this suite itself only needs curl + openssl + kubectl).
  mise trust >/dev/null 2>&1 || true
}

# Echoes "<sync> <health>" for the `platform` ArgoCD Application, e.g. "Synced Healthy".
platform_app_status() {
  kubectl --context "$CTX" -n argocd get application platform \
    -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null
}

# Waits up to ~5 min for the `platform` layer to reach Synced + Healthy. The
# Flagsmith Helm release, its DB migration/bootstrap, and the API pod's
# Postgres-gated readiness all happen inside this reconcile, so allow generous time.
wait_for_platform_synced_healthy() {
  for _ in $(seq 1 60); do
    if [ "$(platform_app_status)" = "Synced Healthy" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

@test "the shared Istio Gateway serves the Flagsmith admin UI over local-CA TLS and its API /health returns 200 (the feature-flags service, DB-backed)" {
  # THEN 0: ArgoCD has reconciled the Flagsmith content into the platform layer.
  # This is the GitOps precondition -- the Flagsmith release is Synced/Healthy
  # under the single `platform` Application (sync-wave 2). (Passes even on the
  # argocd-only placeholder; the RED baseline comes at THEN 1.)
  run wait_for_platform_synced_healthy
  [ "$status" -eq 0 ]

  # WHEN + THEN 1: the operator reaches the Flagsmith admin UI at its dev host
  # through the k3d loadbalancer port-map. `-k` tolerates the local CA that is
  # deliberately not in the host trust store. A live UI status (2xx or 3xx) --
  # NOT the 404 of the unrouted host (RED baseline) -- proves the request path
  # resolves: host :443 -> k3d port-map -> node IP (Service externalIPs) ->
  # gateway pods -> the `flagsmith` HTTPRoute `/` rule -> the frontend Service.
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://${FLAGSMITH_HOST}/"
  [ "$status" -eq 0 ]
  # `|| false` is load-bearing: bats-core (1.13) does NOT abort a test on a bare
  # mid-test `[[ ]]` that returns non-zero (only a `[ ]`/simple command or the
  # test's terminal command fails it) -- so without the guard a broken UI route
  # (a 404/5xx here) would be silently masked by the later passing assertions.
  # The `|| false` turns this into a simple-command failure that reliably aborts.
  [[ "$output" =~ ^(2[0-9][0-9]|3[0-9][0-9])$ ]] || false

  # THEN 2: TLS is terminated at the Gateway with a certificate ISSUED BY THE
  # LOCAL CA. Uses `openssl s_client | openssl x509 -noout -issuer` (not
  # `curl -kv | grep`) per the cleared networking.bats Q6 resolution: the
  # operator's system `curl` links LibreSSL, making `curl -v`'s cert dump a
  # brittle, backend-dependent interface for this assertion. Asserting the local
  # CA's CommonName proves cert-manager's SelfSigned->CA chain issued the cert
  # served for the flagsmith host's SNI (the TLS half of the shared contract).
  run bash -c "openssl s_client -connect 127.0.0.1:443 -servername '${FLAGSMITH_HOST}' </dev/null 2>/dev/null | openssl x509 -noout -issuer"
  [ "$status" -eq 0 ]
  # `|| false` for the same bats-core reason as THEN 1 above: guard the bare
  # `[[ ]]` so a wrong issuer reliably aborts rather than being masked.
  [[ "$output" == *"${CA_CN}"* ]] || false

  # THEN 3: the Flagsmith API health endpoint returns 200 through the same
  # Gateway (the `flagsmith` HTTPRoute's `/health` -> API-Service rule). A 200 --
  # NOT the 404 of the unrouted host (RED baseline) -- proves the Django API is
  # up AND its connection to the shared CNPG `flagsmith` database is live, since
  # Flagsmith's health/readiness check queries the DB. This is the assertion that
  # makes the test about the DB-backed SERVICE, not merely UI reachability, while
  # staying off the fragile admin-credential/flag-read surface (design decision 5).
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://${FLAGSMITH_HOST}${HEALTH_PATH}"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}
