# Backing up and restoring data

You arrived here because you're worried about losing something on
`agrippa-dev`, or you already have. Read this whole document before you run
anything: the honest answer is that most of what makes this cluster useful
day to day has no automated backup today, and this document exists to tell
you that plainly rather than let you assume otherwise.

## The one fact that governs everything below

`agrippa-dev` holds two very different kinds of state, and they have
completely different exposure:

- **Declarative state**: every manifest, chart pin, config value, and sealed
  credential that describes what should be running. This lives in git and
  nowhere else needs to. Losing the whole cluster loses none of it.
- **Runtime data**: rows and files that accumulate only inside the running
  cluster because a human or a workload put them there at some point after
  deploy. Nothing in git knows this data exists. Losing the PVC that holds it
  loses it, permanently.

A `git revert` or a full cluster rebuild restores the first kind perfectly.
It does nothing at all for the second kind. Confusing the two is the single
most likely way to lose data on this platform, because "the cluster rebuilds
from git" is true and also does not mean what it sounds like it means.

---

## 1. What IS backed up today: declarative state, in git

Every layer (`core`, `storage`, `platform`, `observability`, `workloads`) is
an ArgoCD `Application` synced from `origin/main`, with sealed credentials
committed as sops-encrypted `Secret` manifests under `secrets/`. That
includes:

- Every Kubernetes manifest and Helm chart version pin.
- Every config value: Grafana dashboards, the Keycloak realm import, Istio
  routes, resource requests, everything under `apps/` and each layer's
  `overlays/dev/`.
- Every sealed credential (`secrets/dev/**/*.enc.yaml`), decrypted at apply
  time by KSOPS in the ArgoCD repo-server.

This is genuinely RPO 0 for what it covers: git *is* the backup. A destroyed
node, a `mise run cluster:down`, or a corrupted cluster all reconstruct
identically via `mise run cluster:up` + `mise run bootstrap`, because nothing
in this category exists anywhere except as a commit on `main`. The full
teardown-and-rebuild procedure, what it reconstructs, and what it does not,
is [`./disaster-recovery.md`](./disaster-recovery.md); read that first if
you're facing a whole-cluster problem rather than a single bad dataset.

What this category explicitly does **not** cover is the subject of the next
section.

---

## 2. What is NOT backed up today: runtime data

Nothing below has an automated backup. If you lose the volume it lives on,
you lose the data, full stop, with no current recovery path other than
whatever you manually dumped beforehand (section 3).

### Postgres row data

One shared CNPG `Cluster` named `postgres` in the `storage` namespace, one
instance, backed by a `local-path` PVC (`rancher.io/local-path`, single node,
no replication, confirmed live: `kubectl -n storage get pvc postgres-1`).
Four real databases live on it beyond the `smoke` fixture:

| Database | What's actually at risk |
| --- | --- |
| `keycloak` | Users, sessions, and client state created at runtime. The realm *definition* itself (`agrippa` realm, clients, roles) is reimported declaratively from git on every sync via the `KeycloakRealmImport` resource, so that part is not at risk; any user who signed up, any session token issued, and any admin-console change made through the UI rather than the import file, is runtime-only. |
| `forgejo` | Users, issues, pull request state, wiki metadata, webhooks, tokens: everything Forgejo stores as SQL rows. (Forgejo's actual git repository content is a separate concern entirely, covered in section 6.) |
| `flagsmith` | Flag *values* an operator sets at runtime through the Flagsmith UI (on/off state, multivariate values, per-environment overrides). The Flagsmith deployment itself is declarative; whatever flag state you've actually flipped is not. |
| `smoke` | A fixture/proof database used by the storage feature's own probe test. Not real data, not a concern. |

Losing the `postgres-1` PVC, or the node it's scheduled on, loses every row
in every one of these databases at once, since it is one shared instance
with no replica (`instances: 1`, `maxSyncReplicas: 0`).

### Valkey cached state

One `valkey` Deployment (not a StatefulSet: a single pod, no clustering) in
`storage`, backed by its own `local-path` PVC
(`kubectl -n storage get pvc valkey`, 512Mi), the same no-replication
exposure as Postgres. As of today, only
the `smoke` fixture actually has a Valkey credential (`smoke-valkey`
Secret); Forgejo isn't wired to it by design and Flagsmith's Redis/Valkey
cache option is an unenabled, deferred toggle. So right now there's no real
workload data sitting in Valkey to lose. The moment either of those
integrations turns on, whatever gets cached there inherits the identical
single-PVC, no-backup exposure described above with zero additional work
required to create the gap.

### Why this matters more than it might look like

The cluster's own self-healing (ArgoCD's `selfHeal: true`) can make it feel
like nothing here is ever really at risk, because so much of the platform
really does repair itself automatically. Runtime data is the exception. No
reconciler, no `selfHeal`, and no `mise run cluster:up` rebuild brings any of
this back. It only exists once, in one place, on one unreplicated PVC.

