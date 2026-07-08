#!/usr/bin/env bats
#
# Feature test for Git hosting (Forgejo server, Postgres-backed), roadmap item 6 /
# Feature 6 of the local k3d project. This feature-step lands the Forgejo SERVER
# only; forgejo-runner / Actions / CI is a DEFERRED, documented follow-up
# increment (cleared research reviewer item 1) and is deliberately NOT asserted
# here.
#
# Primary user story (Given / When / Then):
#   Given the bootstrapped long-lived `agrippa-dev` cluster (Features 1-4) with
#         this Forgejo content committed and reconciled by ArgoCD into the
#         `platform` layer -- the Forgejo server backed by the shared `postgres`
#         Cluster's `forgejo` database/role (the storage contract), its sealed
#         initial admin credential (KSOPS-decrypted into the `forgejo` namespace),
#         and its `HTTPRoute` at git.davidsouther.com.127.0.0.1.nip.io on the
#         shared Istio Gateway (the networking contract),
#   When an operator reaches Forgejo's API through the shared Gateway,
#        authenticates with the sealed admin credential, and creates and pushes to
#        a repository,
#   Then the `platform` Application is Synced/Healthy, Forgejo's API answers
#        through the Gateway over a certificate ISSUED BY THE LOCAL CA (CN=Agrippa
#        Local Dev CA), the authenticated admin call succeeds (proving the sealed
#        credential + the Postgres-backed user store), and a newly created
#        repository accepts a `git push` and serves the pushed commit back --
#        proving Git hosting is live and usable end-to-end. NO runner/Actions/CI
#        assertion (deferred).
#
# EXPECTED TO FAIL until Git hosting lands the `platform/overlays/dev/forgejo`
# composition (the official Forgejo Helm chart against the shared `postgres`
# Cluster's `forgejo` database/role, the sealed admin + DB credentials, and the
# HTTPRoute + Gateway-cert SAN append) and ArgoCD reconciles it. Before that,
# `platform/overlays/dev` carries only `argocd.yaml`: the `platform` Application
# is already trivially Synced/Healthy (so THEN 0 passes even now, exactly as
# networking.bats' THEN 0 passed on empty `core` and storage.bats' on empty
# `storage`), but no `forgejo` namespace exists and nothing listens at the git
# dev host -- so the suite fails at THEN 1. That red state defines "done" for this
# feature-step.
#
# NOTE: this suite deliberately does NOT tear the cluster, Forgejo, or its
# datastore down. All are long-lived and GitOps-managed: ArgoCD's prune/selfHeal
# would re-create anything torn down. The throwaway PROBE REPOSITORY the test
# creates is runtime data (rows in Postgres + objects on the PVC), NOT a
# declarative resource, so creating and deleting it does not fight the reconciler;
# it is cleaned up at the end of the test and defensively in teardown. Re-running
# is safe.
#
# Run:  bats tests/git-hosting.bats
#
# Requires: bats-core, curl, git, openssl, kubectl, and (for green) the running
# bootstrapped `agrippa-dev` cluster with the Forgejo `platform` content
# reconciled by ArgoCD. The build phase re-verifies the Forgejo API paths, the
# admin-Secret key names, and the chart's Service/pod labels against the pinned
# chart version; any that differ are corrected there (this suite is RED until then
# regardless).
#
# GIT_HOST overrides the target host so the same test could point at another dev
# nip.io host. Credentials are read from the in-cluster KSOPS-decrypted Secret, so
# the test needs no committed plaintext.

CTX="k3d-agrippa-dev"
NS="forgejo"
GIT_HOST="${GIT_HOST:-git.davidsouther.com.127.0.0.1.nip.io}"
ADMIN_SECRET="forgejo-admin"
# A distinctive, collision-proof probe repo slug (deleted first, then re-created,
# then removed at the end -- runtime data, safe to churn).
PROBE_REPO="agrippa-git-hosting-probe"
# The local CA's CommonName -- cert-manager's CA ClusterIssuer signs every leaf
# cert on the platform, the shared Gateway cert included. Seeing this as the TLS
# issuer for the git host proves the same Gateway/local-CA contract networking.bats
# proved for the ArgoCD host now covers Forgejo's appended SAN.
CA_CN="Agrippa Local Dev CA"

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  cd "$REPO_ROOT" || return 1
  mise trust >/dev/null 2>&1 || true
}

