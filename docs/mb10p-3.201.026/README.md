# Xiaomi Smart Band 10 Pro – Global 3.201.026: native ELF (nhánh `mb10p-global-3.201.026`)

Nhánh của fork cá nhân; **không** gửi lên upstream (`m0tral/MiWatchNativeApps`). Nền: upstream commit `a392529`.

| Tài liệu | Nội dung |
|---|---|
| [MILESTONE.md](MILESTONE.md) | Hardware PASS (chủ thiết bị báo) tách khỏi phần chưa thử và phần kiểm tra offline; ID package |
| [LIFECYCLE_AND_REBOOT.md](LIFECYCLE_AND_REBOOT.md) | boot flow, nội bộ package manager, hành vi sau reboot, thiết kế gỡ cài đặt an toàn theo tầng và cổng nâng cấp |
| [OBSERVATION_CHECKLIST.md](OBSERVATION_CHECKLIST.md) | thông tin cần quan sát trước/sau reboot, tiêu chí "sạch" |
| [NATIVE_APP_MANAGER.md](NATIVE_APP_MANAGER.md) | Manager: màn hình, nhận diện firmware/build ID, chốt an toàn, những điều nó không làm |
| [HARDWARE_TEST_MANAGER_HELLO.md](HARDWARE_TEST_MANAGER_HELLO.md) | checklist thử Manager trên máy, giai đoạn 1: chỉ Hello |
| [EASYFACE_BUILD.md](EASYFACE_BUILD.md) | build `.face` trên Windows, định dạng gói, đặt/kiểm watchface ID (`tools/mb10p/face_id.py`) |
| [REPRODUCE.md](REPRODUCE.md) | tái tạo build, SHA-256, những gì cố ý không đưa vào repo |
| [SYMBOLS.tsv](SYMBOLS.tsv) | ánh xạ ký hiệu → địa chỉ 3.201.026 (kèm bằng chứng) |

Kiểm tra nhanh: `bash tools/mb10p/verify_all.sh`.

Nguyên tắc: không sửa/flash firmware; không nạp module khi boot; gỡ module đăng ký package manager = reboot cho tới khi các cổng G1–G5
trong `LIFECYCLE_AND_REBOOT.md` có log thật.