---

## 3. Manual stopgap: `pg_dump` / `pg_dumpall` right now

There is no automated backup tier yet (see section 5). Until one exists, the
only real protection for Postgres row data is a manual dump you take
yourself and move off-cluster. This section gives commands that were run
live against `agrippa-dev` while writing this document, so what's marked
"works" actually works, and what's marked "doesn't work" actually failed
with the error shown.

Point `kubectl` at the cluster first, same as everywhere else in this repo:

```bash
export KUBECONFIG="$(k3d kubeconfig write agrippa-dev)"
kubectl config use-context k3d-agrippa-dev
```

Find the CNPG primary pod:

```bash
POD=$(kubectl -n storage get cluster postgres -o jsonpath='{.status.currentPrimary}')
echo "$POD"
```

### Option A: per-database `pg_dump` (works today, no extra setup)

This is the same connection pattern `USAGE.md`'s "The database: Postgres and
Valkey" section uses for `psql`, applied to `pg_dump` instead, using each
app's own already-sealed credential (`<app>-db` Secret, from
`kubectl -n storage get secrets`). No superuser or extra privilege needed:
each app's role owns its own database's tables.

```bash
# example: forgejo
PASS=$(kubectl -n storage get secret forgejo-db -o jsonpath='{.data.password}' | base64 -d)
kubectl -n storage exec "$POD" -c postgres -- env PGPASSWORD="$PASS" \
  pg_dump -h localhost -U forgejo -d forgejo \
  > ~/agrippa-backups/forgejo-$(date +%Y%m%d-%H%M%S).sql
```

Repeat for `keycloak-db`/`keycloak` and `flagsmith-db`/`flagsmith`. Two
details that matter:

- **No `-it` on the `kubectl exec`.** `-it` allocates a TTY meant for an
  interactive session; it will inject control characters into the dump
  stream. Plain `kubectl exec` (no `-i`, no `-t`) streams `pg_dump`'s stdout
  cleanly to your shell, which the `>` redirect then writes to a file on
  *your machine*, not the pod's PVC. That's the whole point: a dump sitting
  only on the same PVC it's meant to protect against is not a real backup.
- **Pick a destination outside this repo.** `~/agrippa-backups/` above is a
  placeholder: use any path outside the git working tree. These dumps
  contain real user data, session tokens, and (depending on the table) may
  contain credential-adjacent material, and this project's committed-secret
  discipline (`DEVELOPMENT.md` § Secrets) is sops-encryption-or-nothing.
  A plaintext SQL dump does not meet that bar and should never be committed,
  encrypted or not.

Confirmed live: this exact command, run against `forgejo`, produced a clean
`pg_dump` SQL stream (exit code 0). All four app roles (`smoke`, `keycloak`,
`forgejo`, `flagsmith`) have `SELECT`/dump rights on their own database only,
by ordinary Postgres ownership, nothing special was granted for this to
work.

### Option B: whole-cluster `pg_dumpall` (does NOT work today)

`pg_dumpall` needs to read role definitions out of `pg_authid`, which
requires superuser. Tried live against this cluster using a per-app
credential:

