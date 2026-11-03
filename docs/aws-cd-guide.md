### 11.2. Cho GitHub Actions deploy lên EC2 thay bạn

**Luồng hiện tại dùng Access Key ID + Secret Access Key của IAM user riêng cho CD. Không cần Identity providers, OIDC provider, trust policy hay AWS_ROLE_ARN.** Làm lại từ 11.2.1 đến 11.2.11; hướng dẫn bỏ qua CD trước đó không còn áp dụng.

Access key chỉ xác thực danh tính; nó không vượt giới hạn của project/tài khoản. Nếu AWS chặn tạo key hoặc thay đổi Security Group ở cấp tài khoản, cần xử lý thông báo đó trước. Không nâng cấp tài khoản chỉ vì hướng dẫn yêu cầu.

**Mục tiêu:** trước đây bạn SSH vào EC2 và chạy deploy. Sau bước này, bạn vào GitHub, nhập hai image đã build ở bước 6, bấm **Run workflow**; GitHub chạy deploy trên EC2 và kiểm tra ứng dụng. Bản này chạy bằng nút bấm, **chưa tự deploy mỗi lần merge backend/frontend**.

```text
Bạn chọn digest backend + frontend trong GitHub repo infra
  → GitHub Actions xác thực AWS bằng IAM access keys trong GitHub Secrets
  → mở SSH chỉ cho IP runner trong thời gian deploy
  → SSH vào EC2, upload Compose/scripts và manifest image
  → EC2 pull image GHCR, chạy deploy.sh và smoke test
  → GitHub xóa rule SSH tạm
```

**Ba quyền riêng:** IAM user có access key cho runner gọi AWS API thêm/xóa rule Security Group; key SSH cho runner đăng nhập `ubuntu`; Docker login GHCR trên EC2 cho EC2 quyền tải image. Ba loại key/token này không thay thế nhau.

Ví dụ dùng Sydney `ap-southeast-2` và Elastic IP `32.237.9.46` của phiên lab hiện tại. Nếu đã thay hạ tầng, dùng thông tin mới. Mỗi phần ghi rõ thao tác ở Windows, VMware, EC2 hay trình duyệt.

#### 11.2.1. Chuẩn bị EC2 và lưu bản deploy tốt để rollback

**Trên EC2**, trong phiên SSH user `ubuntu`:

```bash
cd /opt/url-shortener
test -s .env && test -s release.env && echo 'PASS env/release exist'
docker info >/dev/null && echo 'PASS ubuntu can use Docker'
curl --fail http://127.0.0.1:8080/healthz
```

Nếu chưa có `.smoke.json`, khởi tạo một lần:

```bash
bash scripts/smoke.sh init http://127.0.0.1:8080
```

Nếu đã có fixture thì không init lại. Kiểm tra và lưu release hiện tại làm mốc rollback:

```bash
bash scripts/smoke.sh run http://127.0.0.1:8080
bash scripts/deploy.sh /opt/url-shortener/release.env
test -s releases/current.env && echo 'PASS rollback baseline exists'
```

Deploy sẽ recreate app/frontend bằng image hiện tại, có gián đoạn ngắn. Cần thấy `PASS deployment`. Nếu pull báo `unauthorized`, Docker login GHCR lại **trên EC2 bằng user ubuntu** như bước 10; login trên VMware không truyền sang EC2. Chỉ đi tiếp khi các kiểm tra PASS.

Workflow không upload `.env`, mật khẩu GHCR hay `.smoke.json`; chúng phải có sẵn trên EC2. PostgreSQL/Redis/Kafka phải đang chạy trước khi gọi deploy script.

#### 11.2.2. Ghi lại thông tin AWS và tên repo infra

**GitHub:** mở repo chứa `compose/`, `scripts/`, `workflow-examples/`. Đây là repo **infra**, không phải frontend/backend. Ghi chính xác `OWNER/REPO` trên URL, ví dụ `ThanhND05/url-shortener-infra` nếu đó là URL thật. Tên thư mục local chưa đủ để kết luận tên repo GitHub.

**AWS Console:** ghi Account ID. Vào **EC2 → Instances → chọn instance lab → Security → bấm Security Group**. Lấy **Group ID**, không dùng tên group, VPC ID hay instance ID. Group ID ở phiên lab trước là `sg-0e31ccff000f7ac27`; kiểm tra lại nếu đã tạo lại hạ tầng.

Bạn cần bốn thông tin: Account ID, region, Group ID và `OWNER/REPO`.

#### 11.2.3. Tạo GitHub Environment

