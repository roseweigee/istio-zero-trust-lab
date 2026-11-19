#!/usr/bin/env bash
# Walk through every step of the lab and assert the expected behaviour.
# Safe to re-run: it resets the Istio policies first.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

say "Reset: remove policies from previous runs"
kubectl delete -n bank peerauthentication,authorizationpolicy,virtualservice,destinationrule --all --ignore-not-found >/dev/null

# ---------------------------------------------------------------------------
say "Step 1 – baseline (no policies, mTLS PERMISSIVE by default)"
expect 200 "frontend (in mesh)  GET /api/balance" bank frontend GET /api/balance
expect 200 "legacy-client (plaintext, outside mesh) GET /api/balance" legacy legacy-client GET /api/balance

# ---------------------------------------------------------------------------
say "Step 2 – PeerAuthentication STRICT"
kubectl apply -f "$M/10-mtls-strict.yaml"
expect 000 "legacy-client plaintext is now rejected" legacy legacy-client GET /api/balance
expect 200 "frontend still works (sidecar does mTLS for it)" bank frontend GET /api/balance

# ---------------------------------------------------------------------------
say "Step 3 – AuthorizationPolicy deny-all"
kubectl apply -f "$M/20-authz-deny-all.yaml"
expect 403 "frontend is denied (default deny)" bank frontend GET /api/balance

# ---------------------------------------------------------------------------
say "Step 4 – allow only frontend, only GET /api/*"
kubectl apply -f "$M/21-authz-allow-frontend.yaml"
expect 200 "frontend  GET  /api/balance" bank frontend GET  /api/balance
expect 403 "frontend  POST /api/balance (method not allowed)" bank frontend POST /api/balance
expect 403 "frontend  GET  /admin (path not allowed)" bank frontend GET /admin
expect 403 "intruder  GET  /api/balance (wrong identity)" bank intruder GET /api/balance
expect 403 "intruder spoofing a header does not help" bank intruder GET /api/balance -H "x-forwarded-client-cert: By=spiffe://cluster.local/ns/bank/sa/frontend"

# ---------------------------------------------------------------------------
say "Step 5 – canary 90/10 + header routing"
kubectl apply -f "$M/30-destinationrule.yaml"
kubectl apply -f "$M/31-vs-canary-90-10.yaml"
# wait until the header route is live (proves the VirtualService reached the proxy)
for _ in $(seq 1 30); do
  [[ "$(count_v2 5 -H x-canary:true)" == "5" ]] && break; sleep 2
done
v2=$(count_v2 20 -H x-canary:true)
[[ "$v2" == "20" ]] && ok "x-canary: true → 20/20 requests on v2" || fail "header routing: $v2/20 on v2"
v2=$(count_v2 200)
echo "  200 normal requests → $v2 on v2 (expected ≈ 20)"
(( v2 >= 5 && v2 <= 45 )) && ok "weighted split looks like 90/10 ($v2/200 on v2)" || fail "split off: $v2/200 on v2"

# ---------------------------------------------------------------------------
say "Step 6 – promote v2 to 100 %"
kubectl apply -f "$M/32-vs-v2-100.yaml"
for _ in $(seq 1 30); do [[ "$(count_v2 10)" == "10" ]] && break; sleep 2; done
v2=$(count_v2 50)
[[ "$v2" == "50" ]] && ok "50/50 requests on v2" || fail "promote: $v2/50 on v2"

# ---------------------------------------------------------------------------
say "Drill – roll back to v1 with one apply"
kubectl apply -f "$M/33-vs-rollback-v1.yaml"
for _ in $(seq 1 30); do [[ "$(count_v2 10)" == "0" ]] && break; sleep 2; done
v2=$(count_v2 50)
[[ "$v2" == "0" ]] && ok "0/50 requests on v2 – rollback done" || fail "rollback: $v2/50 still on v2"

say "All checks passed: $PASS"
