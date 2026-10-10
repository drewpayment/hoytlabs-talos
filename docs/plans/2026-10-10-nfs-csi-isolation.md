# nfs-csi claims share one NAS directory: isolation plan (surfsense)

Status: plan. Nothing in this PR is applied to the cluster. The cutover steps
below are each a git commit, because ArgoCD auto-syncs the `surfsense`
Application with `prune: true` and `selfHeal: true`.

## Hazard

`infrastructure/storage/csi-driver-nfs/storageclass.yaml` sets a constant
`subDir: kubernetes-pvcs`. Every PVC of class `nfs-csi` is therefore mounted at
the same NAS path. Confirmed live from `/proc/mounts` in the backend, worker and
redis pods:

```
192.168.86.44:/mnt/tank/appdata/kubernetes-pvcs /shared_tmp        nfs4 rw,...
192.168.86.44:/mnt/tank/appdata/kubernetes-pvcs /app/.local_object_store nfs4 rw,...
192.168.86.44:/mnt/tank/appdata/kubernetes-pvcs /data              nfs4 rw,...
```

The volume handles agree (`192.168.86.44#mnt/tank/appdata#kubernetes-pvcs#pvc-<uid>#`),
but the mount source has no per-PV suffix, so the PV name is not a directory.

Consequences:
- The object-store claim and the shared-tmp claim are the same directory. Both
  `/app/.local_object_store` and `/shared_tmp` in the backend show identical
  listings.
- Redis's `/data` is the same directory too.
- Nothing separates one app's files from another's. Quota is not enforced by
  the driver.

Corrections to the original brief, from measurement:
- File count is about 35,000, not 49,000. The root has 500 `tmp*.md` files, not thousands.
- The redpanda app is NOT deleted. `apps/redpanda` runs and uses local xfs for its data
  (`/dev/sda6` at `/var/lib/redpanda/data`). The `redpanda/` entry on the share is
  leftover data from two PVs (`pvc-4d029039...`, `pvc-eb9c8e1f...`, claim
  `redpanda/data-redpanda-0`, created 2026-01-03) that are now `Released` with
  `Retain`.
- "mv is a rename" holds only within one mount point. Separate PVC mounts in a
  pod are separate mount points, so a rename between them is EXDEV. The migration
  therefore copies (`cp -a`), and that also keeps the rollback path intact.

## Inventory

Measured with read-only `kubectl exec ... -- ls/du/stat/find` on the running
surfsense backend (root of the shared directory, same as worker and redis).
Sizes are `du -sh`. Total used on the share: 1.2 GiB (`df`).

| Entry (at share root) | Size | Files | Owner / mode | Claim (attributed by config path) | Action |
|---|---|---|---|---|---|
| `knowledge_store/` | 37 MB | 7,707 | root:1000, setgid | object store (`FILE_STORAGE_LOCAL_PATH=/app/.local_object_store`, `KNOWLEDGE_STORE_ENABLED`) | copy to object-store-v2 |
| `dump.rdb` | 529 KB | 1 | 999:1000, 0600 | redis (`/data`, default `dir`) | copy to redis-v2 |
| `appendonlydir/` | 16.6 MB apparent (3 files: base RDB, incr AOF, manifest; du shows 2.4 MB) | 3 | 999:1000, setgid | redis (`--appendonly yes`) | copy to redis-v2 |
| `gitingest/` | 531 MB | 26,388 | root:1000, setgid | shared-tmp scratch (`TMPDIR=/shared_tmp`; gitingest clones) | leave behind |
| `playwright_chromiumdev_profile-UUEJvE/` | 36 MB | 422 | root:1000, setgid | shared-tmp scratch (chromium profile) | leave behind |
| `tmp*.md` (500 files) | 2.3 MB | 500 | root:1000, 0660 | shared-tmp scratch (tempfiles) | leave behind |
| `org.chromium.Chromium.1WL7ir/`, `playwright-artifacts-gzntP3/`, `pulse-PKdhtXMmr18n/`, `pymp-{4gseu532,kjnvgqa9,ktxrzm49,ql2cf4n9,ra8yh1m7}/` | <5 KB each | few | root:1000, setgid | shared-tmp scratch (Sep 2-5) | leave behind |
| `torchinductor_root/` | <5 KB | few | root:1000, setgid | shared-tmp scratch (torch compile cache) | leave behind |
| `redpanda/`, `cloud_storage_cache/`, `pid.lock` | 2.5 KB, 512 B, 2 B | few | 101:1000 (uid 101 = redpanda), Jan 3 2026 | ORPHAN (leftover from two Released redpanda PVs) | leave behind; human decision later |