**GitHub repo infra → Settings → Environments → New environment**:

1. Đặt tên chính xác `aws-lab`, bấm **Configure environment**.
2. Trong **Deployment branches and tags**, nếu có, chọn **Selected branches and tags**, thêm branch `main`.
3. Giữ trang này để thêm variables/secrets bên dưới. Nếu không thấy Environments, kiểm tra quyền quản trị repo và gói GitHub có hỗ trợ cho loại repo đang dùng không.

Environment chứa cấu hình cho deploy AWS, không tạo thêm EC2. Workflow hiện tại cũng kiểm tra chỉ chạy trên `main`.

#### 11.2.4. Tạo IAM user riêng và cấp quyền CD

**AWS Console → IAM → IAM users → Create user**:

1. User name: `github-url-shortener-deploy`.
2. Không bật console access; user này dùng cho workflow.
3. Không gắn `AdministratorAccess` hoặc `AmazonEC2FullAccess`; tạo user rồi thêm policy giới hạn bên dưới. Không cần xóa hay đổi quyền user `devops-lab` đang dùng cho Terraform.
4. Mở user vừa tạo → **Permissions → Add permissions → Create inline policy → JSON**. Nếu giao diện đặt **Create inline policy** ở menu khác, chọn thao tác tạo inline policy cho chính user đó.

Dán policy sau, thay `YOUR_ACCOUNT_ID` và `YOUR_SG_ID`; region phải là region EC2 thật. Lấy thông tin ở 11.2.2:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress"
    ],
    "Resource": "arn:aws:ec2:ap-southeast-2:YOUR_ACCOUNT_ID:security-group/YOUR_SG_ID"
  }]
}
```

Đặt policy name `manage-lab-ssh-rule`, lưu. User chỉ có quyền thêm/xóa ingress trên group lab; workflow dùng để mở SSH cho IP runner `/32` rồi thu hồi. Không cần quyền tạo/xóa EC2 hoặc Terraform. Policy cho phép thay đổi ingress trên group này; script hiện tại chỉ thêm/xóa rule runner.

Phiên đang tạo user/key/policy cần quyền IAM tương ứng; riêng `AmazonEC2FullAccess` không đủ. Nếu gặp `AccessDenied`, xem quyền và giới hạn tài khoản; không giải quyết bằng cách tạo root access key.

#### 11.2.5. Tạo access key và lưu vào GitHub Secrets

**AWS → IAM → IAM users → github-url-shortener-deploy → Security credentials → Access keys → Create access key**:

1. Chọn use case **Third-party service** cho GitHub Actions nếu giao diện có; đọc/xác nhận lựa chọn dùng access key.
2. Description có thể đặt `github-actions-aws-lab`, rồi **Create access key**.
3. Giữ trang hiển thị **Access key ID** và **Secret access key** để nhập thẳng vào GitHub. Secret key chỉ xem được lúc tạo; nếu mất phải tạo key khác, không xem lại được. [Quản lý IAM access keys](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html).

**GitHub repo infra → Settings → Environments → aws-lab → Environment secrets → Add environment secret**. Tạo hai secret riêng:

| Name | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | Access key ID của user CD vừa tạo |
| `AWS_SECRET_ACCESS_KEY` | Secret access key cùng cặp |

Dán nguyên giá trị, không thêm dấu ngoặc kép. Không đưa chúng vào `.env`, `release.env`, YAML, repo hoặc chat. Không dùng credentials tạm của phiên `aws login` để điền hai secret này; phiên đó có thời hạn và thường cần thêm session token. Luồng ở đây dùng cặp key dài hạn của IAM user riêng.

Workflow lấy key bằng `aws-actions/configure-aws-credentials`:

```yaml
- name: Configure AWS credentials from IAM user keys
  uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    aws-region: ${{ vars.AWS_REGION }}
```

Không còn `role-to-assume` và không cần `id-token: write`. Mẫu đã được sửa trong repo. [Cấu hình action chính thức](https://github.com/aws-actions/configure-aws-credentials).

Khi kết thúc lab: **IAM → user CD → Security credentials → chọn key → Deactivate**, rồi xóa key khi không còn cần. Khi đổi key: tạo cặp mới, cập nhật cả hai GitHub secrets, chạy thử thành công, rồi deactivate/xóa cặp cũ. Nếu key bị lộ, thu hồi ngay và thay cặp mới.

#### 11.2.6. Thêm ba variables trên GitHub

**GitHub repo infra → Settings → Environments → aws-lab → Environment variables → Add environment variable**. Tạo từng biến:

| Name | Value |
|---|---|
| `AWS_REGION` | `ap-southeast-2` |
| `AWS_SG_ID` | Group ID đã kiểm tra ở 11.2.2 |
| `VM_HOST` | `32.237.9.46`, chỉ IP, không thêm `ubuntu@` hay `http://` |

