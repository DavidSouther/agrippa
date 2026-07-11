#!/usr/bin/env bats
#
# Feature test for Feature flags (Flagsmith), Feature 7 of the local k3d project.
#
# Primary user story (Given / When / Then):
#   Given the bootstrapped long-lived `agrippa-dev` cluster with this Feature
#         flags content committed and reconciled by ArgoCD into the `platform`
#         layer -- the Flagsmith chart backed by the shared Postgres
#         `flagsmith` database/role, its sealed database-url/secret-key
#         credentials, and its HTTPRoute on the shared Gateway,
#   When an operator reaches https://flagsmith.127.0.0.1.nip.io/ through the
#        k3d `:443` host port-map, connects to the shared Postgres Cluster as
#        role `flagsmith` using the sealed `flagsmith-db` credential, and
#        requests the Flagsmith API's own DB-gated health endpoint,
#   Then the platform layer is Synced/Healthy, Flagsmith's frontend answers
#        through the shared Gateway, the sealed `flagsmith-db` credential
#        authenticates a real connection to the `flagsmith` database, and the
#        API's `/health` endpoint reports healthy -- proving it reached
#        Postgres using the sealed `flagsmith-database-url` credential --
#        proving the feature-flags contract end-to-end.
#
# NOTE on scope: Flagsmith's own chart has no sealed admin-login credential to
# assert against (its `api.bootstrap` initContainer only prints a one-time
# password-reset link to its own pod logs, per the chart's NOTES.txt -- there
# is no Secret holding it). The sealed credentials Feature 7 actually owns are
# the `flagsmith-db` CNPG role, `flagsmith-database-url`, and
# `flagsmith-secret-key` -- this suite proves those authenticate, in place of
# an admin-login round-trip.
#
# NOTE: this suite deliberately does NOT tear the cluster, ArgoCD, or
# Flagsmith itself down. All are long-lived and GitOps-managed; this suite
# only reads, so re-running it is safe.
#
# Run:  bats tests/feature-flags.bats
#
# Requires: bats-core, mise, curl, kubectl, and (for green) the running
# bootstrapped `agrippa-dev` cluster with the Feature flags `platform` content
# reconciled by ArgoCD.
#
# This suite polls the `platform` Application independently of
# tests/git-hosting.bats/auth.bats (Keycloak, Forgejo, and Flagsmith all live
# in that one layer) rather than sharing a helper across suites, matching
# this repo's existing convention of no cross-suite test helpers.
#
# FLAGSMITH_HOST overrides the target host so the same test could point at
# another dev nip.io host if this ever moves.

CTX="k3d-agrippa-dev"
NS="argocd"
FLAGSMITH_HOST="${FLAGSMITH_HOST:-flagsmith.127.0.0.1.nip.io}"
STORAGE_NS="storage"
PG_CLUSTER="postgres"
SLUG="flagsmith"

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

# The CNPG primary pod for the shared `postgres` Cluster (same cluster and
# label spelling tests/storage.bats already probes).
pg_primary_pod() {
  mise x kubectl -- kubectl --context "$CTX" -n "$STORAGE_NS" get pods \
    -l "cnpg.io/cluster=${PG_CLUSTER},cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

@test "Flagsmith serves the feature-flags contract: platform Synced/Healthy, reachable through the Gateway, and the sealed database credentials authenticate against Postgres and Flagsmith's own health API" {
  # THEN 0: ArgoCD has reconciled Feature flags into the platform layer.
  run wait_for_synced_healthy platform
  [ "$status" -eq 0 ]

  # THEN 1: Flagsmith's frontend answers through the shared Gateway at its
  # nip.io host. -k tolerates the local, deliberately-untrusted-by-design dev
  # CA.
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${FLAGSMITH_HOST}/"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(2[0-9][0-9]|3[0-9][0-9])$ ]]

  # THEN 2: the sealed `flagsmith-db` credential authenticates a real
  # connection to database `flagsmith` as role `flagsmith`, the same
  # CNPG-managed-role pattern tests/storage.bats proves for `smoke`. The
  # connection is over TCP (`-h 127.0.0.1`) on purpose: that exercises CNPG's
  # `host ... scram-sha-256` pg_hba rule so PGPASSWORD is actually verified,
  # rather than the unix-socket `local ... peer`/`trust` rule.
  pod="$(pg_primary_pod)"
  [ -n "$pod" ]
  pgpw="$(mise x kubectl -- kubectl --context "$CTX" -n "$STORAGE_NS" get secret "${SLUG}-db" \
    -o go-template='{{ index .data "password" | base64decode }}')"
  [ -n "$pgpw" ]
  run mise x kubectl -- kubectl --context "$CTX" -n "$STORAGE_NS" exec "$pod" -c postgres -- \
    env PGPASSWORD="$pgpw" psql -h 127.0.0.1 -U "$SLUG" -d "$SLUG" -tAc 'select current_database()'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$SLUG"* ]]

  # THEN 3: the API's own `/health` endpoint, routed by the HTTPRoute's
  # PathPrefix `/health` rule straight to flagsmith-api, reports healthy --
  # Flagsmith's own django-health-check view only reports healthy once it has
  # connected to Postgres, so a 200 here proves the sealed
  # `flagsmith-database-url` credential authenticates through Flagsmith's own
  # API, not just a direct psql connection.
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${FLAGSMITH_HOST}/health"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}
