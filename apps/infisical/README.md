# Infisical

Self-hosted [Infisical](https://infisical.com) secrets manager, deployed as a
pure-Kustomize ArgoCD application (no Helm). Auto-discovered by
`apps/appset.yaml` and served at **https://infisical.hoytlabs.app**.

## Components

| Resource | Image | Notes |
|----------|-------|-------|
| `infisical` Deployment | `infisical/infisical:v0.160.7` | Backend + UI on port 8080 (`/api/status` health). Pinned per Infisical's "always pin a version" guidance. |
| `infisical-postgres` Deployment | `postgres:16-alpine` | Persistent data on NFS (`192.168.86.44:/mnt/tank/db/infisical`). |
| `infisical-redis` Deployment | `redis:7-alpine` | Ephemeral cache / queue. |

### Database migrations

The standalone Infisical image's entrypoint does **not** run schema migrations.
They are run explicitly by the `migration` initContainer in `deployment.yaml`
(`npm run migration:latest`), gated behind a `wait-for-postgres` initContainer.
This is idempotent and re-runs automatically on every rollout/upgrade, so
bumping the image tag also applies that version's migrations.

## Required Doppler secrets

The `infisical-secret` ExternalSecret pulls these keys from the
`doppler-cluster-secret-store`. Add them to Doppler **before** the app syncs:

| Doppler key | How to generate |
|-------------|-----------------|
| `INFISICAL_ENCRYPTION_KEY` | `openssl rand -hex 16` |
| `INFISICAL_AUTH_SECRET` | `openssl rand -base64 32` |
| `INFISICAL_POSTGRES_USER` | any value, e.g. `infisical` |
| `INFISICAL_POSTGRES_PASSWORD` | `openssl rand -base64 24` |

> ⚠️ `ENCRYPTION_KEY` and `AUTH_SECRET` must remain **stable** for the life of
> the instance. Rotating `ENCRYPTION_KEY` makes existing encrypted data
> unreadable.

`DB_CONNECTION_URI` and `REDIS_URL` are composed in-manifest from the above
secret + the ConfigMap, so they are not stored in Doppler.

## Prerequisites

- The NFS export `/mnt/tank/db/infisical` must exist on `192.168.86.44`.
- Wildcard `*.hoytlabs.app` TLS is already terminated at `gateway-external`;
  external-dns publishes the `infisical.hoytlabs.app` record from the HTTPRoute
  annotation.

## First-time setup

Once synced and healthy, browse to https://infisical.hoytlabs.app to create the
initial admin account (the first signup becomes the instance admin).
