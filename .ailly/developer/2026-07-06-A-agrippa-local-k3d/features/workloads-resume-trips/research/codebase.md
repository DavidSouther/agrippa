# Codebase: Workloads (resume + trips) — current repo state

## Findings

**The `tests/agrippa.bats` three-edit gestalt fix is already committed — it is
not this feature-step's work to author.** `design.md`'s Workloads section and
`plan.md`'s Feature 9 both describe "(a) collapse `GESTALT_ENV`→`ENV`, (b) a
trips dev branch, (c) `curl -k` on dev probes" as this feature-step's item 5.
`git diff HEAD -- tests/agrippa.bats` is empty (working tree matches HEAD) and
`git diff 3b42fa6 a9cdfbc -- tests/agrippa.bats` shows all three edits landed
in commit `a9cdfbc`, whose message states explicitly: "the `test:static`/
`test:policy`/`test:chart`/`test:feature`/`test:gestalt` tasks, the conftest
plaintext-Secret guard with self-tests, and the **three-edit
`tests/agrippa.bats` gestalt fix**" as part of Feature 0 (Prerequisites). The
file today already: uses `ENV` throughout (no `GESTALT_ENV` reference
anywhere — confirmed by `grep`), gives the trips test an `if [ "${ENV}" =
"dev" ]` branch asserting `^(2[0-9][0-9]|3[0-9][0-9])$` reachability with
`curl -sS -k`, and adds `-k` to both the dev-path `/healthz` and Grafana
probes. **This feature-step's remaining job against this file is
verification only**: run it against the real resume/trips Deployments once
they exist and confirm it goes green, not re-author the edits. Design/plan
should correct the still-pending framing inherited from the parent
design/plan.

