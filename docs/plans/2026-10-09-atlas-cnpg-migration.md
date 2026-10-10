# Atlas database: move to CloudNativePG

## Why

- Atlas used a shared single-instance Postgres in the `orbit` namespace
  (`postgresql.orbit.svc.cluster.local`), with `DATABASE_URL` in Doppler synced
  into `atlas-secret`. That server lost its data directory twice, the second
  time with Atlas's role and database gone with it.
- It now runs on a node-local `openebs-hostpath` PVC. That survives pod
  deletion but not node or disk loss, and it has no failover.
- Goal: an Atlas-owned CNPG `Cluster` (`atlas-db`) with 2 instances on
  `openebs-hostpath`, spread across nodes by required pod anti-affinity, so a
  node loss fails over at the Postgres layer. No Longhorn.
- The CloudNativePG operator (1.30.0) is already installed. `surfsense-postgres`
  has run on `openebs-hostpath` for weeks, so the Talos kubelet mount problem
  that broke the July 2026 attempt (`git show 6a6a7ca`, `0ac41f9`) is gone.

## What changes

- `cnpg-cluster.yaml` (new): `Cluster/atlas-db`, 2 instances, PostgreSQL 17.11,
  5Gi on `openebs-hostpath`, `bootstrap.initdb` with database and owner `atlas`,
  `enableSuperuserAccess: true`. Sync wave 0.
- CNPG generates `atlas-db-app` (key `uri` is the web app's `DATABASE_URL`) and
  `atlas-db-superuser` (used only by the bootstrap Job).
- `web-deployment.yaml`: `DATABASE_URL` comes from `atlas-db-app/uri`. Sync wave 2.
- `bootstrap-job.yaml`: no longer a PreSync hook. It is a `Sync` hook at wave 1,
  with an initContainer that waits for `atlas-db-rw` to accept connections.
  `DATABASE_URL` and the `ATLAS_DB_ADMIN_*` credentials come from the CNPG Secrets.
- `externalsecret.yaml`: `DATABASE_URL`, `ATLAS_DB_ADMIN_USER` and
  `ATLAS_DB_ADMIN_PASSWORD` are removed from Doppler sync.
- `kustomization.yaml`: adds `cnpg-cluster.yaml` under Core.

Sync order: wave 0 (Cluster) → wave 1 (bootstrap Job: db:ensure, migrate, seed)
→ wave 2 (web Deployment).

## Cutover

1. Merge the PR to `main`.
2. ArgoCD creates the `Cluster`. Wait until `atlas-db` reports healthy (see
   verification).
3. The wave-1 bootstrap Job waits for `atlas-db-rw`, then runs `db:ensure`
   (creates nothing that already exists), migrations and the seed.
4. The wave-2 web Deployment rolls out against `atlas-db-rw`.

If the sync fails with `Job "atlas-bootstrap" is invalid: ... field is
immutable`, the live Job is still the old PreSync-hook Job. Delete it once with
`kubectl -n atlas delete job atlas-bootstrap` and let ArgoCD resync.

## Verification

```sh
kubectl -n atlas get cluster atlas-db
kubectl cnpg status atlas-db        # if the cnpg plugin is installed
kubectl -n atlas get pods -l cnpg.io/cluster=atlas-db -o wide   # 2 pods, different nodes
kubectl -n atlas get job atlas-bootstrap
kubectl -n atlas logs job/atlas-bootstrap -c bootstrap
curl -fsS https://atlas.hoytlabs.app/api/health
```

## Data migration

The database is currently empty after today's loss. If it holds data at
cutover, restore it into the new cluster. The `atlas-db` Cluster does not exist
until this PR syncs, so the restore runs after wave 0 and before the web
Deployment (wave 2) rolls out. The simplest way is to pause the web Deployment
(`kubectl -n atlas scale deploy/atlas-web --replicas=0`) until the restore is
done:

1. Take a `pg_dump --format=custom` from orbit's Postgres, or use the latest
   nightly dump from the NAS volume written by `db-backup-cronjob.yaml`.
2. Once `atlas-db` is healthy and the bootstrap Job has created the `atlas`
   role and database, run `pg_restore --no-owner --no-privileges` against
   `atlas-db-rw` as the `atlas` role (use the `uri` from `atlas-db-app`).

## Rollback

Revert the PR. The orbit Postgres still exists, and Doppler `ATLAS_DATABASE_URL`
still points at it, so reverting restores the previous wiring. Delete the
`atlas-db` Cluster only once the rollback is confirmed, since its PVCs hold the
new data.

## Follow-ups

- Point `db-backup-cronjob.yaml` at `atlas-db-app`'s `uri` instead of
  `atlas-secret/DATABASE_URL`. It breaks once this change lands (see PR).
- Delete `apps/orbit` after the cutover is verified.
- Delete `ATLAS_DATABASE_URL` from Doppler after the cutover.
- Consider CNPG scheduled backups (barman object store) in place of `pg_dump`.