Attribution note: all three claims mount the same directory, so the mapping above
comes from config paths and writers, not from separate physical directories. The
only claim-specific data is `knowledge_store/` (object store) and `dump.rdb` plus
`appendonlydir/` (redis). Everything else is shared-tmp scratch or orphan. The worker's
`gitingest-scratch` emptyDir (10Gi, local xfs) shadows `/shared_tmp/gitingest` in the
worker only. The backend still sees the NFS `gitingest/` directory.

### Mounts (live pods, which claim and where)

| Claim (deprecated name) | Pod / container | Mount path | Notes |
|---|---|---|---|
| `surfsense-object-store-pvc` (50Gi) | `surfsense-backend` / `backend` | `/app/.local_object_store` | `FILE_STORAGE_LOCAL_PATH` |
| `surfsense-object-store-pvc` | `surfsense-worker` / `worker` | `/app/.local_object_store` | |
| `surfsense-shared-tmp-pvc` (20Gi) | `surfsense-backend` / `backend` | `/shared_tmp` | `TMPDIR` |
| `surfsense-shared-tmp-pvc` | `surfsense-worker` / `worker` | `/shared_tmp` | plus emptyDir at `/shared_tmp/gitingest` |
| `surfsense-redis-pvc` (5Gi) | `surfsense-redis` / `redis` | `/data` | `redis-server --appendonly yes` |

No nfs-csi claim is used by beat, migrations, searxng, zero-cache, postgres,
frontend, or the minknotes sync CronJob. (Postgres and zero-cache use openebs-hostpath.)

### Pod identity and directory ownership

| Workload | Runs as | fsGroup | Notes |
|---|---|---|---|
| backend | root (0) | none | image declares no USER; writes root-owned files |
| worker | root (0) | none | same image |
| redis | 999:1000 | 1000 | `dump.rdb`, `appendonlydir` are 999:1000 |

The share root is `drwxrwsrwx root:1000` (0777 with setgid). Root-owned files
created by the backend keep `root` as owner, so the export does not squash root.
Redis works today because the directory is world-writable.

Dynamically created subdirectories (new class) are expected to be created as
root with mode 0777. This is not verified. The migrate Job prints it before copying (cutover step 4).

## Decision: new claim names (option a), not delete and recreate (option b)

Chosen: keep the old claims in place, add three `-v2` claims on `nfs-csi-isolated`,
and switch consumers in one commit.

Reasons:
1. `storageClassName` is immutable, so option (b) means deleting claims. With
   `prune: true` and Retain, that is a risky, git-driven delete of a live PVC.
2. The old claims stay Bound and untouched. Rollback is a one-commit revert of
   the Deployments, with no re-provisioning.
3. The copy-based migration needs the old data in place anyway, for rollback.

Option (b) would only be cleaner if the -v2 names were unwanted later. That is a
small, separate rename, and it can wait.

Manifests in this PR:
- `infrastructure/storage/csi-driver-nfs/storageclass.yaml`: `nfs-csi` marked deprecated; new `nfs-csi-isolated` (same server and share, `subDir: "${pvc.metadata.namespace}/${pvc.metadata.name}"`, `onDelete: retain`, `reclaimPolicy: Retain`, `allowVolumeExpansion: true`). No `mountOptions`, to match the live `nfs-csi` (mount shows `local_lock=none`, no `nolock`). The atlas class adds `nolock`; that is intentionally not copied.
- `apps/surfsense/pvc.yaml`: the three old claims are marked deprecated and kept. Three new claims are added: `surfsense-object-store-v2-pvc` (50Gi), `surfsense-shared-tmp-v2-pvc` (20Gi), `surfsense-redis-v2-pvc` (5Gi). These are created empty and mount nothing until the cutover. Expected directories: `/mnt/tank/appdata/surfsense/<claim-name>` (no PV suffix, confirmed by the `atlas/atlas-db-backups` handle).
- `apps/surfsense/nfs-migrate-job.example.yaml`: the one-off copy Job. Not in `kustomization.yaml`.
- Deployments are NOT changed in this PR.

### ArgoCD wiring

- `infrastructure/appset.yaml` (`ApplicationSet` `infrastructure-components`) generates one Application per `infrastructure/storage/*` directory. That covers `csi-driver-nfs`, using the `kustomize-build-with-helm` plugin, `prune: true`, `selfHeal: false`.
- `storageclass.yaml` is applied by the `csi-driver-nfs` Application. The new `nfs-csi-isolated` class will sync on merge. `kubectl get sc` shows `atlas-nfs-isolated` already exists; that came from `apps/atlas`.
- Live `csi-driver-nfs` is `Synced/Progressing`, unrelated to this change.
- Because `prune: true`, a future PR that deletes `nfs-csi` would prune the class. Bound PVs keep working when a class is deleted, so this is safe once no PVC references it.

