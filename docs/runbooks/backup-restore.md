# Backing up and restoring data

You arrived here because you're worried about losing something on
`agrippa-dev`, or you already have. Read the section that matches your
situation. The short version: Postgres row data now has automated,
near-zero-RPO backup and point-in-time recovery through CloudNativePG's
native WAL archiving plus scheduled base backups to a dedicated MinIO. A few
things still have no automated backup, and this document is explicit about
which.

## The one fact that governs everything below

`agrippa-dev` holds two very different kinds of state, and they have
completely different exposure:

- **Declarative state**: every manifest, chart pin, config value, and sealed
  credential that describes what should be running. This lives in git and
  nowhere else needs to. Losing the whole cluster loses none of it.
- **Runtime data**: rows and files that accumulate only inside the running
  cluster because a human or a workload put them there at some point after
  deploy. Nothing in git knows this data exists. Losing the volume that holds
  it loses it, unless something backed it up first.

A `git revert` or a full cluster rebuild restores the first kind perfectly.
It does nothing at all for the second kind. That distinction still governs
this whole document. What changed is that one large slice of the second kind,
Postgres row data, now has a real automated backup path, described in section
2. The rest of the second kind is enumerated in section 3.

---

## 1. What IS backed up: declarative state, in git

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

---

## 2. What IS backed up: Postgres row data, via CNPG-native backup

The shared CNPG `Cluster` named `postgres` in the `storage` namespace archives
its write-ahead log continuously and takes a full base backup on a schedule,
both to a dedicated MinIO instance. Together these give point-in-time recovery
to any moment covered by the archive, not just the instants a snapshot ran.

### The pieces, and where they live

- **A dedicated MinIO** (`storage/overlays/dev/minio/`): a single-replica
  `Deployment` + `Service` + `local-path` PVC named `minio-backup` in the
  `storage` namespace, exposing an S3-compatible endpoint at
  `http://minio-backup.storage.svc:9000`. It is deliberately separate from the
  MinIO that Mimir bundles for its own chunk storage, so Postgres backup
  availability does not depend on the Observability layer's health. A one-shot
  bucket-creation hook (`create-bucket.yaml`) makes the `postgres-backups`
  bucket, because barman-cloud never creates its destination bucket itself.
- **The object-store credentials** (`secrets/dev/storage/minio/backup.enc.yaml`):
  an `accessKeyId` / `secretAccessKey` pair, sops-encrypted under the same
  dev `age` recipient as every other secret and decrypted by KSOPS at sync
  time. MinIO reads it as its root user; the Cluster reads the same keys as
  its S3 credentials. Rotating it is a re-encrypt of that one file.
- **Continuous WAL archiving** (`.spec.backup.barmanObjectStore` on the
  Cluster): CNPG sets Postgres's `archive_command` to ship every completed WAL
  segment (gzip-compressed) to `s3://postgres-backups/postgres/`. This is what
  makes recovery near-zero-RPO: the recovery floor advances with each archived
  segment, not only with each base backup.
- **Scheduled base backups** (`storage/overlays/dev/scheduled-backup.yaml`):
  a `ScheduledBackup` named `postgres-daily`, `method: barmanObjectStore`,
  `schedule: "0 0 3 * * *"` (03:00 daily, robfig/cron with a leading seconds
  field), `immediate: true` so a first base backup runs as soon as the
  resource reconciles rather than waiting for the first 03:00.
- **Retention** (`.spec.backup.retentionPolicy: 7d`): barman prunes base
  backups and the WAL they no longer need past seven days. Sized for the dev
  cluster's small local-path volumes; raise it when a workload needs a longer
  recovery window, and raise the `minio-backup` PVC to match.

### The honest limit on this claim

This is verified as *correct configuration*, not as *observed working against a
live cluster*. Everything above renders and schema-validates: the MinIO
manifests pass kubeconform, the Cluster and `ScheduledBackup` validate against
the vendored CNPG 1.30 CRD OpenAPI schema, the sealed secret round-trips
through sops and passes the plaintext-Secret guard, and the full overlay
composes under `kubectl kustomize --enable-helm`. What has *not* been done here
is standing up the cluster and watching a backup complete, a WAL segment land
in the bucket, and a restore come back green. Before trusting this for anything
that matters, confirm on a running cluster:

```bash
kubectl -n storage get cluster postgres \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}{"\n"}'
kubectl -n storage get backup            # ScheduledBackup-created Backups, phase=completed
kubectl -n storage exec deploy/minio-backup -- \
  ls -R /data/postgres-backups | head    # base backups + wals present
```

Do not read a bare `ContinuousArchiving: True` alone as proof: CNPG's
`archive_command` can report success before a destination is reachable. Pair it
with a `Backup` in `phase: completed` and objects actually present in the
bucket.

---

## 3. What is still NOT backed up automatically

### The MinIO instance's own durability

