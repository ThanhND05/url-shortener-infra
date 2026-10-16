# URL Shortener Infrastructure

Repo chính thức cho cấu hình triển khai và vận hành URL Shortener: Ubuntu Server trên VMware trước, EC2 sau. Thư mục `devops-lab-kit` ở workspace cũ chỉ là bản mẫu, không cần copy nó sang VM.

## Cấu trúc

```text
projects/
├── url_shortener_be/
├── url_shortener_fe/
└── url-shortener-infra/
    ├── compose/
    ├── scripts/
    ├── monitoring/
    ├── environments/
    │   ├── dev/         # GCP hiện có
    │   └── aws-lab/     # AWS lab, state riêng
    ├── modules/         # GCP hiện có
    ├── bootstrap/
    └── workflow-examples/
```

## Cách làm việc

1. Sửa source/config trên Windows trong repo tương ứng, commit/push lên GitHub.
2. VM clone ba repo một lần; các lần sau `git pull --ff-only` đúng branch.
3. Build/run ở repo infra. Đến giai đoạn CI, pull image GHCR thay cho build source trên server.
4. `.env`, fixture `.smoke.json`, backup và release manifest là dữ liệu riêng server, không commit.

Ví dụ trên **Ubuntu VM**, sau khi đã clone repo và áp dụng profile/security/factory backend theo hướng dẫn:

```bash
cd ~/projects/url-shortener-infra
bash scripts/init-env.sh
# Sửa .env: VM IP, WEB_BIND=0.0.0.0 và các URL có port 8080.
docker compose --env-file .env -f compose/compose.yml -f compose/compose.vm.yml config --quiet
docker compose --env-file .env -f compose/compose.yml -f compose/compose.vm.yml build
docker compose --env-file .env -f compose/compose.yml -f compose/compose.vm.yml up -d --wait --wait-timeout 300
bash scripts/smoke.sh init
bash scripts/smoke.sh run
```

Chạy `init-env.sh` một lần, các lần sau sửa `.env` đang có. Không xóa env/volume để cập nhật code.

## File dùng theo giai đoạn

| Giai đoạn | File |
|---|---|
| Chuẩn bị backend | `backend-examples/application-lab.yaml`, thay đổi Java theo implementation guide |
| Chạy VMware | `compose/compose.yml`, `compose/compose.vm.yml`, `compose/nginx.conf` |
| Kiểm tra/deploy | `scripts/smoke.sh`, `deploy.sh`, `rollback.sh` |
| CI ứng dụng | Copy mẫu backend/frontend từ `workflow-examples/` vào repo ứng dụng tương ứng |
| Monitoring/benchmark | `monitoring/`, `load-tests/` |
| Backup/restore | `scripts/backup.sh`, `restore.sh`, `compose/compose.restore.yml` |
| AWS | `environments/aws-lab/`, `bootstrap/` |
| CD AWS | Bật mẫu `workflow-examples/deploy-lab.yml` sau khi cấu hình Environment/OIDC/SSH |
| Mở rộng sau cùng | `k8s/`, backup S3 |

`.github/workflows/terraform-ci.yml` hiện format-check toàn repo và init/validate môi trường GCP; mẫu validate AWS chưa được bật tự động. Chạy `terraform fmt`, `init -backend=false`, `validate` cho `environments/aws-lab` trước khi commit và bổ sung CI AWS khi đến bài đó. Không dùng chung state GCP/AWS.

## Nếu đã chạy từ kit trên VM

Giữ thư mục kit cũ và volumes đang có. Clone repo infra cạnh hai repo ứng dụng, copy **chỉ** file riêng server cần giữ (`.env`, `.smoke.json`, manifest/release history) từ kit sang infra; kiểm tra diff config trước khi dùng. Cả hai Compose dùng project name `urlshortener`, vì vậy cùng trỏ đến named volumes; không chạy hai bản cấu hình cùng lúc, không `down -v`.

Với VM chưa có kit/ứng dụng chạy: chỉ cần clone repo infra, không có bước SCP kit.

Hướng dẫn chi tiết ở workspace: `DEVOPS_IMPLEMENTATION_GUIDE_URL_SHORTENER.md`. Phạm vi kiểm chứng: [docs/VALIDATION.md](docs/VALIDATION.md).
