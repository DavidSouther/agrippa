#!/usr/bin/env bats
#
# Feature test for Workloads (resume + trips static sites, in-cluster), roadmap
# item 9 / Feature 9 of the local k3d project -- the project's LAST feature-step.
# This runs David's two real, production static sites (github.com/davidsouther/
# resume serving davidsouther.com + /blog, and github.com/davidsouther/trips
# serving trips.davidsouther.com) inside the k3d cluster, built from git
# submodules into local images by `mise run workloads:build` and reconciled by
# ArgoCD as plain kustomize `resources:` YAML under the `workloads` layer.
#
# Primary user story (Given / When / Then):
#   Given the bootstrapped long-lived `agrippa-dev` cluster (Features 0-8) with
#         this Workloads content committed, the resume:dev/trips:dev images built
#         and `k3d image import`-ed by `mise run workloads:build`, and ArgoCD
#         reconciling the two plain-`resources:` overlays into the `workloads`
#         layer (Deployment with imagePullPolicy: Never, Service, and an HTTPRoute
#         on the shared Istio Gateway per workload -- the networking contract),
#   When an operator reaches each site through the shared Gateway at its dev host,
#   Then the `workloads` Application is Synced/Healthy, the personal-site host
#        serves 200 with real rendered content at `/` and at `/blog`, its
#        `/healthz` returns exactly 200 (parent design decision 4), and the trips
#        host serves 200 with real rendered content at `/` -- proving both of
#        David's real sites run in-cluster and are reachable end-to-end through
#        the Gateway over the local-CA cert.
#
# EXPECTED TO FAIL until Workloads lands the `workloads/overlays/dev/{resume,trips}`
# plain-`resources:` composition (Namespace + Deployment + Service + HTTPRoute per
# workload), the two appended `agrippa-gateway-tls` SANs, the `apps/workloads.yaml`
# sync seam, and the built+imported images, and ArgoCD reconciles it. Before that,
# `workloads/overlays/dev` is the `resources: []` placeholder: the `workloads`
# Application is already trivially Synced/Healthy (so THEN 0 passes even now,
# exactly as git-hosting.bats' THEN 0 passed on the argocd-only `platform`), but
# no HTTPRoute routes either dev host -- so the Gateway answers TLS for any SNI
# and returns an empty 404, and the suite fails at THEN 1. That red state defines
# "done" for this feature-step.
#
# NOTE: this suite deliberately does NOT tear the cluster or the workloads down.
# Both are long-lived and GitOps-managed; ArgoCD's prune/selfHeal would re-create
# anything torn down. The suite performs static GETs only -- it creates nothing it
# must clean up. Re-running is safe.
#
# Run:  bats tests/workloads.bats
#
# Requires: bats-core, curl, kubectl, and (for green) the running bootstrapped
# `agrippa-dev` cluster with the resume/trips images built + imported by
# `mise run workloads:build` and the `workloads` content reconciled by ArgoCD.
#
# PUBLIC_HOST / TRIPS_HOST override the target hosts so the same test could point
# at other dev nip.io hosts. They mirror the gestalt suite's own override names
# (tests/agrippa.bats) so a single set of env vars drives both.

CTX="k3d-agrippa-dev"
PUBLIC_HOST="${PUBLIC_HOST:-davidsouther.com.127.0.0.1.nip.io}"
TRIPS_HOST="${TRIPS_HOST:-trips.davidsouther.com.127.0.0.1.nip.io}"

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  cd "$REPO_ROOT" || return 1
  mise trust >/dev/null 2>&1 || true
}

# Echoes "<sync> <health>" for the `workloads` ArgoCD Application.
workloads_app_status() {
  kubectl --context "$CTX" -n argocd get application workloads \
    -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null
}