```bash
PASS=$(kubectl -n storage get secret forgejo-db -o jsonpath='{.data.password}' | base64 -d)
kubectl -n storage exec "$POD" -c postgres -- env PGPASSWORD="$PASS" \
  pg_dumpall -h localhost -U forgejo
```

```text
pg_dumpall: error: query failed: ERROR:  permission denied for table pg_authid
```

That's expected, not a fluke: this Cluster's spec sets
`enableSuperuserAccess: false`, so CNPG never creates a
`postgres-superuser` Secret (confirmed live,
`kubectl -n storage get secret postgres-superuser` returns `NotFound`). The
`postgres` role itself does exist and is genuinely a superuser
(`kubectl -n storage exec "$POD" -c postgres -- psql -U app -d app -c '\du'`
shows `Superuser, Create role, Create DB, Replication, Bypass RLS`), but CNPG
holds it as an internally "reserved" managed role and its password is never
exposed as a credential you can read. The only roles with an accessible
password today are the four `managed.roles` app roles (`smoke`, `keycloak`,
`forgejo`, `flagsmith`) plus `app`, the `initdb` bootstrap owner of an
otherwise-unused `app` database, which is not a superuser either (it can
`CONNECT` to other apps' databases thanks to Postgres's default public
`CONNECT` grant, but cannot read their tables: a live
`pg_dump -U app -d forgejo` attempt failed with
`permission denied for table version`).

**Bottom line: `pg_dumpall` is not currently possible against this cluster
without a deliberate privilege change** (for example, flipping
`enableSuperuserAccess: true` on the `Cluster` spec, which is itself a real
security-posture decision, not a backup-runbook footnote, and is not
recommended here). Until that changes, back up database by database with
Option A.

---

## 4. Restoring from a dump

The reverse of Option A. Use `-i`, not `-it`, so stdin carries the file
cleanly rather than a terminal:

```bash
POD=$(kubectl -n storage get cluster postgres -o jsonpath='{.status.currentPrimary}')
PASS=$(kubectl -n storage get secret forgejo-db -o jsonpath='{.data.password}' | base64 -d)
kubectl -n storage exec -i "$POD" -c postgres -- env PGPASSWORD="$PASS" \
  psql -h localhost -U forgejo -d forgejo < ~/agrippa-backups/forgejo-20260710-060000.sql
```

If the dump was instead taken with `pg_dump -Fc` (custom format, worth using
over the plain-SQL default above once you're restoring anything nontrivial:
it supports parallel restore and picking individual tables back out), use
`pg_restore` against the same connection instead of piping SQL through
`psql`:

```bash
kubectl -n storage cp ./forgejo.dump "$POD":/tmp/forgejo.dump -c postgres
kubectl -n storage exec -i "$POD" -c postgres -- env PGPASSWORD="$PASS" \
  pg_restore -h localhost -U forgejo -d forgejo --clean --if-exists /tmp/forgejo.dump
```

### The caveat this runbook does not solve

This Cluster's databases and roles are declaratively managed: a per-app CNPG
`Database` CR and `managed.roles[]` entry are reconciled continuously by
both CNPG and, upstream of that, ArgoCD's own `selfHeal`. Restoring into a
database while that reconciliation is active is a real risk worth knowing
about, not something worked out here: a restore that recreates objects with
different ownership or grants than what `managed.roles` expects, or that
races a CNPG role-password rotation, can end up fought over by the
reconciler rather than landing cleanly. There's no documented safe sequence
for this in the current build. If you're doing a real restore, treat it as
an incident: watch `kubectl -n storage get cluster postgres` and the
consuming app's pod logs closely afterward, and be ready for the possibility
that something needs a second pass.

---

## 5. What real backup automation would need (not built yet)

This section is forward-looking. Nothing here exists in the cluster today;
it's this runbook's own deferred-work note, so the intent isn't lost by the
time someone picks it up: review CloudNativePG for application-consistent
Postgres backup and point-in-time recovery.

