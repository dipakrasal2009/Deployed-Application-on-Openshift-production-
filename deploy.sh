#!/usr/bin/env bash
#
# deploy.sh — Deploys the DevOps Health Check full-stack app to OpenShift
#
# Usage:
#   ./deploy.sh                # deploy everything
#   ./deploy.sh --dry-run      # print what would be applied, without applying
#   ./deploy.sh --verify-only  # skip deploy, just run the post-deploy checks
#
# Requires: oc CLI logged in to the target cluster (`oc login ...`),
# and this script run from the directory containing the manifest YAML files.

set -euo pipefail

MANIFEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
VERIFY_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --verify-only) VERIFY_ONLY=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ── Colors for readable output ────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}==>${NC} $1"; }
ok()    { echo -e "${GREEN}✔${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "${RED}✘${NC} $1"; }

apply() {
  local file="$1"
  local path="${MANIFEST_DIR}/${file}"

  if [[ ! -f "$path" ]]; then
    fail "Missing manifest: $file (expected at $path)"
    exit 1
  fi

  if $DRY_RUN; then
    echo "  [dry-run] oc apply -f $file"
  else
    oc apply -f "$path"
  fi
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
  log "Checking oc CLI and cluster login..."
  if ! command -v oc >/dev/null 2>&1; then
    fail "'oc' CLI not found in PATH. Install the OpenShift CLI first."
    exit 1
  fi
  if ! oc whoami >/dev/null 2>&1; then
    fail "Not logged in to an OpenShift cluster. Run 'oc login <cluster-url>' first."
    exit 1
  fi
  ok "Logged in as $(oc whoami) on $(oc whoami --show-server)"
}

# ── Deployment steps ────────────────────────────────────────────────────────
deploy_namespaces() {
  log "Creating namespaces..."
  apply "database-namespace.yaml"
  apply "backend-namespace.yaml"
  apply "frontend-namespace.yaml"
  ok "Namespaces applied"
}

deploy_database() {
  log "Deploying database tier (namespace: database)..."
  apply "postgres-secret.yaml"
  apply "postgres-pvc.yaml"
  apply "postgres-deployment.yaml"
  apply "postgres-service.yaml"
  ok "Database tier applied"
}

deploy_backend() {
  log "Deploying backend tier (namespace: backend)..."
  apply "backend-secret.yaml"
  apply "backend-deployment.yaml"
  apply "backend-service.yaml"
  apply "backend-route.yaml"
  ok "Backend tier applied"
}

deploy_frontend() {
  log "Deploying frontend tier (namespace: frontend)..."
  apply "frontend-nginx-configmap.yaml"
  apply "frontend-ui-configmap.yaml"
  apply "frontend-deployment.yaml"
  apply "frontend-service.yaml"
  apply "frontend-route.yaml"
  ok "Frontend tier applied"
}

apply_scc() {
  log "Granting 'anyuid' SCC to frontend's default service account..."
  log "(Required because stock nginx:alpine needs root to bind port 80"
  log " and create its cache dirs — OpenShift's restricted-v2 SCC blocks this by default.)"
  if $DRY_RUN; then
    echo "  [dry-run] oc adm policy add-scc-to-user anyuid -z default -n frontend"
  else
    oc adm policy add-scc-to-user anyuid -z default -n frontend
  fi
  ok "SCC granted"
}

deploy_network_policies() {
  log "Applying NetworkPolicies..."
  apply "backend-networkpolicy.yaml"
  apply "database-networkpolicy.yaml"
  ok "NetworkPolicies applied"
}

restart_frontend() {
  log "Restarting frontend deployment to pick up the SCC change..."
  if $DRY_RUN; then
    echo "  [dry-run] oc rollout restart deployment/frontend -n frontend"
  else
    oc rollout restart deployment/frontend -n frontend
  fi
  ok "Frontend restart triggered"
}

wait_for_rollouts() {
  if $DRY_RUN; then
    warn "Skipping rollout wait in dry-run mode"
    return
  fi
  log "Waiting for rollouts to complete (timeout 120s each)..."
  oc rollout status deployment/postgres  -n database --timeout=120s || warn "postgres rollout did not complete in time"
  oc rollout status deployment/backend   -n backend  --timeout=120s || warn "backend rollout did not complete in time"
  oc rollout status deployment/frontend  -n frontend --timeout=120s || warn "frontend rollout did not complete in time"
}

# ── Post-deploy verification ─────────────────────────────────────────────
verify() {
  log "Verifying deployment..."

  echo
  echo "── Pods ──────────────────────────────────────────────"
  for ns in database backend frontend; do
    echo "[$ns]"
    oc get pods -n "$ns"
    echo
  done

  echo "── Routes ────────────────────────────────────────────"
  FRONTEND_HOST=$(oc get route frontend -n frontend -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  BACKEND_HOST=$(oc get route backend -n backend -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

  if [[ -n "$FRONTEND_HOST" ]]; then
    ok "Frontend URL: http://${FRONTEND_HOST}"
  else
    warn "Could not resolve frontend route host"
  fi

  if [[ -n "$BACKEND_HOST" ]]; then
    ok "Backend URL:  http://${BACKEND_HOST}"
  else
    warn "Could not resolve backend route host"
  fi

  echo
  echo "── Quick backend health check ───────────────────────"
  if [[ -n "$BACKEND_HOST" ]]; then
    if curl -sf --max-time 5 "http://${BACKEND_HOST}/services" >/dev/null; then
      ok "Backend API responded successfully at /services"
    else
      warn "Backend API did not respond at /services (it may still be starting up)"
    fi
  fi

  echo
  echo "── Frontend config sanity check ─────────────────────"
  FRONTEND_POD=$(oc get pods -n frontend -l app=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$FRONTEND_POD" ]]; then
    if oc exec "$FRONTEND_POD" -n frontend -- grep -q "const API = '/api'" /usr/share/nginx/html/index.html 2>/dev/null; then
      ok "Frontend is serving the patched index.html (relative /api path)"
    else
      warn "Frontend index.html does not contain the expected API patch — check the ConfigMap mount"
    fi
  else
    warn "No frontend pod found to inspect"
  fi

  echo
  log "Verification complete. If any pod isn't Running, check:"
  echo "    oc describe pod <pod-name> -n <namespace>"
  echo "    oc logs <pod-name> -n <namespace> --previous"
}

# ── Main ─────────────────────────────────────────────────────────────────
main() {
  preflight

  if ! $VERIFY_ONLY; then
    deploy_namespaces
    deploy_database
    deploy_backend
    deploy_frontend
    apply_scc
    restart_frontend
    deploy_network_policies
    wait_for_rollouts
  fi

  verify

  echo
  ok "Done."
}

main
