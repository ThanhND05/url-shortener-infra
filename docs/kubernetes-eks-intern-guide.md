# URL Shortener: Kubernetes trên VMware → Helm → Amazon EKS, mức intern

Ngày soạn: 04/11/2026. Đọc theo thứ tự. Mỗi khối lệnh ghi rõ chạy trên máy nào; dừng sửa khi đầu ra không đúng. Không copy các lệnh tạo/xóa cloud rồi chạy một lượt.

Đây là guide tiếp nối dự án Compose/EC2 đã hoàn thành. Guide này thay cho bài kind bridge cũ nếu bạn muốn đưa **toàn bộ stack lab** lên Kubernetes: frontend, backend, PostgreSQL, Redis và Kafka. Dùng database lab mới, không chuyển dữ liệu Compose/EC2. Code chart và cấu hình đi kèm trong repo infra; cuối bản guide xuất tại workspace có phụ lục toàn bộ code để đối chiếu.

## 0. Kết quả cần đạt và phần chưa cần học

Bạn sẽ biết tạo cluster, dùng kubectl, deploy Helm chart, lấy image đã qua CI theo digest, quản lý config/secret, đọc probe/resource/event, thử persistence và rollback, rồi triển khai cùng chart lên EKS với EBS và NLB.

Mức intern ở đây chưa yêu cầu tự quản lý control plane bằng kubeadm, Kafka HA/operator, service mesh, Argo CD, Vault hoặc database production. PostgreSQL/Redis/Kafka mỗi loại một replica, dữ liệu test; không gọi hệ thống là production HA. Không scale StatefulSet data services để giả lập HA.

| Môi trường | Kubernetes | Dữ liệu | Cách truy cập |
|---|---|---|---|
| VMware | kind, một node container | PVC trên storage local của kind | port-forward + SSH tunnel |
| AWS | EKS managed control plane + 2 managed worker nodes | PVC dùng EBS CSI | internet-facing NLB, giới hạn IP người học |

```text
Windows: VS Code/GitHub/trình duyệt
  ↓ SSH
Ubuntu VMware: Docker, kind, kubectl, Helm, AWS CLI, eksctl
  ├─ kind → Helm release → app + data lab riêng
  └─ AWS API → EKS cluster mới → cùng Helm chart
                                     ↓
Trình duyệt → NLB:80 → frontend/Nginx → app Service:8080
                                        ├─ postgres:5432 → PVC/EBS
                                        ├─ redis:6379 → PVC/EBS
                                        └─ kafka:9092 → PVC/EBS
```

NLB làm cân bằng tải TCP, Nginx trong frontend làm reverse proxy `/api/` và `/r/`. Bài này không cần Ingress controller để app truy cập được. EKS nằm ở VPC riêng do eksctl tạo; không tái sử dụng VPC Terraform chỉ có một subnet của EC2 cũ.

## 1. Quy ước, cấu hình VM và lưu code

- VM đề xuất 4 vCPU, 10–12 GB RAM, ổ 60–80 GB và còn ít nhất khoảng 20 GB. Windows của bạn có 32 GB RAM, cân đối phần còn lại cho Windows/IDE.
- Giữ backend image có profile `lab`, Actuator port 8081, probes và SecurityConfig đã làm trước. CI backend/frontend phải xanh.
- Chỉ dùng dữ liệu giả, giữ EC2 cũ làm mốc so sánh. Không sửa/ngắt dịch vụ EC2 trong bài này.
- `YOUR_*`, `REPLACE_*`, `TEN_POD` là chỗ phải thay; không phải giá trị để chạy nguyên.
- `.lab/` là dữ liệu riêng môi trường, đã gitignore. Không commit secret env, Docker login config, kubeconfig hoặc Helm rendered Secret. Base64 trong Kubernetes Secret không phải encryption.

**Windows PowerShell**, commit/push các file mới trong repo infra sau khi review:

```powershell
cd D:\privateProject\projects\url-shortener-infra
git status --short
git add charts k8s scripts/k8s-lab-env.sh docs/kubernetes-eks-intern-guide.md .github/workflows/k8s-chart-ci.yml .gitignore
git commit -m "feat: add intern Kubernetes and EKS lab"
git push
```

Nếu làm nhánh riêng thì merge PR vào main. **VMware:**

```bash
cd ~/projects/url-shortener-infra
git pull --ff-only
free -h
df -h /
nproc
docker info >/dev/null
```

Nếu thiếu tài nguyên, shutdown VM rồi chỉnh VMware settings. Không chỉ tăng virtual disk mà quên mở rộng partition/LVM/filesystem; `df -h /` mới là dung lượng Ubuntu dùng được.

## 2. Cài công cụ trên VMware

Mọi lệnh Bash trong guide, trừ khi ghi khác, chạy trong **SSH vào VMware user thanh**, thư mục `~/projects/url-shortener-infra`. Không chạy ở terminal EC2.

```bash
sudo apt-get update
sudo apt-get install -y curl jq unzip openssl
uname -m
mkdir -p .lab/tools docs/evidence/k8s
```

