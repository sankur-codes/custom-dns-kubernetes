#!/usr/bin/env bash
# setup-azure.sh — Create Azure infrastructure for the custom DNS demo.
#
# Creates: Resource Group, VNet, Subnet, NSG, Public IPs, NICs, VMs.
# Reads all configuration from config.env (no interactive prompts).
# Saves runtime outputs (IPs) to azure/.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${REPO_DIR}/scripts/common.sh"

load_project_config

ENVFILE="${SCRIPT_DIR}/.env"

# ── Check prerequisites ─────────────────────────────────────────────

header "Azure Custom DNS Setup"

info "Checking prerequisites..."
command -v az  >/dev/null 2>&1 || error "az CLI not found. Install: brew install azure-cli"
command -v jq  >/dev/null 2>&1 || error "jq not found. Install: brew install jq"
command -v ssh >/dev/null 2>&1 || error "ssh not found."
success "All tools available."

# Check Azure login
ACCOUNT=$(az account show 2>/dev/null || true)
if [ -z "$ACCOUNT" ]; then
    warn "Not logged in to Azure."
    echo "  Run:  az login"
    echo "  Then re-run this script."
    exit 1
fi

AZ_USER=$(echo "$ACCOUNT" | jq -r '.user.name')
AZ_SUB=$(echo "$ACCOUNT"  | jq -r '.name')
AZ_SUB_ID=$(echo "$ACCOUNT" | jq -r '.id')
info "Logged in as: ${AZ_USER}"
info "Subscription: ${AZ_SUB} (${AZ_SUB_ID})"
echo ""

# ── Check for existing resources ───────────────────────────────────

if [ -f "$ENVFILE" ]; then
    load_config "$ENVFILE"
    if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        success "Resource group '${RESOURCE_GROUP}' already exists. Infrastructure is up."
        exit 0
    fi
fi

# ── SSH key ──────────────────────────────────────────────────────────

if [ ! -f "$SSH_KEY_PATH" ]; then
    info "SSH key not found at ${SSH_KEY_PATH}. Generating..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "custom-dns-demo"
    success "SSH key generated: ${SSH_KEY_PATH}"
fi

# ── Detect caller IP for NSG ────────────────────────────────────────

