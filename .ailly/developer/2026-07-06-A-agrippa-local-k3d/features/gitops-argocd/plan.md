# Implementation Plan: GitOps (ArgoCD app-of-apps, KSOPS/age, local bootstrap)

*Reviewed 2026-07-07*

> A separately dispatched long-loop reviewer cleared this feature plan's draft
> gate on 2026-07-07. This plan carries no net-new "Open Artifact Decision"
> section of its own (it transcribes the already-cleared feature design's
> Specification, per that design's resolved decisions 1 and 2), so the review's
> job was to verify the plan's steps against the cleared `design.md`, against
> the actually-committed repo state (`tests/gitops.bats`, `mise.toml`,
> `DEVELOPMENT.md`, `tests/policy/secrets.rego`, `git remote -v`), and against
> current external tool-version data (`mise ls-remote`). Two corrections were
> made directly to this document (the `sops`/`age`/`kustomize` tool pins, and a
> command-line-argument secret-exposure inconsistency in Step 1's Implementation
> Outline); everything else checked out with no change needed. No escalation
> trigger fired; the full record is in the *Resolved by the long-loop reviewer*
> block at the end of this document.

**Feature test:** `tests/gitops.bats`
**User story:** Given the running `agrippa-dev` cluster, the Step 0 toolchain, and an unlocked Bitwarden session holding `agrippa-age-dev`, when an operator runs `mise run bootstrap`, then the `sops-age` trust root exists in `argocd`, the repo-server is KSOPS-enabled, the root app-of-apps is self-managing and Synced/Healthy, and the five-layer skeleton (`core`/`storage`/`platform`/`observability`/`workloads`) is registered.

**Libraries & Skills (carried forward from `design.md`; load before each build step):**

- `developer:initialize` — this feature adds `sops`, `age`, `kustomize` pins (optionally `argocd`) and the `bootstrap` task to the Step 0 `mise.toml`.
- `research:public` and `research:codebase` for per-tool detail the build hits (a KSOPS repo-server plugin flag, an ArgoCD `Application` field, a `sync-wave` edge case, the exact pinned ArgoCD install manifest).
- No library-shipped agentic skill exists for ArgoCD, KSOPS, SOPS, or age (confirmed again this session per `design.md`'s directive). Build to `DEVELOPMENT.md` (`## Secrets`, `## Testing`), `ARCHITECTURE.html` (app-of-apps view), and `README.md` (Cluster Infrastructure table) directly.

**Patterns beat (`patterns:using-patterns` consulted):** No domain-object pattern applies — this feature-step has no typed application code, only infrastructure config (a `mise` task, ArgoCD `Application` CRDs, a kustomize install tree, one bats suite), mirroring `cluster-core-k3d`'s same conclusion. `newtype`, `domain-objects`, `type-states`, `parse-dont-validate`, `aggregate`, and the persistence patterns all require a typed domain model that does not exist here. Two patterns shape *how* the surface and its tests are written: **`arrange-act-assert`** for the one bats `@test` (setup/`run`/assert, matching the sibling suites), and **`errors-typed-untyped`**, resolved to the untyped side — a `mise` task's process exit code is the correct, sufficient failure signal for `bootstrap`, consumed only by an operator's shell and by bats; no in-process caller needs distinct typed failure modes. One additional pressure specific to this feature: the `sops-age` **Secret is a trust-root artifact, not a domain object** — it is created imperatively by `bootstrap` and never modeled as an application type, consistent with the "no typed domain model" conclusion above.

**Steps:**
- [x] Step 0: API surface area
- [x] Step 1: Trust root — namespace, `sops-age` Secret, `.sops.yaml` dev recipient
- [x] Step 2: KSOPS-enabled ArgoCD install
- [x] Step 3: App-of-apps skeleton and root self-management (feature test green) — unblocked, see note below
- [x] Step 4: Idempotency, `test:feature` exclusion, and regression safety

## Step 0: API surface area

Fix every file path and task/resource name before any has real logic, mirroring `cluster-core-k3d`'s Step 0 convention (honest fail-loud stub bodies, not silent no-ops).

```toml
# mise.toml -- tool pins (real values; not "logic") and a stub task body
[tools]
sops        = "3.13.2"     # current stable; cross-checked against `mise ls-remote sops`
age         = "1.3.1"      # current stable; cross-checked against `mise ls-remote age`
kustomize   = "5.8.1"      # current stable; cross-checked against `mise ls-remote kustomize`
# argocd CLI: optional pin, only if the build finds a CLI-driven check useful;
# bw (Bitwarden CLI) stays operator-provided, never pinned (DEVELOPMENT.md custody).

[tasks."bootstrap"]
description = "Create the sops-age trust root, install a KSOPS-enabled ArgoCD, apply the root app-of-apps once"
run = "echo 'not implemented: bootstrap' >&2; exit 1"
```

```yaml
# .sops.yaml -- path-scoping rule only; PLACEHOLDER recipient.
# The real dev age public key is generated once via `age-keygen` and its
# private half stored in Bitwarden as `agrippa-age-dev` (Step 1 build-time
# prerequisite, human-gated by Bitwarden write access) -- never fabricated
# in this design/plan artifact.
creation_rules:
  - path_regex: secrets/dev/.*
    age: "AGE-PLACEHOLDER-REPLACE-WITH-REAL-agrippa-age-dev-PUBLIC-KEY"
```

```yaml
# apps/kustomization.yaml -- lists every Application manifest this step defines
resources:
  - root.yaml
  - core.yaml
  - storage.yaml
  - platform.yaml
  - observability.yaml
  - workloads.yaml
```

```yaml
# apps/root.yaml, apps/core.yaml, apps/storage.yaml, apps/platform.yaml,
# apps/observability.yaml, apps/workloads.yaml -- name/kind fixed now, spec
# (source, destination, sync-wave, syncPolicy) filled in Step 3.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root            # (or core/storage/platform/observability/workloads)
  namespace: argocd
spec: {}                 # stub -- Step 3 fills this in
```

```yaml
# apps/platform/argocd/kustomization.yaml -- empty for now; Step 2 fills in
# the pinned ArgoCD install manifest + the KSOPS repo-server patch.
resources: []
```

This fixes: the `bootstrap` task ID; the `.sops.yaml` path-scoping rule shape (real recipient value deferred to Step 1); the flat `apps/<layer>.yaml` layout and all six Application names (per the cleared design's resolved decision 1); and the `apps/platform/argocd/` install home (resolved decision 2). `tests/gitops.bats` is a `design.md` artifact and already exists (it captured this feature-step's RED baseline: "no such task"); Step 0 does not touch it. After Step 0, `mise run bootstrap`'s first assertion (`[ "$status" -eq 0 ]`) still fails, now for the legible reason the stub exits 1 rather than "no such task."

## Step 1: Trust root — namespace, `sops-age` Secret, `.sops.yaml` dev recipient

**Enables:** `tests/gitops.bats`'s first two assertions: `run mise run bootstrap; [ "$status" -eq 0 ]` and `kubectl -n argocd get secret sops-age`. The repo-server, root-app, and five-layer assertions still fail (nothing installed yet).

**Build-time prerequisite (human-gated, not fabricated here):** if `agrippa-age-dev` does not yet exist in Bitwarden, generating it (`age-keygen`, private half written straight to Bitwarden via `bw create`/`bw edit`, public half committed to `.sops.yaml`) is a one-time custody action requiring an unlocked Bitwarden session — surface it as a blocker per `design.md`'s failure-mode analysis if the item is absent, never invent a key.

Implement `bootstrap`'s body through the trust-root stage only (stages 3-4 land in Steps 2-3, so the task body simply ends here for now): require `bw` present and its session unlocked; `bw get notes agrippa-age-dev` piped directly into `kubectl create secret generic sops-age --from-file=key.txt=/dev/stdin` (or equivalent) so the key never touches a temp file or a command-line argument; `kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -` and the same apply-not-create pattern for the Secret, so re-running is idempotent. Any `bw` failure (missing binary, locked vault, missing item) exits non-zero with a message naming the missing prerequisite — no plaintext fallback.

**Tests**

```bash
test "bootstrap creates the argocd namespace and sops-age Secret idempotently":
  run mise run bootstrap
  assert status == 0
  run kubectl --context k3d-agrippa-dev -n argocd get secret sops-age
  assert status == 0
  run mise run bootstrap        # second run
  assert status == 0
  run kubectl --context k3d-agrippa-dev -n argocd get secret sops-age
  assert status == 0            # still there, not duplicated or errored
```

- Edge case: `bw` not installed, not logged in, or locked → `bootstrap` exits non-zero with a clear, named-prerequisite message; no key is written to disk or committed.
- Edge case: `agrippa-age-dev` absent from Bitwarden → same fail-loud behavior, reported as a human-resolved blocker, not generated inline by the task.
- Edge case: re-running against an already-bootstrapped namespace/Secret does not error and does not recreate (namespace/Secret both use the `apply`, not `create`, idempotency pattern).

**Implementation Outline**

```text
task bootstrap:
  require bw present and unlocked, else exit 1 with named-prerequisite message
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  bw get notes agrippa-age-dev | \
    kubectl create secret generic sops-age -n argocd --from-file=key.txt=/dev/stdin \
      --dry-run=client -o yaml | kubectl apply -f -
  # piped directly, stdin only -- never a shell variable interpolated into a
  # command-line argument, matching Step 1's "no command-line argument" body text
  # stages 3-4 appended in Steps 2-3
```

## Step 2: KSOPS-enabled ArgoCD install

**Enables:** `tests/gitops.bats`'s repo-server assertion: `kubectl -n argocd get deployment argocd-repo-server -o yaml` contains both `ksops` and `sops-age`. The root-app and five-layer assertions still fail (nothing applied under `apps/` yet).

Fill `apps/platform/argocd/kustomization.yaml`: `resources` references the pinned upstream ArgoCD install manifest (namespace `argocd`); a strategic-merge `patches` entry on the `argocd-repo-server` Deployment adds an init container that installs `sops`/`kustomize`/`ksops` into a shared `emptyDir`, mounts that volume plus a volume sourced from the `sops-age` Secret onto the repo-server container, and sets the ksops plugin's expected config path/env — the concrete field names are a build-time `research:public` lookup against the KSOPS project's documented repo-server patch, re-derived rather than copied from this sketch. Append stage 3 to `bootstrap`: `kubectl apply -k apps/platform/argocd --wait` (or an explicit `kubectl wait --for=condition=available deployment/argocd-repo-server -n argocd`), so the task now exits 0 only once the KSOPS-patched repo-server is actually ready.

**Tests**

```bash
test "the repo-server deployment is KSOPS-enabled after bootstrap":
  run mise run bootstrap
  assert status == 0
  run kubectl --context k3d-agrippa-dev -n argocd get deployment argocd-repo-server -o yaml
  assert output contains "ksops" (case-insensitive)
  assert output contains "sops-age"
```

- Edge case: the init container must run to completion (not linger as an unready sidecar) or `--wait`/`kubectl wait` never returns; verify with a real `kubectl rollout status`.
- Edge case: re-applying `apps/platform/argocd` against an already-installed ArgoCD must not restart or duplicate unrelated ArgoCD components (server, application-controller, dex) — `kubectl apply -k` is declarative and idempotent by construction, but this is worth a live check.
- Edge case: the `sops-age` Secret from Step 1 must already exist before this stage runs, or the volume mount fails at pod scheduling — stage ordering inside `bootstrap` matters.

**Implementation Outline**

```text
# apps/platform/argocd/kustomization.yaml
resources:
  - https://.../install.yaml?ref=<pinned-tag>   # exact ArgoCD version, research at build
patches:
  - target: {kind: Deployment, name: argocd-repo-server}
    patch: |
      - op: add
        path: /spec/template/spec/initContainers/-
        value: {name: ksops-install, ...}        # installs sops/kustomize/ksops
      - op: add
        path: /spec/template/spec/volumes/-
        value: {name: sops-age, secret: {secretName: sops-age}}

task bootstrap (stage 3 appended):
  kubectl apply -k apps/platform/argocd --wait
```

## Step 3: App-of-apps skeleton and root self-management (feature test green)

**Enables:** the remaining two assertions — `wait_for_synced_healthy root` and `kubectl -n argocd get application <layer>` for all five layers. After this step `tests/gitops.bats` is fully GREEN.

Fill each layer Application (`core.yaml` … `workloads.yaml`): `spec.destination` = in-cluster; `spec.project` = `default`; `spec.source.repoURL` = this repo's committed git remote (`origin`, branch `main` — the exact URL form, https vs ssh with a configured repo credential, is a build-time detail to re-derive, not fixed here); `spec.source.path` = `<layer>/overlays/dev`, a **new, empty-but-valid** kustomization (`resources: []`) this step also creates at each of those five paths, so every layer Application syncs zero resources and reports Synced/Healthy trivially; `metadata.annotations["argocd.argoproj.io/sync-wave"]` = `0/1/2/3/4` for `core/storage/platform/observability/workloads` respectively; `spec.syncPolicy.automated = {prune: true, selfHeal: true}`; `core.yaml` additionally sets `syncOptions: [ServerSideApply=true, SkipDryRunOnMissingResource=true]` as a forward seam for the CRD-heavy content (cert-manager, Gateway API, Istio) a later feature-step lands there. Fill `apps/root.yaml`: same destination/project, `spec.source.path = apps` (the directory this very file lives in), `syncPolicy.automated = {prune: true, selfHeal: true}` — this is the "manages itself" property, since ArgoCD reconciling `apps/` re-applies `apps/root.yaml` itself. Add a thin `argocd` Application inside the platform layer's own kustomization (`platform/overlays/dev`) pointing at `apps/platform/argocd`, so ArgoCD's own install is self-managed from the same source the manual `bootstrap` applied once (resolved decision 2). Append stage 4 to `bootstrap`: `kubectl apply -k apps` (once — idempotent, ArgoCD reconciles from there).

**Tests**

```bash
test "bootstrap yields a Synced/Healthy self-managing root and five registered layers":
  run mise run bootstrap
  assert status == 0
  run bats tests/gitops.bats     # the feature test itself
  assert status == 0
```

- Edge case: `apps/root.yaml`'s `source.path` must be `apps` (the directory), not `apps/root.yaml` (the file) — pointing at itself as a single manifest, rather than the directory, breaks the "manages the whole apps/ tree including itself" property.
- Edge case: each layer's placeholder `<layer>/overlays/dev/kustomization.yaml` must exist and be valid (`resources: []`) so ArgoCD renders zero resources rather than erroring on a missing directory — Health must default to Healthy on an empty resource set, not Unknown or Missing.
- Edge case: sync-wave ordering must not block the skeleton itself — with no cross-layer resource dependency yet, all five layer Applications and root can reach Synced/Healthy in one reconcile pass; waves only bite once real content lands in a later feature-step.
- Edge case: the plaintext-`Secret` conftest guard (`tests/policy/secrets.rego`) must stay green — nothing committed under `apps/` or the new `<layer>/overlays/dev` paths is a plaintext Secret.

**Implementation Outline**

```text
# apps/root.yaml (filled)
spec:
  project: default
  source: {repoURL: <origin-url>, targetRevision: main, path: apps}
  destination: {server: https://kubernetes.default.svc, namespace: argocd}
  syncPolicy: {automated: {prune: true, selfHeal: true}}

# apps/core.yaml (filled; storage/platform/observability/workloads follow the same shape)
metadata:
  annotations: {argocd.argoproj.io/sync-wave: "0"}
spec:
  project: default
  source: {repoURL: <origin-url>, targetRevision: main, path: core/overlays/dev}
  destination: {server: https://kubernetes.default.svc, namespace: argocd}
  # syncOptions nests under syncPolicy, not spec -- corrected at build time
  # against the live v3.4.4 Application CRD schema (see Build-time correction
  # below); this outline originally had it as a spec-level sibling of
  # syncPolicy, which `kubectl apply` rejects under strict decoding.
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: ["ServerSideApply=true", "SkipDryRunOnMissingResource=true"]

task bootstrap (stage 4 appended):
  kubectl apply -k apps
```

**Build-time correction (this session):** `spec.syncOptions` (as written above and
originally in `apps/core.yaml`/`platform/overlays/dev/argocd.yaml`) is rejected
by `kubectl apply` with `strict decoding error: unknown field "spec.syncOptions"`
against the real ArgoCD v3.4.4 Application CRD, confirmed by inspecting the
CRD's `openAPIV3Schema` directly: `syncOptions` is one of
`spec.syncPolicy`'s properties (alongside `automated`, `retry`,
`managedNamespaceMetadata`), not a `spec`-level sibling of `syncPolicy`. Fixed
in both files to nest `syncOptions` under `syncPolicy`; the outline above is
corrected to match. Reversible, in scope (this step's own manifests), not
underdetermined (the live CRD schema is authoritative).

**Blocker found this session, resolved by the user.** With the syncOptions fix
applied, `mise run bootstrap` exited 0 and created all six Applications, but
`root` never reached Synced — `kubectl -n argocd get application root
-o jsonpath='{.status.conditions}'` reported `"failed to list refs: remote
repository is empty"`. Verified independently: `git ls-remote
https://github.com/DavidSouther/agrippa.git` and `gh api
repos/DavidSouther/agrippa --jq .size` (returned `0`) both confirmed the
`origin` remote (`git@github.com:DavidSouther/aristotle.git`, an outdated
working name) had never been pushed to. Build execution stopped rather than
pushing local history to a public GitHub repository unilaterally (a
human-owned, git-safety-gated action) or faking a green result. The
coordinator asked the user directly; the user confirmed Aristotle was an
outdated prior working name, `DavidSouther/agrippa` is the real (public,
empty) repo, and authorized repointing `origin` and pushing. `origin` was
updated from `git@github.com:DavidSouther/aristotle.git` to
`git@github.com:DavidSouther/agrippa.git` and `git push -u origin main`
landed the 4 local commits. After a `argocd.argoproj.io/refresh=hard` on each
Application, all seven (`root` + the five layers + the self-managed `argocd`
app) reached `Synced`/`Healthy`, and `tests/gitops.bats` now passes end to
end.

## Step 4: Idempotency, `test:feature` exclusion, and regression safety

**Enables:** no new bats assertion (the suite is already green after Step 3) — this step closes `design.md`'s remaining non-assertion Metrics: `bootstrap` idempotent end-to-end, the `test:feature` auto-discovery exclusion, and no regression to earlier harness.

Add one line to the Step 0 `mise.toml`'s `test:feature` task: exclude `gitops.bats` from its `tests/*.bats` auto-discovery loop, alongside the existing `agrippa.bats|harness.bats|preflight.bats|cluster-core.bats` exclusions (per `design.md`'s Cross-step touches), since this suite drives `bootstrap` against the long-lived `agrippa-dev` cluster, not `test:feature`'s throwaway one. No task-body change beyond this line; `bootstrap` itself (Steps 1-3) is already written to be safely re-run.

**Tests**

```bash
test "bootstrap re-run end-to-end does not error, duplicate, or wipe ArgoCD":
  run mise run bootstrap
  assert status == 0
  server_created_1="$(kubectl --context k3d-agrippa-dev -n argocd get pod -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.creationTimestamp}')"
  run mise run bootstrap        # second run
  assert status == 0
  run bats tests/gitops.bats
  assert status == 0
  server_created_2="$(kubectl --context k3d-agrippa-dev -n argocd get pod -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.creationTimestamp}')"
  assert server_created_1 == server_created_2   # not recreated

test "test:feature stays green-on-empty and does not pick up gitops.bats":
  run mise run test:feature
  assert status == 0

test "no regression to earlier harness":
  run mise run test:push
  assert status == 0
  run bats tests/harness.bats
  assert status == 0
  run bats tests/cluster-core.bats
  assert status == 0
```

- Edge case: a second `bootstrap` run mid-sync (ArgoCD still reconciling from the first) must not error — `kubectl apply -k`/`--wait` are safe to interleave with ArgoCD's own reconciliation.
- Edge case: the `test:feature` exclusion `case` list must still run every other `tests/*.bats` probe unchanged.
- Edge case: this step's `mise.toml`/`apps/`/`.sops.yaml` additions must not regress `test:static` (kubeconform + the plaintext-Secret conftest guard) or `test:chart`.

**Implementation Outline**

```diff
# mise.toml, test:feature task's exclusion case list
- agrippa.bats|harness.bats|preflight.bats|cluster-core.bats) continue ;;
+ agrippa.bats|harness.bats|preflight.bats|cluster-core.bats|gitops.bats) continue ;;
```

## Resolved by the long-loop reviewer (2026-07-07)

This plan carries no net-new "Open Artifact Decision" section of its own (that
gate already ran and cleared at the feature design, per its Summary's *Resolved
by the long-loop reviewer (2026-07-06)* block), so this review's job was to
verify the plan's steps against the cleared `design.md`, against the currently
committed repo state, and against live external tool-version data, correcting
in place wherever the plan's own text disagreed with itself or with the
project's established conventions. Researched via `research:codebase` (direct
inspection of `tests/gitops.bats`, `mise.toml`, `DEVELOPMENT.md`,
`tests/policy/secrets.rego`, and `git remote -v` against the real repo tree)
and `research:dependencies`/`mise ls-remote` (the exact mechanism this plan's
own Step 0 comments name) for the three new tool pins. No escalation trigger
(irreversible, out of recorded scope, underdetermined) fired.

