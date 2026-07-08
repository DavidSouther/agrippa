# Implementation Plan: Cluster core (local k3d substrate)

*Reviewed 2026-07-06*

> A separately dispatched long-loop reviewer cleared this feature plan's draft
> gate on 2026-07-06. It found no net-new Open Artifact Decision of its own (the
> plan transcribes the already-cleared feature design's Specification) and,
> uniquely for this feature-step, live-verified every step's claim against the
> already-materialized artifacts and the running `agrippa-dev` cluster (bats
> suite, idempotent re-run, `--disable` flags, port-map, `test:feature`
> exclusion, no regression to `test:push`/`harness.bats`) rather than only
> reading the repo tree. No discrepancy was found and no correction was needed;
> the full record is in the *Resolved by the long-loop reviewer* block at the
> end of this document. No escalation trigger fired.

**Feature test:** `tests/cluster-core.bats`
**User story:** Given a clean checkout with the Step 0 toolchain (k3d, kubectl, docker) and a running Docker daemon, when an operator runs `mise run cluster:up`, then a single-node local k3d cluster named `agrippa-dev` is Ready with ServiceLB and Traefik both disabled and host `:443` published through the k3d loadbalancer.

**Libraries & Skills (carried forward from `design.md`; load before each build step):**

- `developer:initialize`, for any residual `mise` question. This feature only adds `cluster:up`/`cluster:down` tasks to the already-shaped Step 0 `mise.toml`, with no new `[tools]` entries or task-family conventions.
- `research:public` and `research:codebase` for any per-tool detail the build hits (a `k3d.io/v1alpha5` config field, a metallb-vs-ServiceLB nuance, the k3d loadbalancer port-map mechanics).
- No library-shipped agentic skill exists for k3d, k3s, or metallb (confirmed again this session per `design.md`'s Libraries & Skills directive). Build to `ARCHITECTURE.html` (Cluster Core layer, Environments table), `README.md`, and `DEVELOPMENT.md` directly.

**Patterns beat (`patterns:using-patterns` consulted):** No domain-object pattern applies. This feature-step has no typed application code, only infrastructure config (a k3d YAML manifest, two mise/bash tasks, one bats suite). `newtype`, `domain-objects`, `type-states`, `parse-dont-validate`, `aggregate`, and the persistence patterns all require a typed domain model that does not exist here, so none are invoked. Two patterns shape *how* the surface and its tests are written, not the surface itself: **`arrange-act-assert`** for the one bats `@test` (the existing setup/`run`/assert shape `tests/cluster-core.bats` and its sibling suites already follow), and **`errors-typed-untyped`**, resolved to the untyped side. A task's process exit code is the correct, sufficient failure signal for `mise run cluster:up`/`cluster:down`, consumed only by an operator's shell and by bats; no in-process caller needs to match distinct typed failure modes.

**Steps:**
- [x] Step 0: API surface area
- [x] Step 1: Single-node cluster stands up and reaches Ready
- [x] Step 2: ServiceLB and Traefik disabled at the k3s layer
- [x] Step 3: Host port-map, idempotent re-run, and the `test:feature` exclusion (feature test goes green)

**Checkbox note (2026-07-08, long-loop coordinator):** these four steps were
already fully built and live-verified — the plan's own *Resolved by the
long-loop reviewer (2026-07-06)* block below executed every step's claim
against the running `agrippa-dev` cluster and found nothing needing
correction — but the checkboxes above were never ticked during that build.
Re-verified again now (`bats tests/cluster-core.bats` → `ok 1`) before
ticking, per this session's own regression pass.

## Step 0: API surface area

Fix the file layout and the two task IDs before either has real logic, mirroring the Step 0 `mise.toml`'s existing task-family convention (named `[tasks."namespace:verb"]`, honest stub bodies rather than silent no-ops).

```yaml
# k3d/agrippa-dev.yaml -- Step 0 skeleton, minimum viable Simple config
# (servers/agents/image fixed now; extraArgs and ports land in Steps 2-3)
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: agrippa-dev
servers: 1
agents: 0
image: rancher/k3s:v1.35.5-k3s1
options:
  k3d:
    wait: true
    timeout: "120s"
```

```toml
# mise.toml -- Step 0 stub task bodies (added to the existing Step 0 file)

[tasks."cluster:up"]
description = "Create (or ensure) the local agrippa-dev k3d cluster from k3d/agrippa-dev.yaml"
run = "echo 'not implemented: cluster:up' >&2; exit 1"

[tasks."cluster:down"]
description = "Delete the local agrippa-dev k3d cluster"
run = "echo 'not implemented: cluster:down' >&2; exit 1"
```

This fixes the config file path (`k3d/agrippa-dev.yaml`), the cluster name (`agrippa-dev`), and the two task IDs (`cluster:up`/`cluster:down`) every later step fills in. `tests/cluster-core.bats` is a `design.md` artifact and already exists (it captured this feature-step's RED baseline: "no such task"); Step 0 does not touch it. After Step 0, `mise run cluster:up`'s first assertion (`[ "$status" -eq 0 ]`) still fails, now for the legible reason the stub exits 1 rather than "no such task."

## Step 1: Single-node cluster stands up and reaches Ready

**Enables:** `tests/cluster-core.bats`'s first two assertions: `run mise run cluster:up; [ "$status" -eq 0 ]` and `wait_for_node_ready` (kubectl reports the node `Ready`). The Traefik-absent, ServiceLB-disabled, and port-443 assertions still fail.

Implement `cluster:up`'s create path: `k3d cluster create --config k3d/agrippa-dev.yaml` (the Step 0 config's `options.k3d.wait: true` / `timeout: "120s"` already blocks until the node is Ready, matching `tests/preflight.bats`'s `wait_for_node_ready` model). Implement `cluster:down` as `k3d cluster delete agrippa-dev`. Skip the existence guard (Step 3) and the `--disable` args (Step 2) for now; a bare create is the smallest slice that gets a Ready node.

**Tests**

```bash
test "cluster:up creates agrippa-dev and its node reaches Ready":
  run mise run cluster:up
  assert status == 0
  run kubectl --context k3d-agrippa-dev get nodes --no-headers
  assert output contains "Ready"
```

- Edge case: `cluster:up` must exit non-zero (not hang past the config's 120s wait timeout) if Docker is not running or lacks the preflight-checked 4 CPU / 8GB.
- Edge case: `cluster:down` on a cluster that does not exist yet must not crash the operator's shell session (acceptable to exit non-zero; not asserted by the feature test, which never tears down).

**Implementation Outline**

```text
task cluster:up:
  k3d cluster create --config k3d/agrippa-dev.yaml
  kubectl config use-context k3d-agrippa-dev

task cluster:down:
  k3d cluster delete agrippa-dev
```

## Step 2: ServiceLB and Traefik disabled at the k3s layer

**Enables:** `tests/cluster-core.bats`'s Traefik and ServiceLB assertions: no `traefik` pod in `kube-system`, and `docker inspect` on the server container's `.Args` contains `--disable=servicelb`. The host-port-443 assertion still fails.

Add `options.k3s.extraArgs` to `k3d/agrippa-dev.yaml`: `--disable=servicelb` and `--disable=traefik`, each scoped `nodeFilters: ["server:*"]` per k3d's `v1alpha5` schema, so k3s starts with both bundled controllers off. No task-body change is needed; `cluster:up`'s `k3d cluster create --config ...` already reads whatever the config file declares.

**Tests**

```bash
test "kube-system has no traefik and the server was started with --disable=servicelb":
  run mise run cluster:down   # clean slate: extraArgs only take effect at create time
  run mise run cluster:up
  run kubectl --context k3d-agrippa-dev -n kube-system get pods --no-headers
  assert output does not contain "traefik"
  run docker inspect --format '{{json .Args}}' k3d-agrippa-dev-server-0
  assert output contains "--disable=servicelb"
```

- Edge case: both `--disable=` args must land on the `server:*` node filter, not a filter that would also (mis)apply to a future agent node.
- Edge case: `kube-system` must still come up with `coredns`, `local-path-provisioner`, and `metrics-server` (the design's recorded verification); disabling servicelb/traefik must not disable anything else.

**Implementation Outline**

```text
# k3d/agrippa-dev.yaml, options.k3s.extraArgs addition
options:
  k3s:
    extraArgs:
      - arg: "--disable=servicelb"
        nodeFilters: ["server:*"]
      - arg: "--disable=traefik"
        nodeFilters: ["server:*"]
```

## Step 3: Host port-map, idempotent re-run, and the `test:feature` exclusion (feature test goes green)

**Enables:** `tests/cluster-core.bats`'s final assertion: `docker port k3d-agrippa-dev-serverlb` includes `443`. After this step the feature test is fully GREEN. This step also closes the two non-assertion acceptance criteria from `design.md`'s Metrics (idempotent re-run; `test:feature` stays green-on-empty for this suite).

Add `ports: [{port: "80:80", nodeFilters: [loadbalancer]}, {port: "443:443", nodeFilters: [loadbalancer]}]` to `k3d/agrippa-dev.yaml` (443 required by the test; 80 alongside it per the design's resolved decision 4, since k3d port-maps are fixed at create time and cannot be added to a running cluster). Add an existence guard to `cluster:up`: `k3d cluster list agrippa-dev` before creating, `k3d cluster start agrippa-dev` if it already exists, `k3d cluster create` only otherwise, so re-running the feature test (or a later feature-step) never recreates and wipes the long-lived cluster. Add a one-line edit to the Step 0 `mise.toml`'s `test:feature` task: exclude `cluster-core.bats` from its `tests/*.bats` auto-discovery loop, alongside the existing `agrippa.bats`/`harness.bats`/`preflight.bats` exclusions, since this suite drives the persistent `agrippa-dev` cluster rather than `test:feature`'s throwaway `agrippa-feature` one.

**Tests**

```bash
test "the feature test: cluster:up yields a ready, disabled, port-mapped agrippa-dev end-to-end":
  run bats tests/cluster-core.bats
  assert status == 0

test "cluster:up is idempotent: a second run does not error and does not recreate":
  run mise run cluster:up
  assert status == 0
  first_creation="$(docker inspect --format '{{.Created}}' k3d-agrippa-dev-server-0)"
  run mise run cluster:up   # re-run against the already-existing cluster
  assert status == 0
  second_creation="$(docker inspect --format '{{.Created}}' k3d-agrippa-dev-server-0)"
  assert first_creation == second_creation   # same container, not recreated

test "test:feature stays green-on-empty and does not pick up cluster-core.bats":
  run mise run test:feature
  assert status == 0
```

- Edge case: `cluster:up` must fail loudly (report-as-blocked), not silently drop the port-map, if a host process already holds `:80` or `:443`. This was checked free during design, but the create-time failure mode stays a hard error, not a fallback.
- Edge case: the existence guard's `k3d cluster start` path must not error when the cluster is already started (bats re-running the suite back-to-back).
- Edge case: `test:feature`'s exclusion `case` list must still run every other `tests/*.bats` probe suite unchanged (no regression to Feature 0's harness).
- Edge case: this step's changes must not regress Feature 0's own harness. `mise run test:push` and `bats tests/harness.bats` must stay green after the `mise.toml` edit.

**Implementation Outline**

```text
task cluster:up:
  if k3d cluster list agrippa-dev succeeds:
    k3d cluster start agrippa-dev   # idempotent re-run, no recreate
  else:
    k3d cluster create --config k3d/agrippa-dev.yaml
  kubectl config use-context k3d-agrippa-dev
```

```diff
# mise.toml, test:feature task's exclusion case list
- agrippa.bats|harness.bats|preflight.bats) continue ;;
+ agrippa.bats|harness.bats|preflight.bats|cluster-core.bats) continue ;;
```

## Resolved by the long-loop reviewer (2026-07-06)

This plan carries no net-new "Open Artifact Decision" section of its own (that
gate already ran and cleared at the feature design), so this review's job was
to verify the plan against the cleared feature `design.md` and, because this is
the one feature-step where the Design-phase run already materialized and stood
up the substrate, against the live repo tree and the running `agrippa-dev`
cluster itself. Researched via `research:codebase` (direct repo inspection of
`k3d/agrippa-dev.yaml`, `mise.toml`, `tests/cluster-core.bats`, `README.md`,
`DEVELOPMENT.md`) and direct execution against the installed toolchain (`k3d
5.9.0`, `docker`, `kubectl`, `bats`, `mise`) — the equivalent of `research:public`
for this feature-step, since every claim to verify is "does this committed
config/task/test actually do what the plan says against the real tool," not a
question answered by external docs. No escalation trigger (irreversible, out of
recorded scope, underdetermined) fired, so this plan's draft gate is cleared.

**1. Does Step 0's task/file inventory match the cleared feature design's
Specification? Decided: yes — no change.** The config path
(`k3d/agrippa-dev.yaml`), cluster name (`agrippa-dev`), and the two task IDs
(`cluster:up`/`cluster:down`) map one-for-one onto `design.md`'s four already-
resolved Open Artifact Decisions (file path, cluster name, task names, and the
80+443 port set). Preserving the cleared design's decomposition verbatim is the
conservative default.

**2. Are the plan's claims about current repo state accurate? Decided: yes —
verified, no change needed.** `research:codebase` confirmed `k3d/agrippa-dev.yaml`,
the `cluster:up`/`cluster:down` tasks in `mise.toml`, and `tests/cluster-core.bats`
all already exist with exactly the shape each step describes (the `k3d.io/v1alpha5`
config with both `--disable=` extraArgs on `server:*` and both port-maps on
`loadbalancer`; the existence-guarded `cluster:up` body; the `test:feature`
exclusion list already carrying `cluster-core.bats`), and that `README.md`
already carries the Cluster Core layer and Environments table content this
step's Libraries & Skills directive names as the build contract, needing no
edit from this plan.

**3. Do the plan's steps actually work end-to-end, not just read correctly?
Decided: yes — live-verified, no change needed.** This is the one feature-step
whose Design-phase run left a real cluster running, so this review checked
behavior, not just text, against the live toolchain: `bats tests/cluster-core.bats`
passes (`ok 1`, matching Step 3's "feature test goes green" claim); `kubectl
--context k3d-agrippa-dev get nodes` shows the node `Ready`; `docker inspect`
on `k3d-agrippa-dev-server-0` carries `--disable=servicelb` (Step 2's claim);
`docker port k3d-agrippa-dev-serverlb` includes `443` (Step 3's claim); a second
`mise run cluster:up` left the server container's `Created` timestamp unchanged
(Step 3's idempotency claim — no recreate); `k3d cluster list <name>` exits 0
when the cluster exists and exits 1 (`FATA No nodes found`) when it does not,
confirming the existence-guard logic in Step 3's Implementation Outline behaves
as described; `mise run test:feature` created and tore down its own throwaway
`agrippa-feature` cluster and logged both "no chainsaw suite yet" and "no
component bats probes yet," confirming it does not pick up `cluster-core.bats`
(Step 3's `test:feature`-exclusion claim); and `mise run test:push` plus
`bats tests/harness.bats` both stayed green afterward (Step 3's no-regression
edge case). Every plan claim checked against the running system held; nothing
needed correction.

**4. Does the plan carry any other net-new open decision needing escalation?
Decided: no — the gate clears.** No irreversible, out-of-scope, or
underdetermined item remains for this artifact. The `*Draft*` marker is removed
(changed to *Reviewed*).
