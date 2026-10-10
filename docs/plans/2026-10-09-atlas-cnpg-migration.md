# Atlas database: move to CloudNativePG

## Why

- Atlas used a shared single-instance Postgres in the `orbit` namespace
  (`postgresql.orbit.svc.cluster.local`), with `DATABASE_URL` in Doppler synced
  into `atlas-secret`. That server lost its data directory twice; the second
  time Atlas's role and database were lost with it.
- It now runs on a node-local `openebs-hostpath` PVC. That survives pod deletion
  but not node or disk loss, and there is no failover.
- Goal: an Atlas-owned CNPG `Cluster` (`atlas-db`) with 2 instances on node-local
  storage, spread across nodes by required pod anti-affinity, so a node loss
  fails over at the Postgres layer. No Longhorn.
- The CNPG operator (1.30.0) is installed. `openebs-hostpath` PVCs work on this
  cluster: orbit's postgresql-data and surfsense run on it on msi-1 and dell-1,
  and the repo has no Talos config change for it. The July failure
  (`git show 6a6a7ca`, `0ac41f9`) was on an older setup.

## What changes

- `cnpg-cluster.yaml` (new): `Cluster/atlas-db`, 2 instances, PostgreSQL 17.11 (`17.11-standard-trixie`, Debian 13),
  5Gi on `openebs-hostpath-retain`, initdb database and owner `atlas` with ICU
  en-US locale, no superuser access, `Prune=false,Delete=false`. Sync wave 0.
- `db-storageclass.yaml` (new): `openebs-hostpath-retain`, cluster-scoped. It is
  `openebs-hostpath` with `reclaimPolicy: Retain`.
