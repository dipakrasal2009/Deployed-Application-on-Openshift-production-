# DevOps Health Check — OpenShift Deployment

A full-stack application (Nginx frontend + Go backend API + PostgreSQL database) deployed on an OpenShift cluster, split across three isolated namespaces. This document explains everything created for this deployment, why each piece exists, the issues hit along the way, and how to verify it's actually working end to end.

---

## 1. Architecture

```
                 Internet
                     │
                     ▼
        ┌─────────────────────────┐
        │   OpenShift Route        │  frontend-frontend.apps.<cluster>
        │   (namespace: frontend)  │
        └────────────┬─────────────┘
                     │
                     ▼
        ┌─────────────────────────┐
        │   Nginx (static UI)      │  Service: frontend:80
        │   + /api/ reverse proxy  │
        └────────────┬─────────────┘
                     │  proxy_pass /api/ → backend Service (internal, ClusterIP)
                     ▼
        ┌─────────────────────────┐
        │   Go Backend API         │  Service: backend.backend.svc.cluster.local:8080
        │   (namespace: backend)   │
        └────────────┬─────────────┘
                     │  DB_HOST=postgres.database.svc.cluster.local
                     ▼
        ┌─────────────────────────┐
        │   PostgreSQL 15          │  Service: postgres.database.svc.cluster.local:5432
        │   (namespace: database)  │  Backed by a PersistentVolumeClaim
        └─────────────────────────┘
```

**Why three separate namespaces instead of one?**
This mirrors how real production clusters are organized — each tier gets its own namespace so you can apply different RBAC, quotas, and NetworkPolicies per tier. It also forces you to think properly about cross-namespace service discovery (`<service>.<namespace>.svc.cluster.local`), which is the whole point of practicing this on OpenShift rather than a single flat namespace.

**Why does only the database have no Route?**
The database should never be reachable from outside the cluster. Only the frontend and backend get Routes (external HTTP entry points); Postgres only gets a ClusterIP Service, reachable exclusively from inside the cluster.

---

## 2. Namespaces

| File | What it does |
|---|---|
| `frontend-namespace.yaml` | Creates the `frontend` namespace |
| `backend-namespace.yaml` | Creates the `backend` namespace |
| `database-namespace.yaml` | Creates the `database` namespace |

Each is a minimal `Namespace` object — nothing more than a name. They exist purely to give each tier its own isolated Kubernetes "folder" for RBAC, quotas, and network policy boundaries.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: database
```

---

## 3. Database tier (`namespace: database`)

### `postgres-secret.yaml`
Stores the DB credentials (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`) as a Kubernetes `Secret` instead of hardcoding them into the Deployment. Secrets are namespace-scoped, so this copy lives in `database` for the Postgres container to consume.

> ⚠️ Credentials here are `admin` / `admin123` — fine for a learning deployment, not something to carry into anything real.

### `postgres-pvc.yaml`
A `PersistentVolumeClaim` requesting 2Gi of `ReadWriteOnce` storage. Without this, Postgres would store its data in the container's writable layer, and **all data would vanish** every time the pod restarts or reschedules. The PVC gives Postgres a stable, cluster-provisioned disk that survives pod restarts.

