#!/usr/bin/env bats
#
# Feature test for Git hosting (Forgejo), Feature 6 of the local k3d project.
#
# Primary user story (Given / When / Then):
#   Given the bootstrapped long-lived `agrippa-dev` cluster with this Git hosting
#         content committed and reconciled by ArgoCD into the `platform` layer --
#         the Forgejo chart backed by the shared Postgres `forgejo` database, its
#         sealed admin credential, and its HTTPRoute on the shared Gateway,
#   When an operator reaches https://git.davidsouther.com.127.0.0.1.nip.io/
#        through the k3d `:443` host port-map, authenticates against Forgejo's
#        REST API with the sealed admin credential, and creates a repository
#        through that API,
#   Then the platform layer is Synced/Healthy, Forgejo answers through the shared
#        Gateway, the admin credential authenticates against `/api/v1/user` (200,
#        not 401), and a repository created through the API round-trips on a
#        follow-up GET -- proving the git-hosting contract end-to-end at the API
#        level.
#
# NOTE on scope: this suite proves repository create/read/delete through
# Forgejo's REST API, not a full `git clone`/`push`/`pull` over the git wire
# protocol. The API-level round-trip is the practical proxy for "a pushed
# repository serves its content back" -- a real git-protocol probe would need
# its own throwaway SSH/HTTPS client identity and is heavier than this suite
# takes on.
#
# NOTE: this suite deliberately does NOT tear the cluster, ArgoCD, or Forgejo
# itself down. All are long-lived and GitOps-managed. It DOES delete the
# throwaway repo it creates, and defensively pre-cleans before creating, so
# re-running this suite is safe (idempotent) even after a prior failed run.
#
# Run:  bats tests/git-hosting.bats
#
# Requires: bats-core, mise, curl, kubectl, and (for green) the running
# bootstrapped `agrippa-dev` cluster with the Git hosting `platform` content
# reconciled by ArgoCD.
#
# GIT_HOST overrides the target host so the same test could point at another
# dev nip.io host if this ever moves.

CTX="k3d-agrippa-dev"
NS="argocd"
GIT_HOST="${GIT_HOST:-git.davidsouther.com.127.0.0.1.nip.io}"
FORGEJO_NS="forgejo"
PROBE_REPO="agrippa-bats-probe"

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

@test "Forgejo serves the git-hosting contract: platform Synced/Healthy, reachable through the Gateway, admin auth, and an API-created repo round-trips" {
  # THEN 0: ArgoCD has reconciled Git hosting into the platform layer.
  run wait_for_synced_healthy platform
  [ "$status" -eq 0 ]

  # THEN 1: Forgejo answers through the shared Gateway at its nip.io host. -k
  # tolerates the local, deliberately-untrusted-by-design dev CA.
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${GIT_HOST}/"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(2[0-9][0-9]|3[0-9][0-9])$ ]]

  # THEN 2: the sealed forgejo-admin credential authenticates against Forgejo's
  # REST API. Keys are literally `username`/`password` -- confirmed against
  # platform/overlays/dev/forgejo/chart/kustomization.yaml's own comment on
  # admin.existingSecret's expected shape. Read live via kubectl's go-template
  # base64decode (portable across the GNU/BSD `base64 -d`/`-D` split) -- never
  # decrypted from the sops-encrypted source file.
  admin_user="$(mise x kubectl -- kubectl --context "$CTX" -n "$FORGEJO_NS" get secret forgejo-admin \
    -o go-template='{{ index .data "username" | base64decode }}')"
  admin_pass="$(mise x kubectl -- kubectl --context "$CTX" -n "$FORGEJO_NS" get secret forgejo-admin \
    -o go-template='{{ index .data "password" | base64decode }}')"
  [ -n "$admin_user" ]
  [ -n "$admin_pass" ]

  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -u "${admin_user}:${admin_pass}" "https://${GIT_HOST}/api/v1/user"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  # THEN 3: a repository created through the REST API as the admin user
  # round-trips on a follow-up GET -- the API-level proxy for "a pushed
  # repository serves its content back" (see the header NOTE on scope).
  # Defensive pre-clean: a prior run that failed between create and delete
  # would otherwise make this create 409 Conflict instead of 201.
  curl -k -sS -o /dev/null --max-time 10 -u "${admin_user}:${admin_pass}" \
    -X DELETE "https://${GIT_HOST}/api/v1/repos/${admin_user}/${PROBE_REPO}" || true

  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -u "${admin_user}:${admin_pass}" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${PROBE_REPO}\",\"auto_init\":true,\"private\":true}" \
    "https://${GIT_HOST}/api/v1/user/repos"
  [ "$status" -eq 0 ]
  [ "$output" = "201" ]

  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -u "${admin_user}:${admin_pass}" \
    "https://${GIT_HOST}/api/v1/repos/${admin_user}/${PROBE_REPO}"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  # Clean up the throwaway repo so re-runs are idempotent.
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -u "${admin_user}:${admin_pass}" -X DELETE \
    "https://${GIT_HOST}/api/v1/repos/${admin_user}/${PROBE_REPO}"
  [ "$status" -eq 0 ]
  [ "$output" = "204" ]
}