**1. `sops`/`age`/`kustomize` tool-pin versions: leave "pin to research at
build" or decide a concrete current-stable value now. Decided: pin to current
stable now — `sops = "3.13.2"`, `age = "1.3.1"`, `kustomize = "5.8.1"`.** The
plan's Step 0 code block already labels these "real values; not 'logic'" (the
same status as every other Step 0 fixed name/path), but the three version
strings it carried (`3.9.4`/`1.2.1`/`5.5.0`) were stale placeholders deferred
with a "pin to research at build" comment. The repo's own committed root
`mise.toml` already establishes the applicable convention for exactly this
situation: `kubeconform` and `conftest` are pinned to concrete values with the
comment "current stable; cross-checked against `mise ls-remote`", decided at
plan/design time rather than deferred. Running that same command
(`mise ls-remote sops|age|kustomize`) against the live `mise` registry returned
`3.13.2`/`1.3.1`/`5.8.1` as the current latest release of each, so this review
pinned to those and reworded the comments to match the established
"cross-checked" convention. Reversible (a version bump, nothing else depends on
the exact string) and squarely in this plan's own recorded Step 0 scope (its
Libraries & Skills line already names these three pins as this feature's
addition to `mise.toml`); not underdetermined, since `mise ls-remote` is a
deterministic, authoritative source the plan itself names as the checking
mechanism. This is the conservative default: match the convention the rest of
the file already follows rather than leave a second, inconsistent deferral
style live in the same document. (The ArgoCD install manifest's pinned tag and
the KSOPS repo-server patch's exact field names were left as-is, still deferred
to build-time `research:public` — unlike a `mise`-registry version, those
require reading the live KSOPS/ArgoCD project docs for exact YAML shape, which
`design.md`'s Libraries & Skills and this plan's own text both already name as
build-phase, tool-specific research, consistent throughout the plan and not a
net-new gap this gate should close.)

