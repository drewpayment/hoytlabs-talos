# SurfSense

Self-hosted [SurfSense](https://www.surfsense.com) — a research/RAG assistant —
ported from the upstream `docker/docker-compose.yml` to this cluster.

Pinned to release **0.0.39** (`ghcr.io/modsetter/surfsense-backend` and
`-web` share the tag; bump both together in `kustomization.yaml`).

## Before the first sync

The Application will sit in a failed sync until all four of these are true.

### 1. Doppler keys

The ExternalSecret pulls five keys. Create them first:

| Doppler key | Value |
| --- | --- |
| `SS_POSTGRES_USER` | e.g. `surfsense` |
| `SS_POSTGRES_PASSWORD` | **alphanumeric only** — see below |
| `SS_SECRET_KEY` | `openssl rand -base64 32` |
| `SS_ZERO_ADMIN_PASSWORD` | any random string |
| `SS_SEARXNG_SECRET` | any random string |

`SS_POSTGRES_PASSWORD` is interpolated into `DATABASE_URL` and the three
`ZERO_*_DB` connection strings as a bare substring. Nothing in the chain
percent-encodes it, so a `@`, `:`, `/` or `#` yields a URL that parses into the
wrong host and fails without naming the cause.

### 2. Verify the `openebs-hostpath` StorageClass exists

```bash
kubectl get sc openebs-hostpath
```

`infrastructure/storage/openebs` installs the chart with
`engines.local.hostpath.enabled: true`, which should create it, but no other app
in this repo consumes it — this is the first. Postgres and the zero-cache
replica both claim from it.

### 3. Verify the `nfs-csi` StorageClass provisions dynamically

```bash
kubectl get sc nfs-csi
```

The object store, scratch dir and Redis use dynamic RWX claims against it rather
than the static-PV pattern the other apps use, so no directories need creating
on the TrueNAS box by hand. This is also the first app in the repo to use it
dynamically — if it misbehaves, fall back to static PVs under
`/mnt/tank/db/surfsense/{object-store,shared-tmp,redis}`.

### 4. DNS

The HTTPRoute carries the `external-dns` hostname annotation for
`surfsense.hoytlabs.app`, same as every other app. Traffic arrives via the
Cloudflare tunnel → `gateway-external`.

## Sync ordering

Upstream expresses ordering with `depends_on: service_completed_successfully`.
Sync waves reproduce it:

| Wave | Resources |
| --- | --- |
| -1 | ExternalSecret |
| 0 | Postgres, Redis, SearXNG, PVCs, ConfigMaps |
| 1 | `surfsense-migrations` Job — `alembic upgrade head` + `zero_publication` check |
| 2 | backend (`SERVICE_ROLE=api`), zero-cache |
| 3 | worker, beat, frontend, HTTPRoute |

ArgoCD will not start wave 2 until the Job reports Complete, so a failed
migration halts the sync instead of rolling pods against a drifted schema.

Note this is a Job in a sync wave, **not** a `PreSync` hook like
`atlas-bootstrap`. atlas migrates a Postgres that exists outside its own
Application; this one ships its own database, and a PreSync hook runs before
every sync-phase resource — including `surfsense-postgres`.

## What was dropped from the compose stack

**`opensandbox-server` and `sandbox-image`.** The sandbox runtime mounts
`/var/run/docker.sock` and spawns sibling Docker containers on the host daemon.
Talos runs containerd and exposes no Docker daemon to workloads, so this cannot
run here at all. `SANDBOX_ENABLED=FALSE` in the ConfigMap. To get the feature
back you would either point `SANDBOX_PROVIDER=daytona` at Daytona's hosted API,
or stand up `opensandbox-server` on a separate non-Talos Docker host and set
`OPENSANDBOX_DOMAIN` to it.

**`proxy` (Caddy).** Replaced by `http-route.yaml` against the existing Envoy
gateway. TLS is already handled by cert-manager plus the Cloudflare tunnel, so
Caddy's ACME half was redundant too.

**`whatsapp-bridge`.** Already commented out upstream.

## Things that will bite

- **Uploads cap at 100 MB, not 500 MB.** Cloudflare's free tier hard-caps
  request bodies at 100 MB and all external traffic crosses the tunnel.
  `MAX_FILE_SIZE_MB` is set to match, so users get a clear app-level rejection
  instead of an opaque 413 from Cloudflare. Raising it requires routing
  SurfSense through `gateway-internal` only.
- **First pull is several GB per node.** The backend image bakes CPU torch,
  Docling models and EasyOCR weights into its layers, and three Deployments plus
  a Job run it. They can land on three different nodes and pull it three times.
  If that hurts, add node affinity to co-locate api/worker/beat.
- **Postgres and zero-cache are node-pinned** by their hostpath volumes. Losing
  that node means restoring from backup, not rescheduling. There is no backup
  CronJob in here yet — add a `pg_dump` to NFS before you put anything you care
  about in it.
- **`REGISTRATION_ENABLED` is `TRUE`.** The app is reachable from the public
  internet. Flip it to `FALSE` in `configmap.yaml` once your account exists.
- **The backend runs as root.** The upstream image declares no `USER` and its
  entrypoint writes to root-owned paths, so `runAsNonRoot` cannot be set on it.
  Capabilities are dropped and privilege escalation is off; that is the ceiling
  without rebuilding the image. The frontend does run as uid 1001.
- **Startup is slow by design.** The backend loads torch, Docling and the
  embedding model before `/ready` answers (startup budget: 10 min); zero-cache
  rebuilds its replica from the WAL on first boot (budget: 15 min). Both look
  like hangs on a first sync and are not.

## Model / LLM configuration

No LLM provider key is wired up. SurfSense configures chat models in-app after
first login rather than purely through env vars, so start there. If you want a
provider key present at boot instead, add it to `externalsecret.yaml` and
reference it from the backend, worker and beat Deployments.
