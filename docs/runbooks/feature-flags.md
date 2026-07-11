# Feature flags runbook (Flagsmith)

How to flip a feature flag on the `agrippa-dev` cluster's Flagsmith
instance, both by hand through the UI and by script through the API, and
what this project's own "Release Flag" concept is versus what actually
exists. Point `kubectl` at the cluster first if you haven't already
this shell session:

```bash
export KUBECONFIG="$(k3d kubeconfig write agrippa-dev)"
kubectl config use-context k3d-agrippa-dev
```

Flagsmith lives in the `flagsmith` namespace, deployed via the official
`Flagsmith/flagsmith-charts` chart pinned at `0.82.0`
(`platform/overlays/dev/flagsmith/helm/kustomization.yaml`), reconciled by
the `platform` ArgoCD Application, exposed through the shared Istio Gateway
at `https://flagsmith.127.0.0.1.nip.io/`. Live-checked:
`kubectl -n argocd get application platform` reports `Synced Healthy`,
`curl -k https://flagsmith.127.0.0.1.nip.io/` returns `200`, and
`curl -k https://flagsmith.127.0.0.1.nip.io/health` (the Django
`django-health-check` aggregate view, DB-gated) also returns `200` -- the
service is up and its shared-Postgres connection is live.

## 1. Flipping an application-level flag in Flagsmith (the UI)

This is the generic, working mechanism: it applies to any feature flag you
create in this Flagsmith instance, independent of whether anything in the
cluster actually reads it yet (see the note at the end of this section).

### Logging in -- what's actually there, live-verified

`api.bootstrap.enabled: true` is set in the chart values
(`adminEmail: admin@agrippa.local`, `organisationName: agrippa`,
`projectName: agrippa`), which runs a `bootstrap` initContainer on every
`flagsmith-api` pod start. This project's intended login path (the chart's
own documented single-operator flow, no scripted step) has the operator
read the one-time password-reset link Flagsmith's bootstrap logs to the API
pod's stdout. That claim is **not confirmed live** in this cluster. What was
actually checked:

- `kubectl -n flagsmith get secrets` lists exactly three Secrets:
  `flagsmith`, `flagsmith-database-url`, `flagsmith-secret-key`. The first
  is a Helm-templated Secret the chart renders unconditionally (key
  `DATABASE_URL`, value empty) -- superseded at runtime because
  `databaseExternal.urlFromExistingSecret.enabled: true` points the API at
  `flagsmith-database-url` instead. **None of the three Secrets holds a
  username or password.** There is no sealed admin credential anywhere in
  this namespace.
- The full available log of the `bootstrap` initContainer
  (`kubectl -n flagsmith logs deploy/flagsmith-api -c bootstrap`) contains
  only Django system-check deprecation warnings (`axes.W004`, `axes.W006`).
  No superuser-creation confirmation, no password, no reset link. The same
  is true of the `migrate-db` initContainer and the main `flagsmith-api`
  container's own log.
- No SMTP/email backend is set anywhere in
  `platform/overlays/dev/flagsmith/helm/kustomization.yaml`'s
  `valuesInline`, so even Flagsmith's own self-service "Forgot your
  password?" link on the login page has no mail relay to deliver a reset
  email through in this cluster.

Net finding: **first-admin login is an open gap, not a live-verified
working flow.** Before assuming it's unusable, re-check the logs yourself
-- the pod may have been running long enough that its log buffer rotated, or
a fresh deploy may behave differently:

```bash
kubectl -n flagsmith logs deploy/flagsmith-api -c bootstrap
kubectl -n flagsmith logs deploy/flagsmith-api -c migrate-db
kubectl -n flagsmith logs deploy/flagsmith-api | grep -i -E 'password|reset|link'
```

If nothing turns up, the standard Django operational escape hatch is
setting the password directly against the running app:

```bash
kubectl -n flagsmith exec -it deploy/flagsmith-api -- python manage.py changepassword admin@agrippa.local
```

