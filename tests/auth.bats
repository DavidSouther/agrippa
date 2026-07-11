#!/usr/bin/env bats
#
# Feature test for Auth (Keycloak), Feature 5 of the local k3d project.
#
# Primary user story (Given / When / Then):
#   Given the bootstrapped long-lived `agrippa-dev` cluster with this Auth
#         content committed and reconciled by ArgoCD into the `platform` layer --
#         the Keycloak Operator, the DB-backed Keycloak CR, its bootstrap admin
#         credential, its HTTPRoute on the shared Gateway, and the `agrippa`
#         realm import,
#   When an operator reaches https://auth.127.0.0.1.nip.io/ through the k3d
#        `:443` host port-map, obtains an admin token from Keycloak's own token
#        endpoint using the bootstrap admin credential, and requests the
#        `agrippa` realm's public discovery document,
#   Then the platform layer is Synced/Healthy, Keycloak answers through the
#        shared Gateway, the bootstrap admin credential exchanges for a real
#        access token, and the `agrippa` realm import has landed and is publicly
#        discoverable -- proving the auth contract end-to-end.
#
# NOTE: this suite deliberately does NOT tear the cluster, ArgoCD, or Keycloak
# down. All are long-lived and GitOps-managed; this suite only reads, so
# re-running it is safe.
#
# Run:  bats tests/auth.bats
#
# Requires: bats-core, mise, curl, jq, kubectl, and (for green) the running
# bootstrapped `agrippa-dev` cluster with the Auth `platform` content reconciled
# by ArgoCD.
#
# This suite polls the `platform` Application independently of
# tests/git-hosting.bats (both Keycloak and Forgejo live in that one layer)
# rather than sharing a helper across suites, matching this repo's existing
# convention of no cross-suite test helpers.
#
# AUTH_HOST overrides the target host so the same test could point at another
# dev nip.io host if this ever moves.

CTX="k3d-agrippa-dev"
NS="argocd"
AUTH_HOST="${AUTH_HOST:-auth.127.0.0.1.nip.io}"
KEYCLOAK_NS="keycloak"
REALM="agrippa"

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

@test "Keycloak serves the auth contract: platform Synced/Healthy, reachable through the Gateway, admin token exchange, and the agrippa realm import" {
  # THEN 0: ArgoCD has reconciled Auth into the platform layer.
  run wait_for_synced_healthy platform
  [ "$status" -eq 0 ]

  # THEN 1: Keycloak answers through the shared Gateway at its nip.io host. -k
  # tolerates the local, deliberately-untrusted-by-design dev CA.
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${AUTH_HOST}/"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(2[0-9][0-9]|3[0-9][0-9])$ ]]

  # THEN 2: the sealed keycloak-admin bootstrap credential exchanges for a real
  # access token against Keycloak's own token endpoint. Keys are literally
  # `username`/`password` -- confirmed against
  # secrets/dev/platform/keycloak/README.md's own `kubectl create secret
  # generic keycloak-admin --from-literal=username=... --from-literal=password=...`
  # regeneration recipe, which is the Keycloak Operator's own
  # bootstrapAdmin.user.secret shape. Read live via kubectl's go-template
  # base64decode (portable across the GNU/BSD `base64 -d`/`-D` split) -- never
  # decrypted from the sops-encrypted source file.
  admin_user="$(mise x kubectl -- kubectl --context "$CTX" -n "$KEYCLOAK_NS" get secret keycloak-admin \
    -o go-template='{{ index .data "username" | base64decode }}')"
  admin_pass="$(mise x kubectl -- kubectl --context "$CTX" -n "$KEYCLOAK_NS" get secret keycloak-admin \
    -o go-template='{{ index .data "password" | base64decode }}')"
  [ -n "$admin_user" ]
  [ -n "$admin_pass" ]

  run curl -k -sS --max-time 10 \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=${admin_user}" \
    --data-urlencode "password=${admin_pass}" \
    "https://${AUTH_HOST}/realms/master/protocol/openid-connect/token"
  [ "$status" -eq 0 ]
  token="$(echo "$output" | mise x jq -- jq -r '.access_token // empty')"
  [ -n "$token" ]

  # THEN 3: the agrippa realm import has landed and is publicly discoverable --
  # the unauthenticated realm-info endpoint returns 200 with that realm's own
  # public discovery document.
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${AUTH_HOST}/realms/${REALM}"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
}