## Other references to `nfs-csi` (grep)

- `apps/surfsense/pvc.yaml`: the three old claims (`storageClassName: nfs-csi`). Updated in this PR.
- `apps/surfsense/README.md` lines 41-51: step 3 says to verify `nfs-csi`. It also says static fallback paths are `/mnt/tank/db/surfsense/{object-store,shared-tmp,redis}`. That path is stale; the live share is `/mnt/tank/appdata`. Not changed here. Update in the follow-up.
- `apps/atlas/db-backup-storageclass.yaml` and `apps/atlas/db-backup-pvc.yaml`: comments only. The atlas claim uses `atlas-nfs-isolated`, already correct.
- `CLAUDE.md` lines 46 and 71: general mention of "NFS CSI driver". Not a storageClassName reference.
- Not nfs-csi: `apps/infisical` (`infisical-storage`), `apps/sprinkler` (`sprinkler-storage`, share `/mnt/tank/db`), and the cluster default `tank-db` (from `values.yaml`). All on other shares or classes.

## Cutover

### Hard prerequisites (gate before C1a)

Do not start C1a until all of these hold. The StorageClass is synced by the
`csi-driver-nfs` infrastructure Application, which has `selfHeal: false`. Provisioner
retries can take up to 30 minutes.

```
kubectl get sc nfs-csi-isolated                      # must exist
kubectl -n surfsense get pvc surfsense-object-store-v2-pvc surfsense-shared-tmp-v2-pvc surfsense-redis-v2-pvc   # all STATUS Bound
```

### Corrected step order (verbatim)

merge -> SC/PVC gate -> C1a -> queue gate -> C1b -> Job -> C2 -> verify incl. `ls -ld /data` in redis -> later cleanup

Why the split: `redis-deployment.yaml` is sync-wave 0, while backend, worker and
beat are in waves 2-3. A single commit that scales everything to 0 would stop redis
before the writers, and the writers would then fail on queue operations.

**Merge.** This PR. The `-v2` claims bind to empty directories. Nothing mounts them yet.

**C1a (commit): stop the writers.** In `apps/surfsense/`:
- `minknotes-sync-cronjob.yaml`: `spec.suspend: true`.
- `beat-deployment.yaml`, `worker-deployment.yaml`, `backend-deployment.yaml`: `replicas: 0`.
- Leave `redis`, `frontend`, `postgres`, `zero-cache`, `searxng` running.

**Queue gate (manual, read-only).** All must print 0 before C1b:
```
kubectl -n surfsense exec deploy/surfsense-redis -c redis -- sh -c 'for k in surfsense surfsense.connectors surfsense.gateway; do redis-cli llen $k; done; redis-cli hlen unacked'
```
If any value is nonzero, wait, or look at why the queue is not draining. Do not continue.

**C1b (commit): stop redis.** In `apps/surfsense/redis-deployment.yaml`: `replicas: 0`.
Watch the shutdown while it syncs:
```
kubectl -n surfsense logs -f deploy/surfsense-redis
```
Wait for "DB saved on disk" and "ready to exit". AOF is on, so the SIGTERM shutdown
persists state. No BGSAVE is needed. It cannot be timed reliably under auto-sync anyway.

**Job (manual, one-off copy).** Create the Job from the example file. It checks the destinations
are empty (or clears them with RESET=1), copies `knowledge_store` to the object-store-v2
claim and `dump.rdb` and `appendonlydir` to redis-v2. It then runs `chown 999:1000` and
`chmod 2770` on the redis-v2 root, and verifies with a metadata listing (owner, group, mode, path) that must match the old
tree, plus `diff -rq`/`cmp` on the contents. It prints `MIGRATION OK` only if everything passes.
The Job also prints the destination modes before copying. That is the first time the new
directory mode is visible, so this is the check for the unknown in item 1 of the Unknowns section.
```
sed -n '/^apiVersion/,$p' apps/surfsense/nfs-migrate-job.example.yaml | kubectl -n surfsense create -f -
kubectl -n surfsense logs job/surfsense-nfs-migrate -f
```
Expect `MIGRATION OK`. On failure, fix the cause and rerun with RESET=1 (it empties only
the two -v2 destinations; the old share is never touched). Delete the Job after verifying:
`kubectl -n surfsense delete job surfsense-nfs-migrate`.

