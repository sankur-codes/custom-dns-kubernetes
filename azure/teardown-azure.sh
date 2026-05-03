#!/usr/bin/env bash
# teardown-azure.sh — Destroy all Azure resources for the custom DNS demo.
#
# Deletes the entire resource group (which cascades to all resources within it).
# Reads config from config.env + azure/.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${REPO_DIR}/scripts/common.sh"

load_project_config

ENVFILE="${SCRIPT_DIR}/.env"

# ── Load runtime state ────────────────────────────────────────────

if [ ! -f "$ENVFILE" ]; then
    warn "azure/.env not found. Nothing to tear down."
    exit 0
fi

load_config "$ENVFILE"

header "Azure Teardown"

info "This will permanently delete ALL resources in:"
echo ""
echo "  Resource Group:  ${RESOURCE_GROUP}"
echo "  Location:        ${LOCATION}"
echo "  Cluster:         ${CLUSTER_NAME}"
echo ""
echo "  Resources to be deleted:"
echo "    - VMs:        ${CP_VM} ${WORKER_VMS}"
echo "    - VNet:       ${VNET_NAME}"
echo "    - NSG:        ${NSG_NAME}"
echo "    - Public IPs, NICs, OS disks (all within the resource group)"
echo ""

warn "This action is IRREVERSIBLE."
echo ""
confirm "Delete resource group '${RESOURCE_GROUP}' and ALL its resources?" \
    || { info "Aborted. No resources were deleted."; exit 0; }

echo ""
confirm "Are you absolutely sure? This will destroy everything." \
    || { info "Aborted."; exit 0; }

# ── Delete resource group ────────────────────────────────────────────

info "Deleting resource group '${RESOURCE_GROUP}'..."
info "(This may take 2-5 minutes as Azure deallocates all resources)"

az group delete --name "$RESOURCE_GROUP" --yes --no-wait

info "Deletion initiated (running in background on Azure)."

# ── Clean up local files ─────────────────────────────────────────────

rm -f "${SCRIPT_DIR}/.env"
rm -f "${SCRIPT_DIR}/kubeconfig"
success "Local config files removed."

header "Teardown Complete"

echo "  Resource group '${RESOURCE_GROUP}' is being deleted."
echo "  Check status:  az group show --name ${RESOURCE_GROUP} 2>/dev/null"
echo ""
echo "  To verify deletion is complete:"
echo "    az group exists --name ${RESOURCE_GROUP}"
echo ""
