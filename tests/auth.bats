#!/usr/bin/env bats
#
# Feature test for Auth (Keycloak via the Keycloak Operator), roadmap item 5 /
# Feature 5 of the local k3d project. This feature-step is a PURE CONSUMER of two
# already-landed shared contracts -- Storage's (Feature 4: per-app DB/role naming,
# the managed.roles[] append + Database CR + sealed credential) and Networking's
# (Feature 3: the shared Gateway/HTTPRoute/hostname/TLS scheme). It defines no
# shared contract of its own.
#
# Primary user story (Given / When / Then):
#   Given the bootstrapped long-lived `agrippa-dev` cluster (Features 1-4) with this
#         Auth content committed and reconciled by ArgoCD into the `platform` layer
#         -- the Keycloak Operator in the `keycloak` namespace, the `Keycloak` CR
#         `keycloak` wired to the shared `postgres` Cluster over its plain-HTTP
#         listener, the `keycloak` `Database` CR in the `storage` namespace, and the
#         declaratively-imported minimal `agrippa` dev realm,
#   When an operator requests the `agrippa` realm's OIDC discovery document at
#        https://auth.127.0.0.1.nip.io/realms/agrippa/.well-known/openid-configuration
#        through the k3d `:443` host port-map,
#   Then the `platform` Application is Synced/Healthy, the `Keycloak` CR reports Ready
#        and the `KeycloakRealmImport` reports done, the `keycloak` `Database` CR (in
#        `storage`) is applied, the discovery endpoint returns 200 with `issuer`
#        https://auth.127.0.0.1.nip.io/realms/agrippa (proving the realm was imported,
#        persisted in Postgres, and served correctly behind the reverse-proxying
#        Gateway), and the TLS certificate presented is ISSUED BY THE LOCAL CA
#        (CN=Agrippa Local Dev CA), not the Operator's built-in default -- proving the
#        Operator + external-Postgres + declarative-realm-import + shared-Gateway/
#        HTTPRoute/local-CA-TLS path end-to-end.
#
# EXPECTED TO FAIL until Auth lands the `platform/overlays/dev/keycloak` composition
# (the Keycloak Operator + CRDs, the `Keycloak` CR, the `keycloak` `Database` CR in
# `storage`, the `KeycloakRealmImport`, the two sealed credentials, the HTTPRoute, and
# the `auth.127.0.0.1.nip.io` append to the shared Gateway cert's dnsNames) and ArgoCD
# reconciles it. Before that, `platform/overlays/dev` carries only `argocd.yaml`: the
# `platform` Application is already trivially Synced/Healthy (so THEN 0 passes even
# now, exactly as storage.bats' / networking.bats' THEN 0 passed on their empty
# layers), but the `keycloak` namespace, the Keycloak CRDs, the CRs, and the
# `auth.127.0.0.1.nip.io` route all do not exist -- so the suite fails at THEN 1. That
# red state defines "done" for this feature-step.
#
# NOTE: this suite deliberately does NOT tear the cluster, Keycloak, or the realm
# down. All are long-lived and GitOps-managed: ArgoCD's prune/selfHeal re-creates
# anything torn down, so the `agrippa` realm is a PERMANENT declarative health-check
# target, not a throwaway. Re-running is safe.
#
# Run:  bats tests/auth.bats
#
# Requires: bats-core, curl, openssl, kubectl, and (for green) the running
# bootstrapped `agrippa-dev` cluster with the Auth `platform` content reconciled by
# ArgoCD. The build phase re-verifies the Keycloak CR/RealmImport status-condition
# spellings and the discovery-endpoint path against the pinned Operator version; any
# that differ are corrected there (this suite is RED until then regardless).
#
# GW_HOST overrides the target host so the same test could point at another dev
# nip.io host; REALM overrides the imported dev realm id.

CTX="k3d-agrippa-dev"
NS="keycloak"
STORAGE_NS="storage"
KC_CR="keycloak"
REALM="${REALM:-agrippa}"
GW_HOST="${GW_HOST:-auth.127.0.0.1.nip.io}"
# The local CA's CommonName -- the cert-manager CA ClusterIssuer (`agrippa-ca`) that
# signs every leaf cert on the platform, the shared Gateway cert included. Seeing
# this as the TLS issuer proves cert-manager wired the Gateway TLS for this host, not
# Keycloak's / Istio's built-in default.
CA_CN="Agrippa Local Dev CA"

setup() {
  # Run from the repo root (standard bats hygiene); the assertions themselves drive
  # kubectl/curl against the long-lived cluster and read no committed files.
  cd "$(dirname "$BATS_TEST_FILENAME")/.." || return 1
}