This command is **not verified** here (it mutates the live admin account,
outside the read-only scope of this pass) and is not asserted anywhere in
this repo's design, build, or test record -- verify the exact
management-command name against this image's `manage.py` before relying on
it. Once you have credentials, log in at
`https://flagsmith.127.0.0.1.nip.io/` (the browser will warn about an
untrusted CA -- that's the local `Agrippa Local Dev CA`, click through it,
or use `curl -k` for scripted checks).

### Toggling a flag

Flagsmith's own model, not this project's invention: **Organisation ->
Project -> Environment -> Feature**. The bootstrap created one organisation
and one project, both named `agrippa`; open the project in the left nav,
pick an environment (Flagsmith's default install typically ships
`Development` and `Production` environments per project -- confirm the
exact names live in the UI rather than assuming), and you land on the
Features list for that environment.

From there:

1. **Create a feature** (if none exists yet): give it a name, an optional
   default value, and whether it's on or off by default.
2. **Toggle it per environment**: each environment has its own
   enabled/disabled state and its own value override for the same feature
   -- flipping it in `Development` does not touch `Production` (or
   whichever environment names the bootstrap actually created).
3. **Edit its value**: for a non-boolean flag, edit the environment's
   feature-state value directly in the same panel.

Changes take effect immediately -- no deploy, no ArgoCD sync. See the
Safety Note (section 4) for what "immediately" and "no deploy" imply.

### How a workload would read it -- a seam, not yet exercised

Per `ARCHITECTURE.html` (S5 Platform, the OpenFeature -> Flagsmith service
panel), this project's intended consumption pattern is **OpenFeature** as
the vendor-neutral client SDK convention, with Flagsmith shipping
first-party OpenFeature providers per language:

- Rust: `open-feature` + `flagsmith` provider (crates.io)
- TypeScript: `@openfeature/web-sdk` + `flagsmith-client-provider` (npm)
- Python: `openfeature-sdk` + `openfeature-provider-flagsmith` (PyPI)

