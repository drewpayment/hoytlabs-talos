#!/bin/bash
# fix-kubeconfig.sh - Script to fix kubeconfig certificate verification error

# Define colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if talosctl is installed
if ! command -v talosctl &> /dev/null; then
    echo -e "${RED}Error: talosctl is not installed.${NC}"
    echo "Please install talosctl first: https://www.talos.dev/v1.5/introduction/getting-started/"
    exit 1
fi

# Get the first control plane node IP
read -p "Enter the IP address of one of your control plane nodes: " NODE_IP

# Create output directory if it doesn't exist
TALOS_DIR="../infrastructure/talos-cluster/talos"
mkdir -p $TALOS_DIR

echo -e "${YELLOW}Fetching kubeconfig using --insecure flag...${NC}"

# Get kubeconfig with insecure flag
if talosctl kubeconfig --insecure --nodes $NODE_IP -f $TALOS_DIR/kubeconfig; then
    echo -e "${GREEN}Successfully retrieved kubeconfig!${NC}"
    echo "Kubeconfig saved to $TALOS_DIR/kubeconfig"
    echo ""
    echo -e "${YELLOW}To use this kubeconfig, run:${NC}"
    echo "export KUBECONFIG=$TALOS_DIR/kubeconfig"
    echo "kubectl get nodes"
else
    echo -e "${RED}Failed to retrieve kubeconfig.${NC}"
    echo "Please check your network and make sure the node is reachable."
    exit 1
fi

echo ""
echo -e "${YELLOW}Creating talosconfig...${NC}"

# Generate talosconfig for all nodes
if talosctl config endpoint $NODE_IP && talosctl config node $NODE_IP; then
    echo -e "${GREEN}Successfully created talosconfig!${NC}"
    echo "Talosconfig saved to ~/.talos/config"
    echo ""
    echo -e "${YELLOW}To use talosctl, run:${NC}"
    echo "talosctl -n $NODE_IP --insecure version"
else
    echo -e "${RED}Failed to create talosconfig.${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}Setup complete!${NC}"