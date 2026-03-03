# Mission Control K8s Deployment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy openclaw-mission-control (frontend, backend, worker, postgres, redis) to the hoytlabs-talos cluster via Kustomize manifests auto-discovered by ArgoCD.

**Architecture:** Plain Kustomize manifests in `apps/mission-control/`. ArgoCD ApplicationSet auto-discovers any `apps/*` directory. Secrets come from Doppler via ExternalSecrets. Networking uses Gateway API HTTPRoutes on `*.hoytlabs.app`.

**Tech Stack:** Kustomize, ArgoCD, Gateway API (Envoy), ExternalSecrets (Doppler), OpenEBS hostpath, PostgreSQL 16, Redis 7, FastAPI, Next.js

---

### Task 1: Create namespace and service account

**Files:**
- Create: `apps/mission-control/namespace.yaml`
- Create: `apps/mission-control/serviceaccount.yaml`

**Step 1: Create the namespace manifest**

```yaml
# apps/mission-control/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mission-control
```

**Step 2: Create the service account**

```yaml
# apps/mission-control/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mission-control
  namespace: mission-control
  labels:
    app.kubernetes.io/name: mission-control
```

**Step 3: Commit**

```bash
git add apps/mission-control/namespace.yaml apps/mission-control/serviceaccount.yaml
git commit -m "feat(mission-control): add namespace and service account"
```

---

### Task 2: Create ExternalSecret for Doppler secrets

**Files:**
- Create: `apps/mission-control/externalsecret.yaml`

**Step 1: Create the ExternalSecret**

This pulls secrets from Doppler via the existing `doppler-cluster-secret-store`. The Doppler keys are already configured.

```yaml
# apps/mission-control/externalsecret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: mission-control-secret
  namespace: mission-control
spec:
  refreshInterval: "1h"
  secretStoreRef:
    kind: ClusterSecretStore
    name: doppler-cluster-secret-store
  target:
    name: mission-control-secret
  data:
    - secretKey: postgres_user
      remoteRef:
        key: MC_POSTGRES_USER
    - secretKey: postgres_password
      remoteRef:
        key: MC_POSTGRES_PASSWORD
    - secretKey: clerk_secret_key
      remoteRef:
        key: MC_CLERK_SECRET_KEY
    - secretKey: clerk_publishable_key
      remoteRef:
        key: MC_CLERK_PUBLISHABLE_KEY
    - secretKey: local_auth_token
      remoteRef:
        key: MC_LOCAL_AUTH_TOKEN
```

**Step 2: Commit**

```bash
git add apps/mission-control/externalsecret.yaml
git commit -m "feat(mission-control): add ExternalSecret for Doppler integration"
```

---

### Task 3: Create ConfigMap for non-secret environment variables

**Files:**
- Create: `apps/mission-control/configmap.yaml`

**Step 1: Create the ConfigMap**

```yaml
# apps/mission-control/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mission-control-config
  namespace: mission-control
data:
  ENVIRONMENT: "production"
  LOG_LEVEL: "INFO"
  LOG_FORMAT: "json"
  LOG_USE_UTC: "true"
  AUTH_MODE: "clerk"
  DB_AUTO_MIGRATE: "true"
  POSTGRES_DB: "mission_control"
  CORS_ORIGINS: "https://mission-control.hoytlabs.app"
  RQ_QUEUE_NAME: "default"
  RQ_DISPATCH_THROTTLE_SECONDS: "15.0"
  RQ_DISPATCH_MAX_RETRIES: "3"
```

**Step 2: Commit**

```bash
git add apps/mission-control/configmap.yaml
git commit -m "feat(mission-control): add ConfigMap for environment variables"
```

---

### Task 4: Create PostgreSQL deployment, service, and PVC

**Files:**
- Create: `apps/mission-control/pvc.yaml`
- Create: `apps/mission-control/postgres-deployment.yaml`
- Create: `apps/mission-control/postgres-svc.yaml`

**Step 1: Create PVC using OpenEBS hostpath**

```yaml
# apps/mission-control/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mission-control-postgres-pvc
  namespace: mission-control
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: openebs-hostpath
  resources:
    requests:
      storage: 10Gi
```