### `postgres-deployment.yaml`
Runs `postgres:15` (deliberately **not** `postgres:latest` — see issue #2 below), pulling credentials from `postgres-secret` via `secretKeyRef` instead of plaintext env vars. Mounts the PVC at `/var/lib/postgresql/data`, with `PGDATA` pointed at a **subdirectory** (`/var/lib/postgresql/data/pgdata`) rather than the mount root — see issue #2 for why that matters.

### `postgres-service.yaml`
A `ClusterIP` Service exposing Postgres internally on port `5432`. This is what gives Postgres its stable internal DNS name: `postgres.database.svc.cluster.local`. Backend pods never talk to the Postgres pod's IP directly (pod IPs change on every restart) — they always go through this Service name.

---

## 4. Backend tier (`namespace: backend`)

### `backend-secret.yaml`
A **second copy** of the DB credentials, this time in the `backend` namespace. This isn't a mistake — Kubernetes Secrets cannot be referenced across namespaces, so if the backend Deployment needs `secretKeyRef` access to DB credentials, a copy has to physically exist in `backend` too.

> ⚠️ **Trade-off to be aware of:** because it's a duplicate, if you ever rotate the password you must update **both** copies (`database` and `backend`) or the backend will fail to authenticate. A more robust setup would use external-secrets tooling to keep them in sync automatically — out of scope for this learning deployment, but worth knowing.

### `backend-deployment.yaml`
Runs the Go API (`devops-healthcheck-app:latest`) on port `8080`. Key environment variables:
- `DB_HOST=postgres.database.svc.cluster.local` — cross-namespace DNS name pointing at the Postgres Service
- `DB_PORT=5432`
- `DB_USER` / `DB_PASSWORD` / `DB_NAME` — pulled from `postgres-secret` (the local copy in `backend`) via `secretKeyRef`

### `backend-service.yaml`
`ClusterIP` Service exposing the backend internally on port `8080`, giving it the stable name `backend.backend.svc.cluster.local` — this is what the frontend's Nginx reverse proxy targets.

### `backend-route.yaml`
An OpenShift `Route` exposing the backend externally (useful for direct API testing with `curl`, independent of the frontend).

### `backend-networkpolicy.yaml`
Restricts inbound traffic to backend pods so that **only pods in the `frontend` namespace** can reach it on port `8080`. Without this, OpenShift's default networking (OVN-Kubernetes) allows all namespaces to talk to each other freely — this policy is what actually enforces the "only frontend should call backend" architecture at the network layer, not just by convention.

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: frontend
    ports:
      - protocol: TCP
        port: 8080
```

---

## 5. Frontend tier (`namespace: frontend`)

This is the tier that caused the most trouble, so it has the most moving parts. The original `dipakrasal2009/devops-healthcheck-ui` image ships with two files baked in at build time:

- `nginx.conf` — serves the static `index.html`, **no reverse proxy configured**
- `ui.html` (served as `index.html`) — its JavaScript builds the backend URL as:
  ```js
  const API = 'http://' + window.location.hostname + ':8080';
  ```

That hardcoded `:8080` is the root cause of "frontend not connecting to backend." On OpenShift, Routes only ever expose ports 80/443 — you can never reach `:8080` on a Route's hostname, and the frontend Route's hostname is a completely different hostname from the backend Route's anyway. So the browser was calling a URL that could never resolve.

**Fix approach:** rather than rebuilding and re-pushing the Docker image, both files are overridden at deploy time using ConfigMaps mounted over the baked-in files. No image rebuild needed.

### `frontend-nginx-configmap.yaml`
A `ConfigMap` holding a replacement `default.conf` for Nginx:
```nginx
location / {
    try_files $uri $uri/ /index.html;
}

location /api/ {
    proxy_pass http://backend.backend.svc.cluster.local:8080/;
    ...
}
```
Any request to `/api/...` from the browser is forwarded server-side (inside the cluster) to the backend Service. Because `proxy_pass` ends in `/`, Nginx **strips the `/api/` prefix** before forwarding — which matters because the Go backend's actual routes have no `/api` prefix at all (`/services`, `/healthcheck`, `/runall`).

### `frontend-ui-configmap.yaml`
A `ConfigMap` holding a patched copy of `ui.html`, with the one meaningful change:
```js
const API = '/api';   // was: 'http://' + window.location.hostname + ':8080'
```
Now the browser calls a **relative, same-origin** path. The browser never needs to know the backend's internal address at all — Nginx handles that server-side.

### `frontend-deployment.yaml`
Runs the Nginx image, but mounts both ConfigMaps over the files baked into the image using `subPath`:
```yaml
volumeMounts:
  - name: nginx-conf
    mountPath: /etc/nginx/conf.d/default.conf
    subPath: default.conf
  - name: ui-html
    mountPath: /usr/share/nginx/html/index.html
    subPath: index.html
```

### `frontend-service.yaml`
`ClusterIP` Service exposing Nginx internally on port `80`.

### `frontend-route.yaml`
The external entry point for the whole application — this is the URL you actually open in a browser.

---

## 6. Issues faced during deployment (and the actual fix for each)

| # | Symptom | Root Cause | Fix |
|---|---|---|---|
| 1 | Frontend pod `CrashLoopBackOff`, exit code 1, no readable logs at first | Plain `nginx:alpine` image needs to run as root to create `/var/cache/nginx/*` and bind port 80. OpenShift's default `restricted-v2` SCC forces containers to run as an arbitrary non-root UID, so Nginx can't create its own working directories and dies immediately | `oc adm policy add-scc-to-user anyuid -z default -n frontend`, then restart the deployment. **This SCC grant is namespace-scoped and does not persist across cluster/namespace re-creation** — you'll need to run it again on a fresh cluster. |
| 2 | PostgreSQL `CrashLoopBackOff` | Two separate causes: (a) `postgres:latest` resolved to PostgreSQL 18, which had compatibility issues with the setup; (b) mounting the PVC directly at Postgres's data directory caused a stray `lost+found` folder (created by the filesystem) to make Postgres refuse to start, since it expects an empty or valid data directory | Pinned the image to `postgres:15`; set `PGDATA=/var/lib/postgresql/data/pgdata` so Postgres writes into a clean subdirectory instead of the PVC mount root; deleted and recreated the PVC and Deployment from scratch |
| 3 | Backend `CrashLoopBackOff` | Backend started before Postgres was ready to accept connections | Restarted the backend Deployment once Postgres was confirmed healthy (`oc rollout restart deployment/backend -n backend`) |
| 4 | Frontend running, but showed no data / API calls failing | Frontend JavaScript hardcoded `http://<hostname>:8080` as the backend URL — this can never work through an OpenShift Route, which only exposes 80/443, and the frontend/backend Routes have different hostnames entirely | Overrode the baked-in `ui.html` and `nginx.conf` via ConfigMaps: frontend now calls a relative `/api/...` path, and Nginx reverse-proxies that to the backend Service internally |

---

## 7. Deployment order

Namespaces first, then each tier bottom-up (database → backend → frontend), so that DNS names each tier depends on already exist when the next tier starts:

```bash
# 1. Namespaces
oc apply -f database-namespace.yaml
oc apply -f backend-namespace.yaml
oc apply -f frontend-namespace.yaml

# 2. Database tier
oc apply -f postgres-secret.yaml
oc apply -f postgres-pvc.yaml
oc apply -f postgres-deployment.yaml
oc apply -f postgres-service.yaml

# 3. Backend tier
oc apply -f backend-secret.yaml
oc apply -f backend-deployment.yaml
oc apply -f backend-service.yaml
oc apply -f backend-route.yaml

# 4. Frontend tier
oc apply -f frontend-nginx-configmap.yaml
oc apply -f frontend-ui-configmap.yaml
oc apply -f frontend-deployment.yaml
oc apply -f frontend-service.yaml
oc apply -f frontend-route.yaml

# 5. Required SCC grant (Nginx needs to run as root-equivalent under restricted-v2)
oc adm policy add-scc-to-user anyuid -z default -n frontend
oc rollout restart deployment/frontend -n frontend

# 6. NetworkPolicies (lock down cross-namespace traffic to only what's needed)
oc apply -f backend-networkpolicy.yaml
oc apply -f database-networkpolicy.yaml
```

---

## 8. Verifying the deployment

### Check everything is running
```bash
oc get all -n database
oc get all -n backend
oc get all -n frontend
```
Every pod should show `1/1 Running` with a low restart count once things settle.

### Check pod logs if something's wrong
```bash
oc logs deployment/frontend -n frontend
oc logs deployment/backend -n backend
oc logs deployment/postgres -n database

# If a pod is crash-looping, get the logs from the PREVIOUS (crashed) attempt:
oc logs <pod-name> -n frontend --previous
```

### Test the backend API directly (bypassing the frontend)
```bash
oc get route -n backend
curl http://<backend-route-host>/services
curl http://<backend-route-host>/runall -X POST
```

### Confirm the frontend's reverse proxy and JS fix actually took effect
```bash
oc exec -it deployment/frontend -n frontend -- cat /etc/nginx/conf.d/default.conf
oc exec -it deployment/frontend -n frontend -- grep "const API" /usr/share/nginx/html/index.html
```
You should see the `/api/` `proxy_pass` block, and `const API = '/api';`.

---

## 9. Database testing commands

### Get the Postgres pod name
```bash
oc get pods -n database
```

### Open a shell inside the pod
```bash
oc exec -it <postgres-pod-name> -n database -- bash
# or, if bash isn't available:
oc exec -it <postgres-pod-name> -n database -- sh
```

### Connect with psql
```bash
psql -U admin -d healthcheck
# If prompted for a password, it's: admin123

# Or skip the prompt:
export PGPASSWORD=admin123
psql -U admin -d healthcheck
```

### Useful psql commands once connected
```sql
\l              -- list all databases
\c healthcheck  -- connect to the healthcheck database
\dt             -- list all tables
\d services     -- describe the "services" table
SELECT * FROM services;   -- view all rows
\q              -- quit psql
```

### One-liners (no interactive shell needed)
```bash
# List tables
oc exec -it <postgres-pod-name> -n database -- \
  psql -U admin -d healthcheck -c "\dt"

# List databases
oc exec -it <postgres-pod-name> -n database -- \
  psql -U admin -d postgres -c "\l"

# View all rows in the services table
oc exec -it <postgres-pod-name> -n database -- \
  psql -U admin -d healthcheck -c "SELECT * FROM services;"
```

### End-to-end write-path test
This confirms the whole chain (browser → frontend → backend → Postgres) actually works, not just that pages load:
1. Add a service through the frontend UI
2. Then check it landed in the database:
   ```bash
   oc exec -it <postgres-pod-name> -n database -- \
     psql -U admin -d healthcheck -c "SELECT * FROM services ORDER BY id DESC LIMIT 1;"
   ```

---

## 10. Lessons learned

- **OpenShift's default SCC (`restricted-v2`) blocks containers that expect to run as root** (e.g. stock `nginx:alpine`). Either grant `anyuid` to the namespace's service account, or use an image built to run as a non-root user on an unprivileged port.
- **Avoid `:latest` tags for stateful services** like Postgres — an untested major version bump (14→18 in this case) can silently break things. Pin to a specific version.
- **Point `PGDATA` at a subdirectory of the PVC mount**, not the mount root — filesystem artifacts like `lost+found` in the raw mount can prevent Postgres from starting.
- **Browsers cannot resolve `*.svc.cluster.local`** — that DNS only exists inside the cluster's network. Any URL the browser calls directly must be either a public Route hostname or a relative path proxied server-side.
- **Kubernetes Secrets are namespace-scoped** — if two tiers in different namespaces both need the same credentials, the Secret has to be duplicated into both, and kept in sync manually (or via external tooling).
- **NetworkPolicies are opt-in and additive** — OpenShift allows all cross-namespace traffic by default. Adding a NetworkPolicy that selects a pod switches that pod to "deny unless explicitly allowed," so any NetworkPolicy you add must include every legitimate source of traffic (including DNS, if you ever add egress-restricting policies).
