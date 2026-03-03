# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kubernetes homelab infrastructure running on Talos OS, managed via GitOps (ArgoCD) with Pulumi for cluster provisioning. Three-node control plane cluster with Cilium CNI, NFS/OpenEBS storage, and Gateway API for ingress.

## Common Commands

### Cluster Setup (infrastructure/talos-cluster/)
```bash
bun install                    # Install dependencies
pulumi stack init dev          # Initialize Pulumi stack
pulumi up --yes                # Deploy/update cluster
pulumi destroy                 # Tear down cluster
```

### Talos Operations
```bash
talosctl gen config <cluster> <endpoint>   # Generate configs
talosctl apply-config -n <node> -f <file>  # Apply to node
talosctl bootstrap -n <node>               # Bootstrap cluster
talosctl kubeconfig -n <node>              # Get kubeconfig
talosctl health --wait-timeout 10m         # Health check
```

### Kubernetes/GitOps
```bash
kubectl get nodes                          # Verify cluster
kustomize build <path>                     # Build manifests
argocd app sync <app>                      # Force ArgoCD sync
```

### Main Setup Script
```bash
./scripts/setup.sh             # Full cluster setup automation
./scripts/bootstrap-argocd.sh  # Bootstrap ArgoCD
```

## Architecture

### Directory Structure
- `infrastructure/talos-cluster/` - Pulumi IaC for Talos cluster provisioning (TypeScript)
- `infrastructure/controllers/` - Core controllers (ArgoCD, cert-manager, networking)
- `infrastructure/storage/` - Storage backends (OpenEBS, NFS CSI)
- `apps/` - Application deployments managed by ArgoCD ApplicationSet
- `monitoring/` - Prometheus stack and observability
- `scripts/` - Shell automation scripts

### GitOps Flow
1. ArgoCD watches this repository
2. `infrastructure/appset.yaml` discovers and deploys infrastructure components (sync-wave: -2)
3. `apps/appset.yaml` discovers and deploys applications (sync-wave: 1)
4. Each app directory becomes an ArgoCD Application with auto-created namespace

### Application Pattern
Each app in `apps/<name>/` follows this structure:
- `kustomization.yaml` - Resource list
- `namespace.yaml` - Namespace definition
- `deployment.yaml` - Workload spec
- `service.yaml` - Service exposure
- `http-route.yaml` - Gateway API ingress (subdomain: `<app>.hoytlabs.app`)
- `externalsecret.yaml` - Doppler secret integration

### Key Technologies
- **Runtime**: Bun (for TypeScript/Pulumi)
- **Cluster OS**: Talos (immutable Kubernetes)
- **GitOps**: ArgoCD with ApplicationSets and Kustomize plugin
- **Networking**: Cilium CNI with Gateway API
- **Storage**: NFS CSI driver, OpenEBS
- **Secrets**: SOPS/AGE encryption, ExternalSecrets with Doppler

## Cluster Configuration

Defined in `infrastructure/talos-cluster/Pulumi.dev.yaml`:
- 3 control plane nodes: 192.168.86.200, .204, .201
- VIP: 192.168.86.220
- Kubernetes version: 1.33.0

## Secrets Management

- SOPS configuration in `.sops.yaml` using AGE encryption
- Encrypted secrets: `infrastructure/controllers/cert-manager/secret.sops.yaml`
- Runtime secrets: ExternalSecret CRs pulling from Doppler