# Best-effort remove the probe repo so a crashed run leaves nothing behind. Reads
# the admin credential fresh (empty/no-op on the RED baseline where the Secret
# does not exist yet). Runs after every test in this file.
teardown() {
  local user pw auth
  user="$(admin_key username || true)"
  pw="$(admin_key password || true)"
  if [ -n "$user" ] && [ -n "$pw" ]; then
    auth="$(printf '%s:%s' "$user" "$pw" | base64 | tr -d '\n')"
    curl -k -sS -o /dev/null --max-time 10 -X DELETE \
      -H "Authorization: Basic ${auth}" \
      "https://${GIT_HOST}/api/v1/repos/${user}/${PROBE_REPO}" 2>/dev/null || true
  fi
}

# Echoes "<sync> <health>" for the `platform` ArgoCD Application.
platform_app_status() {
  kubectl --context "$CTX" -n argocd get application platform \
    -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null
}

# Waits up to ~5 min for the `platform` layer to reach Synced + Healthy. The
# Forgejo chart, its DB provisioning, and the HTTPRoute all reconcile inside this,
# so allow generous time.
wait_for_platform_synced_healthy() {
  for _ in $(seq 1 60); do
    if [ "$(platform_app_status)" = "Synced Healthy" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# Echoes one base64-decoded key ("username" or "password") of the sealed,
# KSOPS-decrypted admin Secret; empty if the Secret does not exist yet.
admin_key() {
  kubectl --context "$CTX" -n "$NS" get secret "$ADMIN_SECRET" \
    -o go-template="{{ index .data \"$1\" | base64decode }}" 2>/dev/null
}

@test "Forgejo serves through the Gateway over local-CA TLS, authenticates the sealed admin, and hosts a pushed repo (Git hosting is live)" {
  # THEN 0: ArgoCD has reconciled the Forgejo content into the platform layer.
  # This is the GitOps precondition -- the Forgejo Deployment, its Database/role,
  # and its HTTPRoute are Synced/Healthy under the single `platform` Application
  # (sync-wave 2). (Passes even on the argocd-only placeholder; the RED baseline
  # comes at THEN 1.)
  run wait_for_platform_synced_healthy
  [ "$status" -eq 0 ]

  # WHEN + THEN 1: Forgejo's API is reachable through the shared Gateway at its dev
  # host through the k3d :443 port-map. `-k` tolerates the local CA that is
  # deliberately not host-trusted (research decision 3). The version endpoint needs
  # no auth; a 200 with a version payload -- NOT the connection failure of the
  # empty placeholder -- proves the whole request path resolves: host :443 -> k3d
  # port-map -> node IP (Gateway externalIPs) -> gateway pods -> the `forgejo`
  # HTTPRoute -> the Forgejo Service -> a running, DB-backed Forgejo.
  run curl -k -sS --max-time 10 "https://${GIT_HOST}/api/v1/version"
  [ "$status" -eq 0 ]
  # grep pipeline, not a bare `[[ ]]`: in this bats/bash, a non-final `[[ ]]`
  # does NOT fail the test (set -e exempts conditional compounds), so content
  # assertions use the reliably-gating `grep -q` idiom (as gitops.bats does).
  echo "$output" | grep -q '"version"'

  # THEN 2: TLS is terminated at the Gateway with a certificate ISSUED BY THE LOCAL
  # CA -- proving Forgejo's appended `dnsNames` SAN is covered by the shared
  # `agrippa-gateway-tls` cert cert-manager's SelfSigned->CA chain issues, not an
  # Istio default. Uses `openssl s_client | openssl x509 -noout -issuer` (the
  # stable interface networking.bats' cleared Q6 resolution established; the
  # operator's system `curl` links LibreSSL, making `curl -v`'s cert dump brittle).
  run bash -c "openssl s_client -connect 127.0.0.1:443 -servername '${GIT_HOST}' </dev/null 2>/dev/null | openssl x509 -noout -issuer"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$CA_CN"

  # THEN 3: an authenticated admin API call succeeds using the sealed credential --
  # decrypted by KSOPS into the `forgejo` namespace Secret `forgejo-admin` and
  # asserted onto Forgejo's admin user by the chart's `admin.existingSecret`. This
  # proves the sealed-credential path AND that Forgejo's Postgres-backed user store
  # is live: `GET /api/v1/user` (basic auth) returns the authenticated user's login.
  admin_user="$(admin_key username || true)"
  admin_pw="$(admin_key password || true)"
  [ -n "$admin_user" ]
  [ -n "$admin_pw" ]
  auth="$(printf '%s:%s' "$admin_user" "$admin_pw" | base64 | tr -d '\n')"
  run curl -k -sS --max-time 10 -H "Authorization: Basic ${auth}" \
    "https://${GIT_HOST}/api/v1/user"
  [ "$status" -eq 0 ]
  # tolerant of JSON whitespace; proves the authenticated identity is the sealed
  # admin (a `"login"` field, whose value is the admin username).
  echo "$output" | grep -q '"login"'
  echo "$output" | grep -qF "$admin_user"

  # THEN 4: Git hosting works end-to-end -- create a repository via the API, clone
  # it, push a commit over HTTP, and confirm Forgejo serves the pushed file back.
  # This exercises the core git-hosting function (repo metadata written to Postgres,
  # git objects to the PVC, HTTP git transport through the Gateway). Delete-first
  # makes the create idempotent across re-runs; auto_init gives a `main` branch to
  # push onto.
  curl -k -sS -o /dev/null --max-time 10 -X DELETE -H "Authorization: Basic ${auth}" \
    "https://${GIT_HOST}/api/v1/repos/${admin_user}/${PROBE_REPO}" 2>/dev/null || true
  run curl -k -sS --max-time 15 -o /dev/null -w '%{http_code}' \
    -X POST -H "Authorization: Basic ${auth}" -H 'Content-Type: application/json' \
    -d "{\"name\":\"${PROBE_REPO}\",\"auto_init\":true,\"default_branch\":\"main\"}" \
    "https://${GIT_HOST}/api/v1/user/repos"
  [ "$status" -eq 0 ]
  [ "$output" = "201" ]

  # Clone -> commit -> push over HTTPS. `http.sslVerify=false` tolerates the local
  # CA; the Authorization header carries the sealed admin credential without
  # putting the (random) password in the URL (no URL-encoding hazard).
  work="${BATS_TEST_TMPDIR}/repo"
  run git -c http.sslVerify=false -c http.extraHeader="Authorization: Basic ${auth}" \
    clone "https://${GIT_HOST}/${admin_user}/${PROBE_REPO}.git" "$work"
  [ "$status" -eq 0 ]
  echo "agrippa git-hosting probe" > "${work}/probe.txt"
  run git -C "$work" -c user.email=probe@agrippa.local -c user.name=agrippa-probe \
    -c commit.gpgsign=false add probe.txt
  [ "$status" -eq 0 ]
  run git -C "$work" -c user.email=probe@agrippa.local -c user.name=agrippa-probe \
    -c commit.gpgsign=false commit -m "git-hosting probe push"
  [ "$status" -eq 0 ]
  run git -C "$work" -c http.sslVerify=false -c http.extraHeader="Authorization: Basic ${auth}" \
    push origin HEAD:main
  [ "$status" -eq 0 ]

  # Confirm Forgejo served the pushed commit back: the file exists on `main` via the
  # contents API (200). This proves the push landed in Forgejo's object store and is
  # queryable, not merely that the client-side push command exited 0.
  run curl -k -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Basic ${auth}" \
    "https://${GIT_HOST}/api/v1/repos/${admin_user}/${PROBE_REPO}/contents/probe.txt?ref=main"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  # Cleanup: remove the probe repository (runtime data, not GitOps-managed).
  # teardown() also does this defensively if an assertion above aborted the test.
  curl -k -sS -o /dev/null --max-time 10 -X DELETE -H "Authorization: Basic ${auth}" \
    "https://${GIT_HOST}/api/v1/repos/${admin_user}/${PROBE_REPO}" 2>/dev/null || true
}