**Step 2: Create Postgres deployment**

```yaml
# apps/mission-control/postgres-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mission-control-postgres
  namespace: mission-control
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: mission-control-postgres
  template:
    metadata:
      labels:
        app: mission-control-postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              valueFrom:
                configMapKeyRef:
                  name: mission-control-config
                  key: POSTGRES_DB
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: mission-control-secret
                  key: postgres_user
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mission-control-secret
                  key: postgres_password
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command:
                - pg_isready
                - -U
                - $(POSTGRES_USER)
                - -d
                - $(POSTGRES_DB)
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 5
          livenessProbe:
            exec:
              command:
                - pg_isready
                - -U
                - $(POSTGRES_USER)
                - -d
                - $(POSTGRES_DB)
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 5
      volumes:
        - name: postgres-data
          persistentVolumeClaim:
            claimName: mission-control-postgres-pvc
```

**Step 3: Create Postgres service**

```yaml
# apps/mission-control/postgres-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: mission-control-postgres
  namespace: mission-control
spec:
  selector:
    app: mission-control-postgres
  ports:
    - port: 5432
      targetPort: 5432
```

**Step 4: Commit**

```bash
git add apps/mission-control/pvc.yaml apps/mission-control/postgres-deployment.yaml apps/mission-control/postgres-svc.yaml
git commit -m "feat(mission-control): add PostgreSQL deployment with OpenEBS storage"
```

---

### Task 5: Create Redis deployment and service

**Files:**
- Create: `apps/mission-control/redis-deployment.yaml`
- Create: `apps/mission-control/redis-svc.yaml`

**Step 1: Create Redis deployment**

```yaml
# apps/mission-control/redis-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mission-control-redis
  namespace: mission-control
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mission-control-redis
  template:
    metadata:
      labels:
        app: mission-control-redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports:
            - containerPort: 6379
          readinessProbe:
            exec:
              command:
                - redis-cli
                - ping
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 5
          livenessProbe:
            exec:
              command:
                - redis-cli
                - ping
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 5
```

**Step 2: Create Redis service**

```yaml
# apps/mission-control/redis-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: mission-control-redis
  namespace: mission-control
spec:
  selector:
    app: mission-control-redis
  ports:
    - port: 6379
      targetPort: 6379
```

**Step 3: Commit**

```bash
git add apps/mission-control/redis-deployment.yaml apps/mission-control/redis-svc.yaml
git commit -m "feat(mission-control): add Redis deployment and service"
```

---

### Task 6: Create backend deployment and service

**Files:**
- Create: `apps/mission-control/backend-deployment.yaml`
- Create: `apps/mission-control/backend-svc.yaml`

**Step 1: Create backend deployment**

The backend needs DATABASE_URL composed from secret refs, plus config and secret env vars.

```yaml
# apps/mission-control/backend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mission-control-backend
  namespace: mission-control
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
  selector:
    matchLabels:
      app: mission-control-backend
  template:
    metadata:
      labels:
        app: mission-control-backend
    spec:
      serviceAccountName: mission-control
      containers:
        - name: backend
          image: ghcr.io/drewpayment/openclaw-mission-control-backend:latest
          ports:
            - name: http
              containerPort: 8000
              protocol: TCP
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: mission-control-secret
                  key: postgres_user
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mission-control-secret
                  key: postgres_password
            - name: DATABASE_URL
              value: "postgresql+psycopg://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@mission-control-postgres:5432/mission_control"
            - name: RQ_REDIS_URL
              value: "redis://mission-control-redis:6379/0"
            - name: CLERK_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: mission-control-secret
                  key: clerk_secret_key
            - name: LOCAL_AUTH_TOKEN
              valueFrom:
                secretKeyRef:
                  name: mission-control-secret
                  key: local_auth_token
          envFrom:
            - configMapRef:
                name: mission-control-config
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
```

**Step 2: Create backend service**

```yaml
# apps/mission-control/backend-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: mission-control-backend
  namespace: mission-control
spec:
  selector:
    app: mission-control-backend
  ports:
    - port: 8000
      targetPort: 8000
      name: http
```

**Step 3: Commit**

