#!/usr/bin/env bash
# Delete the whole kind cluster.
set -euo pipefail
CLUSTER="${CLUSTER:-istio-lab}"
kind delete cluster --name "$CLUSTER"
