# Public: Keycloak on Kubernetes (Auth feature-step)

## Findings

**Keycloak does not ship an official Helm chart — only an official Operator,
installed by raw manifests.** The keycloak.org documentation tree (`/operator/*`)
documents exactly two installation paths for the Operator: Operator Lifecycle
Manager (OpenShift/OLM `fast` channel) or plain `kubectl apply` of three raw
manifests from the `keycloak/keycloak-k8s-resources` repository — two CRDs
(`keycloaks.k8s.keycloak.org-v1.yml`, `keycloakrealmimports.k8s.keycloak.org-v1.yml`)
and the operator Deployment/RBAC manifest (`kubernetes.yml`) [1]. No Helm chart
is mentioned anywhere in that tree, and a community request to add one
(`keycloak/keycloak#37636`) is still open [2] — corroborating that this is a
deliberate gap, not an oversight this research missed. The raw-manifest shape is
a direct match for how this project's `core` layer already installs metallb,
cert-manager, and the Gateway API CRDs (pinned-URL `resources:` entries, no
`helmCharts:` inflation needed) [in-repo prior art, below].

**Community Helm charts exist but are either stale or don't fit this project's
declarative-CR posture.** The old `helm/charts` "stable" `keycloak` chart is
part of the archived, years-deprecated monolithic community chart repo (frozen
since ~2020) [3] — a dead option, not a live alternative. The actively
maintained community option is `codecentric/helm-charts`' `keycloakx` chart,
which does support an external Postgres (`database.vendor: postgres`,
`database.hostname`/`port`/`database`, or `database.existingSecret` for
credentials) and admin-credential wiring via `extraEnv` `secretKeyRef` [4], but
its README documents no realm-import mechanism at all — only Keycloak's own
container-level imperative flag (`--import-realm`, reading a JSON file baked
into the image or mounted via an init container) covers that, and that
mechanism is a run-once, first-boot-only action, not a continuously-reconciled
resource.

**Bitnami's Keycloak chart is caught in the same 2025 Broadcom restructuring
already ruled out for Storage — confirmed to apply here too, not a
Storage-only concern.** The same catalog move that paywalled
`bitnami/postgresql` and `bitnami/valkey` (most free chart OCI packages moved
behind "Bitnami Secure Images" after 2025-09-29, leaving only a frozen
`bitnamilegacy` snapshot with no further patches) [5][6] affects
`bitnami/keycloak` identically — it is one of the charts named in the same
catalog-restructuring changelog and issue thread [6][7], and the Keycloak
project's own GitHub tracks the fallout directly (`keycloak/keycloak#42143`,
"hosting successor of bitnami/keycloak chart+image in keycloak") [8]. This
falsifies a plausible pre-2025 assumption ("Bitnami's Keycloak chart is the
easy default") for the same structural reason Storage's research already
falsified it for Postgres/Valkey — not a new finding in kind, but a confirmed
extension of it to this feature-step.

**The Operator's `Keycloak` CR (`k8s.keycloak.org/v2beta1`) configures an
external Postgres with the same "Secret-reference role/password" shape CNPG
already produces for this project.** A representative CR:

```yaml
apiVersion: k8s.keycloak.org/v2beta1
kind: Keycloak
metadata:
  name: example-kc
spec:
  instances: 1
  db:
    vendor: postgres
    host: postgres-db
    usernameSecret:
      name: keycloak-db-secret
      key: username
    passwordSecret:
      name: keycloak-db-secret
      key: password
  http:
    tlsSecret: example-tls-secret
  hostname:
    hostname: test.keycloak.org
  proxy:
    headers: xforwarded
  ingress:
    className: openshift-default
```

`spec.db.usernameSecret`/`passwordSecret` reference a plain Kubernetes Secret
with `username`/`password` keys [9] — exactly the `kubernetes.io/basic-auth`
Secret shape CNPG's `Cluster.spec.managed.roles[].passwordSecret` already
expects on this project's shared `postgres` Cluster [in-repo prior art]. One
sealed Secret can serve both consumers: CNPG's role `passwordSecret` reference
and Keycloak's `db.usernameSecret`/`passwordSecret` reference, with no new
sealing mechanism invented — the identical
`openssl rand | kubectl create secret --dry-run=client -o yaml | sops --encrypt`
pipeline the Storage feature-step already committed [in-repo prior art].
Keycloak defaults to its bundled dev H2 database only when `spec.db` is
omitted entirely; setting `spec.db.vendor: postgres` with a real host is what
opts out of it [10].

**CloudNativePG's `Database` CRD is namespace-scoped to its `Cluster` via a
`LocalObjectReference` — it cannot cross namespaces.** An open CNPG feature
request confirms the current limitation explicitly: "the Database CRD uses
`LocalObjectReference` for the cluster setting, which means it is awkward to
share a Postgres cluster among applications in different namespaces... Database
resources and their referenced Clusters must exist in the same namespace" [11].
This is load-bearing for this feature-step: the shared `postgres` Cluster lives
in the `storage` namespace, so Keycloak's own `Database` CR
(`name: keycloak, owner: keycloak, cluster: {name: postgres}`) must carry
`metadata.namespace: storage` regardless of which directory in the repo the
YAML file itself lives in (it can still be authored inside this feature-step's
own `platform/overlays/dev/keycloak/` tree and simply declare that namespace —
ArgoCD already applies cross-namespace resources from one Application in this
repo, e.g. `core`'s `Certificate`/`Gateway` objects land in `istio-ingress`
while the `core` Application's own `destination.namespace` is not that
namespace [in-repo prior art]). A naive assumption that the `Database` CR could
live in a self-contained `keycloak` namespace alongside the rest of this
feature-step's resources would silently fail to reconcile.

**The Keycloak Operator does not fully support watching multiple or all
namespaces — the Operator and its `Keycloak`/`KeycloakRealmImport` CRs are
expected to be co-located in one namespace, unlike CNPG's operator/operand
split.** The installation docs state this directly: "It is currently not fully
supported for the operator to watch multiple or all namespaces" [1], and the
kubectl install path grants the Operator's ServiceAccount cluster-wide RBAC
(`ClusterRole`/`ClusterRoleBinding`) scoped to whatever single namespace it is
deployed into, with the binding needing a manual patch if that namespace is
not the doc's default [1]. This is the opposite shape from CNPG (Storage
feature-step's operator runs in `cnpg-system`, its `Cluster`/`Database` operands
run in `storage` [in-repo prior art]) and is worth recording explicitly so this
feature-step does not copy that split by habit: recommend one `keycloak`
namespace holding the Operator, the `Keycloak` CR, and the
`KeycloakRealmImport` CR together, with only the `Database` CR living in
`storage` (forced by the CNPG constraint above).

