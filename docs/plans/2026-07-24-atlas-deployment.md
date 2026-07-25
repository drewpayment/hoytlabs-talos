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
- `cnpg-cluster.yaml` — CNPG `Cluster` `atlas-db`, 1 instance, PostgreSQL
  17.10, 2Gi on `openebs-hostpath`, explicit `bootstrap.initdb`
  (`database: atlas`, `owner: atlas`). Auto-creates Secret `atlas-db-app` with
  connection keys, notably `uri`.
- `bootstrap-job.yaml` — ArgoCD PostSync hook Job running drizzle migrate +
  idempotent seed, same pattern as `sprinkler-bootstrap`.
- `web-deployment.yaml` — Next.js server, probes on `/api/health:3000`,
  sprinkler-sized resources (50m/192Mi req, 512Mi limit).
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

The Atlas app's `cnpg-cluster.yaml` (`Cluster` CRD) lives in a *separate*
ArgoCD Application (`apps/atlas`, sync-wave `1`) from the operator install
(`infrastructure/controllers/cloudnative-pg`, sync-wave `-2`). Both
ApplicationSets set `ServerSideApply=true`; the apps ApplicationSet also has
`retry: {limit: 2, backoff: {duration: 5s, factor: 2, maxDuration: 3m}}`.
There is no existing in-repo precedent for a brand-new operator + a CR
consuming it in the very first commit (the only CRD-ordering precedent,
`cert-manager`'s `cluster-issuer.yaml`, ships in the *same* Application as the
operator and uses a per-resource `commonAnnotations` sync-wave override to
sequence within that Application — not applicable here since our CRD and CR
are already in different Applications/waves).

Expectation: on a clean sync, infra wave `-2` completes (CNPG CRDs
`Established`) before the apps wave `1` starts, so `atlas`'s Cluster should
apply cleanly. If ArgoCD fans out the two ApplicationSets closer together than
strict wave ordering suggests, the apps retry policy (2 retries, up to 3m
backoff) should absorb a transient "no matches for kind Cluster" error.
**Manual step if it doesn't self-heal:** re-run sync on the `atlas` app once
`cloudnative-pg` is `Healthy`.

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

- Postgres: `openebs-hostpath` StorageClass (local disk; confirmed as the
  StorageClass name actually provisioned by
  `infrastructure/storage/openebs/values.yaml`'s LocalPV Hostpath engine).
  Chosen over NFS to avoid the documented TrueNAS `Maproot` CrashLoop gotcha
  entirely and because local disk suits Postgres better on this cluster.

## Health Checks

Web: `GET /api/health` (readiness + liveness, port 3000)

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
