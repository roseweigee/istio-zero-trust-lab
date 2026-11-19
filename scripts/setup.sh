#!/usr/bin/env bash
# Create a kind cluster, install Istio (minimal profile = istiod only) and deploy the apps.
# Usage: scripts/setup.sh            (needs docker, kind, kubectl, istioctl on PATH)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

CLUSTER="${CLUSTER:-istio-lab}"

say "1/4 kind cluster '$CLUSTER'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "  cluster already exists – reusing it"
else
  kind create cluster --name "$CLUSTER" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

say "2/4 Istio control plane (istiod)"
istioctl version --remote=false
istioctl install --set profile=minimal -y
kubectl -n istio-system rollout status deploy/istiod --timeout=180s

say "3/4 namespaces + apps"
kubectl apply -f "$M/00-namespaces.yaml"
kubectl apply -f "$M/01-apps.yaml"
for d in payments-v1 payments-v2 frontend intruder; do
  kubectl -n bank rollout status "deploy/$d" --timeout=180s
done
kubectl -n legacy rollout status deploy/legacy-client --timeout=180s

say "4/4 sidecar check"
kubectl get pods -n bank -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name'
kubectl get pods -n legacy -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name'
echo
echo "Pods in 'bank' should list istio-proxy next to the app; 'legacy' should not."