A consuming workload would install the OpenFeature SDK for its language,
point Flagsmith's provider at an environment's API key (visible in that
environment's settings in the UI), and read flags through OpenFeature's own
client interface rather than Flagsmith's SDK directly -- keeping the
workload decoupled from Flagsmith specifically.

**No workload in this cluster does this.** `resume` and `trips` are
both fully static sites (jiffies-built, served by nginx) with no runtime
code to wire an SDK into. This is a real, deliberate seam: wiring an actual
workload to an OpenFeature provider was scoped out of this project on
purpose, left for a later feature-step that wires a workload only where it
actually reads a flag -- not a bug, not partially built, just not exercised
end-to-end anywhere in this repo yet.

## 2. The API path (for scripting)

For automation instead of clicking through the UI. Two different surfaces
exist, confirmed live via an in-cluster `curl` against the `flagsmith-api`
Service (the API is **not** Gateway-routed -- the `flagsmith`
HTTPRoute only forwards `/health` and `/`; a Gateway-reachable `/api` path,
which a browser-based OpenFeature client would need, was deliberately left
for a later feature-step and isn't built here).

### Reaching the API at all

Since `/api` isn't exposed through the Gateway, reach it either from inside
the cluster or via a port-forward:

```bash
kubectl -n flagsmith port-forward svc/flagsmith-api 8000:8000
```

Then target `http://localhost:8000/api/v1/...` for everything below.

### The read path -- confirmed live

The client-facing flags endpoint requires an environment key, not a user
token. Confirmed live with an unauthenticated request (no header) against
`flagsmith-api:8000` from inside the cluster:

```bash
curl -sS http://localhost:8000/api/v1/flags/
# {"detail":"Invalid or missing Environment key"}
```

With a real environment key (from that environment's settings page in the
UI):

```bash
curl -sS http://localhost:8000/api/v1/flags/ \
  -H "X-Environment-Key: <environment-api-key>"
```

### The write path -- toggling a flag's value, general pattern only

Confirmed live: the API is reachable and serves an interactive schema page
at `/api/v1/docs/` (HTTP 200, in-cluster). Fetching a machine-readable
OpenAPI/Swagger JSON from a couple of likely paths
(`/api/v1/docs/?format=openapi`, `/api/v1/docs/swagger.json`,
`/api/v1/schema.json`) all 404'd, so the exact write-endpoint shape below
is **not** independently confirmed against this specific deployed instance
-- treat it as the general, long-stable Flagsmith REST pattern, and verify
against `/api/v1/docs/` on this instance before scripting against it:

```bash
# General shape -- verify exact path/fields against /api/v1/docs/ first.
curl -sS -X PATCH \
  -H "Authorization: Token <user-api-token>" \
  -H "Content-Type: application/json" \
  -d '{"enabled": true}' \
  "http://localhost:8000/api/v1/environments/<environment-key>/featurestates/<feature-state-id>/"
```

The `<user-api-token>` here is a management-API token (Account Settings ->
API Keys in the UI, distinct from an environment's client-facing key
above), and `<feature-state-id>` is the numeric ID of the specific
environment's feature-state row -- retrievable via `GET
/api/v1/environments/<environment-key>/featurestates/`. Both details are
the general Flagsmith pattern from its public docs, not something checked
against `flagsmith-charts` `0.82.0` / app `2.238.0` specifically here.

## 3. This project's own Release Flag concept: design intent vs. reality

The design floated a single project-level release flag: not a Flagsmith
`Feature` object, but a git-level gate -- feature-steps would accumulate on a
long-lived integration branch, the platform would stay unreleased until a
final acceptance pass, and promoting that branch to `main` would be the flag
itself flipping.

**This was never built**, and there is no integration branch. Concretely for
this runbook: **there is no Flagsmith `Feature` object anywhere in this
cluster gating platform release, and no mechanism reads one.** Nothing in `overlays/dev`'s
root kustomization is conditionally included based on a flag value. If
you're troubleshooting Flagsmith day to day, this is a non-issue: every
flag you'll find in this instance is an ordinary application-level flag
(section 1), not a hidden platform-release switch.

## 4. Safety note: a flag flip is live runtime state, not a git change

Toggling a flag's value in Flagsmith writes directly to Flagsmith's own
Postgres-backed state -- the `flagsmith` database, owned by the `flagsmith`
role, on the **shared CNPG `postgres` Cluster** in the `storage` namespace
(confirmed live via the `flagsmith-database-url` Secret's DSN target:
`postgres-rw.storage.svc:5432/flagsmith`). It is a runtime API call against
a running Django app, exactly like any other write a user makes through
Flagsmith's UI or API.

This means:

- **It is not a GitOps-managed change.** No file in this repo changes, no
  commit is created, and nothing about it appears in `git log`.
- **It is not covered by [`./rollback.md`](./rollback.md)'s git-revert
  mechanism.** That runbook's whole model depends on `origin/main` being
  the source of truth ArgoCD's `selfHeal` continuously reconciles toward --
  a flag value isn't part of that reconciled state at all, so there is
  nothing for a `git revert` to undo. `rollback.md` itself says this
  explicitly under "Runtime data": "Flagsmith flag values flipped by a
  user... [is] not stored in git, so no git-level or ArgoCD-level rollback
  touches it."
- **It is not restored by a cluster rebuild.** See
  [`./disaster-recovery.md`](./disaster-recovery.md) -- a full rebuild from
  git reconstructs every manifest, chart release, and sealed credential,
  but it starts Flagsmith's Postgres database empty (or however the
  bootstrap leaves it), not with whatever flag values an operator had set
  on the cluster being rebuilt.
- **Flipping the flag back is the only "rollback" that exists for a flag
  change.** If a flag flip causes a problem, the fix is the same kind of
  action that caused it: go back into the UI or the API and flip it again.
  There is no other lever.
