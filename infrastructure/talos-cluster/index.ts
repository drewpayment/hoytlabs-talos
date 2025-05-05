// Pulumi program to deploy a 3-node Talos Kubernetes cluster
import * as pulumi from "@pulumi/pulumi";
import * as command from "@pulumi/command";

// Configuration
const config = new pulumi.Config();
const nodeIps = config.requireObject<string[]>("nodeIps");
const vip = config.get("vip");
const talosctlPath = config.get("talosctlPath") || "talosctl";
const talosOutputDir = config.get("talosOutputDir") || "./talos";

// Make sure the output directory exists
const ensureOutputDir = new command.local.Command("ensure-output-dir", {
    create: `mkdir -p ${talosOutputDir}`,
});

// Generate secrets once and use for all nodes
const talosSecrets = new command.local.Command("generate-talos-secrets", {
    create: pulumi.interpolate`
    ${talosctlPath} gen secrets -o ${talosOutputDir}/secrets.yaml --force
    `,
    triggers: [ensureOutputDir.id]
});

// Generate the talosconfig file
const talosConfigFile = new command.local.Command("generate-talosconfig", {
    create: pulumi.interpolate`
    # Check if secrets file exists
    while [ ! -f "${talosOutputDir}/secrets.yaml" ]; do
        echo "Waiting for secrets file..."
        sleep 1
    done
    
    # Generate Talos configuration with the shared secrets
    ${talosctlPath} gen config --with-secrets ${talosOutputDir}/secrets.yaml \
    --output ${talosOutputDir}/talosconfig \
    --output-types talosconfig \
    --force \
    hoytlabs-cluster https://${vip}:6443
    `,
    triggers: [talosSecrets.id]
});

// Configuration for each node
const nodeConfig = [
    { 
        ip: '192.168.86.200', 
        hostname: 'kube-master-msi-1', 
        filename: 'controlplane-msi.yaml',
        deviceSelector: { busPath: "0*" }
    },
    { 
        ip: '192.168.86.204', 
        hostname: 'kube-master-dell-1', 
        filename: 'controlplane-dell.yaml',
        deviceSelector: { busPath: "0*" }
    },  
    { 
        ip: '192.168.86.201', 
        hostname: 'kube-master-opti-1', 
        filename: 'controlplane-opti.yaml',
        deviceSelector: { busPath: "0*" }
    }
];

const generateNodeConfigs = new command.local.Command("generate-node-configs", {
    create: pulumi.interpolate`
    # Wait for secrets file to be fully created
    if [ ! -f "${talosOutputDir}/secrets.yaml" ]; then
        echo "Error: Secrets file not found. This command depends on secrets generation."
        exit 1
    fi
    
    # Generate configs for each node with specific patches
    for i in 0 1 2; do
        ip=$(echo '${JSON.stringify(nodeConfig)}' | jq -r ".[$i].ip")
        hostname=$(echo '${JSON.stringify(nodeConfig)}' | jq -r ".[$i].hostname")
        filename=$(echo '${JSON.stringify(nodeConfig)}' | jq -r ".[$i].filename")
        busPath=$(echo '${JSON.stringify(nodeConfig)}' | jq -r ".[$i].deviceSelector.busPath")
        
        # Create node-specific patch file
        cat > ${talosOutputDir}/patch-$i.json << EOF
[
  {
    "op": "add",
    "path": "/machine/network/hostname",
    "value": "$hostname"
  },
  {
    "op": "add",
    "path": "/machine/network/interfaces",
    "value": [
      {
        "deviceSelector": {
          "busPath": "$busPath"
        },
        "dhcp": false,
        "addresses": ["$ip/24"],
        "mtu": 1500,
        "routes": [
          {
            "network": "0.0.0.0/0",
            "gateway": "192.168.86.1"
          }
        ],
        "vip": {
          "ip": "${vip}"
        }
      }
    ]
  },
  {
    "op": "add",
    "path": "/machine/certSANs",
    "value": [
      "${vip}",
      "$ip",
      "127.0.0.1"
    ]
  },
  {
    "op": "add",
    "path": "/cluster/apiServer/certSANs",
    "value": [
      "${vip}",
      "$ip",
      "127.0.0.1"
    ]
  }
]
EOF
        
        # Generate config for this specific node
        ${talosctlPath} gen config \
          --with-secrets ${talosOutputDir}/secrets.yaml \
          --config-patch-control-plane '[{"op": "add", "path": "/cluster/allowSchedulingOnControlPlanes", "value": true}]' \
          --config-patch-control-plane @${talosOutputDir}/patch-$i.json \
          --output ${talosOutputDir}/$filename \
          --output-types controlplane \
          --force \
          hoytlabs-cluster https://${vip}:6443
        
        echo "Generated $filename for $hostname ($ip)"
    done
    `,
    triggers: [talosConfigFile.id]
});