**Declarative realm/client bootstrap exists, and it is the deciding factor for
choosing the Operator over any Helm chart.** The `KeycloakRealmImport` CR
(`k8s.keycloak.org/v2beta1`) is a continuously-reconciled resource, not a
run-once import:

```yaml
apiVersion: k8s.keycloak.org/v2beta1
kind: KeycloakRealmImport
metadata:
  name: my-realm-kc
spec:
  keycloakCRName: <name of the keycloak CR>
  realm:
    id: example-realm
    realm: example-realm
    displayName: ExampleRealm
    enabled: true
```

`spec.keycloakCRName` binds it to a `Keycloak` CR in the **same namespace**
[12]; `spec.realm` accepts a full Keycloak `RealmRepresentation` inline
(exported-to-JSON-then-YAML is the documented authoring workflow) [12]. Secret
material inside the realm (e.g. a client secret) need not be embedded in
plaintext: `spec.placeholders` lets values be substituted from a referenced
Kubernetes Secret at reconcile time [12] — the same "reference a sealed Secret,
never inline the value" discipline this project already applies everywhere
else. This is a direct, declarative, GitOps-native analogue of CNPG's
`Database` CR, cert-manager's `Certificate`, and metallb's `IPAddressPool`
[in-repo prior art] — a shape the plain-Helm-chart route (imperative
`--import-realm`) does not offer.

**The admin bootstrap credential has a first-class "bring your own sealed
Secret" field, matching Storage's sealing discipline exactly.**
`spec.bootstrapAdmin.user.secret: <name>` references a pre-existing Secret
carrying `username`+`password` keys; if omitted, the Operator auto-generates
one named `<cr-name>-initial-admin` with a random password instead [13]. One
documented caveat: **if the `master` realm already exists (i.e., after first
successful bootstrap), `spec.bootstrapAdmin` is ignored** [13] — the sealed
credential only takes effect on a cluster's first Keycloak startup against an
empty database, which is a normal, expected property of a bootstrap-only field
and not a gap to design around. This maps directly onto the identical
`openssl rand -base64 24 | kubectl create secret ... --from-file=password=/dev/stdin
| sops --encrypt` pipeline Storage's `smoke-db` Secret already established
[in-repo prior art] — no new sealing mechanism is needed, only its second
application to a different Secret name/path.

