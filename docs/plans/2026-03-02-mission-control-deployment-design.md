# Mission Control Kubernetes Deployment Design

## Overview

Deploy openclaw-mission-control to the hoytlabs-talos cluster as Kustomize manifests under `apps/mission-control/`, auto-discovered by the existing ArgoCD ApplicationSet.

## Workloads

| Workload | Image | Port |
|----------|-------|------|
| frontend | `ghcr.io/drewpayment/openclaw-mission-control-frontend` | 3000 |
| backend | `ghcr.io/drewpayment/openclaw-mission-control-backend` | 8000 |
| webhook-worker | Same backend image, rq worker entrypoint | — |
| postgres | `postgres:16-alpine` | 5432 |
| redis | `redis:7-alpine` | 6379 |

## Manifest Files

All under `apps/mission-control/`:

- `namespace.yaml` — `mission-control` namespace
- `kustomization.yaml` — resource list
- `configmap.yaml` — non-secret env vars
- `externalsecret.yaml` — Doppler secrets (DB creds, Clerk keys)
- `backend-deployment.yaml` — FastAPI backend with liveness/readiness probes
- `frontend-deployment.yaml` — Next.js frontend
- `worker-deployment.yaml` — RQ webhook worker
- `postgres-deployment.yaml` — PostgreSQL 16 with OpenEBS PVC
- `redis-deployment.yaml` — Redis 7 (ephemeral)
- `backend-svc.yaml` — ClusterIP for backend
- `frontend-svc.yaml` — ClusterIP for frontend
- `postgres-svc.yaml` — ClusterIP for postgres
- `redis-svc.yaml` — ClusterIP for redis
- `http-route.yaml` — `mission-control.hoytlabs.app` → frontend:3000
- `backend-http-route.yaml` — `mission-control-api.hoytlabs.app` → backend:8000
- `pvc.yaml` — OpenEBS PVC for Postgres data
- `serviceaccount.yaml` — ServiceAccount

## Networking

- Frontend: `mission-control.hoytlabs.app` via `gateway-external`
- Backend API: `mission-control-api.hoytlabs.app` via `gateway-external`
- external-dns annotations for automatic DNS registration
- `NEXT_PUBLIC_API_URL=https://mission-control-api.hoytlabs.app`
- `CORS_ORIGINS=https://mission-control.hoytlabs.app`

## Secrets (Doppler)

Pulled via ExternalSecret from `doppler-cluster-secret-store`:

- `MC_POSTGRES_USER` / `MC_POSTGRES_PASSWORD`
- `MC_CLERK_SECRET_KEY` / `MC_CLERK_PUBLISHABLE_KEY`
- `MC_LOCAL_AUTH_TOKEN`

## Storage

- Postgres: OpenEBS local PVC
- Redis: ephemeral (job queue only)

## Health Checks

Backend:
- Liveness: `GET /healthz`
- Readiness: `GET /readyz`

## Auth

- Mode: `clerk`
- Clerk keys stored in Doppler

## Pre-requisites (completed)

- Doppler secrets added
- CI/CD for GHCR image builds (to be set up separately)
