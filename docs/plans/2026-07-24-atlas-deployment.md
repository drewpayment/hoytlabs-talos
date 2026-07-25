# Atlas Kubernetes Deployment Design

## Overview

Deploy Atlas (internal architecture-diagram app, Next.js + Excalidraw + Better
Auth) to the hoytlabs-talos cluster as Kustomize manifests under
`apps/atlas/`, auto-discovered by the existing ArgoCD ApplicationSet. This is
the M1 milestone deliverable: skeleton, auth, and deploy pipeline. Full
context: `drewpayment/atlas` repo, `docs/PLAN.md`.

New pattern for this cluster: Postgres is provisioned by the **CloudNativePG**
operator instead of a per-app `postgres:16-alpine` Deployment on an NFS PVC
(the pattern every other app, including sprinkler, uses today). This is the
first CNPG consumer in the cluster.

## Workloads

| Workload | Image | Port |
|----------|-------|------|
| web | `ghcr.io/drewpayment/atlas-web` | 3000 |
| bootstrap (PostSync hook) | `ghcr.io/drewpayment/atlas-bootstrap` | — |
| atlas-db (CNPG Cluster, 1 instance) | `ghcr.io/cloudnative-pg/postgresql:17.10` | 5432 |

## Manifest Files

All under `apps/atlas/`:

- `namespace.yaml` — `atlas` namespace
- `serviceaccount.yaml` — ServiceAccount `atlas`
- `configmap.yaml` — `BETTER_AUTH_URL`, `TRUSTED_ORIGINS`, `NODE_ENV`
- `externalsecret.yaml` — Doppler secrets via `doppler-cluster-secret-store`:
  `BETTER_AUTH_SECRET`, `ADMIN_EMAIL`, `ADMIN_PASSWORD` into Secret
  `atlas-secret`. `DATABASE_URL` is deliberately **not** here — CNPG owns it.
- `storageclass.yaml` — app-owned `atlas-db-storage` (openebs local
  provisioner, same `BasePath` as the cluster-default `openebs-hostpath`,
  but `reclaimPolicy: Retain` instead of `Delete` — see Storage below).
- `cnpg-cluster.yaml` — CNPG `Cluster` `atlas-db`, 1 instance, PostgreSQL
  17.10, 2Gi on `atlas-db-storage`, explicit `bootstrap.initdb`
  (`database: atlas`, `owner: atlas`). Auto-creates Secret `atlas-db-app` with
  connection keys, notably `uri`.
- `bootstrap-job.yaml` — ArgoCD PostSync hook Job running drizzle migrate +
  a check-then-skip seed (admin user), same pattern as `sprinkler-bootstrap`.
  Not upsert: rotating `ADMIN_PASSWORD` in Doppler and resyncing does not
  change an already-seeded admin's password.
- `web-deployment.yaml` — Next.js server. Readiness on `/api/health:3000`
  (DB-backed `select 1`, correctly gates traffic and works pre-migration);
  liveness on `/login:3000` (DB-free — see the in-file comment for why a
  single-instance CNPG cluster makes a DB-backed liveness probe dangerous).
  Sprinkler-sized resources (50m/192Mi req, 512Mi limit); container
  `securityContext` (`runAsNonRoot`, drop `ALL` caps, no privilege
  escalation, `RuntimeDefault` seccomp).
- `web-svc.yaml` — ClusterIP `3000 -> 3000` (matches sprinkler's actual
  convention; sprinkler does not front its web Service on port 80).
- `http-route.yaml` — Gateway API HTTPRoute, `atlas.hoytlabs.app`, parent
  `gateway-external` in ns `gateway` (same gateway every app in this cluster
  uses today — `gateway-internal` exists but is unused by any app, so there
  is no "internal app" convention to follow yet).
- `kustomization.yaml` — resource list + `images:` block pinning
  `ghcr.io/drewpayment/atlas-web` and `ghcr.io/drewpayment/atlas-bootstrap`
  (placeholder `newTag: latest` until first release pin).

## Infrastructure: CloudNativePG operator install

`infrastructure/controllers/cloudnative-pg/` (new, auto-discovered by
`infrastructure/appset.yaml`, sync-wave `-2`):

- `namespace.yaml` — `cloudnative-pg` namespace
- `values.yaml` — homelab-sized operator resources (50m/100Mi req, 256Mi
  limit), `crds.create: true` explicit
- `kustomization.yaml` — `helmCharts` block via the `kustomize-build-with-helm`
  CMP, chart `cloudnative-pg` v0.29.0 (operator appVersion 1.30.0) from
  `https://cloudnative-pg.github.io/charts`

Same shape as `infrastructure/controllers/cert-manager/` (the other
helm-based controller in this repo): namespace + `helmCharts` block, no
hand-written ArgoCD `Application`.

### CRD-before-CR ordering

