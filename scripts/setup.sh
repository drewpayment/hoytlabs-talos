#!/bin/bash
# setup.sh - Script to set up and deploy a Talos Kubernetes cluster

# Define colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Define project directory structure
INFRA_DIR="./infrastructure/talos-cluster"

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

# Check if talosctl is installed
if ! command -v talosctl &> /dev/null; then
    echo -e "${RED}Error: talosctl is not installed.${NC}"
    echo "Please install talosctl first: https://www.talos.dev/v1.6/introduction/getting-started/"
    exit 1
fi

# Check if pulumi is installed
if ! command -v pulumi &> /dev/null; then
    echo -e "${RED}Error: pulumi is not installed.${NC}"
    echo "Please install Pulumi first: https://www.pulumi.com/docs/get-started/install/"
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl is not installed.${NC}"
    echo "Please install kubectl first: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
    exit 1
fi

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo -e "${RED}Error: helm is not installed.${NC}"
    echo "Please install helm first: https://helm.sh/docs/intro/install/"
    exit 1
fi

echo -e "${GREEN}All prerequisites are installed.${NC}"

# Ensure directories exist
echo -e "${YELLOW}Creating project directory structure...${NC}"
mkdir -p "$INFRA_DIR/talos"

# Navigate to the infrastructure directory
cd "$INFRA_DIR" || {
    echo -e "${RED}Failed to navigate to $INFRA_DIR directory.${NC}"
    exit 1
}

# Ensure configuration files exist
if [ ! -f "controlplane-msi.yaml" ] || [ ! -f "controlplane-dell.yaml" ] || [ ! -f "controlplane-opti.yaml" ]; then
    echo -e "${YELLOW}Configuration files not found. Generating from templates...${NC}"
    
    # Generate configs
    talosctl gen config hoytlabs-cluster https://192.168.86.220:6443
    
    echo -e "${YELLOW}Updating configuration files with custom settings...${NC}"
    
    # Update controlplane.yaml - add network interface config
    sed -i.bak '/network:/c\  network:\n    hostname: kube-master-msi-1\n    interfaces:\n      - interface: eth0\n        dhcp: false\n        addresses:\n          - 192.168.86.200/24\n        mtu: 1500\n        routes:\n          - network: 0.0.0.0/0\n            gateway: 192.168.86.1\n        vip:\n          ip: 192.168.86.220\n    nameservers:\n      - 192.168.86.1\n      - 1.1.1.1' controlplane.yaml
    
    # Update worker.yaml - add network interface config
    sed -i.bak '/network:/c\  network:\n    hostname: kube-worker-1\n    interfaces:\n      - interface: eth0\n        dhcp: false\n        addresses:\n          - 192.168.86.210/24\n        mtu: 1500\n        routes:\n          - network: 0.0.0.0/0\n            gateway: 192.168.86.1\n    nameservers:\n      - 192.168.86.1\n      - 1.1.1.1' worker.yaml
    
    # Set CNI to Cilium
    sed -i.bak '/cni:/c\    cni:\n      name: cilium' controlplane.yaml
    sed -i.bak '/cni:/c\    cni:\n      name: cilium' worker.yaml
    
    # Add system customizations to controlplane
    sed -i.bak '/sysctls:/c\  sysctls:\n    fs.inotify.max_queued_events: "65536"\n    fs.inotify.max_user_watches: "524288"\n    fs.inotify.max_user_instances: "8192"' controlplane.yaml
    
    # Add system customizations to worker
    sed -i.bak '/sysctls:/c\  sysctls:\n    fs.inotify.max_queued_events: "65536"\n    fs.inotify.max_user_watches: "524288"\n    fs.inotify.max_user_instances: "8192"' worker.yaml
    
    echo -e "${GREEN}Configuration files updated.${NC}"
else
    echo -e "${GREEN}Configuration files already exist.${NC}"
fi

# Check if Pulumi files exist
if [ ! -f "index.ts" ] || [ ! -f "Pulumi.yaml" ]; then
    echo -e "${YELLOW}Pulumi files not found. Creating them...${NC}"
    
    # Create index.ts
    cat > index.ts << 'EOL'
// Pulumi program to deploy a 3-node Talos Kubernetes cluster
import * as pulumi from "@pulumi/pulumi";
import * as command from "@pulumi/command";
import * as fs from "fs";
import * as path from "path";

// Configuration
const config = new pulumi.Config();
const nodeIps = config.requireObject<string[]>("nodeIps");
const talosctlPath = config.get("talosctlPath") || "talosctl";
const talosOutputDir = config.get("talosOutputDir") || "./talos";

// Make sure the output directory exists
const ensureOutputDir = new command.local.Command("ensure-output-dir", {
    create: `mkdir -p ${talosOutputDir}`,
});

// Apply configurations to all nodes
const applyConfigs = [];

