# Phạm vi kiểm chứng repo infra

Cập nhật: 16/10/2026. Compose/scripts/monitoring/AWS lab đã được đưa vào repo `url-shortener-infra` từ giai đoạn VMware; file GCP đang có trong `environments/dev`, `modules` và workflow hiện hành được giữ riêng.

Không sao chép `.env`, secret, fixture `.smoke.json`, release history, state hay backup từ Windows vào repo. `.gitignore` bổ sung các dữ liệu riêng; `.gitattributes` giữ LF cho shell script và cấu hình text.

Các kiểm tra tĩnh có thể chạy lại bằng `validate_devops_lab_kit.py` ở workspace root (tên cũ, nay kiểm tra repo infra): parse YAML, bash -n, đồng bộ code excerpt trong hướng dẫn, render Compose cho VMware/restore/monitoring/kind và kiểm tra build/bind paths. Script kiểm tra dùng PyYAML/Git Bash/Docker Compose có trên Windows hiện tại, không phải dependency runtime trên VM.

Các kết quả helper đã kiểm tra trong lần viết hướng dẫn: tạo env không ghi đè, thay placeholder và validate release manifest hợp lệ/sai/trùng/thiếu key. Bản copy vào infra giữ cùng nội dung script; lần chuyển repo không thay logic ứng dụng.

Chưa chạy build/test ứng dụng, Docker stack trên VMware, Terraform CLI hoặc cloud deploy trong phiên này. Việc parse/config thành công không chứng minh ứng dụng end-to-end hoạt động. Thực hiện các checkpoint trong implementation guide trên VM trước rồi mới AWS.

Kết quả lần chuyển repo: 19 file YAML parse thành công, 9 script Bash qua `bash -n`, 4 code excerpt trong guide khớp file infra, 5 tổ hợp Compose render thành công và build/bind paths trỏ đúng file. Git ignore đã kiểm tra cho env/fixture/manifest/release history/backup/state. File GCP tracked hiện có giữ nguyên; thay đổi tracked chỉ bổ sung `.gitignore`, phần lab là file mới. Chưa commit hoặc push các thay đổi này.
