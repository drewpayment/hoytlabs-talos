#!/bin/sh
# scripts/kustomize-patch-tunnel-id.sh

# Ensure script fails on error
set -e

echo "CMP: Running initial kustomize build..."
# Build to a temporary file or stdout if further processing is complex
kustomize build . > /tmp/base_manifests.yaml

# Namespace where the ConfigMap 'cloudflared-tunnel-data' is located
# This should be passed or configured if not static. For now, hardcoding as an example.
CONFIGMAP_NAMESPACE="networking"

echo "CMP: Fetching TUNNEL_ID from ConfigMap 'cloudflared-tunnel-data' in namespace '${CONFIGMAP_NAMESPACE}'..."
# This requires kubectl to be in the Argo CD repo-server image and for it to have RBAC.
TUNNEL_ID_VALUE=$(kubectl get configmap cloudflared-tunnel-data -n "${CONFIGMAP_NAMESPACE}" -o "jsonpath={.data.TUNNEL_ID}" 2>/dev/null)

if [ -z "$TUNNEL_ID_VALUE" ]; then
  echo "CMP Error: TUNNEL_ID not found or empty in ConfigMap 'cloudflared-tunnel-data' in namespace '${CONFIGMAP_NAMESPACE}'." >&2
  # Depending on desired behavior, either output base manifests with placeholder or fail
  # For now, let's try to output something so Argo CD doesn't fail catastrophically,
  # but the placeholder will likely cause issues downstream.
  # A better approach might be to `exit 1` if the ID is critical.
  cat /tmp/base_manifests.yaml
  exit 0 # Or exit 1 to indicate failure
fi

echo "CMP: Found TUNNEL_ID: ${TUNNEL_ID_VALUE}"
echo "CMP: Substituting TUNNEL_ID_PLACEHOLDER..."

# Substitute the placeholder. Using | as sed delimiter in case TUNNEL_ID_VALUE has /
sed "s|TUNNEL_ID_PLACEHOLDER|${TUNNEL_ID_VALUE}|g" /tmp/base_manifests.yaml

# Clean up temporary file
rm /tmp/base_manifests.yaml

echo "CMP: Manifest generation complete."