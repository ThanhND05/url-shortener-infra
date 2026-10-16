# Incident lab: <tên>

- Ngày/giờ và timezone:
- Commit/images/machine:
- Cách gây lỗi và giới hạn phạm vi:
- Backup/recovery chuẩn bị trước:
- Ảnh hưởng quan sát được: redirect/auth/analytics/data

## Timeline

| Thời gian | Hành động hoặc bằng chứng |
|---|---|
| T0 | Gây lỗi |
| T1 | Phát hiện từ log/metric/alert |
| T2 | Khôi phục |
| T3 | Smoke test PASS |

## Nguyên nhân và kiểm chứng

Giả thuyết, log/metric củng cố hoặc bác bỏ; không đoán chỉ từ HTTP 502.

## Recovery

Lệnh thực hiện, kiểm tra dữ liệu, thời gian thực đo, việc còn lỗi.

## Phòng ngừa và giới hạn

Issue sửa cụ thể; điều lab chưa chứng minh; artifact đã che secret.