# Waits up to ~5 min for the `workloads` layer to reach Synced + Healthy. The two
# Deployments (each running a locally-imported image, imagePullPolicy: Never),
# Services, and HTTPRoutes all reconcile inside this, so allow generous time.
wait_for_workloads_synced_healthy() {
  for _ in $(seq 1 60); do
    if [ "$(workloads_app_status)" = "Synced Healthy" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

@test "resume and trips render through the Gateway over local-CA TLS, with the personal site's /healthz live (Workloads is live)" {
  # THEN 0: ArgoCD has reconciled the Workloads content into the `workloads`
  # layer. The GitOps precondition -- both Deployments, Services, and HTTPRoutes
  # Synced/Healthy under the single `workloads` Application (sync-wave 4, the last
  # layer). Passes even on the `resources: []` placeholder; the RED baseline comes
  # at THEN 1.
  run wait_for_workloads_synced_healthy
  [ "$status" -eq 0 ]

  # WHEN + THEN 1: the personal site is reachable through the shared Gateway at its
  # dev host through the k3d :443 port-map. `-k` tolerates the local CA that is
  # deliberately not host-trusted (research decision 3). A 200 -- NOT the empty 404
  # of the placeholder -- proves the whole request path resolves: host :443 -> k3d
  # port-map -> node IP (Gateway externalIPs) -> gateway pods -> the `resume`
  # HTTPRoute -> the resume Service -> a running nginx pod serving the built site.
  run curl -k -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://${PUBLIC_HOST}/"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  # ...and it renders David's REAL resume content, not merely an nginx 200. Two
  # gating greps (not a bare non-final `[[ ]]`, which does NOT fail a test in this
  # bats/bash -- set -e exempts conditional compounds -- so content assertions use
  # the reliably-gating `grep -q` idiom, as git-hosting.bats/gitops.bats do): the
  # body is an HTML document, and it names the site's owner ("David"). "david" is
  # a deliberately loose reachability-and-render token -- it distinguishes a real
  # rendered personal site from the empty-404 baseline AND from the trips content
  # a swapped image/route would serve. The full "real resume/blog content" depth
  # (Closing Bell task 2) is judged by the human study; a stricter token confirmed
  # against the live-rendered site is a build-phase tightening, not required here.
  run curl -k -sS --max-time 10 "https://${PUBLIC_HOST}/"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi '<html'
  echo "$output" | grep -qi 'david'

  # THEN 2: the blog renders. `-L` follows any trailing-slash redirect the serving
  # config emits for `/blog` -> `/blog/` (the assumed directory-index shape,
  # docs/blog/index.html; build-verified against the real jiffies output), so this
  # asserts the blog index actually renders (200 + an HTML document) regardless of
  # a bounce. One image and one route serve both `/` and `/blog`: same source,
  # same host (the apex-path placement).
  run curl -k -L -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://${PUBLIC_HOST}/blog"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
  run curl -k -L -sS --max-time 10 "https://${PUBLIC_HOST}/blog"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi '<html'

  # THEN 3: the personal site's liveness endpoint returns exactly 200 -- the nginx
  # `location = /healthz { return 200; }` baked into the resume image's serving
  # stage (parent design decision 4). This is the exact endpoint the gestalt suite
  # (tests/agrippa.bats) probes for a 2xx within its 1s budget; here we assert the
  # precise 200 the return directive produces.
  run curl -k -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://${PUBLIC_HOST}/healthz"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]

  # THEN 4: the trips site is reachable through the Gateway at its own dev host and
  # renders real content. Served publicly with no gating (parent design decision 3
  # -- production's Cloudflare Access edge has no local equivalent). Same request
  # path as the personal site, a distinct HTTPRoute/Service/Deployment/image.
  run curl -k -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://${TRIPS_HOST}/"
  [ "$status" -eq 0 ]
  [ "$output" = "200" ]
  run curl -k -sS --max-time 10 "https://${TRIPS_HOST}/"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi '<html'
  # "trip" is the trips-side counterpart to the resume "david" token: a loose
  # reachability-and-render proof that also discriminates the trips content from
  # the resume content a swapped image/route would serve. The deeper Closing Bell
  # task 3 ("the trip index AND at least one real trip detail page") is judged by
  # the human study; navigating to a specific trip detail page and asserting its
  # title is a build-phase tightening once the live trip URLs are confirmed.
  echo "$output" | grep -qi 'trip'
}
