# Istio 零信任與金絲雀發布 Lab — 操作筆記

情境模擬銀行內部系統：`payments`（付款服務）只能讓 `frontend` 呼叫，服務之間一律走 mTLS 加密；新版 `v2` 先放一小部分流量測試，沒問題再全量，出事一行指令就能退回 `v1`。

| 角色 | Namespace | 有沒有 sidecar | 用途 |
|---|---|---|---|
| payments-v1 / v2 | bank | 有 | 被保護、被金絲雀發布的服務 |
| frontend | bank | 有 | 唯一被允許的呼叫者 |
| intruder | bank | 有 | 在網格內、但身分不對的工作負載 |
| legacy-client | legacy | 沒有 | 網格外、只會講明文 HTTP 的舊系統 |

---

## 0. 環境準備（Mac）

```bash
brew install kind kubectl istioctl
# Docker Desktop 要先開著，資源建議 4 CPU / 8 GB
git clone https://github.com/roseweigee/istio-zero-trust-lab.git
cd istio-zero-trust-lab
```

## 1. 建立叢集、安裝 Istio、部署應用

```bash
bash scripts/setup.sh
```

腳本做了四件事：

1. `kind create cluster --name istio-lab`：建立本機 Kubernetes 叢集。
2. `istioctl install --set profile=minimal -y`：只裝控制平面 istiod，不裝 ingress gateway，lab 用不到。
3. 套用 `00-namespaces.yaml`：`bank` 有標籤 `istio-injection=enabled`，之後在這裡建立的 Pod 都會自動被注入 Envoy sidecar（`istio-proxy` 容器）；`legacy` 沒有。
4. 套用 `01-apps.yaml`，並等待所有 Deployment 就緒。

**確認 sidecar：** 腳本最後會列出每個 Pod 的容器。`bank` 裡的 Pod 會看到 `payments istio-proxy`，`legacy` 只有 `curl`。

> 注意：namespace 要先貼標籤再部署 Pod。如果順序反了，要 `kubectl rollout restart` 讓 Pod 重建才會被注入。

## 2. 一鍵驗證全部步驟

```bash
bash scripts/verify.sh
```

每一步都會自動判斷結果，全部通過最後會印出 `All checks passed`。下面拆開說明每一步；想自己手動練習，可以照每段的指令一個一個打。

手動測試用的指令（`000` 代表連線本身被拒絕或中斷）：

```bash
# 從 frontend 呼叫
kubectl exec -n bank deploy/frontend -c curl -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://payments.bank.svc.cluster.local/api/balance

# 從網格外的 legacy-client 呼叫
kubectl exec -n legacy deploy/legacy-client -c curl -- \
  curl -s -o /dev/null -m 5 -w '%{http_code}\n' http://payments.bank.svc.cluster.local/api/balance
```

---

### Step 1 — 基準狀態

什麼政策都沒套。Istio 預設 mTLS 是 **PERMISSIVE**：網格內的呼叫自動走 mTLS，但也接受明文。

| 呼叫 | 結果 |
|---|---|
| frontend → payments | 200 |
| legacy-client（明文）→ payments | 200 |

PERMISSIVE 的用途是**漸進式導入**：舊系統還沒進網格前不會被擋掉。

### Step 2 — mTLS STRICT（`10-mtls-strict.yaml`）

```yaml
kind: PeerAuthentication
metadata: {name: default, namespace: bank}
spec:
  mtls: {mode: STRICT}
```

| 呼叫 | 結果 |
|---|---|
| legacy-client（明文）→ payments | **000**（連線被重置） |
| frontend → payments | 200 |

重點：
- 是 `payments` 旁邊的 sidecar 拒絕明文連線，應用程式本身完全沒改。
- frontend 的應用程式送的還是明文 HTTP，是它旁邊的 sidecar 自動升級成 mTLS。
- 憑證由 istiod 自動簽發和輪換，身分格式是 SPIFFE ID：`spiffe://cluster.local/ns/bank/sa/frontend`，也就是「哪個 namespace 的哪個 ServiceAccount」。

