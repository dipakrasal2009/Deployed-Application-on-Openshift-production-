#!/usr/bin/env bash
#
# destroy.sh — Tears down the DevOps Health Check full-stack app from OpenShift
#
# Usage:
#   ./destroy.sh                # prompts for confirmation, then deletes everything
#   ./destroy.sh --yes          # skip the confirmation prompt
#   ./destroy.sh --dry-run      # print what would be deleted, without deleting
#   ./destroy.sh --keep-data    # delete workloads/networking but KEEP the Postgres PVC
#                                 (so a redeploy doesn't lose existing data)
#
# Requires: oc CLI logged in to the target cluster.

set -euo pipefail

MANIFEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
SKIP_CONFIRM=false
KEEP_DATA=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y) SKIP_CONFIRM=true ;;
    --keep-data) KEEP_DATA=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ── Colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}==>${NC} $1"; }
ok()    { echo -e "${GREEN}✔${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "${RED}✘${NC} $1"; }

run() {
  local desc="$1"; shift
  if $DRY_RUN; then
    echo "  [dry-run] $*"
  else
    "$@" 2>/dev/null || warn "$desc (may already be gone — continuing)"
  fi
}

# ── Pre-flight ──────────────────────────────────────────────────────────
preflight() {
  if ! command -v oc >/dev/null 2>&1; then
    fail "'oc' CLI not found in PATH."
    exit 1
  fi
  if ! oc whoami >/dev/null 2>&1; then
    fail "Not logged in to an OpenShift cluster. Run 'oc login <cluster-url>' first."
    exit 1
  fi
  ok "Logged in as $(oc whoami) on $(oc whoami --show-server)"
}

confirm() {
  if $SKIP_CONFIRM || $DRY_RUN; then
    return
  fi
  echo
  warn "This will permanently delete the frontend, backend, and database namespaces"
  warn "(pods, services, routes, secrets, configmaps, network policies, and the"
  warn "Postgres PVC — meaning ALL DATABASE DATA — unless --keep-data is passed)."
  echo
  read -r -p "Type 'yes' to continue: " CONFIRMATION
  if [[ "$CONFIRMATION" != "yes" ]]; then
    echo "Aborted. Nothing was deleted."
    exit 0
  fi
}

# ── Teardown steps (reverse of deploy order) ─────────────────────────────
remove_network_policies() {
  log "Removing NetworkPolicies..."
  run "delete backend networkpolicy" oc delete networkpolicy allow-frontend-to-backend -n backend
  run "delete database networkpolicy" oc delete networkpolicy allow-backend-to-postgres -n database
  ok "NetworkPolicies removed"
}

remove_frontend() {
  log "Removing frontend tier..."
  run "delete frontend route" oc delete route frontend -n frontend
  run "delete frontend service" oc delete service frontend -n frontend
  run "delete frontend deployment" oc delete deployment frontend -n frontend
  run "delete frontend ui configmap" oc delete configmap frontend-ui-html -n frontend
  run "delete frontend nginx configmap" oc delete configmap frontend-nginx-conf -n frontend
  ok "Frontend tier removed"
}

remove_backend() {
  log "Removing backend tier..."
  run "delete backend route" oc delete route backend -n backend
  run "delete backend service" oc delete service backend -n backend
  run "delete backend deployment" oc delete deployment backend -n backend
  run "delete backend secret" oc delete secret postgres-secret -n backend
  ok "Backend tier removed"
}

remove_database() {
  log "Removing database tier..."
  run "delete postgres service" oc delete service postgres -n database
  run "delete postgres deployment" oc delete deployment postgres -n database

  if $KEEP_DATA; then
    warn "Skipping PVC deletion (--keep-data passed). Postgres data will persist"
    warn "and be reused if this app is redeployed into the same namespace."
  else
    run "delete postgres pvc" oc delete pvc postgres-pvc -n database
  fi

  run "delete postgres secret" oc delete secret postgres-secret -n database
  ok "Database tier removed"
}

remove_scc_grant() {
  log "Revoking 'anyuid' SCC grant from frontend's default service account..."
  run "remove scc-to-user anyuid" oc adm policy remove-scc-from-user anyuid -z default -n frontend
  ok "SCC grant revoked"
}

remove_namespaces() {
  log "Deleting namespaces (this cascades and removes anything left inside them)..."
  run "delete frontend namespace" oc delete namespace frontend
  run "delete backend namespace" oc delete namespace backend

  if $KEEP_DATA; then
    warn "Skipping 'database' namespace deletion (--keep-data passed),"
    warn "since deleting the namespace would delete the PVC (and its data) too."
    warn "Postgres deployment/service in 'database' were already removed above."
  else
    run "delete database namespace" oc delete namespace database
  fi

  ok "Namespaces deleted"
}

wait_for_namespace_cleanup() {
  if $DRY_RUN; then
    return
  fi
  log "Waiting for namespaces to fully terminate..."
  for ns in frontend backend; do
    while oc get namespace "$ns" >/dev/null 2>&1; do
      echo "  ...waiting for '$ns' to terminate"
      sleep 3
    done
  done
  if ! $KEEP_DATA; then
    while oc get namespace database >/dev/null 2>&1; do
      echo "  ...waiting for 'database' to terminate"
      sleep 3
    done
  fi
  ok "Namespace cleanup complete"
}

verify_gone() {
  log "Verifying teardown..."
  for ns in frontend backend database; do
    if oc get namespace "$ns" >/dev/null 2>&1; then
      warn "Namespace '$ns' still exists"
      oc get all -n "$ns" 2>/dev/null || true
    else
      ok "Namespace '$ns' is gone"
    fi
  done
}

# ── Main ─────────────────────────────────────────────────────────────────
main() {
  preflight
  confirm

  remove_network_policies
  remove_frontend
  remove_backend
  remove_database
  remove_scc_grant
  remove_namespaces
  wait_for_namespace_cleanup
  verify_gone

  echo
  ok "Destroy complete."
  if $KEEP_DATA; then
    warn "Postgres PVC + 'database' namespace were preserved as requested (--keep-data)."
  fi
}

main
