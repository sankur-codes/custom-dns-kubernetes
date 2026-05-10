#!/usr/bin/env bash
#
# deploy-demo-apps.sh — Deploy lightweight demo services into the cluster.
#
# Creates 4 nginx-based services in the demo-apps namespace to generate
# realistic Kubernetes service DNS entries (*.demo-apps.svc.cluster.local).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

KUBE_CONTEXT="kind-${CLUSTER_NAME}"

header "Demo Applications Deployment"

info "Cluster: ${CLUSTER_NAME}"
info "Context: ${KUBE_CONTEXT}"
echo ""

if ! kubectl get nodes --context "$KUBE_CONTEXT" &>/dev/null; then
    error "Cannot reach cluster '${CLUSTER_NAME}'. Is it running? Try: make cluster-up"
fi

info "Deploying demo applications..."

kubectl apply --context "$KUBE_CONTEXT" \
    -f "${REPO_DIR}/monitoring/demo-apps.yaml"

success "Demo applications applied."

info "Waiting for pods to be ready..."

kubectl rollout status deployment/web-frontend \
    --context "$KUBE_CONTEXT" \
    --namespace demo-apps \
    --timeout=120s 2>/dev/null || warn "web-frontend not ready yet"

kubectl rollout status deployment/api-backend \
    --context "$KUBE_CONTEXT" \
    --namespace demo-apps \
    --timeout=60s 2>/dev/null || warn "api-backend not ready yet"

kubectl rollout status deployment/redis-cache \
    --context "$KUBE_CONTEXT" \
    --namespace demo-apps \
    --timeout=60s 2>/dev/null || warn "redis-cache not ready yet"

kubectl rollout status deployment/postgres-db \
    --context "$KUBE_CONTEXT" \
    --namespace demo-apps \
    --timeout=60s 2>/dev/null || warn "postgres-db not ready yet"

echo ""
kubectl get pods --context "$KUBE_CONTEXT" -n demo-apps -o wide
echo ""

header "Demo Applications Ready"

echo "  Services deployed in namespace 'demo-apps':"
echo ""
echo "    web-frontend.demo-apps.svc.cluster.local"
echo "    api-backend.demo-apps.svc.cluster.local"
echo "    redis-cache.demo-apps.svc.cluster.local"
echo "    postgres-db.demo-apps.svc.cluster.local"
echo ""
echo "  These are resolved by kube-dns (standard Kubernetes DNS),"
echo "  NOT by the custom DNS layer. Use them to demonstrate"
echo "  that cluster service discovery is unaffected."
echo ""
echo "  Test with:"
echo "    kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never \\"
echo "        --context ${KUBE_CONTEXT} \\"
echo "        -- nslookup web-frontend.demo-apps.svc.cluster.local"
echo ""
echo "  Clean up with:"
echo "    make demo-apps-clean"
echo ""
