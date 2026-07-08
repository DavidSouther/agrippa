#!/usr/bin/env bats
#
# Feature test for Storage (Postgres via CloudNativePG + Valkey), roadmap item 5 /
# Feature 4 of the local k3d project. This feature-step DEFINES the storage-class +
# per-app DB/role naming shared contract Features 5-8 (Auth/Keycloak, Git
# hosting/Forgejo, Feature flags/Flagsmith, Observability/LGTM) each consume.
#
# Primary user story (Given / When / Then):
#   Given the bootstrapped long-lived `agrippa-dev` cluster (Features 1-2) with this
#         Storage content committed and reconciled by ArgoCD into the `storage`
#         layer -- the CloudNativePG operator, the single shared Postgres `Cluster`
#         named `postgres` on the `local-path` storage class, the shared standalone
#         Valkey instance, and the PERMANENT `smoke` fixture (a Postgres database
#         `smoke` owned by role `smoke`, and a Valkey ACL user `smoke` scoped to
#         `~smoke:*`) standing in for a future per-app consumer,
#   When an operator connects to database `smoke` as role `smoke` using the
#        sops-encrypted credential (decrypted by KSOPS into the `storage`
#        namespace), and authenticates to Valkey as ACL user `smoke`,
#   Then the shared Postgres instance is Healthy on a local-path PVC, the `smoke`
#        database exists and is owned by role `smoke` with the committed credential
#        working (proving the Database CR + managed role + KSOPS credential path
#        end-to-end), and the Valkey `smoke` user can write within `~smoke:*` but is
#        denied outside it (proving the recommended per-app ACL isolation) -- the
#        storage-class + per-app DB/role naming shared contract, proven end-to-end.
#
# EXPECTED TO FAIL until Storage lands the `storage/overlays/dev` composition (the
# CNPG operator, the shared `postgres` Cluster, the shared Valkey instance, the
# permanent `smoke` fixture, and its sops-encrypted credentials) and ArgoCD
# reconciles it. Before that, `storage/overlays/dev` is the empty `resources: []`
# placeholder: the `storage` Application is already trivially Synced/Healthy (so
# THEN 0 passes even now, exactly as networking.bats' THEN 0 passed on empty
# `core`), but no CNPG CRDs, no `storage` namespace, and no `postgres` Cluster
# exist -- so the suite fails at THEN 1. That red state defines "done" for this
# feature-step.
#
# NOTE: this suite deliberately does NOT tear the cluster, the datastores, or the
# `smoke` fixture down. All are long-lived and GitOps-managed: ArgoCD's
# prune/selfHeal would re-create anything torn down, so the `smoke` fixture is a
# PERMANENT declarative health-check target, not a throwaway. Re-running is safe.
#
# Run:  bats tests/storage.bats
#
# Requires: bats-core, kubectl, and (for green) the running bootstrapped
# `agrippa-dev` cluster with the Storage `storage` content reconciled by ArgoCD.
# `psql`/`valkey-cli` run INSIDE the cluster (kubectl exec into the datastore
# pods) -- no host database tooling is needed. The build phase re-verifies the
# CNPG label keys and the Valkey pod label/CLI flags against the pinned versions;
# any that differ are corrected there (this suite is RED until then regardless).

CTX="k3d-agrippa-dev"
NS="storage"
PG_CLUSTER="postgres"
SLUG="smoke"

setup() {
  # Run from the repo root (standard bats hygiene); the assertions themselves
  # drive kubectl against the long-lived cluster and read no committed files.
  cd "$(dirname "$BATS_TEST_FILENAME")/.." || return 1
}

# Echoes "<sync> <health>" for the `storage` ArgoCD Application, e.g. "Synced Healthy".
storage_app_status() {
  kubectl --context "$CTX" -n argocd get application storage \
    -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null
}