**C2 (commit): cut over.** In `apps/surfsense/`:
- `backend-deployment.yaml`: volume `object-store` to `surfsense-object-store-v2-pvc`; volume `shared-tmp` to `surfsense-shared-tmp-v2-pvc`. `replicas: 1`.
- `worker-deployment.yaml`: same two volume changes. `replicas: 1`.
- `redis-deployment.yaml`: volume `redis-data` to `surfsense-redis-v2-pvc`. `replicas: 1`.
- `beat-deployment.yaml`: `replicas: 1`.
- `minknotes-sync-cronjob.yaml`: `suspend: false`.

Container mount paths do not change, so no app config changes.

**Verify.**
```
kubectl -n surfsense get deploy
kubectl -n surfsense exec deploy/surfsense-redis -c redis -- sh -c 'ls -ld /data; ls -la /data; redis-cli config get dir; redis-cli dbsize'
kubectl -n surfsense exec deploy/surfsense-backend -c backend -- sh -c 'ls -la /app/.local_object_store/knowledge_store; ls -la /shared_tmp | head'
kubectl -n surfsense exec deploy/surfsense-backend -c backend -- python -c "import urllib.request as u;print(u.urlopen('http://localhost:8000/ready').status)"
kubectl -n argocd get application surfsense
```
Also check `https://surfsense.hoytlabs.app` loads, run one retrieval against a knowledge
workspace, and confirm the worker picks up a task.

**Later cleanup (separate PRs, not part of cutover).**
1. Remove the three old claims from `pvc.yaml`. With `prune: true`, that deletes the PVCs. Reclaim is Retain, so the PVs go `Released` and the directories stay.
2. Remove `nfs-csi` once nothing refers to it.
3. Decide on the old share root (`kubernetes-pvcs`): archive it, or remove scratch and the redpanda orphans by hand.
4. Delete the two `Released` redpanda PVs, after a human check.

**WARNING for cleanup (step 7).** The old nfs-csi PVs have an empty `onDelete` in their
volume handle, so the driver default (delete) applies. Never set `reclaimPolicy: Delete` on
any nfs-csi PV. With Delete, the driver removes the whole shared `kubernetes-pvcs`
directory, and everything in it. Remove PV objects only, and clean the NAS by hand.

## Rollback

Rollback is a commit (C3), a revert of C2:
- Point `backend`, `worker`, `redis` back at `surfsense-object-store-pvc`, `surfsense-shared-tmp-pvc`, `surfsense-redis-pvc`. Restore `replicas: 1` and `suspend: false`.
- The old claims were never deleted or edited, and the originals were only copied. Data is intact in `kubernetes-pvcs`.
- Trade-off: anything written to the `-v2` directories after C2 is not in the old directory. Re-copy it if it is needed, or accept the loss.

No scale-by-kubectl. ArgoCD `selfHeal: true` reverts `kubectl scale` on the surfsense Application within minutes. Every replica change goes through git.

## Manual actions and read-only checks (what was run for this plan)

- `kubectl get/describe/exec` only. `exec` was used to read `ls`, `du`, `stat`, `find` and `/proc/mounts`, and `redis-cli config get dir`, `dbsize`. No writes.
- No `create`, `apply`, `delete`, `scale` or `patch` in the cluster.

## Unknowns

1. Mode and owner of dynamically created subdirectories (expected 0777, root). The migrate Job prints them before copying (cutover "Job" step). The Job then sets the redis-v2 root to 999:1000 2770.
2. Whether `/mnt/tank/appdata/kubernetes-pvcs` and `/mnt/tank/appdata/surfsense` are on the same ZFS dataset. Not verified. The copy avoids depending on it.
3. Whether the NFS `gitingest/` directory is still written by the backend. The backend has no gitingest emptyDir. It is scratch, so this does not block the migration.
4. Whether `knowledge_store` is the only object-store content. Only that entry was found at the share root.
5. Whether `cloud_storage_cache/`, `pid.lock` and `redpanda/` belong to redpanda. Inferred from uid 101 and the Jan 3 2026 timestamps of the Released PVs.
6. Whether any scratch directory is in use by a running process. Not checked (no `ps` inside the containers).
7. Quota. Not addressed. The NFS driver does not enforce quota. Per-claim quota would need a ZFS dataset per claim, which is out of scope here.
8. Whether csi-driver-nfs v4.11 honours `mountPermissions` in the StorageClass. Not used. Revisit only if the Job's destination-mode print shows the directories are not writable.
