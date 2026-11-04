# Kubernetes cho URL Shortener — thực hành trên VMware sau Compose/AWS

Đây là chặng học tiếp sau implementation guide. Mục tiêu đầu tiên: đưa backend/frontend lên Kubernetes bằng đúng image đã qua CI, hiểu request đi đâu, thực hành probes, cập nhật và phục hồi release. Dùng kind: Kubernetes node chạy trong Docker trên Ubuntu VMware. Không cần tài khoản AWS cho bài này.

## 1. Phạm vi và điều kiện

```text
Windows http://localhost:18080
  → SSH tunnel → VMware localhost:18080
  → kubectl port-forward → Service frontend → Pod frontend/Nginx
  → Service app → Pod backend
  → Service + EndpointSlice → PostgreSQL / Redis / Kafka trong Compose
```

Đây là mô hình lab kết hợp. Chưa có Ingress, HA, autoscaling hoặc data services chạy trong K8s. Một node kind vẫn phụ thuộc một VM. Phần 12 ghi các chặng tiếp theo thay vì gộp mọi công cụ vào lần deploy đầu.

- Đề xuất VM: 4 vCPU, 8–12 GB RAM, ổ 60 GB và ít nhất khoảng 20 GB trống. Đây là cấu hình khởi điểm để đo, không phải bảo đảm dung lượng đủ mọi workload. Máy Windows 32 GB RAM có thể dành mức này cho một VM nếu ứng dụng khác còn đủ RAM.
- Giữ nguyên EC2 đang dùng. Các thao tác dưới đây chạy trên VMware, không chạy trên EC2.
- Có `.env`, `release.env` chứa image GHCR digest đã chạy tốt và Docker login GHCR trên VMware.
- Windows sửa file/commit/push repo infra, VMware `git pull --ff-only` đúng nhánh sau khi merge. Không copy lại thư mục lab-kit.
- Có Docker Engine, curl, jq; user `thanh` dùng Docker không cần sudo.

**Trên VMware:**

```bash
cd ~/projects/url-shortener-infra
free -h
df -h /
nproc
docker info >/dev/null
bash scripts/backup.sh
```

Giữ backup và ghi lại image đang dùng trước khi đổi môi trường. Không chạy `docker compose down -v`, không FLUSHALL Redis. Dữ liệu lab dùng lại từ VM, không tự lấy dữ liệu EC2.

## 2. Tạo cluster kind và cài kubectl

**Trên VMware Ubuntu x86_64**, thực hiện từng khối và dừng nếu lệnh lỗi:

```bash
uname -m
cd ~/projects/url-shortener-infra
mkdir -p docs/evidence
curl -fL https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64 -o /tmp/urlshortener-kind
sudo install -m 0755 /tmp/urlshortener-kind /usr/local/bin/kind
kind version
kind create cluster --config k8s/kind.yml --wait 180s
```

Nếu cluster `urlshortener` đã tồn tại, không tạo/xóa lại; dùng `kind get clusters` kiểm tra. Cài kubectl cùng phiên bản Kubernetes với node vừa tạo:

```bash
KUBE_VERSION=$(docker exec urlshortener-control-plane kubelet --version | awk '{print $2}')
printf 'Kubernetes node version: %s\n' "$KUBE_VERSION"
curl -fL "https://dl.k8s.io/release/$KUBE_VERSION/bin/linux/amd64/kubectl" -o /tmp/urlshortener-kubectl
curl -fL "https://dl.k8s.io/release/$KUBE_VERSION/bin/linux/amd64/kubectl.sha256" -o /tmp/urlshortener-kubectl.sha256
echo "$(cat /tmp/urlshortener-kubectl.sha256)  /tmp/urlshortener-kubectl" | sha256sum --check
```

Chỉ cài binary khi checksum báo OK:

```bash
sudo install -m 0755 /tmp/urlshortener-kubectl /usr/local/bin/kubectl
kubectl config use-context kind-urlshortener
kubectl get nodes -o wide
kubectl version -o yaml > docs/evidence/k8s-version.yaml
```

Cần thấy node `Ready`. Context là cluster kubectl sẽ thao tác; luôn kiểm tra trước lệnh sửa/xóa. [kind Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/), [cài kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/).

## 3. Chuyển backend/frontend khỏi Compose, giữ data services

**Trên VMware, thư mục `~/projects/url-shortener-infra`:**

```bash
docker compose --env-file .env --env-file release.env -f compose/compose.yml stop app frontend
docker compose --env-file .env --env-file release.env -f compose/compose.yml -f compose/compose.kind.yml \
  up -d --wait --wait-timeout 300 postgres redis kafka
kubectl create namespace urlshortener --dry-run=client -o yaml | kubectl apply -f -
bash scripts/k8s-data-bridge.sh
kubectl -n urlshortener get services,endpointslices
```