// Apply controlplane config to first node
applyConfigs.push(
    new command.local.Command("apply-controlplane-config", {
        create: pulumi.interpolate`${talosctlPath} apply-config --insecure --nodes ${nodeIps[0]} --file ./controlplane.yaml`,
        dependsOn: [ensureOutputDir],
    })
);

// Apply worker config to remaining nodes
for (let i = 1; i < nodeIps.length; i++) {
    applyConfigs.push(
        new command.local.Command(`apply-worker-config-${i}`, {
            create: pulumi.interpolate`${talosctlPath} apply-config --insecure --nodes ${nodeIps[i]} --file ./worker.yaml`,
            dependsOn: [ensureOutputDir],
        })
    );
}

// Bootstrap the cluster on the first control plane node
const bootstrapCluster = new command.local.Command("bootstrap-cluster", {
    create: pulumi.interpolate`${talosctlPath} bootstrap --nodes ${nodeIps[0]}`,
    dependsOn: applyConfigs,
});

// Configure talosctl with the node endpoints and save talosconfig
const talosConfigFile = new command.local.Command("generate-talosconfig", {
    create: pulumi.interpolate`${talosctlPath} config endpoint ${nodeIps.join(" ")} && ${talosctlPath} config node ${nodeIps[0]} && cp ~/.talos/config ${talosOutputDir}/talosconfig`,
    dependsOn: [bootstrapCluster],
});

// Wait for the Kubernetes API to be available
const waitForK8s = new command.local.Command("wait-for-kubernetes", {
    create: pulumi.interpolate`${talosctlPath} --talosconfig=${talosOutputDir}/talosconfig health --wait-timeout 10m && sleep 30`,
    dependsOn: [talosConfigFile],
});

// Get the kubeconfig using multiple methods to handle potential certificate issues
const kubeconfig = new command.local.Command("get-kubeconfig", {
    create: pulumi.interpolate`
    # Save talosconfig for reference
    TALOSCONFIG=${talosOutputDir}/talosconfig
    
    # Try method 1: Standard approach
    if ${talosctlPath} --talosconfig=$TALOSCONFIG kubeconfig --nodes ${nodeIps[0]} -f ${talosOutputDir}/kubeconfig; then
        echo "Successfully retrieved kubeconfig using standard method"
    else
        echo "Standard method failed. Trying alternative method..."
        
        # Try method 2: Direct API call 
        if ${talosctlPath} --talosconfig=$TALOSCONFIG -n ${nodeIps[0]} get kubeconfig > ${talosOutputDir}/kubeconfig; then
            echo "Successfully retrieved kubeconfig using direct API call"
        else
            echo "Direct API call failed. Extracting CA and trying with explicit certificate..."
            
            # Try method 3: Extract CA and use it explicitly
            CA=$(grep -A1 "ca:" $TALOSCONFIG | tail -1 | sed 's/ *//')
            echo $CA | base64 -d > ${talosOutputDir}/ca.crt
            
            # Try with explicit CA
            if ${talosctlPath} --talosconfig=$TALOSCONFIG --cacert=${talosOutputDir}/ca.crt kubeconfig --nodes ${nodeIps[0]} -f ${talosOutputDir}/kubeconfig; then
                echo "Successfully retrieved kubeconfig using explicit CA"
            else
                echo "All automatic methods failed. Please try manually with: talosctl -n ${nodeIps[0]} dashboard"
                exit 1
            fi
        fi
    fi
    
    # Check if kubeconfig was successfully created
    if [ -f "${talosOutputDir}/kubeconfig" ] && [ -s "${talosOutputDir}/kubeconfig" ]; then
        echo "Successfully generated kubeconfig at ${talosOutputDir}/kubeconfig"
    else
        echo "Failed to create a valid kubeconfig file"
        exit 1
    fi
    `,
    dependsOn: [waitForK8s],
});

// Deploy Cilium CNI after kubeconfig is available
const deployCilium = new command.local.Command("deploy-cilium", {
    create: pulumi.interpolate`
    export KUBECONFIG=${talosOutputDir}/kubeconfig
    
    # Check if Cilium is already installed
    if ! kubectl get pods -n kube-system -l k8s-app=cilium 2>/dev/null | grep -q Running; then
        echo "Installing Cilium CNI..."
        
        # Install Cilium using Helm
        helm repo add cilium https://helm.cilium.io/
        helm repo update
        
        helm install cilium cilium/cilium --version 1.14.3 \\
            --namespace kube-system \\
            --set kubeProxyReplacement=strict \\
            --set autoDirectNodeRoutes=true \\
            --set ipam.mode=kubernetes
        
        echo "Waiting for Cilium to be ready..."
        kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=cilium --timeout=300s
        
        echo "Cilium installed successfully"
    else
        echo "Cilium is already installed"
    fi
    `,
    dependsOn: [kubeconfig],
});

// Export the necessary information
export const talosconfigPath = `${talosOutputDir}/talosconfig`;
export const kubeconfigPath = `${talosOutputDir}/kubeconfig`;
export const controlPlaneIP = nodeIps[0];
export const workerIPs = nodeIps.slice(1);
export const clusterEndpoint = `https://${nodeIps[0]}:6443`;
EOL
    
    # Create Pulumi.yaml
    cat > Pulumi.yaml << EOL
