# Codebase: shared contracts and current repo state this feature-step consumes

## Findings

**Live cluster/ArgoCD state (verified this session).** `apps/observability.yaml`
already exists and is wired into `apps/kustomization.yaml`'s root resource list:
an ArgoCD `Application` named `observability`, `sync-wave: "3"`, pointing at
`path: observability/overlays/dev`. Its header comment already reads "# Observability
owns loki, grafana, tempo, mimir, alloy." **The `observability/` directory itself
does not exist yet anywhere in the working tree** (`find` confirms no
`observability/overlays/dev/kustomization.yaml`, unlike `core/overlays/dev/` and
`storage/overlays/dev/`, which are live and partially filled). This is a true
Step-0 empty state: the ArgoCD `Application` shell is landed (from the GitOps
feature-step's own scaffolding), but the layer's content is entirely unauthored.
No `charts/` directory exists yet either (Workloads' `charts/resume/`,
`charts/trips/` are still only planned, not built) — this feature-step would be
first to introduce any Helm-values composition purely under `observability/`
rather than `charts/`.

**`apps/observability.yaml`'s sync-wave (`3`) sits after storage's implicit
wave and after core's networking waves, consistent with the design's stated
dependency ("Depends on: Storage — signal stores need PVCs").** No `syncOptions`
(`ServerSideApply`/`SkipDryRunOnMissingResource`) are set on it yet, unlike
`apps/storage.yaml` and `apps/core.yaml`, which both needed those overrides once
their CRD-heavy operators (CNPG, Istio ambient/Gateway API) hit ArgoCD's
dry-run-on-missing-CRD and SMD-diff-mispredicts-controller-fields issues. Mimir's
and Loki's Helm charts render only `Deployment`/`StatefulSet`/`Service`/`PVC`/
`ConfigMap`/`Secret` — no CRDs of their own — so this class of problem is a priori
less likely here than it was for CNPG or Istio ambient, but the design phase
should still budget for it as a live-verified risk, not assume it away, since
`apps/observability.yaml` currently carries none of those overrides and would
need the same fix-at-build-time pattern if a perma-`OutOfSync` symptom appears.

**Repo-server Helm capability is already on.** `apps/platform/argocd/kustomization.yaml`'s
`argocd-cm` patch sets `kustomize.buildOptions: "--enable-alpha-plugins --enable-exec
--enable-helm"` — confirmed live this session, and already the precondition the
storage and networking feature-steps both relied on for their own `helmCharts:`
compositions (CNPG operator, Istio ambient's four charts). No additional
repo-server change is needed for this feature-step's own `helmCharts:` block
(Loki, Grafana, Tempo, Mimir, Alloy are all plain Helm charts, same shape).

**The storage-class + per-app-DB-naming shared contract (from the Storage
feature-step, already landed) is the one this feature-step is bound to by the
parent plan ("shared contract: storage class" — note Feature 8 is bound only to
the storage-class half of the contract, not the DB-naming half, per the parent
plan's own wording, distinct from Features 5-7 which bind to "storage class +
DB naming").**

- `local-path` is the confirmed live dev `StorageClass`, `WaitForFirstConsumer`
  binding mode, single k3d node — every signal store's PVC (Loki chunks, Mimir
  blocks, Tempo local trace backend, and Grafana's own SQLite file if
  persisted) binds here.
- **The per-app Postgres DB/role naming contract exists (database name = role
  name = consuming app's own slug, e.g. `keycloak`/`keycloak`) but this
  feature-step does not need to invoke it**, per this research's own finding
  (Grafana's single-replica dev deployment is well served by its embedded
  SQLite, not external Postgres — see the companion `public.md` note). If a
  later cycle scales Grafana beyond one replica and needs Postgres, the
  consumption contract is already fully specified and ready to invoke
  unchanged: seal a credential to `secrets/dev/storage/postgres/grafana.enc.yaml`,
  append one `managed.roles[]` entry to storage's `postgres-cluster.yaml`, author
  a `Database` CR in this feature-step's own layer, connect at
  `postgres://grafana:<pw>@postgres-rw.storage.svc:5432/grafana`. This
  feature-step's design should record that seam explicitly rather than silently
  ignore it, matching the project's general "seams preserved, not built" pattern
  (Longhorn, Rook-Ceph, terraform/tflint all follow the same shape).
- **The credential-sealing discipline the storage feature-step established**
  (generate in memory via `openssl rand`, pipe straight through
  `kubectl create secret ... --from-file=password=/dev/stdin --dry-run=client -o
  yaml | sops --encrypt --filename-override <path> ... > <path>`, never write
  plaintext to disk, `username`/non-secret fields may live in argv) is the
  mechanism this feature-step should reuse verbatim for any credential
  it does seal — most plausibly a **production-overlay** Grafana admin
  credential later, given this research's finding that the **dev** overlay
  should instead use the literal, already-documented `admin`/`admin` (not a
  sealed secret) to match `DEVELOPMENT.md` and the committed gestalt test.

**The Gateway + HTTPRoute + hostname + TLS shared contract (from the Networking
feature-step, already landed for one consumer: ArgoCD) is what this feature-step
will append to, not re-invent.** Concretely, from `core/overlays/dev/`, live and
Synced this session:

- `Gateway` **`agrippa-gateway`** in namespace `istio-ingress`, `gatewayClassName:
  istio`, an `https` listener on `:443` (`tls.mode: Terminate`, `certificateRefs:
  [agrippa-gateway-tls]`, `allowedRoutes.namespaces.from: All`) — already open to
  routes from any namespace, so this feature-step's `HTTPRoute` needs no Gateway
  edit, only its own new `HTTPRoute` object.
- `Certificate` **`agrippa-gateway-tls`** in `istio-ingress` (`issuerRef:
  agrippa-ca`, `secretName: agrippa-gateway-tls`), currently `dnsNames:
  [argocd.127.0.0.1.nip.io]` — a **single shared, append-only-SAN certificate**.
  This feature-step's own dev hostname (see below) must be appended to that one
  list (a one-line edit to a `core`-owned file, the exact "later UI features
  append their host" seam the networking feature-step's own plan names
  explicitly), not a new `Certificate` object.
- `HTTPRoute` pattern precedent (`argocd-httproute.yaml`): `parentRefs: [{name:
  agrippa-gateway, namespace: istio-ingress, sectionName: https}]`, explicit
  `hostnames:` list, explicit `rules[].matches` (must be spelled out explicitly —
  the networking feature-step's build found ArgoCD's pre-sync SMD diff does not
  reliably replicate the API-schema default `[{path: {type: PathPrefix, value:
  "/"}}]` when `matches` is omitted), `backendRefs:` to the target Service. If
  Grafana's backend Service serves plain HTTP internally (the Grafana chart's
  default; unlike ArgoCD's `argocd-server`, which defaults to HTTPS and needed a
  `DestinationRule` for backend TLS re-origination), a plain HTTP `backendRefs`
  needs **no** matching `DestinationRule` — a materially simpler case than the
  ArgoCD precedent, worth confirming explicitly at design time (Grafana's
  service.yaml/service port defaults) rather than assuming the ArgoCD
  TLS-re-origination shape is required again.
- `argocd.argoproj.io/compare-options: ServerSideDiff=true` is the confirmed fix
  for the perma-`OutOfSync` Gateway/HTTPRoute symptom (ArgoCD's SMD comparison
  strategy mispredicting CRD/API-schema-defaulted fields) — already applied to
  `apps/storage.yaml` per its own comment citing the same root cause found in
  the networking feature-step's build. `apps/observability.yaml` does not yet
  carry this annotation; the design/build phases should treat it as a
  known-likely-needed addition once this feature-step's own `HTTPRoute` lands,
  not a surprise to rediscover.

**Dev hostname: `dashboard.davidsouther.com.127.0.0.1.nip.io`, not
`dashboard.127.0.0.1.nip.io`.** Two independent internal sources agree and must
be reconciled together:

1. `tests/agrippa.bats`'s `setup()` defaults `DASHBOARD_HOST` to the literal
   **production** hostname `dashboard.davidsouther.com` (line 32) — this is the
   value `ENV=prod` (the suite's own default `ENV`) uses unmodified.
2. The parent `design.md`'s resolved decision 6 fixes the **dev** hostname
   scheme as `<prod-host>.127.0.0.1.nip.io` — mirroring the prod host with a
   loopback suffix appended, not replacing it — and gives
   `dashboard.davidsouther.com.127.0.0.1.nip.io` as its own explicit worked
   example for this exact host.

Composing these two facts: running `tests/agrippa.bats` locally with `ENV=dev`
requires overriding `DASHBOARD_HOST` explicitly to
`dashboard.davidsouther.com.127.0.0.1.nip.io` (the suite's own default is always
the bare prod name regardless of `ENV`, per its `setup()` code — `ENV` only
switches which *assertions* run, not the default hostnames). The parent task
brief's own suggested value (`dashboard.127.0.0.1.nip.io`, dropping the
`davidsouther.com` middle label) does **not** match either committed source and
should not be used — this research corrects that starting assumption rather
than confirming it. The Networking feature-step's own precedent
(`argocd.127.0.0.1.nip.io`, no prod-host middle label, because ArgoCD "has no
named prod host") is a *different* case precisely because ArgoCD is not one of
the three hostnames `tests/agrippa.bats` already names; Grafana/dashboard *is*
one of those three (`PUBLIC_HOST`, `TRIPS_HOST`, `DASHBOARD_HOST`), so it must
follow the mirrored-prod-host pattern, not the bare-service-name pattern.

**No Prometheus Operator CRDs are installed or referenced anywhere in the
already-landed layers.** Grepped `cluster-core-k3d`, `gitops-argocd`, and
`step0-mise-testing-harness`'s design/plan documents for
`prometheus.operator`/`ServiceMonitor`/`PodMonitor`/`monitoring.coreos` — zero
matches. Confirms (alongside the public research's own finding) that Alloy's
`discovery.kubernetes`-based self-discovery is the correct default collection
mechanism, not a CRD-based one -- installing `kube-prometheus-stack` or
the Prometheus Operator solely to unlock ServiceMonitor discovery would be new,
unbudgeted scope this feature-step's own Specification line ("reduced
replicas") argues against.

**Istio ambient is confirmed live cluster-wide** (`global.platform: k3d`,
`profile: ambient`, four Helm-inflated charts: `base`, `istiod`, `cni`,
`ztunnel`, all in the `core` layer per the Networking feature-step's own design
and plan). ztunnel's own `/stats/prometheus` metrics endpoint (port 15020) is
therefore already running in this cluster and available to scrape if a later
design iteration wants mesh-level TCP metrics — but nothing in the already-
landed Networking feature-step's design or plan authors any scrape
configuration or Prometheus-format export wiring for it; it is pure upside
this feature-step could opt into, not a dependency it is missing.

**Namespace convention:** every already-landed layer uses its own layer name as
its primary namespace (`storage` for CNPG/Valkey, `istio-ingress` for the
Gateway, `argocd` for ArgoCD/GitOps, `cnpg-system` for the CNPG operator itself).
The consistent extrapolation for this feature-step is an `observability`
namespace for Loki/Grafana/Tempo/Mimir/Alloy — matching the ArgoCD
`Application`'s own header comment structure and the five-layer naming the
parent design fixed verbatim from `ARCHITECTURE.html`. This is not independently
confirmed by any committed manifest (nothing yet exists under `observability/`),
but is the only naming choice consistent with every sibling layer already
built, and should be treated as the working default rather than an open
question.

## Sources

Internal, `research:codebase` direct inspection this session (no external
citations):

- `apps/observability.yaml`, `apps/kustomization.yaml`, `apps/storage.yaml`,
  `apps/core.yaml`, `apps/platform/argocd/kustomization.yaml`
- `tests/agrippa.bats` (`setup()`, the `dashboard.davidsouther.com` test case)
- `DEVELOPMENT.md` (`## Testing`, `## Secrets`)
- `ARCHITECTURE.html` (Observability slide `#s3`, layer-name legend, `data-docs`
  chip references for `loki`/`grafana`/`tempo`/`mimir`/`alloy`)
- `.ailly/developer/2026-07-06-A-agrippa-local-k3d/design.md` (Specification §
  Observability, resolved item 6 hostname scheme)
- `.ailly/developer/2026-07-06-A-agrippa-local-k3d/plan.md` (Feature 8 section,
  Shared Contracts)
- `.ailly/developer/2026-07-06-A-agrippa-local-k3d/closing-bell.md` (critical
  task 4)
- `.ailly/developer/2026-07-06-A-agrippa-local-k3d/features/storage-postgres-valkey/design.md`
  (storage-class + DB/role naming contract, secret-sealing mechanism,
  `local-path` confirmation)
- `.ailly/developer/2026-07-06-A-agrippa-local-k3d/features/networking-istio/design.md`
  and `plan.md` (Gateway/HTTPRoute/Certificate contract, ambient install shape,
  ArgoCD compare-options fix, `argocd.127.0.0.1.nip.io` precedent)
- `.ailly/developer/2026-07-06-A-agrippa-local-k3d/features/cluster-core-k3d/`,
  `gitops-argocd/`, `step0-mise-testing-harness/` design docs (negative-result
  grep for Prometheus Operator CRDs)