Override nối data containers vào Docker network `kind`. Script tạo Kubernetes Service không selector và EndpointSlice chứa IP data containers; Pod gọi `postgres`, `redis`, `kafka` qua DNS trong namespace. Không dùng `localhost` trong Pod để gọi DB bên ngoài Pod.

Kafka quảng bá `kafka:9092`, tên này phải resolve qua Service trong namespace. Nếu recreate data container làm IP đổi, chạy lại bridge script. Đây là bridge thủ công dành cho lab, không dùng làm service discovery production.

## 4. Nạp đúng image đã qua CI vào kind

**Trên VMware:** xem `cat release.env`, rồi nhập nguyên hai giá trị digest khi được hỏi (không nhập `BACKEND_IMAGE=`):

```bash
read -rp 'Backend full GHCR digest: ' BE_REF
read -rp 'Frontend full GHCR digest: ' FE_REF
docker pull "$BE_REF"
docker pull "$FE_REF"
```

Nếu pull `unauthorized`, Docker login GHCR trên VMware trước như bài trước. Sau khi pull cả hai thành công:

```bash
docker tag "$BE_REF" urlshortener-backend:lab
docker tag "$FE_REF" urlshortener-frontend:lab
kind load docker-image urlshortener-backend:lab urlshortener-frontend:lab --name urlshortener
printf 'BACKEND_SOURCE=%s\nFRONTEND_SOURCE=%s\n' "$BE_REF" "$FE_REF" > docs/evidence/k8s-source-images.txt
```

Manifest hiện dùng hai tag local này với `IfNotPresent`; kind được nạp image sẵn nên không cần GHCR token trong cluster. Tag chỉ đặt tên lại image đã pull, không build lại. Không ghi tag `lab` là bằng chứng release bất biến; giữ digest nguồn ở file evidence. Bài cập nhật phía dưới dùng tag mới cho mỗi release để tránh cache nhầm.

## 5. Tạo ConfigMap và Secret

**Trên VMware:**

```bash
kubectl apply -f k8s/config.yml
kubectl -n urlshortener patch configmap app-config --type merge \
  -p '{"data":{"FRONTEND_URL":"http://localhost:18080","ALLOWED_ORIGINS":"http://localhost:18080"}}'
bash scripts/k8s-secret.sh
kubectl -n urlshortener create configmap nginx-config --from-file=default.conf=compose/nginx.conf \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n urlshortener get configmaps,secrets
```

`app-config` chứa cấu hình thường; `app-secrets` chứa whitelist giá trị cần thiết từ `.env` VMware, không tự sinh mật khẩu DB mới. Script dành cho định dạng `.env` một dòng, không quote do bài lab tạo; không chạy với `bash -x`. Callback VNPay được đặt về URL lab mới; bài này không kiểm thử thanh toán thật.

Kubernetes Secret không có nghĩa dữ liệu đã được mã hóa an toàn; base64 không phải encryption. Không xuất Secret YAML vào Git/evidence, không chia sẻ kubeconfig. Sau khi đổi ConfigMap/Secret dùng qua biến môi trường, cần rollout restart app. Nginx mount ConfigMap bằng subPath cũng cần restart frontend khi thay config.

## 6. Deploy và kiểm tra

**Trên VMware:**

```bash
kubectl apply --dry-run=server -f k8s/app.yml
kubectl apply -f k8s/app.yml
kubectl -n urlshortener rollout status deployment/app --timeout=360s
kubectl -n urlshortener rollout status deployment/frontend --timeout=180s
kubectl -n urlshortener get pods,services -o wide
```

Cần thấy backend và frontend `1/1 Running`. Nếu không, xem phần 10; không chạy lại apply liên tục để chữa lỗi.

Mở **terminal VMware thứ nhất**, giữ lệnh sau chạy:

```bash
kubectl -n urlshortener port-forward --address 127.0.0.1 service/frontend 18080:80
```

Trong **terminal VMware thứ hai**:

```bash
cd ~/projects/url-shortener-infra
curl --fail http://127.0.0.1:18080/healthz
bash scripts/smoke.sh run http://127.0.0.1:18080
```

Nếu VM chưa có `.smoke.json`, chạy `bash scripts/smoke.sh init http://127.0.0.1:18080` một lần trước `run`. Không dùng fixture EC2 với DB VM.

**Trên Windows PowerShell**, mở tunnel rồi giữ cửa sổ đó:

```powershell
ssh -L 18080:127.0.0.1:18080 thanh@192.168.40.100
```