// Configure talosctl endpoints using the generated files
const configureEndpoints = new command.local.Command("configure-endpoints", {
    create: pulumi.interpolate`
    # Ensure config files exist
    for file in controlplane-dell.yaml controlplane-msi.yaml controlplane-opti.yaml; do
        if [ ! -f "$file" ]; then
            echo "Error: Config file $file not found. This command depends on config generation."
            exit 1
        fi
    done
    
    export TALOSCONFIG=${talosOutputDir}/talosconfig
    ${talosctlPath} config endpoints ${nodeIps.join(" ")}
    ${talosctlPath} config nodes ${nodeIps.join(" ")}
    `,
    triggers: [generateNodeConfigs.id]
});

// Apply configurations to all nodes
const applyConfigs = nodeConfig.map((node, i) => 
    new command.local.Command(`apply-controlplane-config-${i}`, {
        create: pulumi.interpolate`
        export TALOSCONFIG=${talosOutputDir}/talosconfig
        ${talosctlPath} apply-config --insecure --nodes ${node.ip} --file ${talosOutputDir}/${node.filename}
        `,
        triggers: [configureEndpoints.id]
    })
);

// First, add a command to bootstrap the cluster
const bootstrapCluster = new command.local.Command("bootstrap-cluster", {
    create: pulumi.interpolate`
    export TALOSCONFIG=${talosOutputDir}/talosconfig
    
    echo "Bootstrapping cluster on first node (${nodeIps[0]})..."
    
    # Bootstrap the cluster - this starts etcd and the control plane
    ${talosctlPath} bootstrap --nodes ${nodeIps[0]}
    
    echo "Waiting for API server to be available..."
    # Wait for API server to be ready
    for i in {1..30}; do
        if ${talosctlPath} health --server=false 2>/dev/null; then
            echo "API server is ready!"
            break
        fi
        echo "Waiting for API server... ($i/30)"
        sleep 10
    done
    `,
    // Run after all configs are applied
    triggers: applyConfigs.map(cmd => cmd.id)
});

// Then wait for all nodes to join
const waitForNodes = new command.local.Command("wait-for-nodes", {
    create: pulumi.interpolate`
    export TALOSCONFIG=${talosOutputDir}/talosconfig
    
    echo "Waiting for all nodes to be ready..."
    
    # Wait for all nodes to be ready
    ${talosctlPath} health --server=false --wait-timeout=10m
    
    # Check that all control plane nodes are members
    echo "Checking cluster membership..."
    for ip in ${nodeIps.join(" ")}; do
        echo "Checking node $ip..."
        ${talosctlPath} get members --nodes $ip
    done
    `,
    triggers: [bootstrapCluster.id]
});

// Get the kubeconfig with improved error handling
const kubeconfig = new command.local.Command("get-kubeconfig", {
    create: pulumi.interpolate`
    # Save talosconfig for reference
    TALOSCONFIG=${talosOutputDir}/talosconfig
    
    # Try to get kubeconfig directly using the standard method
    echo "Retrieving kubeconfig..."
    ${talosctlPath} --talosconfig=$TALOSCONFIG --nodes ${nodeIps[0]} kubeconfig ${talosOutputDir}/kubeconfig
    
    # Check if kubeconfig was successfully created
    if [ -f "${talosOutputDir}/kubeconfig" ] && [ -s "${talosOutputDir}/kubeconfig" ]; then
        echo "Successfully generated kubeconfig at ${talosOutputDir}/kubeconfig"
    else
        echo "Failed to create a valid kubeconfig file"
        exit 1
    fi
    `,
    triggers: [waitForNodes.id]
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
});

// Export the necessary information
export const talosconfigPath = `${talosOutputDir}/talosconfig`;
export const kubeconfigPath = `${talosOutputDir}/kubeconfig`;
export const clusterEndpoint = `https://${vip}:6443`;