The backups are only as durable as where they sit, and today that is a single
`local-path` PVC (`minio-backup`, `storage` namespace) on one node, the same
single-point exposure as the Postgres PVC it protects. Losing that node loses
the object store and every base backup and WAL in it at the same time. This is
adequate for a dev cluster (it protects against the far more common Postgres
PVC loss, bad-migration, and fat-finger-DELETE cases while the node itself
survives) but it is not off-cluster durability. Replicating `postgres-backups`
to genuinely off-cluster storage (a second MinIO, an external S3 bucket, or a
periodic `mc mirror` off the node) is the remaining deferred hardening. Until
then, a backup and the primary it protects share a failure domain at the node
level.

### Valkey cached state

One `valkey` Deployment (a single pod, no clustering) in `storage`, backed by
its own `local-path` PVC (512Mi), has no automated backup and no CNPG-style
equivalent. Today only the `smoke` fixture has a Valkey credential; Forgejo
isn't wired to it by design and Flagsmith's cache toggle is unenabled, so there
is no real workload data in Valkey to lose right now. The moment either
integration turns on, whatever gets cached there inherits the single-PVC,
no-backup exposure with zero additional work required to create the gap.

### Forgejo git repository content

Postgres holds Forgejo's *metadata* (users, issues, pull-request state,
webhooks), and that metadata is now covered by section 2 like every other
database. Forgejo's actual git content, every commit, branch, blob, LFS
object, and attachment, lives on a *separate* Forgejo PVC
(`gitea-shared-storage`, namespace `forgejo`, 2Gi, `local-path`), entirely
outside Postgres. CNPG backup does not touch it. See section 7 for the manual
mitigation and why it remains an open gap.

---

## 4. Restoring Postgres from the automated backup

CNPG restores by bootstrapping a **new** Cluster from the object store, not by
writing back into a running one. You keep the same object store as an
`externalCluster` source, and the new Cluster replays the base backup plus WAL
up to the target you choose. Field names below are from the CNPG 1.30 `Cluster`
CRD (`.spec.bootstrap.recovery`, `.spec.externalClusters`).

### Full recovery (latest available point)

Recover to the most recent consistent state the archive can reach:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-restore
  namespace: storage
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie
  storage:
    storageClass: local-path
    size: 1Gi
  bootstrap:
    recovery:
      source: postgres
  externalClusters:
    - name: postgres
      barmanObjectStore:
        destinationPath: s3://postgres-backups/
        endpointURL: http://minio-backup.storage.svc:9000
        serverName: postgres
        s3Credentials:
          accessKeyId:
            name: minio-backup
            key: accessKeyId
          secretAccessKey:
            name: minio-backup
            key: secretAccessKey
        wal:
          compression: gzip
```

`source: postgres` points at the `externalClusters[]` entry of the same name;
its `serverName: postgres` is the folder the original cluster wrote under
(the default is the source cluster's name). The recovered cluster's own future
backups should use a *different* `serverName` if it will archive to the same
bucket, so it never overwrites the history it just recovered from.

### Point-in-time recovery

Add a `recoveryTarget` to stop the replay at a specific moment, transaction, or
LSN instead of the latest point. The most common is a timestamp, for "restore
to just before the bad migration at 02:47":

```yaml
  bootstrap:
    recovery:
      source: postgres
      recoveryTarget:
        targetTime: "2026-07-11 02:45:00+00"
```

`recoveryTarget` also accepts `backupID`, `targetLSN`, `targetXID`,
`targetName`, and `targetImmediate` (stop at the first consistent state). With
no `recoveryTarget`, recovery runs to the end of the archive (the full-recovery
case above).

### Cutting over after a restore

`postgres-restore` comes up as a parallel cluster. Cutting the platform over to
it means repointing the consuming apps (Keycloak, Forgejo, Flagsmith) at the
new cluster's service, or renaming so the restored cluster takes the `postgres`
name. Treat that as an incident, not a routine step: the roles and per-app
`Database` CRs are reconciled continuously by CNPG and, above it, ArgoCD's
`selfHeal`, so a rename or repoint races those reconcilers. Do it with eyes on
`kubectl -n storage get cluster` and the consuming apps' logs, and expect it may
take a second pass. These recovery manifests follow the documented CNPG API but
have not been exercised end-to-end against this cluster; validate on a scratch
namespace before a real cutover.

---

## 5. Manual logical exports with `pg_dump` (complementary, still useful)

The automated backup in section 2 is a *physical* backup: whole-cluster,
byte-level, ideal for disaster recovery and PITR. It is not the right tool for
"give me a portable SQL file of just the `flagsmith` database to load
elsewhere," or "extract one table." For those, a logical `pg_dump` is still the
answer, and it needs no extra setup.

Point `kubectl` at the cluster and find the primary:

```bash
export KUBECONFIG="$(k3d kubeconfig write agrippa-dev)"
kubectl config use-context k3d-agrippa-dev
POD=$(kubectl -n storage get cluster postgres -o jsonpath='{.status.currentPrimary}')
```

### Per-database `pg_dump` (works with each app's own credential)

```bash
# example: forgejo
PASS=$(kubectl -n storage get secret forgejo-db -o jsonpath='{.data.password}' | base64 -d)
kubectl -n storage exec "$POD" -c postgres -- env PGPASSWORD="$PASS" \
  pg_dump -h localhost -U forgejo -d forgejo \
  > ~/agrippa-backups/forgejo-$(date +%Y%m%d-%H%M%S).sql
