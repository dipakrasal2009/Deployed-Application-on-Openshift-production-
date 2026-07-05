# Inspecting the Deployed Infrastructure — `oc` Command Reference

This document is a complete set of `oc` commands to inspect **everything** created by the manifests in this deployment — namespaces, workloads, networking, storage, secrets/config, security context constraints, and events — across all three namespaces (`frontend`, `backend`, `database`).

Run these *after* applying the manifests to confirm what actually landed on the cluster.

---

## 1. Quick full overview (all three namespaces at once)

```bash
oc get all -n frontend
oc get all -n backend
oc get all -n database
```

`get all` shows Pods, Deployments, ReplicaSets, Services, and Routes for a namespace in one shot — this is the fastest first check.

### See all three at once, resource-type by resource-type
```bash
oc get pods,deploy,svc,route -n frontend -n backend -n database
# Note: oc doesn't support multiple -n flags in one call reliably;
# if that errors, loop instead:
for ns in frontend backend database; do
  echo "== $ns =="
  oc get pods,deploy,svc,route -n $ns
done
```

### Every namespace this project created, at a glance
```bash
oc get namespaces frontend backend database
```

---

## 2. Pods — the actual running containers

```bash
oc get pods -n frontend
oc get pods -n backend
oc get pods -n database
```

### Wider output (shows node placement, IP, restarts clearly)
```bash
oc get pods -n frontend -o wide
```

### Watch pods live as they come up / restart
```bash
oc get pods -n frontend -w
```

### Full details of a specific pod (events, mounts, env, security context — most useful single command for debugging)
```bash
oc describe pod <pod-name> -n <namespace>
```

### Logs from a pod
```bash
oc logs <pod-name> -n <namespace>

# Logs from a crashed container's PREVIOUS run (essential for CrashLoopBackOff)
oc logs <pod-name> -n <namespace> --previous

# Follow logs live
oc logs -f <pod-name> -n <namespace>

# Logs by deployment name instead of exact pod name
oc logs deployment/frontend -n frontend
```

### Get a shell inside a running pod
```bash
oc exec -it <pod-name> -n <namespace> -- bash
# or
oc exec -it <pod-name> -n <namespace> -- sh
```

---

## 3. Deployments and ReplicaSets

```bash
oc get deployments -n frontend
oc get deployments -n backend
oc get deployments -n database
```

### Full spec + status + rollout history of a Deployment
```bash
oc describe deployment frontend -n frontend
oc describe deployment backend -n backend
oc describe deployment postgres -n database
```

### ReplicaSets (shows old vs current, useful after a rollout)
```bash
oc get rs -n frontend
```

### Rollout status / history
```bash
oc rollout status deployment/frontend -n frontend
oc rollout history deployment/frontend -n frontend
```

---

## 4. Services (internal cluster networking)

```bash
oc get svc -n frontend
oc get svc -n backend
oc get svc -n database
```

### Full details — confirms selector labels match pod labels, and port mappings
```bash
oc describe svc frontend -n frontend
oc describe svc backend -n backend
oc describe svc postgres -n database
```

### Confirm the internal DNS names actually resolve (run from inside any pod)
```bash
oc exec -it <backend-pod-name> -n backend -- nslookup postgres.database.svc.cluster.local
oc exec -it <frontend-pod-name> -n frontend -- nslookup backend.backend.svc.cluster.local
```

---

## 5. Routes (external entry points)

```bash
oc get routes -n frontend
oc get routes -n backend
```

### Full route details (hostname, TLS termination, target service/port)
```bash
oc describe route frontend -n frontend
oc describe route backend -n backend
```

### Just print the external hostnames (handy for copy-pasting into curl/browser)
```bash
oc get route frontend -n frontend -o jsonpath='{.spec.host}{"\n"}'
oc get route backend -n backend -o jsonpath='{.spec.host}{"\n"}'
```

---

## 6. Secrets

```bash
oc get secrets -n database
oc get secrets -n backend
```

### Describe a secret (shows keys, NOT values, by design)
```bash
oc describe secret postgres-secret -n database
```

### Decode an actual value (only when you deliberately need to verify it)
```bash
oc get secret postgres-secret -n database -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
```

---

## 7. ConfigMaps (frontend Nginx config + patched UI)

```bash
oc get configmaps -n frontend
```

### Confirm the ConfigMap actually contains what you expect
```bash
oc describe configmap frontend-nginx-conf -n frontend
oc describe configmap frontend-ui-html -n frontend

# Print the full contents
oc get configmap frontend-nginx-conf -n frontend -o yaml
```

### Confirm the ConfigMap is actually mounted correctly inside the running pod
```bash
oc exec -it deployment/frontend -n frontend -- cat /etc/nginx/conf.d/default.conf
oc exec -it deployment/frontend -n frontend -- grep "const API" /usr/share/nginx/html/index.html
```

---

## 8. PersistentVolumeClaims and PersistentVolumes (Postgres storage)

```bash
oc get pvc -n database
oc describe pvc postgres-pvc -n database
```

### See the underlying PersistentVolume it's bound to (cluster-scoped, no namespace)
```bash
oc get pv
oc describe pv <pv-name-shown-in-pvc-output>
```

### Confirm the volume is actually mounted in the Postgres pod, and check disk usage
```bash
oc exec -it <postgres-pod-name> -n database -- df -h /var/lib/postgresql/data
```

---

## 9. NetworkPolicies

```bash
oc get networkpolicy -n backend
oc get networkpolicy -n database
```

### Full policy details (confirms selector + allowed sources/ports)
```bash
oc describe networkpolicy allow-frontend-to-backend -n backend
oc describe networkpolicy allow-backend-to-postgres -n database
```

### Confirm namespace labels the policies rely on actually exist
```bash
oc get namespace frontend --show-labels
oc get namespace backend --show-labels
```
(Look for `kubernetes.io/metadata.name=frontend` etc. — this is what the NetworkPolicy `namespaceSelector` matches against.)

---

## 10. SecurityContextConstraints (the `anyuid` grant for frontend)

```bash
# Confirm the frontend namespace's default service account has anyuid
oc get scc anyuid -o yaml

# See which SCC a running pod actually landed under
oc get pod <frontend-pod-name> -n frontend -o yaml | grep scc

# List all service accounts bound to the anyuid SCC
oc adm policy who-can use scc anyuid
```

---

## 11. Events (chronological log of everything the cluster did)

```bash
oc get events -n frontend --sort-by='.lastTimestamp'
oc get events -n backend --sort-by='.lastTimestamp'
oc get events -n database --sort-by='.lastTimestamp'
```
This shows scheduling, image pulls, container starts/crashes, and probe failures in time order — usually the fastest way to spot *when* something went wrong.

---

## 12. Resource usage (if metrics-server is enabled on the cluster)

```bash
oc adm top pods -n frontend
oc adm top pods -n backend
oc adm top pods -n database

oc adm top nodes
```

---

## 13. One command to dump literally everything

```bash
for ns in frontend backend database; do
  echo "############################"
  echo "# NAMESPACE: $ns"
  echo "############################"
  oc get all,configmap,secret,pvc,networkpolicy -n $ns
  echo
done
```

Useful as a single "give me the full current state" snapshot, e.g. to paste into a chat when asking for help debugging.

---

## 14. Export the actual running config back to YAML

Handy when you want to compare what's *actually running* on the cluster against your local manifest files (e.g. to check if someone `oc edit`-ed something by hand):

```bash
oc get deployment frontend -n frontend -o yaml
oc get svc backend -n backend -o yaml
oc get configmap frontend-nginx-conf -n frontend -o yaml
```