**2. Step 1's Implementation Outline used `--from-literal=key.txt="$key"` to
create the `sops-age` Secret, which contradicts the same step's own prose.
Decided: rewrite the outline to pipe `bw get notes agrippa-age-dev` directly
into `kubectl create secret generic sops-age --from-file=key.txt=/dev/stdin`,
matching the prose.** Step 1's body text is explicit: the key must reach
`kubectl` "piped directly ... so the key never touches a temp file or a
command-line argument" — and `design.md`'s Challenges section states the same
invariant ("The secret never touches disk or git... must avoid temp files and
command-line exposure of the key"). The Implementation Outline's own
`--from-literal=key.txt="$key"` line put the decrypted key value directly into
a process's argv (visible via `ps`/`/proc/<pid>/cmdline` on any multi-tenant or
logged host), directly contradicting the paragraph immediately above it in the
same document. This is not a judgment call — the plan's own prose already fixed
the conservative, secure answer two paragraphs earlier; the outline just failed
to match it. Corrected to a direct `bw get notes agrippa-age-dev | kubectl
create secret ... --from-file=key.txt=/dev/stdin` pipe, which never assigns the
key to a shell variable or an argv position. Reversible, in scope (Step 1's own
content), and not underdetermined (the prose and `DEVELOPMENT.md`/`design.md`
custody policy all already agree on the answer).

