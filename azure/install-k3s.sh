#!/usr/bin/env bash
# install-k3s.sh — Install k3s on Azure VMs with static pod support.
#
# Installs k3s server on the control-plane VM and k3s agents on worker VMs.
# Enables kubelet static pod manifest path so CoreDNS can be deployed as
# a static pod on every node.
#
# Reads config from config.env + azure/.env (runtime IPs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${REPO_DIR}/scripts/common.sh"

load_project_config

ENVFILE="${SCRIPT_DIR}/.env"

# ── Load runtime state ────────────────────────────────────────────

if [ ! -f "$ENVFILE" ]; then
    error "azure/.env not found. Run 'make azure-infra' first."
fi

load_config "$ENVFILE"

header "k3s Cluster Installation"

info "Configuration:"
echo "  Cluster name:    ${CLUSTER_NAME}"
echo "  Control plane:   ${CP_VM} (${CP_PUBLIC_IP})"
echo "  Workers:         ${WORKER_COUNT}"
echo "  SSH user:        ${SSH_USER}"
echo "  SSH key:         ${SSH_KEY_PATH}"
echo ""

# ── Check SSH connectivity ──────────────────────────────────────────

info "Verifying SSH connectivity..."
ALL_PUBLIC="${CP_PUBLIC_IP} ${WORKER_PUBLIC_IPS}"
for IP in $ALL_PUBLIC; do
    if ! ssh_exec "$IP" "echo ok" &>/dev/null; then
        error "Cannot SSH to ${IP}. Check your NSG rules and SSH key."
    fi
done
success "SSH connectivity verified on all VMs."
echo ""

# ── Step 1: Disable systemd-resolved stub listener ──────────────────

info "[1/4] Disabling systemd-resolved stub listener..."

for IP in $ALL_PUBLIC; do
    ssh_exec "$IP" "
        sudo mkdir -p /etc/systemd/resolved.conf.d
        echo '[Resolve]
DNSStubListener=no' | sudo tee /etc/systemd/resolved.conf.d/nostub.conf >/dev/null
        sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        sudo systemctl restart systemd-resolved
    "
done
success "systemd-resolved stub listener disabled on all VMs."

# ── Step 2: Install k3s server on control-plane ─────────────────────

echo ""
info "[2/4] Installing k3s server on ${CP_VM}..."

ssh_exec "$CP_PUBLIC_IP" "
    sudo mkdir -p /etc/kubernetes/manifests
    curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC='server \
        --tls-san ${CP_PUBLIC_IP} \
        --tls-san api.${DOMAIN} \
        --node-name ${CP_VM} \
        --kubelet-arg=pod-manifest-path=/etc/kubernetes/manifests \
        --disable traefik \
        --write-kubeconfig-mode 644' sh -
"

info "  Waiting for k3s server to become ready..."
for attempt in $(seq 1 60); do
    if ssh_exec "$CP_PUBLIC_IP" "sudo k3s kubectl get nodes" &>/dev/null; then
        break
    fi
    sleep 2
done

success "k3s server installed on ${CP_VM}."

# Get the join token
K3S_TOKEN=$(ssh_exec "$CP_PUBLIC_IP" "sudo cat /var/lib/rancher/k3s/server/node-token")
info "  Join token retrieved."

# ── Step 3: Install k3s agents on workers ────────────────────────────

echo ""
info "[3/4] Installing k3s agents on workers..."

i=0
for IP in $WORKER_PUBLIC_IPS; do
    WORKER_VM=$(echo "$WORKER_VMS" | awk "{print \$((${i}+1))}")
    info "  Installing k3s agent on ${WORKER_VM} (${IP})..."

    ssh_exec "$IP" "
        sudo mkdir -p /etc/kubernetes/manifests
        curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC='agent \
            --server https://${CP_PRIVATE_IP}:6443 \
            --token ${K3S_TOKEN} \
            --node-name ${WORKER_VM} \
            --kubelet-arg=pod-manifest-path=/etc/kubernetes/manifests' sh -
    "
    i=$((i + 1))
done

info "  Waiting for workers to join the cluster..."
for attempt in $(seq 1 60); do
    READY_COUNT=$(ssh_exec "$CP_PUBLIC_IP" \
        "sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready'" || echo "0")
    EXPECTED=$((WORKER_COUNT + 1))
    if [ "$READY_COUNT" -ge "$EXPECTED" ]; then
        break
    fi
    sleep 3
done

success "All k3s agents installed."

# ── Step 4: Fetch kubeconfig ─────────────────────────────────────────

echo ""
info "[4/4] Fetching kubeconfig..."

KUBECONFIG_FILE="${SCRIPT_DIR}/kubeconfig"
ssh_exec "$CP_PUBLIC_IP" "sudo cat /etc/rancher/k3s/k3s.yaml" \
    | sed "s|127.0.0.1|${CP_PUBLIC_IP}|g" \
    | sed "s|default|${CLUSTER_NAME}|g" \
    > "$KUBECONFIG_FILE"

chmod 600 "$KUBECONFIG_FILE"
success "Kubeconfig saved to azure/kubeconfig"

# ── Summary ──────────────────────────────────────────────────────────

echo ""
header "k3s Cluster Ready"

ssh_exec "$CP_PUBLIC_IP" "sudo k3s kubectl get nodes -o wide" 2>/dev/null || true

echo ""
echo "  Use this kubeconfig:"
echo "    export KUBECONFIG=${KUBECONFIG_FILE}"
echo "    kubectl get nodes"
echo ""
echo "  Next step:  make azure-deploy    (deploy CoreDNS static pods)"
echo ""

# Persist runtime state
save_config "$ENVFILE" \
    CLUSTER_NAME DOMAIN RESOURCE_GROUP LOCATION VM_SIZE \
    VNET_NAME VNET_CIDR SUBNET_NAME SUBNET_CIDR NSG_NAME \
    SSH_KEY_PATH SSH_USER \
    CP_VM CP_PUBLIC_IP CP_PRIVATE_IP \
    WORKER_COUNT WORKER_VMS WORKER_PUBLIC_IPS WORKER_PRIVATE_IPS \
    INGRESS_IP