The Atlas app's `cnpg-cluster.yaml` (`Cluster` CR) lives in a *separate*
ArgoCD Application (`apps/atlas`) from the operator install
(`infrastructure/controllers/cloudnative-pg`). **Correction from an earlier
draft of this doc:** the `sync-wave: "-2"` / `"-2"`-style annotations on
`infrastructure/appset.yaml` and `apps/appset.yaml` sit on the
**ApplicationSet objects themselves**, not on the per-directory Applications
they generate — ApplicationSets do not propagate that annotation down, so
there is no actual ordering guarantee between the `cloudnative-pg`
Application and the `atlas` Application. `ServerSideApply=true` does not
help either: the API server hard-rejects a `Cluster` manifest against a GVK
that isn't registered yet, it doesn't defer or queue it.

What actually makes this converge instead of wedging: `apps/appset.yaml`'s
`syncPolicy.automated.selfHeal: true` keeps re-driving the `atlas`
Application's sync on a loop until it succeeds. If the first attempt lands
before `cloudnative-pg` has installed the CRDs (or before the operator pod
is `Ready` — its `ValidatingWebhookConfiguration` is `failurePolicy: Fail`,
backed by a self-signed cert the operator generates and patches into the
webhook config at startup, so the webhook itself gates admission until the
operator is genuinely up, not merely until the CRD is `Established`), that
sync attempt fails cleanly and selfHeal retries it. No resources are ever
successfully created on a failed attempt, so `prune: true` has nothing to
tear down in the interim. Convergence is on the order of minutes once
`cloudnative-pg` reaches `Healthy`, not a permanent failure requiring
intervention. `cnpg-cluster.yaml` carries
`argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` to quiet
the "no matches for kind Cluster" dry-run noise on the syncs before that
point.

**Manual step only if it doesn't self-heal within a few minutes:** check
`cloudnative-pg` Application health first (operator pod `Ready`, CRDs
present), then re-run sync on the `atlas` Application.

## Networking

- Web: `atlas.hoytlabs.app` via `gateway-external`
- external-dns annotation for automatic DNS registration
- TLS: existing wildcard `*.hoytlabs.app` cert at the Gateway, no per-app
  Certificate

## Secrets (Doppler) — manual step for Drew

Add these keys in Doppler before merge/first sync:

- `ATLAS_BETTER_AUTH_SECRET`
- `ATLAS_ADMIN_EMAIL`
- `ATLAS_ADMIN_PASSWORD`

`DATABASE_URL` is not a Doppler key for Atlas — it comes from the
CNPG-generated `atlas-db-app` Secret's `uri` key.

## Storage

- Postgres: app-owned `atlas-db-storage` StorageClass
  (`apps/atlas/storageclass.yaml`), not the cluster-default
  `openebs-hostpath` directly. Same provisioner (`openebs.io/local`) and
  `BasePath` (`/var/openebs/local`, confirmed against the rendered output of
  `infrastructure/storage/openebs/`) — the only difference is
  `reclaimPolicy: Retain` instead of `openebs-hostpath`'s `Delete`. This app
  syncs with `prune: true`; on `Delete` reclaim, a pruned-and-recreated
  `Cluster` CR (e.g. from a bad manifest edit, or the ArgoCD selfHeal loop
  described above misfiring) would silently delete the underlying PV and the
  database with it. `Retain` means a deleted PVC/PV leaves the hostpath data
  on disk for manual recovery instead of destroying it. Local disk (over
  NFS) chosen to avoid the documented TrueNAS `Maproot` CrashLoop gotcha
  entirely and because local disk suits Postgres better on this cluster.

### Accepted debt (M1)

This is a single-instance CNPG cluster on node-local (`openebs-hostpath`
provisioner) storage: **no replicas, no streaming standby, no backups
configured, and the pod is pinned to whichever node its PV was created on**
— if that node goes down, the database goes down with it until the node
comes back, full stop. There is currently no automated backup path (no
`Backup`/`ScheduledBackup` CR, no barman-object-store or volume-snapshot
config); the restore path today is manual: recreate the `Cluster` from the
`Retain`-ed PV if the node recovers, or recreate + re-seed via
`bootstrap-job.yaml` + restore application data from a manually-taken `pg_dump`
if it doesn't. This is acceptable for M1's walking-skeleton scope but is real
production risk that a later milestone should close (at minimum: a
scheduled `pg_dump` CronJob to off-cluster storage before Atlas holds any
data anyone would be upset to lose).

## Health Checks

Web: readiness `GET /api/health` (DB-backed, gates traffic); liveness
`GET /login` (DB-free, port 3000 — see rationale in `web-deployment.yaml`).

## Release flow

1. Merge to `main` in `drewpayment/atlas` → GitHub Actions pushes
   `ghcr.io/drewpayment/atlas-web` and `atlas-bootstrap` tagged `:latest` +
   `:<sha>`.
2. Edit `apps/atlas/kustomization.yaml` in hoytlabs-talos: set both
   `images[].newTag` to the merge SHA; commit as
   `deploy(atlas): bump newTag to the atlas merge SHA (<description>)`.
3. ArgoCD auto-syncs; rollout + PostSync migration/seed Job. Never
   kubectl-mutate.

## Pre-requisites (before first sync)

- Doppler secrets added (see above)
- CI/CD for GHCR image builds (`atlas-web`, `atlas-bootstrap`) set up in the
  `atlas` repo
- GHCR packages public (no imagePullSecrets configured cluster-wide)