**3. Does the plan's step decomposition still match the cleared feature
design's Specification? Decided: yes — no change needed.** The flat
`apps/<layer>.yaml` layout and the `apps/platform/argocd/` install home
(design's resolved decisions 1 and 2) are both correctly carried into Step 0's
file inventory and Step 2/3's content. The root Application name `root`
(design's resolved decision 3) matches `tests/gitops.bats` line 100's
`wait_for_synced_healthy root` exactly. The sync-wave integers
`core=0/storage=1/platform=2/observability=3/workloads=4` (design's resolved
decision 4) are reproduced verbatim in Step 3. The `secrets/dev/` sub-layout
(design's resolved decision 5) is correctly left untouched by this plan, since
that decision itself defers the concrete per-component paths to each owning
layer's own future feature-step, not this one.

**4. Are the plan's claims about current repo state accurate? Decided: yes —
verified, no change needed.** `research:codebase` confirmed: `tests/gitops.bats`
exists with exactly the RED baseline and assertion shape the plan describes
(the `root` name at line 100; the `sops-age`/`ksops`/five-layer assertions);
the Step 0 `mise.toml`'s `test:feature` exclusion list currently reads
`agrippa.bats|harness.bats|preflight.bats|cluster-core.bats) continue ;;`,
exactly the pre-image Step 4's diff assumes; `DEVELOPMENT.md` § Secrets already
carries the `.sops.yaml` path-rule example at line 61 and the
`storage/postgres/secret.enc.yaml` example at line 96, matching the design's
own cross-references; `tests/policy/secrets.rego` already implements the
plaintext-`Secret` deny/allow shape Step 3/4's edge cases assume; and neither
`apps/`, `.sops.yaml`, nor any `sops`/`age`/`kustomize` `mise.toml` pin exist
yet in the repo tree, consistent with `design.md`'s explicit statement that its
Design-phase run left the feature test RED and did not build anything. `git
remote -v` returned an SSH-form remote (`git@github.com:DavidSouther/aristotle.git`),
confirming Step 3's deferral of "the exact URL form, https vs ssh with a
configured repo credential" to build-time was the right call rather than an
omission — an SSH remote needs a build-time decision about ArgoCD repo
credentials (deploy key vs. switching to an HTTPS PAT) that this plan cannot
responsibly guess.

**5. Does the plan carry any other net-new open decision needing escalation?
Decided: no — the gate clears.** No irreversible, out-of-scope, or
underdetermined item remains. The `*Draft*` marker is removed (changed to
*Reviewed*).