**Exposure: disable the Operator's own Ingress and route through the shared
Gateway instead, and Keycloak (unlike ArgoCD) offers a first-class plain-HTTP
toggle that avoids a backend-TLS re-origination dance.**
`spec.ingress.enabled: false` disables the Operator-managed Ingress entirely,
leaving only the plain `<cr-name>-service` ClusterIP Service it always creates
[14] — the same "operator creates the Service, an externally-authored
HTTPRoute targets it" shape this project's Networking feature-step already
uses for `argocd-server` [in-repo prior art]. Unlike `argocd-server`, which
defaults to HTTPS-only and forced Networking to choose backend-TLS
re-origination via a `DestinationRule` [in-repo prior art], Keycloak exposes an
explicit `spec.http.httpEnabled: true` toggle that opens a plain-HTTP listener
on the Service (default port 8080, HTTPS 8443 stays the default-enabled
listener) [15] — so an HTTPRoute can `backendRefs` to `<cr-name>-service:8080`
directly, with TLS terminated once at the shared Gateway and no second
`DestinationRule`/backend-TLS object needed for this feature-step. (Istio
ambient's ztunnel wraps the pod-to-pod hop in mTLS regardless of the
application-layer protocol choice, so plain HTTP inside the mesh is not a
plaintext-on-the-wire concern here [in-repo prior art, `core`'s ambient
profile].) `spec.hostname.hostname` should be set to the chosen dev host so
Keycloak's self-generated issuer/redirect URLs are correct behind the
reverse-proxying Gateway, and `spec.proxy.headers: xforwarded` (shown in the
canonical example above [9]) is the documented setting for exactly that
reverse-proxy scenario.

**Keycloak's admin/bootstrap environment-variable names changed in the 26.x
line** (`KEYCLOAK_ADMIN`/`KEYCLOAK_ADMIN_PASSWORD` → `KC_BOOTSTRAP_ADMIN_USERNAME`/
`KC_BOOTSTRAP_ADMIN_PASSWORD`) [16] — irrelevant to the Operator path chosen
here (which abstracts this via `spec.bootstrapAdmin`), but worth recording
since it is exactly the kind of docs/version drift that bites a
build-time script copied from an older tutorial; noted so the plan/build phases
don't reach for the older env var names if they ever touch a raw container.
Current stable release at research time is the 26.6.x line (26.6.3, released
2026-06-04; 26.6.4 tagged nightly in the Operator docs) [17][1] — a build-time
version pin, not fixed here, consistent with how Networking and Storage both
deferred their own upstream version strings to build time.

## Falsification pass

Two plausible priors were tested against live docs rather than assumed:

1. **"Keycloak ships its own official Helm chart, the way CNPG does for
   Postgres."** Falsified: no official chart exists; the Operator (raw
   manifests) is the only officially-documented non-OLM installation path
   [1][2].
2. **"Bitnami's paywall only affects the datastore charts (Postgres/Valkey)
   Storage already ruled out; Keycloak's Bitnami chart might be a separate,
   still-free case."** Falsified: the same 2025 catalog restructuring and the
   same paid "Bitnami Secure Images" successor program apply to
   `bitnami/keycloak` identically [6][7][8].

Neither falsification changes the recommendation's shape — it sharpens it: the
choice is Operator-vs-community-chart, not Operator-vs-Bitnami, and the
Operator wins independently of Bitnami's licensing change on the strength of
declarative realm import (`KeycloakRealmImport`) and this project's
already-established operator-plus-authored-CRs composition shape.

## Sources

- [1] Keycloak Project. "Keycloak Operator Installation." keycloak.org.
  2026 (Nightly 26.6.4). [Online]. Available:
  https://www.keycloak.org/operator/installation
- [2] keycloak/keycloak GitHub. "Helm Chart for keycloak operator · Issue
  #37636." [Online]. Available: https://github.com/keycloak/keycloak/issues/37636
- [3] helm/charts GitHub (archived). "charts/stable/keycloak." [Online].
  Available: https://github.com/helm/charts/tree/master/stable/keycloak
- [4] codecentric/helm-charts GitHub. "charts/keycloakx README — external
  PostgreSQL, admin credentials via existingSecret." [Online]. Available:
  https://github.com/codecentric/helm-charts/blob/master/charts/keycloakx/README.md