**No `charts/` directory has ever been populated by a prior feature-step —
this feature-step is the first real use of it.** `find` for `Chart.yaml`
outside vendored caches returns nothing at the repo-root `charts/*/` level;
every `Chart.yaml` that does exist lives under a `<layer>/overlays/dev/
<component>/charts/<chart>-<version>/<chart>/` path — Helm's own
dependency-cache layout produced by kustomize's `helmCharts:` inflator
pulling an *upstream* OCI/https chart (Forgejo's `oci://code.forgejo.org/
forgejo-helm`, Flagsmith's, Keycloak-operator's, Istio's, cert-manager's,
CNPG's, the LGTM stack's — all vendor charts, none hand-authored in-repo).
`scripts/test-chart.sh` (Feature 0) explicitly green-on-empties when no
`charts/` directory exists yet (`"test:chart: no charts/ directory yet,
skipping helm-unittest"`) — it was built anticipating this feature-step being
the one that finally populates `charts/resume/` and `charts/trips/` with
real `Chart.yaml` + `templates/` + `tests/`. **Consequence: there is no
in-repo precedent for the internals of a hand-authored chart** (values
schema, template helpers, `tests/*.yaml` shape) — the design phase looks
outward (public helm-unittest docs) rather than to a sibling.

**The exact Gateway/HTTPRoute/Certificate consumption contract, read
directly from the live manifests** (not just design prose):
- `core/overlays/dev/gateway.yaml` — `Gateway` `agrippa-gateway` in ns
  `istio-ingress`, listener `https` on `:443` with `tls.mode: Terminate`,
  `certificateRefs: [agrippa-gateway-tls]`, `allowedRoutes.namespaces.from:
  All`.
- `core/overlays/dev/gateway-cert.yaml` — `Certificate` `agrippa-gateway-tls`
  in `istio-ingress`, `issuerRef: {name: agrippa-ca, kind: ClusterIssuer}`,
  `dnsNames:` currently lists exactly five hosts (`argocd.127.0.0.1.nip.io`,
  `dashboard.davidsouther.com.127.0.0.1.nip.io`,
  `auth.127.0.0.1.nip.io`, `git.davidsouther.com.127.0.0.1.nip.io`,
  `flagsmith.127.0.0.1.nip.io`) — **`davidsouther.com.127.0.0.1.nip.io` and
  `trips.davidsouther.com.127.0.0.1.nip.io` are not yet present**; this
  feature-step must append both to this one shared, cross-cutting file (the
  same append-only discipline every prior UI feature used, and the same
  merge-contention watch-item `.ailly/developer/TASKS.md` already records
  under "Per-feature Certificates and per-host blast radius").
- `platform/overlays/dev/forgejo/httproute.yaml` is the cleanest concrete
  `HTTPRoute` template to imitate: `parentRefs: [{name: agrippa-gateway,
  namespace: istio-ingress, sectionName: https}]`, an explicit `matches:
  [{path: {type: PathPrefix, value: /}}]` (the comment there flags that an
  *omitted* `matches:` left `core`'s own ArgoCD route permanently
  OutOfSync — a live-hit trap to avoid by design fiat, not luck), and a
  same-namespace `backendRefs`.
- `platform/overlays/dev/forgejo/kustomization.yaml` /
  `.../forgejo/chart/kustomization.yaml` /
  `.../forgejo/namespace.yaml` together are the closest concrete precedent
  for "one component subdirectory appended to a shared layer
  `kustomization.yaml`'s `resources:` list," including the
  `commonAnnotations: {argocd.argoproj.io/sync-wave: "0"}` pattern on the
  chart-composing kustomization and a `-10`-wave `Namespace`.

**`workloads/overlays/dev/kustomization.yaml` is still the literal
`resources: []` placeholder** its own header comment describes ("Empty-but-
valid placeholder... must reach zero-resource Synced/Healthy trivially until
a later feature-step... lands real content"). `apps/workloads.yaml` (the
layer's single ArgoCD `Application`, sync-wave `"4"`, the last layer) already
points `source.path: workloads/overlays/dev` — no change needed there, only
to what that path composes.

**No `.gitmodules` exists anywhere in this repo yet** — the git-submodule
vendoring mechanism design.md's resolved decision 2 proposes is genuinely new
to this project, not a pattern to copy from a sibling.

**Docker is a deliberate non-`mise`-managed ambient dependency, already
established** (not something this feature-step introduces). `GETTING_STARTED.md`:
"Mise manages all tools, so it and docker are only ambient dependencies";
`tests/preflight.bats` gates `docker is installed` / `docker daemon is
running and reachable` / CPU and memory allocation, all via `docker info`,
with **no** `[tools]` entry for docker in `mise.toml`. This is the direct
precedent for concluding Node also needs no `mise.toml` pin: like Docker, it
only needs to exist inside the multi-stage image's build stage, and neither
the parent design's own npm-build steps nor the proposed `workloads:build`
task run `npm` on the host.

**The `bootstrap` task is the exact structural precedent for `workloads:build`**
(`mise.toml` `[tasks.bootstrap] file = "scripts/bootstrap.sh"` → a plain,
idempotent bash script, staged with comments, using `set -euo pipefail`). The
project design explicitly calls this out as the shape to match: "the one
deliberate imperative step outside GitOps... the same shape as the already-
built `bootstrap` task."

**Resource pressure is real and already caused a build-time fix.** `git log
--oneline` shows `db93c91 fix(plat): raise the flagsmith api container's
memory limit to stop an OOMKill` — direct evidence (not just the coordinator's
framing) that this single-node dev cluster has hit real scheduling pressure
this session. Static-site-serving containers (nginx/node serving pre-built
files) are cheap by comparison, but an unbounded/request-less container is
flagged as a "noisy-neighbor risk" in the forgejo chart's own comments even
where the node has ample headroom — the same discipline (explicit, modest
`resources.requests`/`limits`) should carry to `charts/resume` and
`charts/trips`.

**No workload in this repo has needed a per-app Postgres `Database` CR**
except Auth/Forgejo/Flagsmith — `.ailly/developer/TASKS.md`'s "A `Database`
CR must precede its consuming Deployment's own wave" cross-cutting finding
explicitly flags that Feature 9 likely does not recur it, since resume and
trips are static sites with no runtime datastore. Confirmed: no secrets
directory exists at `secrets/dev/workloads/` and none is needed by this
feature-step's own scope.

## Sources

- Direct repository inspection at the current working-tree commit (`git log`,
  `git diff`, `git show`, `find`, `grep`, `Read`) of: `tests/agrippa.bats`;
  `mise.toml`; `scripts/test-chart.sh`; `scripts/bootstrap.sh`;
  `GETTING_STARTED.md`; `tests/preflight.bats`; `core/overlays/dev/
  gateway.yaml`; `core/overlays/dev/gateway-cert.yaml`;
  `platform/overlays/dev/forgejo/{namespace.yaml,httproute.yaml,
  kustomization.yaml,chart/kustomization.yaml}`; `apps/workloads.yaml`;
  `workloads/overlays/dev/kustomization.yaml`; `.ailly/developer/TASKS.md`.
- Commit `a9cdfbc` ("feat: land Feature 0 (mise + testing harness) plus
  in-progress cluster/GitOps scaffolding") and its diff against `3b42fa6`.
