#!/usr/bin/env bash
#
# deploy-monitoring.sh — Deploy Prometheus + Grafana for CoreDNS observability.
#
# Deploys into the 'monitoring' namespace with:
#   - Prometheus: auto-discovers CoreDNS pods via Kubernetes SD, alerting rules
#   - Grafana: pre-configured datasource + dashboard, anonymous access enabled
#
# Reads configuration from config.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

KUBE_CONTEXT="kind-${CLUSTER_NAME}"

header "Monitoring Stack Deployment"

info "Configuration:"
echo "  Cluster:    ${CLUSTER_NAME}"
echo "  Context:    ${KUBE_CONTEXT}"
echo ""

# ── Check cluster is reachable ──────────────────────────────────────

if ! kubectl get nodes --context "$KUBE_CONTEXT" &>/dev/null; then
    error "Cannot reach cluster '${CLUSTER_NAME}'. Is it running? Try: make cluster-up"
fi

# ── Deploy Prometheus ────────────────────────────────────────────────

info "[1/3] Deploying Prometheus..."

kubectl apply --context "$KUBE_CONTEXT" \
    -f "${REPO_DIR}/monitoring/prometheus.yaml"

success "Prometheus resources applied."

# ── Create Grafana dashboard ConfigMap from JSON ─────────────────────

info "[2/3] Creating Grafana dashboard ConfigMap..."

kubectl create configmap grafana-dashboard-coredns \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring \
    --from-file=coredns-custom-dns.json="${REPO_DIR}/monitoring/grafana-dashboard.json" \
    --dry-run=client -o yaml | \
    kubectl apply --context "$KUBE_CONTEXT" -f -

success "Grafana dashboard ConfigMap created."

# ── Deploy Grafana ───────────────────────────────────────────────────

info "[3/3] Deploying Grafana..."

kubectl apply --context "$KUBE_CONTEXT" \
    -f "${REPO_DIR}/monitoring/grafana.yaml"

success "Grafana resources applied."

# ── Wait for pods ────────────────────────────────────────────────────

info "Waiting for Prometheus to be ready..."
kubectl rollout status deployment/prometheus \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring \
    --timeout=120s 2>/dev/null || warn "Prometheus not ready yet"

info "Waiting for Grafana to be ready..."
kubectl rollout status deployment/grafana \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring \
    --timeout=120s 2>/dev/null || warn "Grafana not ready yet"

# ── Summary ──────────────────────────────────────────────────────────

echo ""
kubectl get pods --context "$KUBE_CONTEXT" -n monitoring

header "Monitoring Stack Ready"

echo "  Access locally via port-forward:"
echo ""
echo "    Prometheus:  make prometheus-ui    (http://localhost:9090)"
echo "    Grafana:     make grafana-ui       (http://localhost:3000)"
echo ""
echo "  Or manually:"
echo "    kubectl port-forward -n monitoring svc/prometheus 9090:9090 --context ${KUBE_CONTEXT}"
echo "    kubectl port-forward -n monitoring svc/grafana 3000:3000 --context ${KUBE_CONTEXT}"
echo ""
echo "  Grafana login: anonymous access enabled (no password needed)"
echo ""
echo "  Prometheus alert rules:"
echo "    - CoreDNSDown (critical) — instance unreachable for 1m"
echo "    - CoreDNSHighSERVFAILRate (warning) — SERVFAIL > 1% for 5m"
echo "    - CoreDNSLatencyP99High (warning) — p99 > 100ms for 5m"
echo "    - CoreDNSForwardLatencyP99High (warning) — forward p99 > 500ms for 5m"
echo "    - CoreDNSCacheHitRateLow (info) — cache hit rate < 50% for 10m"
echo "    - CoreDNSAvailabilitySLOBreach (critical) — availability < 99.9% for 5m"
echo "    - CoreDNSLatencySLOBreach (warning) — <99% of requests within 100ms for 5m"
echo ""