```

Repeat for `keycloak-db`/`keycloak` and `flagsmith-db`/`flagsmith`. Two details
that matter:

- **No `-it` on the `kubectl exec`.** A TTY injects control characters into the
  dump stream. Plain `kubectl exec` streams `pg_dump`'s stdout cleanly, which
  the `>` redirect writes to a file on *your machine*, not the pod's PVC.
- **Pick a destination outside this repo.** `~/agrippa-backups/` is a
  placeholder. These dumps hold real user data and session tokens; a plaintext
  SQL dump does not meet this project's sops-encryption-or-nothing bar for
  secrets and must never be committed.

### Whole-cluster `pg_dumpall` does not work here

`pg_dumpall` reads role definitions from `pg_authid`, which needs superuser.
This Cluster does not set `enableSuperuserAccess`, so no `postgres-superuser`
credential is exposed, and the only readable passwords are the four managed app
roles plus the non-superuser `app` owner. A `pg_dumpall` with an app credential
fails with `permission denied for table pg_authid`. This is expected, not a
regression: for a whole-cluster consistent capture, use the physical backup in
section 2, which is exactly the case it exists for. `pg_dump` per database
remains the logical-export path.

---

## 6. Restoring from a logical dump

The reverse of section 5. Use `-i`, not `-it`, so stdin carries the file
cleanly:

```bash
POD=$(kubectl -n storage get cluster postgres -o jsonpath='{.status.currentPrimary}')
PASS=$(kubectl -n storage get secret forgejo-db -o jsonpath='{.data.password}' | base64 -d)
kubectl -n storage exec -i "$POD" -c postgres -- env PGPASSWORD="$PASS" \
  psql -h localhost -U forgejo -d forgejo < ~/agrippa-backups/forgejo-20260711-020000.sql
```

If the dump was taken with `pg_dump -Fc` (custom format, worth using for
anything nontrivial: parallel restore, selective table extraction), use
`pg_restore` instead of piping SQL through `psql`:

```bash
kubectl -n storage cp ./forgejo.dump "$POD":/tmp/forgejo.dump -c postgres
kubectl -n storage exec -i "$POD" -c postgres -- env PGPASSWORD="$PASS" \
  pg_restore -h localhost -U forgejo -d forgejo --clean --if-exists /tmp/forgejo.dump
```

The same reconciler caveat as section 4 applies: this Cluster's databases and
roles are continuously reconciled by CNPG and ArgoCD's `selfHeal`. A logical
restore that recreates objects with different ownership or grants than
`managed.roles` expects, or that races a role-password rotation, can be fought
over by the reconciler. Treat a real restore as an incident and watch the
Cluster and the consuming app closely afterward.

---

## 7. Forgejo and Flagsmith specifically

### Forgejo: the git PVC is a separate, still-open gap

Section 2 now covers Forgejo's Postgres metadata like any other database. It
does *not* cover Forgejo's git content, which lives on the independent
`gitea-shared-storage` PVC (namespace `forgejo`, 2Gi, `local-path`). No
automated backup reaches that PVC. The most direct manual mitigation is a
filesystem copy off it (`kubectl exec ... tar czf - /data | ...` into a local
archive, or `kubectl cp`), which this document does not turn into a verified
procedure because it hasn't been run and checked the way section 5's commands
were. Treat it as an open gap. Off-cluster durability for this PVC belongs in
the same deferred-hardening bucket as MinIO's own durability (section 3).

### Flagsmith: fully covered

Flagsmith's flag definitions and the runtime values an operator sets through
the UI are ordinary rows in the `flagsmith` Postgres database, so they are
covered by the automated backup in section 2 with no separate store to worry
about.

---

## Quick-reference

| Situation | What protects you |
| --- | --- |
| Whole cluster destroyed or rebuilt from scratch | Git, via `mise run cluster:up` + `mise run bootstrap`; see [`./disaster-recovery.md`](./disaster-recovery.md). Declarative state only. |
| Bad Postgres rows / dropped table in `keycloak`/`forgejo`/`flagsmith`/`smoke` | Automated CNPG backup: bootstrap a new Cluster with `recovery` + `recoveryTarget.targetTime` to just before the damage (section 4). |
| Lost the `postgres-1` PVC or its node | Automated CNPG backup restores from MinIO, as long as the `minio-backup` PVC / node survived (section 4). |
| Need a portable SQL export of one database | `pg_dump` per database (section 5), restored per section 6. |
| Need a whole-cluster consistent Postgres capture | The physical backup in section 2; `pg_dumpall` still doesn't work (no exposed superuser, section 5). |
| Lost the `minio-backup` PVC / its node too | Backups on it are gone; off-cluster durability of MinIO is still deferred (section 3). |
| Lost Forgejo git content (`gitea-shared-storage` PVC) | No automated path; manual filesystem copy only, still an open gap (section 7). |
| Lost Valkey PVC | No backup; no real data there today (section 3). |