Thay IP nếu VMware đã đổi. Mở trình duyệt `http://localhost:18080`, thử đăng nhập, tạo link và redirect. Cách truy cập đầu tiên dùng port-forward để học Service trước; chưa cần Ingress/controller hoặc mở cổng VM cho toàn LAN.

## 7. Hiểu probes và giới hạn trước khi tăng replicas

Trong `k8s/app.yml`:

| Thành phần | Ý nghĩa |
|---|---|
| Deployment | Duy trì số Pod và quản lý revision khi cập nhật |
| Service | Địa chỉ ổn định trước các Pod thay đổi IP |
| startupProbe | Cho app thời gian khởi động trước khi bật readiness/liveness |
| readinessProbe | Pod chưa Ready sẽ không nhận traffic mới qua Service |
| livenessProbe | Thất bại đủ số lần thì container bị restart |
| requests / limits | Yêu cầu tài nguyên để scheduler xếp Pod, giới hạn sử dụng container |

Probe backend dùng management port 8081 và các endpoint Actuator đã bật ở bài Compose. Không dùng health tổng phụ thuộc DB làm liveness để tránh restart hàng loạt khi DB gián đoạn. Readiness mặc định không tự bảo đảm mọi dependency khỏe; smoke test kiểm tra nghiệp vụ riêng. [Kubernetes probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/).

Giữ backend 1 replica lúc đầu. Trước khi scale backend cần kiểm tra seeder chạy nhiều instance, Kafka consumer groups và cơ chế tạo mã/idempotency. Scale frontend là bài đơn giản hơn:

```bash
kubectl -n urlshortener scale deployment/frontend --replicas=2
kubectl -n urlshortener rollout status deployment/frontend --timeout=180s
kubectl -n urlshortener get pods -l app=frontend -o wide
```

Hai Pod trên cùng một VM không tạo HA khi VM chết. Port-forward không phải bộ cân bằng tải production và có thể ngắt khi Pod nó chọn bị thay; chạy lại port-forward khi cần.

## 8. Tự phục hồi và quan sát

**Trên VMware**, chọn một frontend Pod từ lệnh get pods rồi xóa đúng tên đó:

```bash
kubectl -n urlshortener get pods -l app=frontend
kubectl -n urlshortener delete pod TEN_FRONTEND_POD
kubectl -n urlshortener get pods -l app=frontend -w
```

`TEN_FRONTEND_POD` là chỗ giữ chỗ, phải thay. Quan sát Deployment tạo Pod thay thế để đủ replicas; Ctrl+C thoát watch. Nếu mất port-forward, chạy lại phần 6 rồi chạy smoke. Ghi thời gian Pod mới Ready, không suy ra người dùng không gián đoạn chỉ từ trạng thái Running.

## 9. Deploy image mới, tạo lỗi rồi rollback

Lấy frontend digest mới đã qua CI. **Trên VMware**:

```bash
read -rp 'New frontend full GHCR digest: ' NEW_FE_REF
docker pull "$NEW_FE_REF"
docker tag "$NEW_FE_REF" urlshortener-frontend:k8s-v2
kind load docker-image urlshortener-frontend:k8s-v2 --name urlshortener
kubectl -n urlshortener set image deployment/frontend frontend=urlshortener-frontend:k8s-v2
kubectl -n urlshortener rollout status deployment/frontend --timeout=180s
kubectl -n urlshortener rollout history deployment/frontend
```

Mỗi lần cập nhật dùng tag local mới, không tái sử dụng `k8s-v2` cho nội dung khác. Restart port-forward nếu bị ngắt; chạy smoke/UI lại. Chưa chứng minh zero downtime bằng thao tác này.

Thử lỗi image không tồn tại:

```bash
kubectl -n urlshortener set image deployment/frontend frontend=urlshortener-frontend:missing-lab-image
kubectl -n urlshortener rollout status deployment/frontend --timeout=90s
kubectl -n urlshortener get pods -l app=frontend
kubectl -n urlshortener get events --sort-by=.metadata.creationTimestamp
```

Lệnh rollout timeout là lỗi có chủ đích; cần thấy Pod mới `ErrImagePull`/`ImagePullBackOff`. Kubernetes không tự rollback chỉ vì rollout thất bại. Phục hồi:

```bash
kubectl -n urlshortener rollout undo deployment/frontend
kubectl -n urlshortener rollout status deployment/frontend --timeout=180s
```

Kiểm tra image và smoke/UI sau phục hồi. Rollback Deployment không hoàn tác DB migration hay ConfigMap/Secret. `kubectl apply -f k8s/app.yml` lần nữa sẽ đưa image/replicas về giá trị trong file; các lệnh set image/scale là bài tập imperative. Chặng Helm/GitOps sẽ đưa trạng thái mong muốn về Git.