info "Detecting your public IP for NSG SSH rule..."
MY_IP=$(curl -sf https://ifconfig.me 2>/dev/null || curl -sf https://api.ipify.org 2>/dev/null || echo "")
if [ -z "$MY_IP" ]; then
    warn "Could not detect public IP. NSG SSH rule will allow 0.0.0.0/0."
    MY_IP_CIDR="0.0.0.0/0"
else
    MY_IP_CIDR="${MY_IP}/32"
    success "Your IP: ${MY_IP} (SSH will be restricted to this address)"
fi

# ── Build VM name lists ─────────────────────────────────────────────

CP_VM="${CLUSTER_NAME}-cp"
WORKER_VMS=""
for i in $(seq 0 $((WORKER_COUNT - 1))); do
    WORKER_VMS="${WORKER_VMS}${CLUSTER_NAME}-worker-${i} "
done
WORKER_VMS=$(echo "$WORKER_VMS" | xargs)
ALL_VMS="${CP_VM} ${WORKER_VMS}"

# ── Summary ──────────────────────────────────────────────────────────

header "Resource Summary"
echo "  Resource Group:  ${RESOURCE_GROUP} (${LOCATION})"
echo "  VNet:            ${VNET_NAME} (${VNET_CIDR})"
echo "  Subnet:          ${SUBNET_NAME} (${SUBNET_CIDR})"
echo "  NSG:             ${NSG_NAME} (SSH from ${MY_IP_CIDR})"
echo "  VMs:             ${ALL_VMS}"
echo "  VM Size:         ${VM_SIZE}"
echo "  VM OS:           Ubuntu 22.04 LTS"
echo "  Public IPs:      $(echo "$ALL_VMS" | wc -w | tr -d ' ') (one per VM)"
echo "  SSH Key:         ${SSH_KEY_PATH}"
echo "  SSH User:        ${SSH_USER}"
echo ""
echo "  Estimated cost:  ~\$4/day"
echo ""

confirm "Create all these resources?" || error "Aborted."

# ── Create resources ─────────────────────────────────────────────────

TOTAL_STEPS=5
STEP=0

# Step 1: Resource Group
STEP=$((STEP + 1))
info "[${STEP}/${TOTAL_STEPS}] Creating resource group '${RESOURCE_GROUP}'..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" \
    --tags project=custom-dns-demo cluster="$CLUSTER_NAME" \
    --output none
success "Resource group created."

# Step 2: VNet + Subnet
STEP=$((STEP + 1))
info "[${STEP}/${TOTAL_STEPS}] Creating VNet '${VNET_NAME}' and subnet '${SUBNET_NAME}'..."
az network vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --address-prefix "$VNET_CIDR" \
    --subnet-name "$SUBNET_NAME" \
    --subnet-prefix "$SUBNET_CIDR" \
    --output none
success "VNet and subnet created."

# Step 3: NSG + rules
STEP=$((STEP + 1))
info "[${STEP}/${TOTAL_STEPS}] Creating NSG '${NSG_NAME}' with security rules..."
az network nsg create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NSG_NAME" \
    --output none

az network nsg rule create \
    --resource-group "$RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name AllowSSH \
    --priority 1000 \
    --direction Inbound \
    --access Allow \
    --protocol Tcp \
    --destination-port-ranges 22 \
    --source-address-prefixes "$MY_IP_CIDR" \
    --output none

az network nsg rule create \
    --resource-group "$RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name AllowK8sAPI \
    --priority 1010 \
    --direction Inbound \
    --access Allow \
    --protocol Tcp \
    --destination-port-ranges 6443 \
    --source-address-prefixes "$MY_IP_CIDR" \
    --output none

az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --network-security-group "$NSG_NAME" \
    --output none

success "NSG created and associated with subnet."

# Step 4: VMs
STEP=$((STEP + 1))
info "[${STEP}/${TOTAL_STEPS}] Creating VMs..."

for VM in $ALL_VMS; do
    info "  Creating VM '${VM}'..."
    az vm create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM" \
        --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest \
        --size "$VM_SIZE" \
        --vnet-name "$VNET_NAME" \
        --subnet "$SUBNET_NAME" \
        --nsg "" \
        --ssh-key-values "${SSH_KEY_PATH}.pub" \
        --admin-username "$SSH_USER" \
        --public-ip-sku Standard \
        --tags project=custom-dns-demo cluster="$CLUSTER_NAME" role="${VM}" \
        --no-wait \
        --output none
done

info "  Waiting for all VMs to finish provisioning..."
for VM in $ALL_VMS; do
    az vm wait --resource-group "$RESOURCE_GROUP" --name "$VM" --created 2>/dev/null || true
done
success "All VMs created."

# Step 5: Collect IPs
STEP=$((STEP + 1))
info "[${STEP}/${TOTAL_STEPS}] Collecting VM IP addresses..."

CP_PUBLIC_IP=$(az vm show \
    --resource-group "$RESOURCE_GROUP" --name "$CP_VM" \
    --show-details --query publicIps -o tsv 2>/dev/null)
CP_PRIVATE_IP=$(az vm show \
    --resource-group "$RESOURCE_GROUP" --name "$CP_VM" \
    --show-details --query privateIps -o tsv 2>/dev/null)

WORKER_PUBLIC_IPS=""
WORKER_PRIVATE_IPS=""
for VM in $WORKER_VMS; do
    PUB=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM" \
        --show-details --query publicIps -o tsv 2>/dev/null)
    PRIV=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM" \
        --show-details --query privateIps -o tsv 2>/dev/null)
    WORKER_PUBLIC_IPS="${WORKER_PUBLIC_IPS}${PUB} "
    WORKER_PRIVATE_IPS="${WORKER_PRIVATE_IPS}${PRIV} "
done
WORKER_PUBLIC_IPS=$(echo "$WORKER_PUBLIC_IPS" | xargs)
WORKER_PRIVATE_IPS=$(echo "$WORKER_PRIVATE_IPS" | xargs)

# First worker private IP is the "Ingress LB IP"
INGRESS_IP=$(echo "$WORKER_PRIVATE_IPS" | awk '{print $1}')

echo ""
echo "  Control Plane:  ${CP_VM}"
echo "    Public IP:    ${CP_PUBLIC_IP}"
echo "    Private IP:   ${CP_PRIVATE_IP}"
for i in $(seq 1 "$WORKER_COUNT"); do
    VM=$(echo "$WORKER_VMS" | awk "{print \$$i}")
    PUB=$(echo "$WORKER_PUBLIC_IPS" | awk "{print \$$i}")
    PRIV=$(echo "$WORKER_PRIVATE_IPS" | awk "{print \$$i}")
    echo "  Worker $((i-1)):       ${VM}"
    echo "    Public IP:    ${PUB}"
    echo "    Private IP:   ${PRIV}"
done

# ── Save runtime state ──────────────────────────────────────────────

save_config "$ENVFILE" \
    CLUSTER_NAME DOMAIN RESOURCE_GROUP LOCATION VM_SIZE \
    VNET_NAME VNET_CIDR SUBNET_NAME SUBNET_CIDR NSG_NAME \
    SSH_KEY_PATH SSH_USER \
    CP_VM CP_PUBLIC_IP CP_PRIVATE_IP \
    WORKER_COUNT WORKER_VMS WORKER_PUBLIC_IPS WORKER_PRIVATE_IPS \
    INGRESS_IP

success "Runtime state saved to azure/.env"

# ── Wait for SSH ─────────────────────────────────────────────────────

info "Waiting for SSH to be available on all VMs..."
ALL_PUBLIC="${CP_PUBLIC_IP} ${WORKER_PUBLIC_IPS}"
for IP in $ALL_PUBLIC; do
    for attempt in $(seq 1 30); do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=3 -o LogLevel=ERROR \
            -i "$SSH_KEY_PATH" "${SSH_USER}@${IP}" "echo ok" &>/dev/null; then
            break
        fi
        sleep 2
    done
done
success "SSH available on all VMs."

header "Azure Infrastructure Ready"
echo "  Next step:  make azure-cluster    (install k3s)"
echo "  Or run:     make azure-demo       (full lifecycle)"
echo ""