```bash
git add apps/mission-control/backend-deployment.yaml apps/mission-control/backend-svc.yaml
git commit -m "feat(mission-control): add backend API deployment and service"
```

---

### Task 7: Create webhook worker deployment

**Files:**
- Create: `apps/mission-control/worker-deployment.yaml`

**Step 1: Create worker deployment**

Uses the same backend image but overrides the command to run the RQ worker.

```yaml
# apps/mission-control/worker-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mission-control-worker
  namespace: mission-control
spec:
  replicas: 1
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: mission-control-worker
  template:
    metadata:
      labels:
        app: mission-control-worker
    spec:
      serviceAccountName: mission-control
      containers:
        - name: worker
          image: ghcr.io/drewpayment/openclaw-mission-control-backend:latest
          command: ["python", "scripts/rq-docker", "worker"]
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: mission-control-secret
                  key: postgres_user
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mission-control-secret
                  key: postgres_password
            - name: DATABASE_URL
              value: "postgresql+psycopg://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@mission-control-postgres:5432/mission_control"
            - name: RQ_REDIS_URL
              value: "redis://mission-control-redis:6379/0"
            - name: CLERK_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: mission-control-secret
                  key: clerk_secret_key
            - name: LOCAL_AUTH_TOKEN
              valueFrom:
                secretKeyRef:
                  name: mission-control-secret
                  key: local_auth_token
          envFrom:
            - configMapRef:
                name: mission-control-config
```

**Step 2: Commit**

```bash
git add apps/mission-control/worker-deployment.yaml
git commit -m "feat(mission-control): add webhook worker deployment"
```

---

### Task 8: Create frontend deployment and service

**Files:**
- Create: `apps/mission-control/frontend-deployment.yaml`
- Create: `apps/mission-control/frontend-svc.yaml`

**Step 1: Create frontend deployment**

Note: `NEXT_PUBLIC_API_URL` and `NEXT_PUBLIC_AUTH_MODE` are baked at image build time. The GHCR image must be built with these args. At runtime we also set them as env vars for SSR.

```yaml
# apps/mission-control/frontend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mission-control-frontend
  namespace: mission-control
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
  selector:
    matchLabels:
      app: mission-control-frontend
  template:
    metadata:
      labels:
        app: mission-control-frontend
    spec:
      serviceAccountName: mission-control
      containers:
        - name: frontend
          image: ghcr.io/drewpayment/openclaw-mission-control-frontend:latest
          ports:
            - name: http
              containerPort: 3000
              protocol: TCP
          env:
            - name: NEXT_PUBLIC_API_URL
              value: "https://mission-control-api.hoytlabs.app"
            - name: NEXT_PUBLIC_AUTH_MODE
              value: "clerk"
            - name: NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY
              valueFrom:
                secretKeyRef:
                  name: mission-control-secret
                  key: clerk_publishable_key
          livenessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
```

**Step 2: Create frontend service**

```yaml
# apps/mission-control/frontend-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: mission-control-frontend
  namespace: mission-control
spec:
  selector:
    app: mission-control-frontend
  ports:
    - port: 3000
      targetPort: 3000
      name: http
```

**Step 3: Commit**

```bash
git add apps/mission-control/frontend-deployment.yaml apps/mission-control/frontend-svc.yaml
git commit -m "feat(mission-control): add frontend deployment and service"
```

---

### Task 9: Create HTTPRoutes for external access

**Files:**
- Create: `apps/mission-control/http-route.yaml`
- Create: `apps/mission-control/backend-http-route.yaml`

**Step 1: Create frontend HTTPRoute**

```yaml
# apps/mission-control/http-route.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mission-control-http-route
  namespace: mission-control
  annotations:
    external-dns.alpha.kubernetes.io/hostname: mission-control.hoytlabs.app
spec:
  parentRefs:
    - name: gateway-external
      namespace: gateway
  hostnames:
    - "mission-control.hoytlabs.app"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: mission-control-frontend
          port: 3000
          weight: 1
```

**Step 2: Create backend API HTTPRoute**