Tên `VM_HOST` có sẵn trong workflow; ở đây nó chỉ **EC2**, không phải VMware. Nếu đã thêm `AWS_ROLE_ARN` trước đó, workflow mới không dùng biến này; có thể xóa khỏi Environment.

#### 11.2.7. Thêm SSH private key vào GitHub Secret

**Windows PowerShell:** copy key vào clipboard, không in ra terminal:

```powershell
Get-Content -Raw "$env:USERPROFILE\Documents\url-shortener-lab.pem" | Set-Clipboard
```

**GitHub → Environment aws-lab → Environment secrets → Add environment secret**:

- Name: `VM_SSH_KEY`.
- Value: dán toàn bộ nội dung key, gồm dòng `BEGIN ... PRIVATE KEY`, các dòng giữa và `END ... PRIVATE KEY`.
- Bấm **Add secret**. Không nhập đường dẫn file, public key hay mật khẩu GitHub. Không commit key vào repo hay gửi key lên chat.

#### 11.2.8. Thêm thông tin xác minh EC2

Secret `VM_KNOWN_HOSTS` giúp runner kiểm tra mình đang kết nối đúng EC2.

**Trong phiên SSH EC2 đã xác minh trước đó**, lấy fingerprint host:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

**Trên VMware**, lấy public host key và xem fingerprint:

```bash
ssh-keyscan -T 10 -t ed25519 32.237.9.46 > /tmp/url-shortener-ec2-known-hosts
ssh-keygen -lf /tmp/url-shortener-ec2-known-hosts
```

So sánh hai giá trị `SHA256:...`: phải trùng. Nếu khác, dừng kiểm tra IP/máy. Không dùng kết quả `ssh-keyscan` chưa đối chiếu. Nếu trùng, **trên VMware** chạy:

```bash
cat /tmp/url-shortener-ec2-known-hosts
```

Copy dòng dạng `32.237.9.46 ssh-ed25519 AAAA...` vào **GitHub → Environment aws-lab → Environment secrets → Add environment secret**:

- Name: `VM_KNOWN_HOSTS`.
- Value: toàn bộ dòng host key vừa copy, không phải chỉ fingerprint `SHA256:...`.

Đến đây phải có **3 variables và 4 secrets** (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `VM_SSH_KEY`, `VM_KNOWN_HOSTS`). Token GHCR không thêm ở đây vì EC2 đã Docker login ở 11.2.1.

#### 11.2.9. Bật file workflow trong repo infra

**Windows PowerShell:**

```powershell
cd D:\privateProject\projects\url-shortener-infra
New-Item -ItemType Directory -Force .github\workflows | Out-Null
Test-Path .github\workflows\deploy-lab.yml
```

Nếu kết quả `False`, copy mẫu:

```powershell
Copy-Item workflow-examples\deploy-lab.yml .github\workflows\deploy-lab.yml
```

Nếu `True`, review/so sánh file đang có với mẫu mới rồi cập nhật bước credentials sang IAM keys như 11.2.5, bỏ `role-to-assume` và `id-token: write`. Giữ các chỉnh sửa riêng cần thiết. File cần dùng Environment `aws-lab`, trigger `workflow_dispatch`, và hai input `backend_image`, `frontend_image`.

Review file trong IDE rồi commit riêng workflow:

```powershell
git status --short
git add .github/workflows/deploy-lab.yml
git commit -m "ci: add AWS lab deployment workflow"
git push
```

Nếu đang ở nhánh làm việc, mở PR và merge vào `main` như bước 6. Workflow phải có trên branch mặc định `main` để hiện nút chạy. `compose/` và `scripts/` hiện tại cũng cần đã commit/push, vì runner lấy chúng từ GitHub.

File trong `workflow-examples/` chỉ là mẫu; GitHub thực thi file trong `.github/workflows/`.

#### 11.2.10. Chạy lần đầu bằng release hiện tại

**EC2:** xem hai image đang dùng. File này chỉ chứa tham chiếu image, không phải mật khẩu `.env`:

```bash
cd /opt/url-shortener
cat release.env
```

**GitHub repo infra → Actions → Deploy AWS Lab → Run workflow**:

1. Branch: `main`.
2. `backend_image`: dán nguyên giá trị bên phải `BACKEND_IMAGE=`.
3. `frontend_image`: dán nguyên giá trị bên phải `FRONTEND_IMAGE=`.
4. Giá trị phải dạng `ghcr.io/...@sha256:` kèm đủ 64 ký tự hex, không dán tên biến hoặc dấu ngoặc kép.
5. Bấm **Run workflow**, mở run vừa tạo xem từng step.

Lần đầu dùng cùng release để kiểm tra quyền/kết nối/CD; chưa cần sửa code ứng dụng. Workflow upload config/scripts, recreate app/frontend, chạy health/smoke và thu hồi SSH rule. Có gián đoạn ngắn, chưa phải zero downtime.

**Cần thấy:** workflow xanh, log `PASS deployment`, step `Remove runner SSH rule` thành công, UI vẫn dùng được. Trên EC2 kiểm tra:

```bash
cd /opt/url-shortener
cat releases/current.env
bash scripts/smoke.sh run http://127.0.0.1:8080
```

**AWS Console → EC2 → Security Groups → group lab → Inbound rules:** xác nhận rule SSH tạm của runner đã biến mất; rule SSH IP quản trị `/32` của bạn vẫn còn. Nếu runner mất kết nối hoặc cleanup lỗi, `always()` không bảo đảm xóa được rule: kiểm tra và xóa đúng rule runner còn sót, giữ rule quản trị của mình.

#### 11.2.11. Deploy phiên bản mới và thử phục hồi khi lỗi

Luồng cập nhật thường ngày sau khi lần đầu PASS:

1. Sửa backend/frontend → PR → merge `main` ở repo tương ứng.
2. Chờ CI build/scan/push xanh; lấy image digest từ artifact như bước 6.
3. Vào **repo infra → Actions → Deploy AWS Lab → Run workflow**, nhập cặp digest muốn deploy. Chỉ đổi backend thì giữ nguyên digest frontend và ngược lại.
4. Kiểm tra workflow, smoke, UI và `releases/current.env` trên EC2.

Để thử đường xử lý lỗi trên lab, ghi lại cặp digest tốt. Chạy workflow với frontend tốt, backend tham chiếu đúng repo nhưng digest không tồn tại (ví dụ thay phần digest bằng 64 ký tự `0`). Gate định dạng chấp nhận nhưng pull thất bại. Cần thấy workflow đỏ, script phục hồi bản cũ, ứng dụng vẫn hoạt động. Bài này kiểm tra phục hồi khi pull thất bại; chưa chứng minh rollback lỗi ứng dụng sau khởi động. Muốn thử trường hợp đó cần chuẩn bị riêng một image lab có lỗi.

Script lưu release tốt vào `releases/current.env`, release trước đó vào `releases/previous.env` nếu có. Rollback phục hồi image, không hoàn tác migration DB, `.env` hoặc Compose/scripts vừa upload. Chỉ dùng image và schema tương thích.

| Lỗi ở step | Kiểm tra trước |
|---|---|
| Configure AWS credentials / InvalidClientTokenId / SignatureDoesNotMatch | Hai GitHub secrets thuộc cùng cặp key, key Active; không dùng credentials tạm hoặc key đã xóa |
| Open SSH / AccessDenied | Key thuộc đúng IAM user CD, inline policy đúng Account ID/region/Group ID; giới hạn tài khoản có chặn API không |
| SSH timeout | IP `VM_HOST`; EC2 đang chạy; runner rule được tạo trên đúng SG |
| Permission denied (publickey) | Secret `VM_SSH_KEY` đủ dòng, đúng key pair; user `ubuntu` |
| Host key verification failed | `VM_KNOWN_HOSTS` là dòng host key của đúng IP, đã đối chiếu fingerprint |
| Missing release/env/smoke fixture | Hoàn thành 11.2.1; không upload file bí mật vào repo để chữa |
| GHCR unauthorized | Docker login trên EC2 bằng user ubuntu, token có `read:packages` và quyền đọc package |
| Health/smoke fail | Xem log app/frontend trên EC2, không bỏ smoke để workflow xanh |

**Hoàn thành khi:** deploy bằng nút GitHub thành công, đã thử phục hồi release, SSH rule tạm được thu hồi và bạn giải thích được quyền IAM user/SSH/GHCR dùng ở đâu.

Backup S3 định kỳ là bài mở rộng sau CD. Khi làm tiếp, dùng `scripts/backup-to-s3.sh`; instance role, cron và freshness check ở phụ lục phần 8.3. Không lưu AWS access key vào cron.