- CNPG generates `atlas-db-app` (key `uri` is the web app's `DATABASE_URL`).
- `web-deployment.yaml`: `DATABASE_URL` from `atlas-db-app/uri`. Sync wave 2.
- `bootstrap-job.yaml`: a `Sync` hook at wave 1 (was PreSync). An initContainer
  waits for `atlas-db-rw:5432` to accept TCP connections. It reads `DATABASE_URL`
  from `atlas-db-app/uri`. The `ATLAS_DB_ADMIN_*` refs are optional and resolve
  empty, so `db:ensure` skips.
- `externalsecret.yaml`: `DATABASE_URL`, `ATLAS_DB_ADMIN_USER` and
  `ATLAS_DB_ADMIN_PASSWORD` are still synced but unused. They are kept so a revert
  works (see Rollback). They are removed in a follow-up.
- `kustomization.yaml`: adds `db-storageclass.yaml` and `cnpg-cluster.yaml` under
  Core.

Sync order: wave 0 (Cluster) → wave 1 (bootstrap Job: wait for DB, then
`db:ensure` (skips), migrate, seed) → wave 2 (web Deployment).

ArgoCD v2.14.7 has no built-in health check for `postgresql.cnpg.io` Cluster, so
the Cluster is Healthy as soon as it exists. The initContainer's TCP wait is
what actually orders the Job after the database is up.

## Data decision

No data migration. The orbit `atlas` database holds 1 user and 0 diagrams after
the loss and re-seed, and the seed re-creates the admin. The new cluster starts
empty and the bootstrap seed creates the admin. The appendix covers the case
where data must be moved later.

## Cutover

1. Merge the PR to `main`.
2. ArgoCD creates the StorageClass and the Cluster. The bootstrap Job waits for
   `atlas-db-rw`, runs migrate and seed, and the web Deployment rolls out.
3. If a sync fails, see Operations.

The live `atlas-bootstrap` Job is a hook with `BeforeHookCreation`, so ArgoCD
deletes it by name before creating the new hook. No immutable-field error is
expected.

## Verification

```sh
kubectl -n atlas get cluster atlas-db
kubectl -n atlas get pods -l cnpg.io/cluster=atlas-db -o wide   # 2 pods, different nodes
kubectl -n atlas get job atlas-bootstrap
kubectl -n atlas logs job/atlas-bootstrap -c bootstrap
kubectl get pv | grep atlas                                     # RECLAIM POLICY must be Retain
curl -fsS https://atlas.hoytlabs.app/api/health
```

The `kubectl-cnpg` plugin is NOT installed locally. Where a plugin command is
shown, use the plain-kubectl fallback in Operations instead, or install the
plugin first. Plugin form, for reference (always with `-n atlas`):

```sh
kubectl cnpg -n atlas status atlas-db
```

## Rollback

- Revert this PR. The orbit Postgres still runs and Doppler `ATLAS_DATABASE_URL`
  still points at it. Because the `DATABASE_URL` and `ATLAS_DB_ADMIN_*` mappings
  are kept in the ExternalSecret, the reverted pre-CNPG bootstrap Job still finds
  `atlas-secret/DATABASE_URL`.
- The `atlas-db` Cluster is NOT pruned (`Prune=false`), so ArgoCD leaves it
  running after a revert. Delete it by hand only when sure its data is not needed:
  `kubectl -n atlas delete cluster atlas-db`. Its PVCs use the Retain
  StorageClass, so the data on disk is kept.
- If the revert sync wedges, run `kubectl apply -f apps/atlas/externalsecret.yaml`
  from the reverted tree, then sync again.
- After the follow-up PR removes the Doppler mappings, a plain revert is no
  longer a valid rollback. Restore the mappings first.

## Operations

- If a sync fails, check `kubectl -n atlas get cluster atlas-db` and the Job logs
  (`kubectl -n atlas logs job/atlas-bootstrap -c wait-for-db` and `-c bootstrap`).
  Then run `argocd app sync atlas`. Auto-sync does not retry a failed revision
  after `retry.limit` (2), so a human has to trigger it or push a commit.
- Node gone for good: if an instance stays Pending because its PV is pinned to a
  node that is gone, CNPG has to rebuild that instance elsewhere. Plain kubectl
  fallback (the plugin is not installed), for a replica only:
  1. `kubectl -n atlas get pods -l cnpg.io/cluster=atlas-db -o wide` and confirm
     which instance is the primary (`cnpg.io/instanceRole=primary`). Do not
     delete the primary this way.
  2. `kubectl -n atlas delete pvc atlas-db-<n>`. Deleting the PVC of a Pending
     replica releases its node-pinned volume.
  3. `kubectl -n atlas delete pod atlas-db-<n>`. CNPG recreates the instance and
     its PVC, and schedules it on a node that has room.
  With the plugin (`kubectl cnpg -n atlas destroy atlas-db <n>`) the same thing
  is one command.

## Appendix: if data ever needs migrating

Use only if the database later holds data worth keeping. Order matters:

1. Pause the sync at the ApplicationSet level, not on the Application. The
   `applications` ApplicationSet (`apps/appset.yaml`) generates the `atlas`
   Application with `automated` in its template, so disabling auto-sync on the
   Application is overwritten on the next reconcile. Temporarily remove the
   `automated` block from the template in `apps/appset.yaml`, or otherwise
   exclude `atlas`, and restore it in step 6.
2. Scale the web deployment to 0: `kubectl -n atlas scale deploy/atlas-web --replicas=0`.
3. Dump from the source: `pg_dump --format=custom --no-owner --no-privileges`.
4. Merge and sync so the Cluster and the bootstrap Job create the role and
   database.
5. Restore with pg_restore 17 or later:
   `pg_restore --clean --if-exists --no-owner --no-privileges --single-transaction --exit-on-error -d "$URI" dump.file`,
   where `$URI` is `atlas-db-app`'s `uri`.
6. Restore the `automated` block in `apps/appset.yaml`. The web deployment
   rolls back to 1 replica.

## Follow-ups

- Land the backup CronJob right after cutover. It lives on the unpushed local
  branch `atlas/db-backup` (commits 1dde639 and a05f44f) and will be pushed as a
  PR after #38 merges. It already targets `atlas-db-app`'s `uri` with a PG 17
  image. Until it lands, it keeps reading `atlas-secret/DATABASE_URL`, which
  still holds the orbit URL. Nothing in the nightly dumps reflects the new
  cluster until that PR lands.
- Soak period, then a cleanup PR. It removes the `DATABASE_URL` and
  `ATLAS_DB_ADMIN_*` ExternalSecret mappings, then deletes `ATLAS_DATABASE_URL`
  from Doppler and retires `apps/orbit`.
- Consider CNPG scheduled backups (barman object store) in place of `pg_dump`.