```yaml
# apps/mission-control/backend-http-route.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mission-control-api-http-route
  namespace: mission-control
  annotations:
    external-dns.alpha.kubernetes.io/hostname: mission-control-api.hoytlabs.app
spec:
  parentRefs:
    - name: gateway-external
      namespace: gateway
  hostnames:
    - "mission-control-api.hoytlabs.app"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: mission-control-backend
          port: 8000
          weight: 1
```

**Step 3: Commit**

```bash
git add apps/mission-control/http-route.yaml apps/mission-control/backend-http-route.yaml
git commit -m "feat(mission-control): add HTTPRoutes for frontend and API"
```

---

### Task 10: Create Kustomization and verify

**Files:**
- Create: `apps/mission-control/kustomization.yaml`

**Step 1: Create the Kustomization**

```yaml
# apps/mission-control/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - serviceaccount.yaml
  - configmap.yaml
  - externalsecret.yaml
  - pvc.yaml
  - postgres-deployment.yaml
  - postgres-svc.yaml
  - redis-deployment.yaml
  - redis-svc.yaml
  - backend-deployment.yaml
  - backend-svc.yaml
  - worker-deployment.yaml
  - frontend-deployment.yaml
  - frontend-svc.yaml
  - http-route.yaml
  - backend-http-route.yaml
```

**Step 2: Validate the kustomize build**

Run: `kubectl kustomize apps/mission-control/`
Expected: All manifests rendered without errors.

**Step 3: Commit**

```bash
git add apps/mission-control/kustomization.yaml
git commit -m "feat(mission-control): add Kustomization to complete deployment manifests"
```

---

### Task 11: Create CI workflow for GHCR image builds (openclaw-mission-control repo)

**Files:**
- Create: `.github/workflows/docker-publish.yml` (in the openclaw-mission-control repo at `/Users/drew.payment/dev/openclaw-mission-control/`)

**Step 1: Create the GitHub Actions workflow**

This builds and pushes both frontend and backend images to GHCR on push to `main` or on tag.

```yaml
# .github/workflows/docker-publish.yml
name: Build and Push Docker Images

on:
  push:
    branches: [main]
    tags: ["v*"]

env:
  REGISTRY: ghcr.io
  BACKEND_IMAGE: ghcr.io/${{ github.repository }}-backend
  FRONTEND_IMAGE: ghcr.io/${{ github.repository }}-frontend

jobs:
  build-backend:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/metadata-action@v5
        id: meta
        with:
          images: ${{ env.BACKEND_IMAGE }}
          tags: |
            type=sha
            type=ref,event=branch
            type=semver,pattern={{version}}
            type=raw,value=latest,enable={{is_default_branch}}
      - uses: docker/build-push-action@v5
        with:
          context: .
          file: backend/Dockerfile
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}

  build-frontend:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/metadata-action@v5
        id: meta
        with:
          images: ${{ env.FRONTEND_IMAGE }}
          tags: |
            type=sha
            type=ref,event=branch
            type=semver,pattern={{version}}
            type=raw,value=latest,enable={{is_default_branch}}
      - uses: docker/build-push-action@v5
        with:
          context: ./frontend
          file: frontend/Dockerfile
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          build-args: |
            NEXT_PUBLIC_API_URL=https://mission-control-api.hoytlabs.app
            NEXT_PUBLIC_AUTH_MODE=clerk
```

**Step 2: Commit (in openclaw-mission-control repo)**

```bash
git add .github/workflows/docker-publish.yml
git commit -m "ci: add GitHub Actions workflow to build and push Docker images to GHCR"
```

---

## Execution Order

Tasks 1-10 are in `hoytlabs-talos` repo.
Task 11 is in `openclaw-mission-control` repo.

Tasks 1-9 can be done in parallel (no dependencies between manifests). Task 10 depends on all files existing. Task 11 is independent and can be done in parallel with everything else.

## Post-Deployment Checklist

After pushing to `main` in hoytlabs-talos:
1. ArgoCD auto-syncs the new `mission-control` application
2. Verify ExternalSecret syncs (Doppler → K8s secret)
3. Verify Postgres PVC binds via OpenEBS
4. Verify backend health endpoints respond
5. Verify frontend loads at `https://mission-control.hoytlabs.app`
6. Verify API accessible at `https://mission-control-api.hoytlabs.app`
