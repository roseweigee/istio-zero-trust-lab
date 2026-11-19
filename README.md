# istio-zero-trust-lab

![lab](https://github.com/roseweigee/istio-zero-trust-lab/actions/workflows/lab.yml/badge.svg)

A small, fully automated Istio lab on a local **kind** cluster: zero-trust service-to-service
security (mTLS STRICT + AuthorizationPolicy) and a canary release with instant rollback.
Every step is asserted by `scripts/verify.sh`, and GitHub Actions runs the whole lab on each push.

The scenario mirrors a bank: a `payments` service must only be reachable by `frontend`,
over mutual TLS, while a new version `v2` is released to a small share of traffic first.

| Step | What is applied | What is proven |
|---|---|---|
| 1 Baseline | nothing (Istio default = PERMISSIVE) | in-mesh and plaintext callers both get 200 |
| 2 mTLS | `PeerAuthentication` STRICT | plaintext caller outside the mesh is rejected; in-mesh caller still 200 |
| 3 Default deny | empty `AuthorizationPolicy` | every request gets 403 |
| 4 Least privilege | allow `sa/frontend`, `GET /api/*` only | frontend GET 200; POST, `/admin`, other identity and a spoofed header all 403 |
| 5 Canary | `DestinationRule` subsets + `VirtualService` 90/10, header `x-canary: true` → v2 | header 20/20 on v2; 200 normal requests ≈ 10 % on v2 |
| 6 Promote | `VirtualService` 100 % v2 | 50/50 on v2 |
| Drill | `VirtualService` 100 % v1 | rollback with one `kubectl apply`, no redeploy |

## Run it

Requires Docker, `kind`, `kubectl`, `istioctl` (`brew install kind kubectl istioctl` on macOS).

```bash
bash scripts/setup.sh      # kind cluster + istiod + apps (~3–5 min)
bash scripts/verify.sh     # walks all steps and asserts them
bash scripts/teardown.sh   # delete the cluster
```

Step-by-step walkthrough in Traditional Chinese: [docs/NOTES.zh-TW.md](docs/NOTES.zh-TW.md).

## Layout

```
manifests/   00 namespaces · 01 apps · 10 mTLS · 20–21 authz · 30–33 traffic
scripts/     setup.sh · verify.sh · teardown.sh · lib.sh
.github/     CI: kubeconform lint → kind → setup → verify (twice, to prove re-runs are clean)
```

## Mapping to OpenShift

OpenShift Service Mesh 3 is based on upstream Istio (installed through the Sail Operator), so the
`PeerAuthentication`, `AuthorizationPolicy`, `DestinationRule` and `VirtualService` objects here
apply unchanged. What differs on OpenShift is the installation (Operator instead of `istioctl`)
and which namespaces are enrolled in the mesh.