CloudNativePG has its own native backup and point-in-time-recovery support:
WAL archiving to object storage, plus `Backup` and `ScheduledBackup` CRDs
that bracket a CSI volume snapshot (or a `barman-cloud`-style base backup)
with `pg_backup_start`/`pg_backup_stop` for an application-consistent
result. That capability could replace the manual `pg_dump` stopgap above
with near-zero-RPO recovery. None of it is wired up here:

- `.spec.backup` and `.spec.plugins` are both empty on the `postgres`
  Cluster (confirmed live). No object storage destination is configured.
- The `backups.postgresql.cnpg.io` and `scheduledbackups.postgresql.cnpg.io`
  CRDs are already installed (they ship with the CNPG operator itself,
  version 1.30.0 here), but zero `Backup` or `ScheduledBackup` resources
  exist anywhere in the cluster. The capability is latent, not configured.
- One easy-to-misread detail: `kubectl -n storage get cluster postgres`
  reports a `ContinuousArchiving: True` / "Continuous archiving is working"
  condition. Don't read that as "WAL is being backed up somewhere safe." The
  Cluster's `archive_command` is CNPG's own `manager wal-archive`, which
  reports success even with no configured backup destination: there is no
  object store or plugin target for it to actually ship WAL segments to
  today, so this condition is not evidence of any recoverable backup
  existing.

The trigger to build this is any Postgres-backed workload needing RPO
under 2 hours, real point-in-time recovery, or a guaranteed
application-consistent restore rather than the crash-consistent volume
snapshot a naive backup would otherwise give. Until that trigger is hit,
section 3's manual `pg_dump` is what exists.

---

## 6. Forgejo and Flagsmith specifically

### Forgejo: a second, separate gap the pg_dump approach does not cover

Postgres only holds Forgejo's *metadata*: users, issues, pull request state,
webhooks, the rows enumerated in section 2. The actual git repository
content, every commit, branch, and blob, along with LFS objects and
uploaded attachments, lives on Forgejo's own PVC
(`gitea-shared-storage`, namespace `forgejo`, 2Gi, `local-path`, confirmed
live), completely independent of Postgres. Dumping the `forgejo` database
with `pg_dump` (section 3) does not back up a single commit.

There is no current backup path for this PVC either, manual or automated.
The most direct manual mitigation, if you need one today, is a plain
filesystem copy off that PVC (`kubectl cp` from the Forgejo pod, or a
`kubectl exec ... tar czf - /data | ...` into a local archive), which this
document does not attempt to turn into a procedure since it hasn't been run
and verified the way section 3's commands have. Treat it as an open gap, not
a solved one.

### Flagsmith: fully covered by the pg_dump approach above

Flagsmith's flag *definitions* (projects, environments, flag keys, and the
runtime values an operator sets through the UI) are ordinary rows in the
`flagsmith` Postgres database, no different from any other table covered in
section 2 and section 3's Option A. There is no separate PVC or
workload-specific store to worry about beyond what's already described
above.

---

## Quick-reference

| Situation | What actually protects you today |
| --- | --- |
| Whole cluster destroyed or rebuilt from scratch | Git, via `mise run cluster:up` + `mise run bootstrap`; see [`./disaster-recovery.md`](./disaster-recovery.md). Declarative state only. |
| Bad Postgres rows in `keycloak`/`forgejo`/`flagsmith`/`smoke` | Nothing automated. A manual `pg_dump` you took beforehand (section 3, Option A), restored per section 4. |
| Need a whole-cluster consistent Postgres snapshot | Not possible today: no accessible superuser credential, `pg_dumpall` fails (section 3, Option B). |
| Lost the `postgres-1` or `valkey` PVC with no prior manual dump | Data is gone. No recovery path exists. |
| Lost Forgejo git repository content (`gitea-shared-storage` PVC) | Data is gone unless you separately copied it off; `pg_dump` never touched it (section 6). |
| Want real automated backup / PITR | Not built. CNPG's native `Backup`/`ScheduledBackup` + WAL archiving is the documented, deferred path (section 5). |
