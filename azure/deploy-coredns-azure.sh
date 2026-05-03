#!/usr/bin/env bash
# deploy-coredns-azure.sh — Deploy CoreDNS static pods to all Azure k3s nodes.
#
# This script:
#   1. Renders the Corefile template with actual IPs from azure/.env
#   2. Copies static pod manifest + Corefile to each VM via SSH
#   3. Waits for CoreDNS to start on port 53
#   4. Reconfigures /etc/resolv.conf to use local CoreDNS
#
# Reads config from config.env + azure/.env (runtime IPs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${REPO_DIR}/scripts/common.sh"

load_project_config

ENVFILE="${SCRIPT_DIR}/.env"
MANIFEST="${REPO_DIR}/manifests/coredns-static-pod.yaml"
COREFILE_TEMPLATE="${REPO_DIR}/manifests/Corefile.template"

# ── Load runtime state ────────────────────────────────────────────

if [ ! -f "$ENVFILE" ]; then
    error "azure/.env not found. Run 'make azure-infra' first."
fi

load_config "$ENVFILE"

# Compute escaped domain for Corefile regex match
DOMAIN_REGEX=$(echo "$DOMAIN" | sed 's/\./\\\\./g')

header "Custom DNS Deployment (Azure)"

info "Configuration:"
echo "  Cluster:          ${CLUSTER_NAME}"
echo "  Domain:           ${DOMAIN}"
echo "  Control plane:    ${CP_VM} (${CP_PRIVATE_IP})"
echo "  Ingress IP:       ${INGRESS_IP}"
echo "  Workers:          ${WORKER_COUNT}"
echo ""
echo "  IP Assignments (simulating load balancers):"
echo "    api.${DOMAIN}:          ${CP_PRIVATE_IP}"
echo "    api-int.${DOMAIN}:      ${CP_PRIVATE_IP}"
echo "    *.apps.${DOMAIN}:       ${INGRESS_IP}"
echo ""

# ── Build VM/IP lists ──────────────────────────────────────────────

ALL_VMS="${CP_VM} ${WORKER_VMS}"
ALL_PUBLIC="${CP_PUBLIC_IP} ${WORKER_PUBLIC_IPS}"
ALL_PRIVATE="${CP_PRIVATE_IP} ${WORKER_PRIVATE_IPS}"

VM_COUNT=$(echo "$ALL_VMS" | wc -w | tr -d ' ')

# ── Deploy to each node ──────────────────────────────────────────────

VM_INDEX=1
for VM in $ALL_VMS; do
    PUB_IP=$(echo "$ALL_PUBLIC"  | awk "{print \$${VM_INDEX}}")
    PRIV_IP=$(echo "$ALL_PRIVATE" | awk "{print \$${VM_INDEX}}")

    echo ""
    info "--- Deploying to ${VM} (${PRIV_IP}) ---"

    # Discover upstream DNS on the VM
    UPSTREAM=$(ssh_exec "$PUB_IP" \
        "grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print \$2}'" 2>/dev/null || echo "")

    # On Azure, the upstream is typically 168.63.129.16 (Azure DNS wire server)
    if [ -z "$UPSTREAM" ]; then
        UPSTREAM="168.63.129.16"
    fi

    echo "  Node IP:       ${PRIV_IP}"
    echo "  Upstream DNS:  ${UPSTREAM}"

    # Create the CoreDNS config directory
    ssh_exec "$PUB_IP" "sudo mkdir -p /etc/coredns"

    # Render the Corefile from template
    TMPFILE=$(mktemp /tmp/Corefile-XXXXXX)
    sed -e "s|__API_IP__|${CP_PRIVATE_IP}|g" \
        -e "s|__INGRESS_IP__|${INGRESS_IP}|g" \
        -e "s|__UPSTREAM_DNS__|${UPSTREAM}|g" \
        -e "s|__DOMAIN__|${DOMAIN}|g" \
        -e "s|__DOMAIN_REGEX__|${DOMAIN_REGEX}|g" \
        "$COREFILE_TEMPLATE" > "$TMPFILE"

    # Copy files to the VM
    ssh_copy "$TMPFILE" "$PUB_IP" "/tmp/Corefile"
    ssh_copy "$MANIFEST" "$PUB_IP" "/tmp/coredns-local.yaml"
    rm -f "$TMPFILE"

    ssh_exec "$PUB_IP" "
        sudo cp /tmp/Corefile /etc/coredns/Corefile
        sudo cp /tmp/coredns-local.yaml /etc/kubernetes/manifests/coredns-local.yaml
        sudo chmod 644 /etc/coredns/Corefile
        sudo chmod 644 /etc/kubernetes/manifests/coredns-local.yaml
        rm -f /tmp/Corefile /tmp/coredns-local.yaml
    "

    info "  Corefile and static pod manifest deployed."

    # Wait for CoreDNS to start listening on port 53
    info "  Waiting for CoreDNS to start..."
    STARTED=false
    for attempt in $(seq 1 60); do
        if ssh_exec "$PUB_IP" "ss -ulnp 2>/dev/null | grep -q ':53 '" 2>/dev/null; then
            STARTED=true
            break
        fi
        sleep 2
    done

    if [ "$STARTED" = true ]; then
        success "  CoreDNS is listening on port 53."
    else
        warn "  CoreDNS may not be ready yet. Check: kubectl get pods -n kube-system"
    fi

    VM_INDEX=$((VM_INDEX + 1))
done

# ── Reconfigure resolv.conf ──────────────────────────────────────────

echo ""
info "Reconfiguring /etc/resolv.conf on all VMs..."

VM_INDEX=1
for VM in $ALL_VMS; do
    PUB_IP=$(echo "$ALL_PUBLIC"  | awk "{print \$${VM_INDEX}}")
    PRIV_IP=$(echo "$ALL_PRIVATE" | awk "{print \$${VM_INDEX}}")

    UPSTREAM=$(ssh_exec "$PUB_IP" \
        "grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print \$2}'" 2>/dev/null || echo "168.63.129.16")

    ssh_exec "$PUB_IP" "
        sudo cp /etc/resolv.conf /etc/resolv.conf.upstream 2>/dev/null || true
        echo 'nameserver ${PRIV_IP}
nameserver ${UPSTREAM}
search ${DOMAIN}' | sudo tee /etc/resolv.conf >/dev/null
    "

    info "  ${VM}: /etc/resolv.conf -> ${PRIV_IP} (local CoreDNS)"
    VM_INDEX=$((VM_INDEX + 1))
done

# ── Summary ──────────────────────────────────────────────────────────

header "Deployment Complete (Azure)"

echo "  CoreDNS static pods deployed to ${VM_COUNT} VMs."
echo ""
echo "  Domains resolved locally (no Azure DNS):"
echo "    api.${DOMAIN}         -> ${CP_PRIVATE_IP}"
echo "    api-int.${DOMAIN}     -> ${CP_PRIVATE_IP}"
echo "    *.apps.${DOMAIN}      -> ${INGRESS_IP}"
echo ""
echo "  Next step:  make azure-verify    (run DNS verification tests)"
echo ""