# Waits up to ~5 min for the `storage` layer to reach Synced + Healthy. The CNPG
# operator, the shared Cluster's bootstrap, and the Valkey release all happen
# inside this reconcile, so allow generous time.
wait_for_storage_synced_healthy() {
  for _ in $(seq 1 60); do
    if [ "$(storage_app_status)" = "Synced Healthy" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# The CNPG primary pod for the shared `postgres` Cluster (label spelling
# re-verified at build against the pinned CNPG version).
pg_primary_pod() {
  kubectl --context "$CTX" -n "$NS" get pods \
    -l "cnpg.io/cluster=${PG_CLUSTER},cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# The shared Valkey pod (label spelling re-verified at build against the pinned
# chart).
valkey_pod() {
  kubectl --context "$CTX" -n "$NS" get pods \
    -l "app.kubernetes.io/name=valkey" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

@test "the shared Postgres + Valkey serve an isolated, sops-credentialed per-app database and ACL user (the storage contract)" {
  # THEN 0: ArgoCD has reconciled the Storage content into the storage layer. This
  # is the GitOps precondition -- the CNPG operator, the shared Cluster, and the
  # Valkey instance are Synced/Healthy under the single `storage` Application
  # (sync-wave 1). (Passes even on the empty placeholder; the RED baseline comes
  # at THEN 1.)
  run wait_for_storage_synced_healthy
  [ "$status" -eq 0 ]

  # THEN 1: the single shared Postgres Cluster `postgres` is Healthy, on a
  # local-path-backed PVC -- the storage-class half of the shared contract. CNPG's
  # healthy phase string contains "healthy" (exact phrasing re-verified at build).
  run kubectl --context "$CTX" -n "$NS" get cluster.postgresql.cnpg.io "$PG_CLUSTER" \
    -o jsonpath='{.status.phase}'
  [ "$status" -eq 0 ]
  [[ "$output" == *healthy* ]]
  run kubectl --context "$CTX" -n "$NS" get pvc \
    -l "cnpg.io/cluster=${PG_CLUSTER}" \
    -o jsonpath='{.items[0].spec.storageClassName}'
  [ "$status" -eq 0 ]
  [ "$output" = "local-path" ]

  # THEN 2: the `smoke` Database CR has been reconciled by the operator -- its
  # database exists in the shared instance. This is the declarative per-app
  # provisioning mechanism the contract is built on (a Database CR per consumer).
  run kubectl --context "$CTX" -n "$NS" get database.postgresql.cnpg.io "$SLUG" \
    -o jsonpath='{.status.applied}'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  # THEN 3: a client connects to database `smoke` as role `smoke` using the
  # committed, sops-encrypted credential -- decrypted by KSOPS into the storage
  # namespace Secret `smoke-db` and applied to the role by CNPG's managed.roles
  # reconcile. This proves the whole credential path end-to-end: sops -> KSOPS ->
  # Secret -> managed role -> a real password-authenticated connection to the
  # isolated database. The connection is over TCP (`-h 127.0.0.1`) on purpose:
  # that exercises CNPG's `host ... scram-sha-256` pg_hba rule so PGPASSWORD is
  # actually verified. A local unix-socket connection would instead hit the
  # `local ... peer`/`trust` rule and prove nothing about the credential.
  pod="$(pg_primary_pod)"
  [ -n "$pod" ]
  pgpw="$(kubectl --context "$CTX" -n "$NS" get secret "${SLUG}-db" \
    -o go-template='{{ index .data "password" | base64decode }}')"
  [ -n "$pgpw" ]
  run kubectl --context "$CTX" -n "$NS" exec "$pod" -c postgres -- \
    env PGPASSWORD="$pgpw" psql -h 127.0.0.1 -U "$SLUG" -d "$SLUG" -tAc 'select current_database()'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$SLUG"* ]]

  # THEN 4: the shared Valkey instance authenticates ACL user `smoke` and scopes it
  # to `~smoke:*` -- a write inside its own key-prefix succeeds, a write outside it
  # is denied (NOPERM). This proves the recommended per-app Valkey ACL isolation
  # extension of the contract: a real AUTH with the committed credential, not a
  # mere existence check.
  vpod="$(valkey_pod)"
  [ -n "$vpod" ]
  vkpw="$(kubectl --context "$CTX" -n "$NS" get secret "${SLUG}-valkey" \
    -o go-template="{{ index .data \"${SLUG}\" | base64decode }}")"
  [ -n "$vkpw" ]
  run kubectl --context "$CTX" -n "$NS" exec "$vpod" -- \
    valkey-cli --no-auth-warning --user "$SLUG" -a "$vkpw" set "${SLUG}:probe" ok
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
  run kubectl --context "$CTX" -n "$NS" exec "$vpod" -- \
    valkey-cli --no-auth-warning --user "$SLUG" -a "$vkpw" set "other:probe" nope
  [[ "$output" == *NOPERM* ]]
}