- [5] BLUESHOE / The New Stack (aggregated via search). "Bitnami catalog
  restructuring: free images moved to `bitnamilegacy`, paid 'Bitnami Secure
  Images' successor, deletion postponed to 2025-09-29." 2025. [Online].
- [6] bitnami/charts GitHub. "Upcoming changes to the Bitnami catalog
  (effective August 28th, 2025) · Issue #35164." [Online]. Available:
  https://github.com/bitnami/charts/issues/35164
- [7] Hacker News. "Broadcom to discontinue free Bitnami Helm charts." 2025.
  [Online]. Available: https://news.ycombinator.com/item?id=44608856
- [8] keycloak/keycloak GitHub. "hosting successor of bitnami/keycloak
  chart+image in keycloak · Issue #42143." [Online]. Available:
  https://github.com/keycloak/keycloak/issues/42143
- [9] Keycloak Project. "Basic Keycloak deployment." keycloak.org. [Online].
  Available: https://www.keycloak.org/operator/basic-deployment
- [10] Keycloak Project. "Configuring the database." keycloak.org. [Online].
  Available: https://www.keycloak.org/server/db
- [11] cloudnative-pg/cloudnative-pg GitHub. "[Feature]: allow cross-namespace
  Database and Role configuration · Issue #6043." [Online]. Available:
  https://github.com/cloudnative-pg/cloudnative-pg/issues/6043
- [12] Keycloak Project. "Automating a realm import." keycloak.org. [Online].
  Available: https://www.keycloak.org/operator/realm-import
- [13] Keycloak Project. "Advanced configuration — spec.bootstrapAdmin."
  keycloak.org. [Online]. Available:
  https://www.keycloak.org/operator/advanced-configuration
- [14] Keycloak Project. "Advanced configuration — spec.ingress, the
  `<cr-name>-service` Service." keycloak.org. [Online]. Available:
  https://www.keycloak.org/operator/advanced-configuration
- [15] Keycloak Project / keycloak/keycloak GitHub Issue #22131 (aggregated).
  "spec.http.httpEnabled, default ports 8080/8443." [Online]. Available:
  https://www.keycloak.org/operator/advanced-configuration ;
  https://github.com/keycloak/keycloak/issues/22131
- [16] Keycloak Project. "Configuring Keycloak — KC_BOOTSTRAP_ADMIN_* env
  vars (26.x rename from KEYCLOAK_ADMIN/KEYCLOAK_ADMIN_PASSWORD)."
  keycloak.org. [Online]. Available: https://www.keycloak.org/server/configuration
- [17] Keycloak Project. "Keycloak 26.6.3 released." 2026-06-04. [Online].
  Available: https://www.keycloak.org/2026/06/keycloak-2663-released

In-repo Prior Art (authoritative, not external): `ARCHITECTURE.html` (§ S5
Platform — "Keycloak — Identity: in-cluster OIDC · Tier-2 auth · Postgres-backed
· SpiceDB deferred"), `ROUTING.md` (Keycloak/OIDC Tier-2 gating references),
`DEVELOPMENT.md` § Secrets, project `design.md` § Specification (Auth
bullet) and § Shared contracts, project `plan.md` § Feature 5 and § Shared
Contracts, `features/storage-postgres-valkey/design.md` (the `Cluster.spec.
managed.roles[]` append contract, the `Database` CR shape, the
`secrets/dev/storage/<store>/<slug>.enc.yaml` sealing discipline and its exact
`openssl rand`→stdin→`sops --encrypt` pipeline), `features/networking-istio/
design.md` (the shared `agrippa-gateway`/`agrippa-gateway-tls` consumption
contract: one `HTTPRoute` + one `dnsNames` append; the `argocd-server`
backend-TLS/`DestinationRule` precedent this feature-step's plain-HTTP choice
avoids repeating). Live cluster state (verified this session, 2026-07-08):
`kubectl -n argocd get application platform core storage` → all
`Synced`/`Healthy`; `cat platform/overlays/dev/kustomization.yaml` →
`resources: [argocd.yaml]` (not an empty placeholder — ArgoCD self-management
already lands there); `cat apps/platform.yaml` → no `ServerSideApply`/
`SkipDryRunOnMissingResource` `syncOptions` (unlike `apps/core.yaml` and
`apps/storage.yaml`, both of which carry it for their own CRD-heavy
operators); `storage/overlays/dev/postgres-cluster.yaml` and
`secrets/dev/storage/` tree inspected directly for the exact live contract
shape this feature-step binds to.