### Step 3 — 預設拒絕（`20-authz-deny-all.yaml`）

```yaml
kind: AuthorizationPolicy
metadata: {name: deny-all, namespace: bank}
spec: {}
```

空的 spec 代表「套用到這個 namespace 所有工作負載，但什麼都不允許」。

| 呼叫 | 結果 |
|---|---|
| frontend → payments | **403**（`RBAC: access denied`） |

零信任的起點：先全部關掉，再一條一條開。

### Step 4 — 最小權限（`21-authz-allow-frontend.yaml`）

```yaml
selector: {matchLabels: {app: payments}}
action: ALLOW
rules:
  - from: [{source: {principals: ["cluster.local/ns/bank/sa/frontend"]}}]
    to:   [{operation: {methods: ["GET"], paths: ["/api/*"]}}]
```

| 呼叫 | 結果 | 原因 |
|---|---|---|
| frontend GET /api/balance | 200 | 身分、方法、路徑都符合 |
| frontend POST /api/balance | 403 | 方法不允許 |
| frontend GET /admin | 403 | 路徑不允許 |
| intruder GET /api/balance | 403 | 身分不對 |
| intruder 偽造 `x-forwarded-client-cert` header | 403 | 身分來自 mTLS 憑證，不是 header |

重點：
- `principals` 一定要搭配 mTLS STRICT 才有意義，因為身分是從對方的憑證取出來的。
- 比 NetworkPolicy 更細：NetworkPolicy 只看 IP 和 port（L3/L4），AuthorizationPolicy 看得到身分、HTTP 方法和路徑（L7）。兩者可以疊加使用。

### Step 5 — 金絲雀發布（`30-destinationrule.yaml`、`31-vs-canary-90-10.yaml`）

`DestinationRule` 用 Pod 的 `version` 標籤定義兩個子集 `v1`、`v2`；`VirtualService` 決定流量怎麼分：

```yaml
http:
  - match: [{headers: {x-canary: {exact: "true"}}}]
    route: [{destination: {host: payments, subset: v2}}]
  - route:
      - {destination: {host: payments, subset: v1}, weight: 90}
      - {destination: {host: payments, subset: v2}, weight: 10}
```

| 測試 | 結果 |
|---|---|
| 帶 `x-canary: true` 送 20 次 | 20/20 到 v2 |
| 一般請求送 200 次 | 約 20 次到 v2（約 10%） |

重點：
- `payments` Service 的 selector 只有 `app: payments`，同時選到 v1、v2；如果沒有 Istio，流量會按 Pod 數平均分。Istio 讓比例和 Pod 數量脫鉤：v2 只有 1 個 Pod 也能只吃 10%。
- header 路由讓測試人員先在正式環境驗證新版，一般使用者完全不受影響。
- 規則由上往下比對，先符合的先用，所以 header 規則要放在權重規則前面。

### Step 6 — 全量切換（`32-vs-v2-100.yaml`）

v2 改成 100%，送 50 次全部到 v2。

### 演練 — 一鍵回滾（`33-vs-rollback-v1.yaml`）

v1 改成 100%，送 50 次全部回到 v1。只改路由規則，不用重新部署，v2 的 Pod 還在，隨時可以再切回去。

---

## 3. 好用的觀察指令

```bash
istioctl analyze -n bank                        # 檢查設定有沒有錯
istioctl proxy-status                           # 每個 sidecar 是否已同步到最新設定
istioctl proxy-config routes deploy/frontend -n bank   # frontend 的 sidecar 實際拿到的路由
kubectl get peerauthentication,authorizationpolicy,destinationrule,virtualservice -n bank
kubectl logs -n bank deploy/payments-v1 -c istio-proxy --tail=20   # 看被拒絕的請求
```