# Echoes "<sync> <health>" for the `platform` ArgoCD Application, e.g. "Synced Healthy".
platform_app_status() {
  kubectl --context "$CTX" -n argocd get application platform \
    -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null
}

# Waits up to ~5 min for the `platform` layer to reach Synced + Healthy. The Keycloak
# Operator install, the `Keycloak` CR's DB bootstrap, and the realm import all happen
# inside this reconcile, so allow generous time.
wait_for_platform_synced_healthy() {
  for _ in $(seq 1 60); do
    if [ "$(platform_app_status)" = "Synced Healthy" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

@test "Keycloak serves its declaratively-imported realm's OIDC discovery through the shared Gateway over local-CA TLS, Postgres-backed" {
  # THEN 0: ArgoCD has reconciled the Auth content into the platform layer. This is
  # the GitOps precondition -- the Operator, the `Keycloak` CR, the realm import, and
  # the HTTPRoute are Synced/Healthy under the single `platform` Application
  # (sync-wave 2). (Passes even on the argocd.yaml-only placeholder; the RED baseline
  # comes at THEN 1.)
  run wait_for_platform_synced_healthy
  [ "$status" -eq 0 ]

  # THEN 1: the `Keycloak` CR is Ready -- the Operator has stood up Keycloak connected
  # to the external shared Postgres (not the bundled dev H2). CNPG's `keycloak` role
  # (a managed.roles[] append) and the `keycloak` database (a Database CR) are what
  # this readiness rests on. (Condition type/status spelling re-verified at build
  # against the pinned Operator.)
  run kubectl --context "$CTX" -n "$NS" get keycloak "$KC_CR" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]

  # THEN 2: the `KeycloakRealmImport` for the `agrippa` realm reports done -- the
  # declarative, continuously-reconciled realm bootstrap (not an imperative
  # first-boot `--import-realm`) has landed the realm. (Condition type/status spelling
  # re-verified at build.)
  run kubectl --context "$CTX" -n "$NS" get keycloakrealmimport "$REALM" \
    -o jsonpath='{.status.conditions[?(@.type=="Done")].status}'
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]

  # THEN 3: the `keycloak` Database CR has been reconciled by CNPG -- proving the
  # Storage consumption contract (a per-app Database CR + managed.roles[] append)
  # provisioned Keycloak's database in the shared instance. NOTE: authored in this
  # feature's own tree but carrying metadata.namespace: storage, because CNPG's
  # Database.spec.cluster is a same-namespace-only LocalObjectReference (issue #6043).
  run kubectl --context "$CTX" -n "$STORAGE_NS" get database.postgresql.cnpg.io "$KC_CR" \
    -o jsonpath='{.status.applied}'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  # WHEN + THEN 4: the operator reaches the `agrippa` realm's OIDC discovery document
  # through the shared Gateway at the Keycloak dev host, via the k3d loadbalancer
  # port-map. `-k` tolerates the local CA that is deliberately not host-trusted. A 200
  # -- NOT a 404 (realm not imported) and NOT a connection failure (nothing routed) --
  # proves the whole request path AND that the realm exists and is DB-persisted: host
  # :443 -> k3d port-map -> node IP -> gateway pods -> the `keycloak` HTTPRoute ->
  # keycloak-service:8080 -> Keycloak -> the imported realm's data in Postgres.
  disco="https://${GW_HOST}/realms/${REALM}/.well-known/openid-configuration"
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 15 "$disco"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  # THEN 5: the discovery document's `issuer` is the external dev host URL, not
  # Keycloak's internal Service address -- proving spec.hostname/spec.proxy are wired
  # correctly so Keycloak's self-generated issuer/redirect URLs are right behind the
  # reverse-proxying Gateway (a bad proxy config yields an http:// or Service-host
  # issuer that would break every downstream OIDC client's redirect flow).
  run curl -k -sS --max-time 15 "$disco"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"issuer\":\"https://${GW_HOST}/realms/${REALM}\""* ]]

  # THEN 6: TLS is terminated at the Gateway with a certificate ISSUED BY THE LOCAL
  # CA. Uses `openssl s_client | openssl x509 -noout -issuer` rather than `curl -kv |
  # grep`, per networking.bats' cleared convention: the operator's system `curl` links
  # LibreSSL, making `curl -v`'s cert dump a brittle, backend-dependent interface.
  # `curl -k` (THEN 4/5) stays the reachability check; asserting the local CA's
  # CommonName here proves cert-manager's SelfSigned->CA chain issued the Gateway cert
  # for this host (the appended `auth.127.0.0.1.nip.io` dnsNames SAN), not a built-in
  # default.
  run bash -c "openssl s_client -connect 127.0.0.1:443 -servername '${GW_HOST}' </dev/null 2>/dev/null | openssl x509 -noout -issuer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${CA_CN}"* ]]
}