Ví dụ binary dành cho `x86_64`. Cài kind 0.33.0 theo [quick start chính thức](https://kind.sigs.k8s.io/docs/user/quick-start/):

```bash
curl -fL https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64 -o .lab/tools/kind
sudo install -m 0755 .lab/tools/kind /usr/local/bin/kind
kind version
```

Cài Helm 4.0.0, phiên bản dùng để kiểm tra chart trong tài liệu này:

```bash
cd ~/projects/url-shortener-infra/.lab/tools
curl -fLO https://get.helm.sh/helm-v4.0.0-linux-amd64.tar.gz
curl -fLO https://get.helm.sh/helm-v4.0.0-linux-amd64.tar.gz.sha256sum
sha256sum --check helm-v4.0.0-linux-amd64.tar.gz.sha256sum
```

Checksum OK rồi mới giải nén/cài:

```bash
tar -xzf helm-v4.0.0-linux-amd64.tar.gz
sudo install -m 0755 linux-amd64/helm /usr/local/bin/helm
helm version --short
cd ~/projects/url-shortener-infra
```

Helm là công cụ đóng gói/cập nhật manifest. Chart là source; values là cấu hình môi trường; release là một lần cài chart vào namespace. Không chứa password trong values của bài này.

## 3. Tạo kind, cài kubectl và chọn đúng context

Nếu Compose VM đang chạy, backup trước rồi dừng stack để nhường RAM. Stop giữ volumes; không `down -v`:

```bash
bash scripts/backup.sh
docker compose --env-file .env -f compose/compose.yml stop
kind get clusters
```

Nếu đã có cluster `urlshortener` từ bài cũ, giữ nó; bỏ lệnh create. Nếu chưa có:

```bash
kind create cluster --config k8s/kind.yml --wait 180s
```

Lấy phiên bản Kubernetes từ node rồi cài kubectl tương ứng:

```bash
KUBE_VERSION=$(docker exec urlshortener-control-plane kubelet --version | awk '{print $2}')
curl -fL "https://dl.k8s.io/release/$KUBE_VERSION/bin/linux/amd64/kubectl" -o .lab/tools/kubectl
curl -fL "https://dl.k8s.io/release/$KUBE_VERSION/bin/linux/amd64/kubectl.sha256" -o .lab/tools/kubectl.sha256
echo "$(cat .lab/tools/kubectl.sha256)  .lab/tools/kubectl" | sha256sum --check
```

Sau checksum OK:

```bash
sudo install -m 0755 .lab/tools/kubectl /usr/local/bin/kubectl
kubectl config use-context kind-urlshortener
kubectl get nodes -o wide
kubectl get storageclass
```

Cần node Ready và StorageClass `standard` dùng local-path. Context quyết định cluster lệnh sẽ sửa. Mọi lần đổi local/cloud đều kiểm tra `kubectl config current-context`.

Nếu bài cũ còn Deployment trong namespace `urlshortener`, scale chúng về 0 để không chạy consumer ngoài dự kiến:

```bash
kubectl get deployments -A
```

Chỉ khi thấy đúng Deployment cũ `app`, `frontend` trong namespace `urlshortener`, chạy:

```bash
kubectl -n urlshortener scale deployment/app deployment/frontend --replicas=0
```

Guide mới dùng namespace **urlshortener-kind**, nên không chồng lên namespace cũ. PVC local trong kind tồn tại qua recreate Pod, nhưng không bảo đảm còn khi xóa cluster kind/node Docker.

## 4. Chuẩn bị image và values local

Lấy hai digest từ artifact CI backend/frontend (hoặc `release.env` đã chạy tốt). Đăng nhập GHCR trên VMware nếu package private như bài trước. Nhập tham chiếu đầy đủ:

```bash
read -rp 'Backend ghcr.io/...@sha256:... : ' BE_IMAGE
read -rp 'Frontend ghcr.io/...@sha256:... : ' FE_IMAGE
docker pull "$BE_IMAGE"
docker pull "$FE_IMAGE"
```

Sau khi cả hai pull thành công, gắn tag local rồi nạp kind:

```bash
docker tag "$BE_IMAGE" urlshortener-backend:k8s-v1
docker tag "$FE_IMAGE" urlshortener-frontend:k8s-v1
kind load docker-image urlshortener-backend:k8s-v1 urlshortener-frontend:k8s-v1 --name urlshortener
mkdir -p .lab/kind
cat > .lab/kind/release.yaml <<'YAML'
backendImage: urlshortener-backend:k8s-v1
frontendImage: urlshortener-frontend:k8s-v1
YAML
printf 'BACKEND_IMAGE=%s\nFRONTEND_IMAGE=%s\n' "$BE_IMAGE" "$FE_IMAGE" > docs/evidence/k8s/kind-image-sources.txt
```

Tag local là cách nạp image vào kind, không build lại. Digest nguồn là bằng chứng truy về CI. Không tái dùng cùng tag cho release khác; dùng `k8s-v2`, `k8s-v3`.

## 5. Secret lab mới, deploy toàn stack bằng Helm

```bash
kubectl config use-context kind-urlshortener
kubectl create namespace urlshortener-kind --dry-run=client -o yaml | kubectl apply -f -
bash scripts/k8s-lab-env.sh init .lab/kind/secrets.env
bash scripts/k8s-lab-env.sh apply .lab/kind/secrets.env urlshortener-kind kind-urlshortener
helm lint charts/url-shortener --strict -f k8s/values-kind.yaml -f .lab/kind/release.yaml
helm template urlshortener charts/url-shortener -n urlshortener-kind \
  -f k8s/values-kind.yaml -f .lab/kind/release.yaml > .lab/kind/rendered.yaml
kubectl apply --dry-run=server -f .lab/kind/rendered.yaml
```

Script `init` chỉ chạy một lần; báo exists thì giữ env cũ. Nó sinh mật khẩu riêng cho database mới của K8s, không đổi `.env` Compose. **Không sinh lại DB_PASSWORD trong khi PVC đã có database**, vì PostgreSQL không đổi password cũ chỉ do biến môi trường đổi.

Deploy:

```bash
helm upgrade --install urlshortener charts/url-shortener -n urlshortener-kind \
  -f k8s/values-kind.yaml -f .lab/kind/release.yaml --wait --timeout 10m
kubectl -n urlshortener-kind get pods,pvc,services
```

Chờ PostgreSQL, Redis, Kafka và app/frontend Ready; PVC Bound. Backend có thể restart trong lúc data services khởi động, vì K8s không có Compose depends_on. Flyway trong backend khởi tạo schema DB mới; `ddl-auto=validate` không phải công cụ tạo schema.

Nếu Helm timeout, giữ nguyên để debug phần 10; không xóa PVC. `helm upgrade --wait` tự nó không bảo đảm tự rollback khi thất bại; xem phần 8.

## 6. Mở UI và smoke test, đúng terminal

**VMware terminal A**, giữ chạy:

```bash
kubectl -n urlshortener-kind port-forward --address 127.0.0.1 service/frontend 18080:80
```

**VMware terminal B**:

```bash
cd ~/projects/url-shortener-infra
curl --fail http://127.0.0.1:18080/healthz
mkdir -p .lab/kind/smoke
cp scripts/smoke.sh .lab/kind/smoke/smoke.sh
cd .lab/kind/smoke
bash smoke.sh init http://127.0.0.1:18080
bash smoke.sh run http://127.0.0.1:18080
```

Init một lần; lần sau chỉ run. Copy smoke vào thư mục riêng vì script lưu `.smoke.json` ở cwd; không dùng fixture của DB Compose hoặc EC2 với DB K8s mới.

**Windows PowerShell**, giữ tunnel:

```powershell
ssh -L 18080:127.0.0.1:18080 thanh@192.168.40.100
```

Mở `http://localhost:18080`, thử đăng ký/đăng nhập, tạo link, redirect. IP VMware thay nếu máy đã đổi. Nếu Pod frontend bị thay và port-forward ngắt, chạy lại terminal A.

## 7. Hiểu tài nguyên và thử tự phục hồi/persistence

| Thành phần | Câu hỏi bạn phải trả lời được |
|---|---|
| Deployment app/frontend | Pod chết thì ai tạo lại? Image mới tạo revision ra sao? |
| Service | Nginx gọi backend bằng tên gì dù Pod IP đổi? |
| ConfigMap/Secret | Config thường và password đặt ở đâu? Base64 có bảo mật không? |
| startup/readiness/liveness | Probe nào trì hoãn kiểm tra, ngắt traffic hay restart container? |
| requests/limits | Pod Pending do gì? OOMKilled khác CPU throttling thế nào? |
| StatefulSet/PVC | Tên Pod/volume ổn định có nghĩa database đã HA chưa? |
| StorageClass | Ai cấp volume? Delete PVC có làm mất volume không? |

Backend liveness/readiness dùng management 8081. Không liveness theo health tổng phụ thuộc DB. Readiness endpoint mặc định không chứng minh mọi dependency khỏe; nghiệp vụ kiểm tra riêng bằng smoke. [Kubernetes probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/).

**VMware**, chọn đúng Pod frontend từ get pods rồi thay `TEN_POD`:

```bash
kubectl -n urlshortener-kind get pods -l app=frontend
kubectl -n urlshortener-kind delete pod TEN_POD
kubectl -n urlshortener-kind get pods -w
```

Quan sát Pod mới Ready, Ctrl+C thoát. Đây là tự phục hồi Pod, không phải HA của cả VM.

Thử persistence PostgreSQL sau khi đã tạo tài khoản/link bằng smoke:

```bash
kubectl -n urlshortener-kind delete pod postgres-0
kubectl -n urlshortener-kind wait --for=condition=Ready pod/postgres-0 --timeout=180s
kubectl -n urlshortener-kind get pvc
```

Mở lại port-forward nếu cần, chạy smoke `run` với fixture cũ: tài khoản/link phải còn. Một bài này chưa thay thế backup/restore. Giữ Redis JWT blacklist và Kafka data, không xóa để chữa lỗi nhanh.

## 8. Release V2 và rollback bằng Helm

**VMware**, kéo frontend digest V2 đã qua CI:

```bash
cd ~/projects/url-shortener-infra
read -rp 'Frontend V2 full digest: ' FE_V2
docker pull "$FE_V2"
docker tag "$FE_V2" urlshortener-frontend:k8s-v2
kind load docker-image urlshortener-frontend:k8s-v2 --name urlshortener
cp .lab/kind/release.yaml .lab/kind/release-v1.yaml
nano .lab/kind/release.yaml
```

Đổi `frontendImage` thành `urlshortener-frontend:k8s-v2`, giữ backend. Lưu rồi deploy bằng cùng lệnh Helm ở phần 5. Chạy smoke/UI, xem:

```bash
helm history urlshortener -n urlshortener-kind
kubectl -n urlshortener-kind rollout status deployment/frontend --timeout=180s
```

Ghi **revision tốt** hiện tại. Tạo lỗi có chủ đích bằng một lần upgrade dùng image không tồn tại:

```bash
helm upgrade urlshortener charts/url-shortener -n urlshortener-kind \
  -f k8s/values-kind.yaml -f .lab/kind/release.yaml \
  --set frontendImage=urlshortener-frontend:missing-lab-image --wait --timeout 90s
kubectl -n urlshortener-kind get pods
helm history urlshortener -n urlshortener-kind
```

Timeout và ImagePullBackOff là lỗi mong đợi. Phục hồi, thay `REVISION_TOT` bằng số vừa ghi (không đoán là 1):

```bash
helm rollback urlshortener REVISION_TOT -n urlshortener-kind --wait --timeout 10m
```

Kiểm tra smoke/UI lại. Rollback chart không rollback DB migrations. Chart không quản lý Secret, nên rollback không đổi password. Tăng backend replicas chưa phải mục tiêu: cần kiểm tra seeder, Kafka consumer/idempotency trước; giữ backend 1 replica.

## 9. Backup và restore PostgreSQL K8s

**VMware**, chọn đúng context và namespace; ví dụ local:

```bash
kubectl config use-context kind-urlshortener
NS=urlshortener-kind
mkdir -p .lab/kind/backups
umask 077
kubectl -n "$NS" exec postgres-0 -- sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  > .lab/kind/backups/postgres.dump
test -s .lab/kind/backups/postgres.dump
sha256sum .lab/kind/backups/postgres.dump > .lab/kind/backups/postgres.dump.sha256
```

Nếu pg_dump lỗi, không dùng file đó; shell redirect vẫn có thể tạo file rỗng. Không dùng `-t` vì dump binary không qua TTY.

Restore thử vào **database mới**, không ghi đè DB đang chạy:

```bash
kubectl -n "$NS" exec postgres-0 -- sh -c 'createdb -U "$POSTGRES_USER" restore_check'
kubectl -n "$NS" exec -i postgres-0 -- sh -c 'pg_restore -U "$POSTGRES_USER" -d restore_check --no-owner --exit-on-error' \
  < .lab/kind/backups/postgres.dump
kubectl -n "$NS" exec postgres-0 -- sh -c 'psql -U "$POSTGRES_USER" -d restore_check -c "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('"'"'pg_catalog'"'"', '"'"'information_schema'"'"');"'
```

`restore_check` tồn tại thì chọn tên DB mới, không tự DROP DB. Kiểm tra số bảng/dữ liệu và ghi thời gian restore; muốn nghiệm thu nghiệp vụ đầy đủ phải trỏ một bản app lab riêng vào DB restore rồi smoke bằng fixture tương ứng. Backup PostgreSQL không mang theo Kafka pending event/Redis JWT blacklist.

## 10. Debug trước khi đụng AWS

```bash
kubectl config current-context
kubectl -n urlshortener-kind get pods,pvc,services
kubectl -n urlshortener-kind describe pod TEN_POD
kubectl -n urlshortener-kind logs deployment/app --tail=100
kubectl -n urlshortener-kind get events --sort-by=.metadata.creationTimestamp
```

| Triệu chứng | Xử lý theo bằng chứng |
|---|---|
| Pending | Describe: RAM/CPU, volume chưa cấp, node chưa Ready |
| PVC Pending | Kiểm tra StorageClass; WaitForFirstConsumer chờ scheduler là bình thường trước khi có consumer |
| ImagePullBackOff | kind load đúng tên cluster/tag; EKS có imagePullSecret/digest đúng không |
| CrashLoopBackOff | `kubectl logs TEN_POD --previous -n ...`, Secret DB, Flyway, Kafka |
| OOMKilled | Limits/JVM và workload; không tăng RAM mù quáng |
| Nginx 502 | App Ready, Service endpoints, app logs và upstream name |
| Health 403/404 | Image đã có profile lab/Actuator/SecurityConfig chưa |
| DB auth fail sau đổi Secret | PVC chứa password cũ; quay lại secret phù hợp, không xóa DB |
| Kafka write permission | Describe/logs, UID/fsGroup 1000 và mount PVC |

Điều kiện lên EKS: deploy lại được từ guide, UI/smoke PASS, Pod tự phục hồi, PostgreSQL còn data sau Pod recreate, có backup/restore và một lần rollback. Không cần HPA/GitOps trước mốc này.

## 11. Cổng kiểm tra tài khoản AWS và chi phí EKS

**Không chạy create cluster trước khi đọc phần này.** Tài khoản hiện tại của bạn là trải nghiệm project mới, Free Plan có giới hạn. AWS liệt kê EKS trong dịch vụ hỗ trợ của trải nghiệm mới, nhưng điều đó không bảo đảm mọi tính năng IAM/instance type/quota được phép. [Danh sách AWS](https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.html).

Guide dùng managed node group, EKS Pod Identity cho EBS/LB controller; **không cần IAM OIDC provider**. Vẫn cần quyền tạo IAM role, PassRole, CloudFormation, VPC/EC2, EKS/add-ons/access entries/Pod Identity và ELB. User CD EC2 chỉ được sửa Security Group từ bài trước **không đủ quyền tạo EKS**. Không gắn quyền rộng cho user CD cũ.

**VMware**, dùng phiên quản trị lab có quyền provisioning được chủ tài khoản cấp, cùng region hiện tại:

```bash
export AWS_PROFILE=aws-lab
export AWS_REGION=ap-southeast-2
aws sts get-caller-identity
aws eks list-clusters --region "$AWS_REGION"
aws cloudformation list-stacks --region "$AWS_REGION" --stack-status-filter CREATE_COMPLETE --max-items 5
```

Nếu phiên aws login hết hạn, đăng nhập lại như phần AWS trước rồi thử STS. Lệnh đọc thành công chỉ chứng minh quyền đọc, không bảo đảm create/PassRole. Nếu Console/API báo upgrade/advanced features hoặc SCP explicit deny, **dừng ở đây**, giữ kết quả local; cần giải quyết quyền/tài khoản với AWS hoặc tài khoản có hỗ trợ. Không tự chuyển Paid Plan, bật advanced features hoặc tạo AWS Organizations để thử vượt giới hạn.

Chi phí EKS standard support là **$0.10/cluster/giờ**, khoảng $2.40/ngày hay $72/30 ngày chỉ control plane; chưa gồm worker EC2, EBS, public IPv4, NLB/LCU và data transfer. Extended support đắt hơn; chọn version đang standard support. [Giá EKS](https://aws.amazon.com/eks/pricing/). Không suy ra eligible Free Tier nghĩa là EKS miễn phí.

Bài chọn 2 worker cỡ 2 vCPU/8 GB làm điểm bắt đầu, maxSize=2 để giới hạn số worker (chưa cài autoscaler). Node t3.large trong mẫu có thể không eligible với Free Plan; kiểm tra instance type và giá đúng region, đổi sang loại x86_64 có ít nhất 8 GB được phép. Đừng đổi sang micro chỉ để create được rồi thiếu RAM chạy Kafka/Java. Phí toàn bộ lab cần tra [AWS Pricing Calculator](https://calculator.aws/) trước khi tạo.

Đặt Budget alert phù hợp, ghi credit trước/sau. Billing có độ trễ; budget không phải công tắc dừng ngay. Dành buổi thực hành có thời gian dọn; EKS không có thao tác Stop cluster như EC2.

## 12. Cài eksctl và chọn version EKS

**VMware:** cài theo [hướng dẫn eksctl](https://docs.aws.amazon.com/eks/latest/eksctl/installation.html). Ví dụ tải release stable mới nhất vào thư mục tools, kiểm tra checksum trước install:

```bash
cd ~/projects/url-shortener-infra/.lab/tools
curl -fLO https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz
curl -fLO https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt
grep 'eksctl_Linux_amd64.tar.gz$' eksctl_checksums.txt | sha256sum --check
```

Checksum OK:

```bash
tar -xzf eksctl_Linux_amd64.tar.gz eksctl
sudo install -m 0755 eksctl /usr/local/bin/eksctl
eksctl version
cd ~/projects/url-shortener-infra
mkdir -p .lab/eks
```

**AWS Console → EKS**, xem version được hỗ trợ trong region; chọn một version standard support, không extended. Có thể dùng CLI mới:

```bash
aws eks describe-cluster-versions --region "$AWS_REGION" --include-all \
  --query 'clusterVersions[?versionStatus==`STANDARD_SUPPORT`].[clusterVersion,endOfStandardSupportDate]' --output table
```

CLI không có lệnh này thì cập nhật AWS CLI hoặc kiểm tra Console; không lấy version kind làm version EKS mặc định. Ghi version lựa chọn. Trước khi thao tác EKS, cài kubectl cùng minor version đó như phần 3 (thay KUBE_VERSION bằng bản patch có thật của minor), hoặc dùng kubectl trong phạm vi skew ±1 minor theo [quy tắc Kubernetes](https://kubernetes.io/releases/version-skew-policy/). Kiểm tra `kubectl version --client`.

Ví dụ cài kubectl cho minor vừa chọn, **VMware** (nhập `1.xx` thật khi được hỏi, không nhập chữ xx):

```bash
read -rp 'EKS minor version selected, e.g. 1.xx: ' EKS_VERSION
KUBE_VERSION=$(curl -fsSL "https://dl.k8s.io/release/stable-${EKS_VERSION}.txt")
curl -fL "https://dl.k8s.io/release/$KUBE_VERSION/bin/linux/amd64/kubectl" -o .lab/tools/kubectl
curl -fL "https://dl.k8s.io/release/$KUBE_VERSION/bin/linux/amd64/kubectl.sha256" -o .lab/tools/kubectl.sha256
echo "$(cat .lab/tools/kubectl.sha256)  .lab/tools/kubectl" | sha256sum --check
```

Chỉ sau checksum OK mới chạy `sudo install -m 0755 .lab/tools/kubectl /usr/local/bin/kubectl`. Phiên bản kubectl này phục vụ EKS; khi quay kind có minor khác quá phạm vi skew, cài lại kubectl phù hợp như phần 3.

Để kiểm tra loại node x86_64 được đánh dấu Free Tier eligible trong region hiện tại:

```bash
aws ec2 describe-instance-types --region "$AWS_REGION" \
  --filters 'Name=free-tier-eligible,Values=true' \
  --query "InstanceTypes[?contains(ProcessorInfo.SupportedArchitectures, 'x86_64')].{Type:InstanceType,RAM_MiB:MemoryInfo.SizeInMiB,vCPU:VCpuInfo.DefaultVCpus}" \
  --output table
```

Chọn loại >=8192 MiB, ví dụ m7i-flex.large nếu nó xuất hiện và được EKS managed node group hỗ trợ ở region. Danh sách này không chứng minh được quyền EKS/IAM hay miễn phí; còn phải kiểm tra giá và quota. Nếu không có loại đủ RAM được phép thì chưa chạy create cluster trên Free Plan hiện tại.

## 13. Chuẩn bị cấu hình cluster mới rồi tạo EKS

**VMware:**

```bash
cd ~/projects/url-shortener-infra
cp k8s/eks/cluster.example.yaml .lab/eks/cluster.yaml
curl --fail --silent https://checkip.amazonaws.com
nano .lab/eks/cluster.yaml
```

Sửa `version`, `publicAccessCIDRs` bằng public IP vừa lấy + `/32`, và `instanceType` nếu cần. Public IP này là IP Internet của đường mạng VMware, không phải `192.168.40.100` hay Elastic IP EC2. Đổi region nếu thực sự đã có quyền ở region khác; mọi file/lệnh phải cùng region.

Mẫu tạo **VPC riêng**, nodes ở public subnets, **không NAT Gateway**, không SSH nodes. Đây là lựa chọn lab giảm thành phần/chi phí; SG không mở DB/Kafka/SSH toàn Internet. Production thường dùng private workers và thiết kế egress riêng. EKS API bật private access cho nodes, public access giới hạn IP quản trị. Không dùng nhầm `terraform apply` trong thư mục aws-lab để tạo EKS.

Review bản cấu hình được eksctl chuẩn hóa trước, thao tác này chưa provision:

```bash
eksctl create cluster -f .lab/eks/cluster.yaml --dry-run > .lab/eks/cluster-reviewed.yaml
cat .lab/eks/cluster-reviewed.yaml
```

Xác nhận tên `urlshortener-intern`, region, version, 2 nodes, max=2, NAT Disable, CIDR đúng. Đây không phải Terraform plan đầy đủ và không chứng minh quyền create thành công. Khi chấp nhận phạm vi/chi phí, tự chạy:

```bash
eksctl create cluster -f .lab/eks/cluster.yaml
```

Có thể mất hàng chục phút. Nếu lỗi, xem CloudFormation stack events, không chạy create liên tục hoặc tự xóa tài nguyên từng phần. Cluster có thể đã tạo một phần và có phí; phần 24 hướng dẫn kiểm tra/dọn đúng cluster.

Sau thành công:

```bash
aws eks update-kubeconfig --region "$AWS_REGION" --name urlshortener-intern --alias urlshortener-eks
kubectl config use-context urlshortener-eks
kubectl get nodes -o wide
kubectl get pods -n kube-system
```

Cần 2 nodes Ready, CoreDNS, kube-proxy, CNI và Pod Identity agent khỏe. Đường mạng đổi IP thì EKS publicAccessCIDRs phải cập nhật bằng AWS API từ phiên quản trị; không sửa SSH SG EC2 cũ để chữa timeout EKS API.

## 14. EBS CSI bằng Pod Identity, tạo StorageClass

**VMware**, context `urlshortener-eks`:

```bash
cp k8s/eks/addons.example.yaml .lab/eks/addons.yaml
nano .lab/eks/addons.yaml
```

Giữ đúng cluster name/region theo cấu hình đã tạo, rồi:

```bash
eksctl create addon -f .lab/eks/addons.yaml
aws eks describe-addon --cluster-name urlshortener-intern --addon-name aws-ebs-csi-driver \
  --region "$AWS_REGION" --query 'addon.status' --output text
kubectl -n kube-system rollout status deployment/ebs-csi-controller --timeout=300s
kubectl apply -f k8s/eks/storage.yaml
kubectl get storageclass gp3-lab
```

Chờ addon ACTIVE. Role cho EBS driver do eksctl tạo qua Pod Identity, trust service `pods.eks.amazonaws.com`, không trust GitHub. Node role phải có `eks-auth:AssumeRoleForPodIdentity` (managed worker policy phù hợp); agent phải hoạt động. [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/eksctl/pod-identity-associations.html).

### 14.1. Nếu eksctl bị SCP chặn GetOpenIDConnectProvider

Nếu lỗi ghi `iam:GetOpenIDConnectProvider ... explicit deny in a service control policy`, eksctl đang kiểm tra OIDC và bị giới hạn cấp tổ chức. Không tạo OIDC provider, không thêm AdministratorAccess để chữa. Có thể dùng API Pod Identity trực tiếp cho thao tác khác được phép; đây không phải cách vượt deny OIDC. Nếu CreateRole/PassRole/CreateAddon cũng bị SCP chặn thì dừng và giải quyết quyền tài khoản.

**VMware**, tạo trust policy cho role riêng EBS driver:

```bash
cd ~/projects/url-shortener-infra
cat > .lab/eks/ebs-pod-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "pods.eks.amazonaws.com"},
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
JSON
aws iam create-role --role-name UrlShortenerInternEbsPodRole \
  --assume-role-policy-document file://.lab/eks/ebs-pod-trust.json
```

Chỉ đi tiếp khi tạo role thành công. Nếu role đã tồn tại từ lần chạy này, kiểm tra đúng trust/purpose rồi tái sử dụng, không sửa role dự án khác.

```bash
aws iam attach-role-policy --role-name UrlShortenerInternEbsPodRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
EBS_ROLE_ARN=$(aws iam get-role --role-name UrlShortenerInternEbsPodRole --query Role.Arn --output text)
aws eks list-addons --cluster-name urlshortener-intern --region "$AWS_REGION"
```

Nếu danh sách chưa có `aws-ebs-csi-driver`:

```bash
aws eks create-addon --cluster-name urlshortener-intern --region "$AWS_REGION" \
  --addon-name aws-ebs-csi-driver \
  --pod-identity-associations "serviceAccount=ebs-csi-controller-sa,roleArn=$EBS_ROLE_ARN"
```

Nếu add-on đã tồn tại, dùng `aws eks update-addon` với các tham số cùng cluster/region/name/pod-identity-associations trên thay vì create. Không tạo association riêng trước create-addon để tránh xung đột ownership. Nếu role vừa tạo chưa propagate, đợi một lát rồi thử lại API sau khi đọc lỗi; không lặp vô hạn.

```bash
aws eks wait addon-active --cluster-name urlshortener-intern --region "$AWS_REGION" --addon-name aws-ebs-csi-driver
kubectl -n kube-system rollout status deployment/ebs-csi-controller --timeout=300s
kubectl apply -f k8s/eks/storage.yaml
kubectl get storageclass gp3-lab
```

AWS API hỗ trợ gắn role vào add-on qua `--pod-identity-associations`; không dùng `--service-account-role-arn` vì đó là nhánh IRSA. [AWS CLI create-addon](https://docs.aws.amazon.com/cli/latest/reference/eks/create-addon.html).

Role `UrlShortenerInternEbsPodRole` tạo bằng AWS CLI không thuộc stack eksctl; ghi vào danh sách cleanup. Chỉ detach policy/xóa role này sau khi EBS/PVC/add-on và association đã dọn xong, xác minh không dùng ở nơi khác.

`gp3-lab` dùng `ebs.csi.aws.com`, mã hóa EBS, WaitForFirstConsumer. ReclaimPolicy Delete nghĩa **xóa PVC có thể xóa EBS và dữ liệu**, không coi PVC là backup. Volume chỉ attach trong AZ phù hợp; nếu một node hết tài nguyên có thể gặp lỗi scheduling/volume topology, đọc events.

## 15. Cài AWS Load Balancer Controller bằng Pod Identity

Guide pin controller **v2.14.1**, Helm chart **1.14.1**; kiểm tra appVersion trước khi cài để policy và controller cùng release. Không dùng chart mới nhất với policy cũ mà không review.

**VMware:**

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
curl -fL https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json \
  -o .lab/eks/lbc-policy.json
aws iam create-policy --policy-name UrlShortenerLabLoadBalancerController \
  --policy-document file://.lab/eks/lbc-policy.json
cp k8s/eks/lbc-identity.example.yaml .lab/eks/lbc-identity.yaml
nano .lab/eks/lbc-identity.yaml
```

Sửa `YOUR_ACCOUNT_ID` thành Account ID vừa lấy, cluster/region đúng. Nếu policy đã tồn tại, kiểm tra lại policy đang có và dùng ARN đó; không tạo policy trùng hay đổi policy đang dùng cho dự án khác.

```bash
eksctl create podidentityassociation -f .lab/eks/lbc-identity.yaml
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm show chart eks/aws-load-balancer-controller --version 1.14.1
```

Cần appVersion v2.14.1. Lấy VPC mới của EKS, không dùng VPC EC2 cũ:

```bash
EKS_VPC=$(aws eks describe-cluster --name urlshortener-intern --region "$AWS_REGION" \
  --query cluster.resourcesVpcConfig.vpcId --output text)
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 1.14.1 -n kube-system \
  --set clusterName=urlshortener-intern --set region="$AWS_REGION" --set vpcId="$EKS_VPC" \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller \
  --wait --timeout 5m
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=180s
```

Nếu chart cần CRDs bổ sung theo release thì xem [hướng dẫn controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/installation/); không tự chuyển sang IRSA/OIDC để chữa lỗi Pod Identity. Bài chỉ dùng NLB Service, không Gateway API. Các bước IAM/policy và Helm tham khảo [AWS LBC](https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html), phần tạo role ở guide này đã đổi sang Pod Identity.

## 16. Secret EKS riêng và quyền pull GHCR

```bash
kubectl config use-context urlshortener-eks
kubectl create namespace urlshortener-eks --dry-run=client -o yaml | kubectl apply -f -
bash scripts/k8s-lab-env.sh init .lab/eks/secrets.env
bash scripts/k8s-lab-env.sh apply .lab/eks/secrets.env urlshortener-eks urlshortener-eks
```

Không copy password/data VM sang EKS trong bài này. Secret chỉ nằm trong namespace đích. IAM access key dùng quản trị AWS không đưa vào Pod.

Vì package private, nodes EKS không có Docker login của VMware. Tạo `ghcr-pull` từ Docker config riêng để không dán token vào argv/YAML. **VMware**:

```bash
mkdir -p .lab/eks/docker
chmod 700 .lab/eks/docker
read -rp 'GitHub username: ' GHCR_USER
read -rsp 'GitHub classic token with read:packages: ' GHCR_TOKEN
echo
printf '%s' "$GHCR_TOKEN" | docker --config "$PWD/.lab/eks/docker" login ghcr.io \
  --username "$GHCR_USER" --password-stdin
unset GHCR_TOKEN
kubectl -n urlshortener-eks create secret generic ghcr-pull \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=.lab/eks/docker/config.json \
  --dry-run=client -o yaml | kubectl apply -f -
```

Token phải đọc được cả package frontend/backend. Docker config này chứa credential, đã nằm trong `.lab/` ignored; không đưa vào evidence. Token đổi/hết hạn thì Docker login lại và apply secret lại. Nếu packages public có thể bỏ imagePullSecrets trong values, nhưng guide giữ đường private để khớp dự án hiện tại.

## 17. Deploy Helm lên EKS và mở UI qua NLB

**VMware:**

```bash
cp k8s/values-eks.yaml .lab/eks/values.yaml
nano .lab/eks/values.yaml
```

Thay `REPLACE_WITH_YOUR_PUBLIC_IPV4/32` bằng public IP Internet của máy Windows sẽ mở UI. Thường cùng IP egress VMware, nhưng VPN/proxy có thể khác. Giữ sourceRanges để lab HTTP chỉ mở cho bạn; không dùng dữ liệu thật. Chart chỉ public frontend port 80, DB/Redis/Kafka/management không có LoadBalancer.

Tạo manifest image riêng **trên VMware**:

```bash
nano .lab/eks/release.yaml
```

Điền hai tham chiếu thật lấy từ CI, giữ dấu quote như ví dụ, thay toàn bộ placeholder:

```yaml
backendImage: "ghcr.io/YOUR_OWNER/YOUR_BACKEND@sha256:YOUR_64_HEX_DIGEST"
frontendImage: "ghcr.io/YOUR_OWNER/YOUR_FRONTEND@sha256:YOUR_64_HEX_DIGEST"
```

Không dùng tag local `k8s-v1` trên EKS. Tiếp tục:

```bash
helm lint charts/url-shortener --strict -f .lab/eks/values.yaml -f .lab/eks/release.yaml
helm template urlshortener charts/url-shortener -n urlshortener-eks \
  -f .lab/eks/values.yaml -f .lab/eks/release.yaml > .lab/eks/rendered.yaml
kubectl apply --dry-run=server -f .lab/eks/rendered.yaml
helm upgrade --install urlshortener charts/url-shortener -n urlshortener-eks \
  -f .lab/eks/values.yaml -f .lab/eks/release.yaml --wait --timeout 15m
kubectl -n urlshortener-eks get pods,pvc,services -o wide
kubectl -n urlshortener-eks get service frontend -w
```

Chờ hostname NLB ở EXTERNAL-IP, Ctrl+C thoát watch. Provision NLB/DNS/target health có thể chậm hơn Pod readiness. Lấy URL:

```bash
NLB_HOST=$(kubectl -n urlshortener-eks get service frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
printf 'Lab URL: http://%s\n' "$NLB_HOST"
```

Nếu NLB_HOST rỗng, không đi tiếp; xem describe Service/LBC logs phần 21. Sửa `publicUrl` trong `.lab/eks/values.yaml` thành `http://HOSTNAME_NLB_VUA_LAY` rồi chạy lại lệnh Helm upgrade phía trên. Không thêm port 18080 cho URL NLB. Chart cập nhật FRONTEND_URL/CORS/callback và checksum làm backend rollout.

**Windows trình duyệt:** mở URL NLB, thử UI. `curl` từ VMware chỉ truy cập được nếu egress của VMware nằm trong sourceRanges. NLB không dùng Elastic IP EC2 cũ; URL thay khi tạo NLB mới.

### 17.1. Nếu AWS chặn tạo load balancer cho tài khoản

Nếu Service Events ghi `OperationNotPermitted: This AWS account currently does not support creating load balancers`, AWS đang từ chối khả năng tạo ELB của tài khoản. Đợi thêm, đổi Helm image hoặc cấp quyền IAM rộng hơn không tự giải quyết được thông báo này. Log chưa xác định đây là giới hạn Free Plan, trạng thái xác minh hay hạn chế khác. Liên hệ AWS Support về khả năng tạo Network Load Balancer trong đúng region; không tự nâng cấp plan để thử chữa.

Để tiếp tục kiểm chứng ứng dụng EKS trước khi được hỗ trợ NLB, dùng port-forward. Cách này không tạo load balancer, chưa hoàn thành nghiệm thu public NLB/TLS. Service LoadBalancer có thể vẫn Pending và controller tiếp tục retry; port-forward chỉ là đường kiểm tra tạm, không làm hostname NLB xuất hiện. Helm lần trước có thể timeout vì chờ Service được cấp load balancer dù các Pod đã chạy.

**VMware terminal A**, không chạy trùng port-forward kind trên cùng cổng:

```bash
kubectl --context urlshortener-eks -n urlshortener-eks get pods
kubectl --context urlshortener-eks -n urlshortener-eks port-forward \
  --address 127.0.0.1 service/frontend 18080:80
```

Giữ terminal A. **Windows PowerShell** mở tunnel đến VMware:

```powershell
ssh -L 18080:127.0.0.1:18080 thanh@192.168.40.100
```

Mở `http://localhost:18080`. Request được chuyển qua VMware tới API EKS và frontend Pod, không chuyển tới kind; context ở lệnh port-forward đã chỉ rõ EKS. Nếu VMware IP đổi thì sửa lệnh tunnel. Phải giữ cả hai cửa sổ hoạt động.

Values EKS mặc định đang là `publicUrl: http://localhost:18080`, nên CORS đã khớp đường truy cập này. Nếu đã đổi publicUrl trước đó, đặt lại URL localhost trong `.lab/eks/values.yaml`; có thể patch ConfigMap tạm và restart app để kiểm tra, nhưng nhớ đồng bộ cấu hình Helm trước lần upgrade sau. Không dùng fixture kind cho DB EKS.

Ở phần 18, thay `http://$NLB_HOST` bằng `http://127.0.0.1:18080` khi chạy smoke từ VMware. Giữ fixture riêng `.lab/eks/smoke`. Ghi bằng chứng đúng là app chạy trên EKS, truy cập qua port-forward; mục NLB còn bị giới hạn tài khoản.

## 18. Smoke EKS và kiểm tra dữ liệu

**VMware**, tạo fixture riêng cho EKS:

```bash
cd ~/projects/url-shortener-infra
mkdir -p .lab/eks/smoke
cp scripts/smoke.sh .lab/eks/smoke/smoke.sh
cd .lab/eks/smoke
bash smoke.sh init "http://$NLB_HOST"
bash smoke.sh run "http://$NLB_HOST"
```

Init chỉ một lần cho DB EKS. Nếu shell mới không còn NLB_HOST, lấy lại như phần 17. Lưu PASS và ảnh UI; không lưu fixture password vào Git.

Kiểm tra persistence cloud: trong context `urlshortener-eks`, xóa riêng `postgres-0` như phần 7; chờ Ready, chạy smoke run bằng fixture cũ. Không thử xóa PVC để kiểm chứng persistence.

Đến đây đạt mục tiêu deploy lên EKS: app chạy đúng image, PVC Bound/EBS tồn tại, UI qua NLB và smoke PASS. Có 2 worker không đồng nghĩa data services 1 replica đã HA.

## 19. TLS khi có domain — phần bổ sung nhỏ

Lab HTTP bị giới hạn IP chỉ để dữ liệu test. Nếu đã có domain và muốn đưa link demo lên CV:

1. **AWS Certificate Manager đúng region EKS → Request public certificate** cho subdomain, ví dụ `short-lab.example.com`.
2. Chọn DNS validation, thêm CNAME xác minh ở nhà cung cấp DNS, đợi certificate Issued. Ghi ARN certificate, không phải private key.
3. Trong `.lab/eks/values.yaml` thêm hai annotation, giữ các annotation NLB cũ:

```yaml
frontend:
  tls: true
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "arn:aws:acm:REGION:ACCOUNT:certificate/CERT_ID"
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
```

`tls: true` đã được chart hỗ trợ: Service chỉ mở listener 443, NLB terminate TLS rồi gửi HTTP đến Nginx; chart đặt scheme forward mặc định là https cho bản TLS-only. Giữ NLB target health HTTP vào port traffic của Pod. Không chỉ thêm certificate annotation mà quên bật tls. Merge các key vào frontend/annotations đang có, không tạo hai block `frontend:` trùng nhau trong cùng file YAML.

4. Trỏ CNAME subdomain đến NLB hostname (Route53 dùng Alias nếu phù hợp). Đặt `publicUrl: https://short-lab.example.com`, Helm upgrade, kiểm tra certificate/cookie/redirect và smoke qua HTTPS.

Nếu chưa có domain, bỏ phần này, ghi rõ lab HTTP. Không claim TLS nếu chưa kiểm tra thực tế. Không bắt buộc mua domain để nghiệm thu bài intern EKS.

## 20. CI cho chart và quy trình release EKS mức intern

CI app hiện tại vẫn build/test/scan/push digest. CI chart kiểm tra cấu hình, không tạo EKS trên mỗi PR.

**Windows PowerShell, repo infra**:

```powershell
cd D:\privateProject\projects\url-shortener-infra
# Workflow/profile đã có trong repo đích; review file hiện tại trong IDE.
git add .github/workflows/k8s-chart-ci.yml
git commit -m "ci: validate Kubernetes Helm chart"
git push
```

Workflow chuẩn đã có trong repo; mở review trực tiếp, không cần copy mẫu. Merge main, xác nhận Actions xanh. Job lint/render chưa thay server-side admission và integration test; không gọi là end-to-end test của cluster.

Release mức intern trong guide này là **CI + Helm deploy do bạn chủ động chạy từ VMware**:

1. Backend/frontend CI xanh, lấy digest mới.
2. Chọn context EKS, sửa `.lab/eks/release.yaml`, giữ digest ứng dụng không đổi.
3. Ghi revision tốt bằng `helm history`.
4. Helm upgrade `--wait`, smoke/UI.
5. Nếu thất bại, Helm rollback về revision tốt, kiểm tra lại app/data.

Không dùng workflow CD EC2 để deploy EKS: nó SSH/Compose, không phải Helm. IAM user CD EC2 cũng không có EKS/RBAC. Tự động CD GitHub→EKS là bài kế tiếp, cần EKS access entry/RBAC cho deploy identity và đường mạng tới API đang giới hạn `/32`; không mở API/network chỉ để job xanh. Guide không bắt Argo CD/OIDC GitHub khi tài khoản chưa hỗ trợ.

## 21. Quan sát cơ bản và troubleshooting EKS

**VMware**, chọn đúng context EKS:

```bash
kubectl config use-context urlshortener-eks
kubectl -n urlshortener-eks get pods,pvc,services -o wide
kubectl -n urlshortener-eks get events --sort-by=.metadata.creationTimestamp
kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=100
kubectl -n kube-system logs deployment/ebs-csi-controller -c ebs-plugin --tail=100
aws eks list-pod-identity-associations --cluster-name urlshortener-intern --region "$AWS_REGION"
```

| Lỗi | Kiểm tra |
|---|---|
| kubectl Unauthorized | AWS_PROFILE/STS session, creator identity và EKS access entry; IAM đọc EKS không tự có Kubernetes RBAC |
| kubectl timeout | PublicAccessCIDRs có egress hiện tại, DNS/network; không phải SSH key |
| PVC Pending, UnauthorizedOperation | EBS addon/agent/Pod Identity role policy, AZ topology, describe PVC |
| NLB Pending | LBC healthy, Pod Identity association, policy đúng controller, public subnet tags `kubernetes.io/role/elb=1` |
| NLB có DNS nhưng timeout | sourceRanges, subnet/SG, DNS propagation, target health trong EC2→Target Groups |
| NLB health fail | `/healthz` proxy Actuator UP, app dependencies, Nginx logs |
| ImagePullBackOff | GHCR secret cùng namespace, token còn hạn, digest có tồn tại |
| Pod Pending trên 2 nodes | CPU/RAM requests, EBS AZ và node placement; không tự tăng maxSize quá budget |

Ở mức này cần biết xem metrics app, không cần cài toàn Prometheus Operator trên cloud để demo. Có thể dùng port-forward backend management chỉ localhost:

```bash
kubectl -n urlshortener-eks port-forward --address 127.0.0.1 service/app 18081:8081
```

Terminal khác: `curl --fail http://127.0.0.1:18081/actuator/prometheus`. Không public management port. `kubectl top` cần metrics-server, không tự có ở mọi cluster; chưa cài thì đọc describe/events/logs và AWS node metrics.

## 22. Backup EKS trước khi dọn và nghiệm thu

Mục tiêu bước này: tạo bản backup PostgreSQL ra VMware, restore thử vào database riêng và lưu bằng chứng dự án. Chưa xóa cluster/PVC ở bước này. Với tài khoản đang bị chặn NLB, nghiệm thu UI/smoke qua port-forward và ghi rõ giới hạn đó.

### 22.1. Chuẩn bị trên VMware

Mở terminal SSH VMware mới; có thể giữ các cửa sổ port-forward đang dùng UI. Các lệnh Bash bên dưới chạy trong **cùng terminal VMware** để giữ các biến tên file/database:

```bash
cd ~/projects/url-shortener-infra
kubectl config use-context urlshortener-eks
kubectl -n urlshortener-eks get pods,pvc
mkdir -p .lab/eks/backups docs/evidence/eks
umask 077
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DUMP="$PWD/.lab/eks/backups/postgres-$STAMP.dump"
RESTORE_DB="restore_check_$(date -u +%Y%m%d%H%M%S)"
```

Cần `postgres-0` Ready và PVC Bound. Nếu credentials hết hạn, login lại profile nguồn như bài trước. Không cần truy cập NLB để exec backup. Tạm ngừng thao tác tạo/sửa link trên UI trong lúc so sánh dữ liệu; pg_dump tự tạo snapshot nhất quán của PostgreSQL, không phải snapshot đồng bộ với Kafka/Redis.

### 22.2. Tạo dump và checksum

```bash
if kubectl -n urlshortener-eks exec postgres-0 -- \
  sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$DUMP"; then
  test -s "$DUMP" && sha256sum "$DUMP" > "$DUMP.sha256"
else
  echo 'BACKUP FAILED: do not use this dump'
fi
ls -lh "$DUMP" "$DUMP.sha256"
sha256sum --check "$DUMP.sha256"
```

Cần có file dump không rỗng, checksum báo OK và không có lỗi pg_dump. Nếu có lỗi thì dừng sửa, chưa restore. Checksum xác minh file không đổi, không tự chứng minh database restore dùng được. File backup nằm trên ổ VMware, bên ngoài cluster EKS. Không thêm `-t` vào exec vì dump là binary.

### 22.3. Restore thử vào database mới

Chạy tạo DB mới; chỉ đi tiếp nếu lệnh thành công:

```bash
kubectl -n urlshortener-eks exec postgres-0 -- \
  sh -c 'createdb -U "$POSTGRES_USER" "$1"' sh "$RESTORE_DB"
```

Tên DB có timestamp để tránh đè database cũ. Không DROP database đang chạy. Restore file vừa tạo:

```bash
SECONDS=0
if kubectl -n urlshortener-eks exec -i postgres-0 -- \
  sh -c 'pg_restore -U "$POSTGRES_USER" -d "$1" --no-owner --exit-on-error' sh "$RESTORE_DB" \
  < "$DUMP"; then
  printf 'Restore database: %s\nElapsed seconds: %s\n' "$RESTORE_DB" "$SECONDS" \
    | tee "docs/evidence/eks/restore-$STAMP.txt"
else
  echo 'RESTORE FAILED: inspect the error; do not mark PASS'
fi
```

Database thật vẫn được app sử dụng như trước; DB restore chỉ dùng kiểm tra. Nếu lỗi thì đọc lỗi đầu tiên trước khi chạy lại; không restore lặp vào DB đã restore dở.

### 22.4. Đối chiếu số dòng các bảng

Tạo SQL kiểm tra trong thư mục riêng VMware:

```bash
cat > .lab/eks/backups/check-counts.sql <<'SQL'
SELECT format('SELECT %L AS table_name, count(*) AS row_count FROM %I.%I;',
              schemaname || '.' || tablename, schemaname, tablename)
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schemaname, tablename;
\gexec
SQL
```

Chạy cùng SQL trên database gốc và bản restore, ghi kết quả không chứa dữ liệu hàng/mật khẩu:

```bash
kubectl -n urlshortener-eks exec -i postgres-0 -- \
  sh -c 'psql -X -v ON_ERROR_STOP=1 -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < .lab/eks/backups/check-counts.sql > ".lab/eks/backups/source-counts-$STAMP.txt"
kubectl -n urlshortener-eks exec -i postgres-0 -- \
  sh -c 'psql -X -v ON_ERROR_STOP=1 -At -U "$POSTGRES_USER" -d "$1"' sh "$RESTORE_DB" \
  < .lab/eks/backups/check-counts.sql > ".lab/eks/backups/restored-counts-$STAMP.txt"
diff -u ".lab/eks/backups/source-counts-$STAMP.txt" ".lab/eks/backups/restored-counts-$STAMP.txt"
```

Chỉ so sánh khi cả hai lệnh psql thành công. Diff không in gì nghĩa số dòng các bảng khớp. Nếu app/Kafka vẫn ghi trong thời gian kiểm tra thì số dòng nguồn có thể thay đổi sau snapshot; khác biệt cần điều tra, chưa đủ kết luận dump hỏng. So sánh số dòng là kiểm tra cấu trúc/dữ liệu cơ bản; chưa chứng minh đầy đủ mọi giá trị hoặc nghiệp vụ của DB restore. Muốn chứng minh nghiệp vụ, cần bản app kiểm thử trỏ DB restore rồi smoke tương ứng; không đổi DB của app hiện tại trong bước này.

### 22.5. Giữ bản backup ngoài VM nếu muốn dọn VM sau này

Ngoài dump/checksum, giữ `.lab/eks/secrets.env` và `.lab/eks/smoke/.smoke.json` tương ứng ở nơi riêng tư; không đưa chúng lên Git. Chúng chứa password, chỉ sao lưu vào nơi bạn kiểm soát quyền truy cập.

Có thể copy cả thư mục dữ liệu lab EKS bằng **PowerShell Windows**, nếu muốn một bản riêng ngoài VMware:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\Documents\urlshortener-private-backup" | Out-Null
scp -r thanh@192.168.40.100:~/projects/url-shortener-infra/.lab/eks "$env:USERPROFILE\Documents\urlshortener-private-backup\"
```

Thay VMware IP nếu đã đổi. Thư mục này có thể gồm cả Docker GHCR login config; giữ riêng tư, không gửi lên chat/repo hay dùng làm evidence công khai. Backup PostgreSQL không chuyển Kafka pending events hoặc Redis JWT blacklist.

### 22.6. Lưu bằng chứng và đánh dấu đúng phần đã hoàn thành

**Quay lại terminal VMware**, repo infra:

```bash
kubectl --context urlshortener-eks get nodes -o wide > docs/evidence/eks/nodes.txt
kubectl --context urlshortener-eks -n urlshortener-eks get pods,pvc,services -o wide \
  > docs/evidence/eks/resources.txt
helm history urlshortener -n urlshortener-eks > docs/evidence/eks/helm-history.txt
```

Mở UI qua port-forward, chạy smoke `run` trong `.lab/eks/smoke` với URL `http://127.0.0.1:18080`, chụp kết quả PASS. Smoke đó kiểm tra database đang chạy, không phải DB restore. Chưa làm rollback thì đánh dấu chưa làm; Helm history đơn thuần chưa chứng minh rollback. Giữ report chi phí và case AWS chặn NLB làm incident thực tế.

Checklist dưới đây là danh sách bằng chứng cần có, không yêu cầu mọi mục phải PASS khi tài khoản chưa hỗ trợ. Với lab hiện tại, thay mục NLB UI bằng UI qua port-forward và ghi NLB/TLS chưa hoàn thành.

| Bằng chứng | Kết quả phải đo/ghi thật |
|---|---|
| Sơ đồ kind/EKS | Chỉ rõ request, DNS, data services, PVC và NLB |
| CI digest | Commit nào tạo backend/frontend đang chạy |
| Helm history + rollback | Lỗi có chủ đích, revision tốt được phục hồi |
| Persistence | Pod PostgreSQL mới vẫn thấy link/tài khoản cũ |
| Backup/restore | Dump checksum, DB restore riêng, thời gian đo |
| Cloud demo | EKS version, 2 nodes Ready, PVC Bound, NLB UI, smoke PASS |
| Cost report | Giờ tạo/xóa, loại node, EBS/NLB, credit/chi phí sau cập nhật |
| Incident | Một lỗi thật hoặc bài fault injection, nguyên nhân và cách xác minh sửa |

Mẫu ghi CV khi đã làm: “Triển khai URL Shortener bằng Helm trên kind và Amazon EKS; cấu hình probes, Secret và PVC/EBS, thử rollout/rollback và backup PostgreSQL; kiểm chứng bằng smoke test.” Chỉ thêm TLS/CD tự động/HPA/HA nếu đã làm và có bằng chứng.

## 23. Tắt local đúng cách

Ctrl+C port-forward và tunnel. Có thể giữ cluster để học tiếp, nhưng kind nodes vẫn dùng tài nguyên VM. Muốn quay Compose, scale app/data K8s về 0 hoặc xóa cluster **sau khi backup dữ liệu riêng kind**. Không chạy cùng workload vào cùng database ngoài ý muốn.

Xóa kind sẽ mất local PVC trong cluster đó:

```bash
kind get clusters
kind delete cluster --name urlshortener
```

Chỉ chạy khi đã đồng ý bỏ cluster local tên này. Compose named volumes cũ không phải volume của chart. Để khởi động Compose lại dùng lệnh up và release.env ở guide trước.

## 24. Dọn EKS cuối buổi — là một phần bắt buộc của bài

**EKS không có nút Stop cluster**. Scale workers về 0 vẫn mất phí control plane; NLB/EBS có thể còn phí. Không xóa EC2 worker bằng tay rồi nghĩ cluster đã hết.

**VMware**, xác nhận account/region/context và đã giữ backup ngoài cluster:

```bash
aws sts get-caller-identity
kubectl config use-context urlshortener-eks
kubectl -n urlshortener-eks get services,pvc
helm history urlshortener -n urlshortener-eks
```

**Bước phá hủy tài nguyên app** — chỉ chạy khi chấp nhận xóa lab:

```bash
helm uninstall urlshortener -n urlshortener-eks --wait --timeout 10m
kubectl -n urlshortener-eks get services,pvc
```

Giữ LBC chạy để nó xóa NLB/target groups và finalizers. Kiểm tra AWS Console NLB đúng lab đã được xóa trước khi gỡ controller/cluster. StatefulSet PVC thường được giữ lại khi uninstall. Sau backup, xóa **đúng ba PVC sau**, không xóa PVC toàn account:

```bash
kubectl -n urlshortener-eks delete pvc data-postgres-0 data-redis-0 data-kafka-0
```

ReclaimPolicy Delete sẽ xóa EBS đã cấp khi controller hoạt động. Chờ xác nhận EBS của PVC đúng lab đã xóa; không xóa volume EC2 cũ.

Giữ LBC policy cho đến khi cleanup load balancer xong. eksctl tạo association LBC bằng CloudFormation riêng; dọn association trước xóa cluster:

```bash
eksctl delete podidentityassociation -f .lab/eks/lbc-identity.yaml
eksctl delete cluster -f .lab/eks/cluster.yaml --wait
```

Nếu addon/association stack báo đang dùng IAM role, xem stack events và associations rồi dọn đúng stack do bài tạo; không force xóa role đang dùng bởi tài nguyên khác. `eksctl delete cluster` xử lý managed node group/VPC và các stack thuộc cluster, nhưng cần kiểm tra tài nguyên tạo ngoài luồng.

Sau thành công:

```bash
aws eks list-clusters --region "$AWS_REGION"
aws cloudformation list-stacks --region "$AWS_REGION" --stack-status-filter DELETE_FAILED --max-items 20
```

Rà Console đúng region: cluster name, workers có tag lab, NLB/target groups, EBS/snapshots, public IP, IAM roles/policy, logs và CloudFormation DELETE_FAILED. Nếu policy `UrlShortenerLabLoadBalancerController` chỉ của bài và không còn attachment, xóa policy riêng đó; không xóa policy đang dùng chung. Đợi Billing cập nhật và ghi cost report. Không xóa VPC/EC2 Terraform của bài trước trong quá trình dọn EKS.

## 25. Tài liệu và phạm vi kiểm chứng

Code hỗ trợ nằm trong `charts/url-shortener/`, `k8s/eks/`, `k8s/values-kind.yaml`, `k8s/values-eks.yaml`, `scripts/k8s-lab-env.sh`. Không bắt chép lại toàn bộ chart bằng tay; dùng Git rồi đối chiếu phụ lục nếu muốn đọc từng file.

Các nguồn chính: [eksctl networking](https://docs.aws.amazon.com/eks/latest/eksctl/vpc-configuration.html), [EKS access entries](https://docs.aws.amazon.com/eks/latest/eksctl/access-entries.html), [Pod Identity](https://docs.aws.amazon.com/eks/latest/eksctl/pod-identity-associations.html), [LBC Helm](https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html), [Kubernetes probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/).

Phạm vi kiểm chứng: lint/render Helm và cú pháp/config local có thể kiểm tra trong workspace; chưa tự tạo cluster kind/EKS, chưa kiểm chứng smoke/persistence/rollback cloud. Chỉ đánh dấu PASS khi bạn đã chạy và giữ kết quả thật. Nếu source/CLI/policy AWS đổi, kiểm tra release tương ứng trước khi thay version.