## 10. Debug theo triệu chứng

**Trên VMware:**

```bash
kubectl -n urlshortener get pods -o wide
kubectl -n urlshortener describe pod TEN_POD
kubectl -n urlshortener logs deployment/app --tail=100
kubectl -n urlshortener get events --sort-by=.metadata.creationTimestamp
kubectl -n urlshortener get endpointslices
```

| Triệu chứng | Kiểm tra |
|---|---|
| Pending | Describe events: thiếu RAM/CPU hoặc scheduler chưa chạy |
| ImagePullBackOff | Đúng tag đã kind load, đúng cluster, imagePullPolicy |
| CrashLoopBackOff | Logs và `kubectl logs TEN_POD -n urlshortener --previous`; DB/Secret/Kafka |
| OOMKilled | Describe last state, memory limits và JVM; đo trước khi tăng |
| Probe 404/403 | Image backend có Actuator profile lab và SecurityConfig đúng chưa |
| DB timeout | Data containers healthy; EndpointSlice có IP hiện tại trên network kind |
| Nginx 502 | Backend Ready? Service app có endpoints? Nginx upstream đúng tên/port? |
| UI lỗi origin | Truy cập đúng localhost:18080, ConfigMap URL đã patch, app đã restart |

Không lưu log chứa token/mật khẩu vào evidence. `kubectl top` cần metrics-server; bài hiện tại chưa cài nên chưa dùng top/HPA.

## 11. Bằng chứng và quay lại Compose

**Trên VMware**, lưu bằng chứng không chứa Secret:

```bash
kubectl -n urlshortener get pods,services -o wide > docs/evidence/k8s-resources.txt
kubectl -n urlshortener rollout history deployment/frontend > docs/evidence/k8s-rollout.txt
```

Kèm screenshot UI, smoke PASS, log lỗi image và rollback, một incident report theo template đang có. Trong CV chỉ ghi đã deploy app lên kind, dùng probes/config/secrets, thử phục hồi và rollout; data services vẫn ở Compose.

Muốn tạm quay lại Compose, dừng port-forward, **scale cả hai Deployment về 0 trước**:

```bash
kubectl -n urlshortener scale deployment/app deployment/frontend --replicas=0
kubectl -n urlshortener get pods
```

Đợi app/frontend Pod không còn (không còn consumer K8s xử lý dữ liệu), sau đó:

```bash
cd ~/projects/url-shortener-infra
docker compose --env-file .env --env-file release.env -f compose/compose.yml up -d --wait --wait-timeout 300 app frontend
bash scripts/smoke.sh run http://127.0.0.1:8080
```

Nếu muốn xóa cluster lab sau khi lưu evidence: kiểm tra context/name rồi `kind delete cluster --name urlshortener`. Lệnh đó xóa tài nguyên Kubernetes và Secret trong cluster; không xóa named volumes PostgreSQL/Redis/Kafka của Compose. Không coi dữ liệu bên trong kind là backup bền vững.

## 12. Các chặng tiếp theo sau khi bài này PASS

| Thứ tự | Bài thực hành | Điều kiện hoàn thành |
|---|---|---|
| 1 | Manifest, Service, probes, rollback (tài liệu này) | Tái tạo được, smoke/UI PASS, tự debug được lỗi |
| 2 | Helm chart và values theo môi trường | Image/config khai báo trong Git, render/lint, install/upgrade/rollback |
| 3 | PVC/StatefulSet với PostgreSQL lab riêng | DB mới trong K8s, dữ liệu còn sau recreate Pod, backup/restore thật; không ghi đè DB Compose |
| 4 | Gateway API hoặc Ingress + controller còn được duy trì | Truy cập qua hostname, giải thích routing/TLS và khác port-forward |
| 5 | Monitoring, requests/limits, metrics-server/HPA | Đo tài nguyên, giải thích CPU request và hành vi scale bằng workload |
| 6 | RBAC, NetworkPolicy với CNI hỗ trợ | Chứng minh quyền/truy cập bị chặn đúng, không chỉ apply YAML |
| 7 | CI kiểm tra manifest/chart, CD/GitOps | Release truy về digest, secrets không nằm trong Git, rollback có bằng chứng |

Không deploy workflow GitHub-hosted runner thẳng vào API private của kind nếu chưa thiết kế đường truy cập. Chỉ mở bài cloud Kubernetes sau khi tính chi phí và kiểm tra tính năng tài khoản; không cần EKS để hoàn thành chặng thực hành hiện tại.

Phạm vi kiểm chứng của bộ file: mới kiểm tra cấu hình/cú pháp local; người học cần chạy kind và các bài lỗi trên VMware để thu kết quả thực tế.
