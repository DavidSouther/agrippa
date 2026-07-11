#!/usr/bin/env bats
#
# Feature test for Workloads (resume + trips static sites), Feature 9 of the
# local k3d project. Runs David's two real, production static sites
# (github.com/davidsouther/resume serving davidsouther.com + /blog, and
# github.com/davidsouther/trips serving trips.davidsouther.com) in-cluster,
# built from git submodules into local images by `mise run workloads:build`
# and reconciled by ArgoCD as plain kustomize `resources:` YAML under the
# `workloads` layer.
#
# Primary user story (Given / When / Then):
#   Given the bootstrapped long-lived `agrippa-dev` cluster with this Workloads
#         content committed, the resume:dev/trips:dev images built and
#         `k3d image import`-ed by `mise run workloads:build`, and ArgoCD
#         reconciling both overlays into the `workloads` layer (a Deployment,
#         Service, and HTTPRoute on the shared Istio Gateway per workload),
#   When an operator reaches each site through the shared Gateway at its dev
#        host,
#   Then the `workloads` Application is Synced/Healthy, the personal site
#        serves 200 with real rendered content at `/` and at `/blog`, its
#        `/healthz` returns exactly 200, and the trips site serves 200 with
#        real rendered content at `/` -- proving both of David's real sites
#        run in-cluster and are reachable end-to-end through the Gateway over
#        the local-CA cert.
#
# NOTE: this suite deliberately does NOT tear the cluster or the workloads
# down. Both are long-lived and GitOps-managed; this suite only reads, so
# re-running it is safe.
#
# Run:  bats tests/workloads.bats
#
# Requires: bats-core, mise, curl, kubectl, and (for green) the running
# bootstrapped `agrippa-dev` cluster with the resume/trips images built +
# imported by `mise run workloads:build` and the `workloads` content
# reconciled by ArgoCD.
#
# PUBLIC_HOST / TRIPS_HOST override the target hosts, mirroring the gestalt
# suite's own override names (tests/agrippa.bats).

CTX="k3d-agrippa-dev"
NS="argocd"
PUBLIC_HOST="${PUBLIC_HOST:-davidsouther.com.127.0.0.1.nip.io}"
TRIPS_HOST="${TRIPS_HOST:-trips.davidsouther.com.127.0.0.1.nip.io}"

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  cd "$REPO_ROOT" || return 1
  # Trust the repo mise.toml so `mise run`/`mise x` are non-interactive.
  mise trust >/dev/null 2>&1 || true
}

# Echoes "<sync> <health>" for the `workloads` ArgoCD Application.
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

@test "resume and trips render through the Gateway over local-CA TLS, with the personal site's /healthz live" {
  # THEN 0: ArgoCD has reconciled Workloads into the workloads layer.
  run wait_for_synced_healthy workloads
  [ "$status" -eq 0 ]

  # THEN 1: the personal site is reachable through the shared Gateway at its
  # dev host. -k tolerates the local, deliberately-untrusted-by-design dev CA.
  run curl -k -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://${PUBLIC_HOST}/"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  run curl -k -sS --max-time 10 "https://${PUBLIC_HOST}/"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi '<html'
  echo "$output" | grep -qi 'david'

  # THEN 2: the blog renders. -L follows the directory-index redirect
  # (/blog -> /blog/).
  run curl -k -L -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://${PUBLIC_HOST}/blog"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
  run curl -k -L -sS --max-time 10 "https://${PUBLIC_HOST}/blog"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi '<html'

  # THEN 3: the personal site's liveness endpoint returns exactly 200 (the
  # nginx `location = /healthz { return 200; }` baked into the resume image).
  run curl -k -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://${PUBLIC_HOST}/healthz"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  # THEN 4: the trips site is reachable through the Gateway at its own dev
  # host and renders real content.
  run curl -k -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://${TRIPS_HOST}/"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
  run curl -k -sS --max-time 10 "https://${TRIPS_HOST}/"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi '<html'
  echo "$output" | grep -qi 'trip'
}
