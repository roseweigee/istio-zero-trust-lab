#!/usr/bin/env bash
# Shared helpers for the lab scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$ROOT/manifests"
PASS=0

say()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔ %s\033[0m\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31m✘ %s\033[0m\n' "$*"; exit 1; }

# call <namespace> <deployment> <method> <path> [extra curl args...]
# Prints the HTTP status code. "000" means the connection itself was refused/reset.
call() {
  local ns=$1 deploy=$2 method=$3 path=$4; shift 4
  kubectl exec -n "$ns" "deploy/$deploy" -c curl -- \
    curl -s -o /dev/null -m 5 -w '%{http_code}' -X "$method" "$@" \
    "http://payments.bank.svc.cluster.local$path" 2>/dev/null || true
}

# expect <code> <description> <call args...>
# Retries for up to 60 s because Istio pushes new config to the proxies asynchronously.
expect() {
  local want=$1 desc=$2; shift 2
  local got=""
  for _ in $(seq 1 30); do
    got="$(call "$@")"
    [[ "$got" == "$want" ]] && { ok "$desc → $got"; return 0; }
    sleep 2
  done
  fail "$desc → expected $want, got $got"
}

# count_v2 <n> [extra curl args...]  – send n requests from frontend, print how many hit v2
count_v2() {
  local n=$1; shift
  kubectl exec -n bank deploy/frontend -c curl -- sh -c \
    "for i in \$(seq 1 $n); do curl -s -m 5 $* http://payments.bank.svc.cluster.local/api/balance; echo; done" \
    | grep -c 'v2' || true
}