name: hoytlabs-talos
runtime: nodejs
description: A Pulumi project to deploy Kubernetes on a Talos cluster
EOL,
    
    # Create Pulumi.dev.yaml
    cat > Pulumi.dev.yaml << EOL
config:
  hoytlabs-talos:nodeIps:
    - "192.168.86.200"  # Control plane node
    - "192.168.86.210"  # Worker node 1
    - "192.168.86.211"  # Worker node 2
  hoytlabs-talos:talosctlPath: "talosctl"
  hoytlabs-talos:talosOutputDir: "./talos"
EOL
    
    # Create package.json
    cat > package.json << EOL
{
  "name": "hoytlabs-talos",
  "version": "1.0.0",
  "description": "Talos Kubernetes cluster deployment with Pulumi",
  "main": "index.js",
  "scripts": {
    "build": "tsc"
  },
  "keywords": [
    "pulumi",
    "talos",
    "kubernetes",
    "cilium"
  ],
  "author": "",
  "license": "MIT",
  "dependencies": {
    "@pulumi/pulumi": "^3.0.0",
    "@pulumi/command": "^0.7.0"
  },
  "devDependencies": {
    "@types/node": "^18.0.0",
    "typescript": "^5.0.0"
  }
}
EOL
    
    # Create tsconfig.json
    cat > tsconfig.json << EOL
{
  "compilerOptions": {
    "target": "es2022",
    "module": "commonjs",
    "moduleResolution": "node",
    "outDir": "bin",
    "rootDir": ".",
    "sourceMap": true,
    "strict": true,
    "esModuleInterop": true,
    "forceConsistentCasingInFileNames": true,
    "skipLibCheck": true,
    "lib": ["es2022", "dom"]
  },
  "include": ["*.ts"],
  "exclude": ["node_modules", "bin"]
}
EOL
    
    echo -e "${GREEN}Pulumi files created.${NC}"
else
    echo -e "${GREEN}Pulumi files already exist.${NC}"
fi

# Install dependencies
echo -e "${YELLOW}Installing npm dependencies...${NC}"
bun install
echo -e "${GREEN}Dependencies installed.${NC}"

# Initialize Pulumi stack if it doesn't exist
if ! pulumi stack ls | grep -q "dev"; then
    echo -e "${YELLOW}Initializing Pulumi stack...${NC}"
    pulumi stack init dev
    echo -e "${GREEN}Pulumi stack initialized.${NC}"
fi

# Deploy with Pulumi
echo -e "${YELLOW}Deploying Talos Kubernetes cluster...${NC}"
echo -e "${YELLOW}This may take 10-15 minutes. Please be patient.${NC}"

pulumi up --yes

# Check if deployment was successful
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Talos Kubernetes cluster deployment completed successfully!${NC}"
    
    # Set up environment for kubectl
    KUBECONFIG=$(pulumi stack output kubeconfigPath --show-secrets)
    KUBECONFIG=$(realpath "$KUBECONFIG")
    
    echo -e "${YELLOW}Setting up kubectl configuration...${NC}"
    export KUBECONFIG
    
    # Wait for nodes to be ready
    echo -e "${YELLOW}Waiting for Kubernetes nodes to be ready...${NC}"
    kubectl wait --for=condition=Ready nodes --all --timeout=5m
    
    # Show cluster info
    echo -e "${GREEN}Kubernetes cluster is now ready!${NC}"
    echo -e "${YELLOW}Cluster info:${NC}"
    kubectl cluster-info
    
    echo -e "${YELLOW}Nodes in the cluster:${NC}"
    kubectl get nodes -o wide
    
    echo -e "${GREEN}Deployment completed successfully!${NC}"
    echo -e "${YELLOW}Use the following commands to interact with your cluster:${NC}"
    echo "export KUBECONFIG=$KUBECONFIG"
    echo "export TALOSCONFIG=$(realpath "./talos/talosconfig")"
    
    # Create a simple test deployment
    read -p "Would you like to deploy a test nginx application? (y/n): " deploy_test
    
    if [[ $deploy_test == "y" || $deploy_test == "Y" ]]; then
        echo -e "${YELLOW}Deploying test nginx application...${NC}"
        kubectl create deployment nginx --image=nginx
        kubectl expose deployment nginx --port=80 --type=ClusterIP
        kubectl wait --for=condition=available --timeout=60s deployment/nginx
        echo -e "${GREEN}Test application deployed successfully!${NC}"
        echo -e "${YELLOW}You can access the application using:${NC}"
        echo "kubectl port-forward service/nginx 8080:80"
        echo "Then visit http://localhost:8080 in your browser."
    fi
else
    echo -e "${RED}Deployment failed. Please check the logs for more information.${NC}"
    exit 1
fi