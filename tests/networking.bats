#!/usr/bin/env bats
#
# Feature test for Networking: Istio ambient + Gateway API + cert-manager +
# metallb
#
# Primary user story (Given / When / Then):
#   Given the bootstrapped long-lived `agrippa-dev` k3d cluster (Features 1-2)
#         with this Networking content committed and reconciled by ArgoCD into the
#         `core` layer,
#   When an operator requests https://argocd.127.0.0.1.nip.io/ through the k3d
#        `:443` host port-map,
#   Then the request is served through the shared Istio Gateway (host :443 -> k3d
#        loadbalancer -> node IP via the Service's externalIPs -> gateway pods ->
#        the `argocd` HTTPRoute -> argocd-server), the response is a live UI status
#        (2xx/3xx, not a connection failure), and the TLS certificate presented is
#        ISSUED BY THE LOCAL CA (CN=Agrippa Local Dev CA), not Istio's built-in
#        self-signed default -- proving the Gateway + HTTPRoute + local-hostname +
#        local-CA-TLS shared contract end-to-end.
#
# This stands in for the
# production Cloudflare edge (public DNS, public ACME TLS, cloudflared), since
# both are cloud-only and out of scope for a local cluster, with a local CA
# (real certs, deliberately not host-trusted -- probed with `curl -k`) and
# `*.nip.io` loopback hostnames reached through the k3d port-map. It also
# DEFINES the shared Gateway/HTTPRoute/hostname/TLS contract every later
# UI-exposed feature-step (Auth, Observability, Workloads) consumes, and
# resolves gitops-argocd's deferred "ArgoCD UI ingress" item by routing the
# ArgoCD UI as this feature's zero-new-workload reachability proof.
#
# NOTE: this suite deliberately does NOT tear the cluster or ArgoCD down. Both are
# long-lived: every later feature-step reconciles into this same cluster. The
# Networking content is GitOps-managed and idempotent, so re-running is safe.
#
# Run:  bats tests/networking.bats
#
# Requires: bats-core, mise, curl, kubectl, and (for green) the running
# bootstrapped `agrippa-dev` cluster with the Networking `core` content
# reconciled by ArgoCD.
#
# GW_HOST overrides the target host so the same test could point at another dev
# nip.io host if the reachability proof ever moves off the ArgoCD UI.

CTX="k3d-agrippa-dev"
GW_HOST="${GW_HOST:-argocd.127.0.0.1.nip.io}"
# The local CA's CommonName -- the cert-manager CA ClusterIssuer that signs every
# leaf cert on the platform (the shared Gateway cert included). Seeing this as the
# TLS issuer proves cert-manager wired the Gateway TLS, not Istio's default.
CA_CN="Agrippa Local Dev CA"

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  cd "$REPO_ROOT" || return 1
  # Trust the repo mise.toml so `mise run` is non-interactive (parity with the
  # sibling suites; this suite itself only needs curl + kubectl).
  mise trust >/dev/null 2>&1 || true
}

# Echoes "<sync> <health>" for the `core` ArgoCD Application, e.g. "Synced Healthy".
core_app_status() {
  mise x kubectl -- kubectl --context "$CTX" -n argocd get application core \
    -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null
}

# Waits up to ~5 min for the `core` layer to reach Synced + Healthy. The upstream
# controllers (metallb, cert-manager, istiod/istio-cni/ztunnel) and the Gateway
# provisioning happen inside this reconcile, so allow generous time.
wait_for_core_synced_healthy() {
  for _ in $(seq 1 60); do
    if [ "$(core_app_status)" = "Synced Healthy" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

@test "the shared Istio Gateway serves the ArgoCD UI over local-CA TLS at its nip.io host through the k3d :443 port-map" {
  # THEN 0: ArgoCD has reconciled the Networking content into the core layer. This
  # is the GitOps precondition -- the four upstream sources and the shared Gateway
  # are Synced/Healthy under the single `core` Application (sync-wave 0).
  run wait_for_core_synced_healthy
  [ "$status" -eq 0 ]

  # WHEN + THEN 1: the operator reaches the shared Gateway at the ArgoCD dev host
  # through the k3d loadbalancer port-map. `-k` tolerates the local CA that is
  # deliberately not in the host trust store -- it stands in for production's
  # publicly trusted ACME cert, which is out of scope for a local cluster. A
  # live UI status (2xx or 3xx) -- NOT the "Empty reply"/connection failure of
  # the empty placeholder -- proves the whole request path resolves: host :443 -> k3d
  # port-map -> node IP (Service externalIPs) -> gateway pods -> the `argocd`
  # HTTPRoute -> argocd-server.
  run curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${GW_HOST}/"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(2[0-9][0-9]|3[0-9][0-9])$ ]]

  # THEN 2: TLS is terminated at the Gateway with a certificate ISSUED BY THE
  # LOCAL CA. Uses `openssl s_client | openssl x509 -noout -issuer` rather
  # than `curl -kv | grep` because the operator's system `curl` links
  # LibreSSL, not OpenSSL, making `curl -v`'s human-readable cert dump a
  # brittle, backend-dependent interface for this exact assertion
  # (confirmed against this session's curl build). `curl -k` (THEN 1 above)
  # stays the reachability check; asserting the local CA's CommonName here
  # proves cert-manager's SelfSigned->CA chain issued the Gateway cert (the
  # TLS half of the shared contract), rather than Istio serving its built-in
  # self-signed default. This is the assertion that makes the test about the
  # CONTRACT, not merely about reachability.
  run bash -c "openssl s_client -connect 127.0.0.1:443 -servername '${GW_HOST}' </dev/null 2>/dev/null | openssl x509 -noout -issuer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${CA_CN}"* ]]
}