## 4. 對應到 OpenShift

OpenShift Service Mesh 3 是以上游 Istio 為基礎，透過 Sail Operator 安裝。本 lab 的 `PeerAuthentication`、`AuthorizationPolicy`、`DestinationRule`、`VirtualService` 寫法完全通用；不同的地方在安裝方式（Operator 而不是 `istioctl`），以及哪些 namespace 要加入網格。

## 5. 常見問題

| 狀況 | 原因與處理 |
|---|---|
| Pod 只有一個容器，沒有 `istio-proxy` | namespace 沒貼 `istio-injection=enabled`，或貼標籤前就建好了 Pod → 補標籤後 `kubectl rollout restart deploy -n bank` |
| 套用政策後結果沒有馬上變 | istiod 推設定到 sidecar 需要幾秒，`verify.sh` 會自動重試最多 60 秒 |
| 拿到 `000` | 連線層級就被拒絕（例如明文打 STRICT），不是 HTTP 錯誤 |
| 拿到 `403 RBAC: access denied` | AuthorizationPolicy 擋下的；用 `istioctl x authz check deploy/payments-v1 -n bank` 看生效的規則 |
| Mac 上 kind 建不起來 | 確認 Docker Desktop 已啟動，資源給夠 |

## 6. 收尾

```bash
bash scripts/teardown.sh
```

---

## 7. 面試可能被問到的問題

**Q1：為什麼需要 Service Mesh？不能在程式裡做就好嗎？**
可以，但每個服務、每種語言都要各自實作 TLS、身分驗證、重試和流量分流，而且改一次要全部重新部署。Service Mesh 把這些橫切關注點下沉到 sidecar，應用只寫商業邏輯，政策用 YAML 統一管理。

**Q2：PERMISSIVE 和 STRICT 差在哪？上線時怎麼切？**
PERMISSIVE 同時接受 mTLS 和明文，STRICT 只接受 mTLS。導入時先全部 PERMISSIVE，等所有呼叫方都進網格、用 `istioctl` 或監控確認沒有明文流量後，再逐個 namespace 切 STRICT。這個 lab 的 Step 1 → Step 2 就是在模擬這個過程。

**Q3：AuthorizationPolicy 跟 NetworkPolicy 怎麼分工？**
NetworkPolicy 在 L3/L4，看 IP 和 port，由 CNI 執行；AuthorizationPolicy 在 L7，看服務身分、HTTP 方法和路徑，由 sidecar 執行。銀行環境建議兩層都做：NetworkPolicy 擋網段，AuthorizationPolicy 管誰能呼叫哪支 API。

**Q4：身分從哪裡來？會不會被偽造？**
istiod 依 ServiceAccount 簽發 SPIFFE 格式的憑證，mTLS 握手時驗證。這個 lab 有測：intruder 偽造 `x-forwarded-client-cert` header 還是被拒絕，因為判斷依據是憑證，不是 header。

**Q5：金絲雀發布出問題怎麼辦？**
改 VirtualService 權重就能回滾，不需要重新部署，幾秒內生效。這個 lab 有演練：從 v2 100% 一次 apply 切回 v1 100%。實務上會搭配錯誤率、延遲的監控，或用 Argo Rollouts 這類工具依指標自動推進或回滾。

**Q6：air-gapped 銀行環境要注意什麼？**
Istio 映像檔要先 mirror 到內部 registry；憑證可以改接銀行自己的 root CA；JWT 驗證不能連外部 JWKS URI，要改成把公鑰直接寫在設定裡；遙測資料留在內部。

**Q7：你實際做過嗎？**
工作上沒有導入過 Service Mesh；這是我自己做的 lab，每一步都用腳本驗證，並在 GitHub Actions 上自動跑，所以 mTLS、授權、金絲雀這幾個機制我都有實際操作過，也知道哪裡容易出錯。
