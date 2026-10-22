# Thông tin cần quan sát trước/sau reboot để kết luận "trạng thái sạch"

Công cụ: `wf_native_manager` (nút **SNAP**, **SCAN**, **VERIFY**) + mắt nhìn launcher. Mọi lệnh đều ghi mã trả về thật vào
`/data/mb10p_manager.log` (tối đa 64 KiB). Log trên `/data` chưa có cách đọc từ điện thoại: **chụp màn hình sau mỗi bước**
(màn hình giữ 6 dòng cuối + tiêu đề). Chưa chạy trên máy: các giá trị "mong đợi" dưới đây là dự đoán, không phải kết quả.

## Quy trình

| Bước | Hành động | Ghi nhận |
|---|---|---|
| S0 | Reboot đồng hồ. Mở Manager → **SNAP** | Snapshot cơ sở (`boot=NEW`, chưa có diff) |
| S1 | Chọn `calc_safe` → **INSTALL**; chờ 2 giây; **VERIFY** | Kết quả INSTALL, VERIFY; mở Calculator, nhìn launcher |
| S2 | **SNAP** | Diff so với S0 |
| S3 | (Tùy chọn, G1) chọn `pm_inspect` → INSTALL → mở rồi đóng Calculator trong 90 giây → **VERIFY** (đợi `DONE`) → **REMOVE** | `flags`, callback, `page state` khi mở/đóng; REMOVE PASS |
| S4 | **Reboot** (nút vật lý/giữ nút theo hướng dẫn của Xiaomi; Manager cố ý không có lệnh reboot) | – |
| S5 | Mở Manager → **SNAP** (không INSTALL) | Phải hiện `boot: NEW since last marker` và diff so với S2 |
| S6 | **SCAN** | `calc_safe absent`, `hello absent`, `pm_inspect absent` |
| S7 | Nhìn launcher | Calculator vắng mặt, không ô trống/lỗi |
| S8 | **INSTALL** `calc_safe` lại → VERIFY | Cài lại được (module vắng sau reboot) |
| S9 | Lặp S4–S8 ba lần | `free` (log dòng `FREE:`) không giảm dần |

## Các khóa SNAP và ý nghĩa

| Khóa | Nguồn | Mong đợi sau reboot (S5) | Ghi chú |
|---|---|---|---|
| `boot` | marker `/tmp/mb10p_boot_marker` | `NEW` | tmpfs bị xóa khi reboot → bằng chứng đã reboot |
| `fw` | `getprop ro.build.version` | `3.201.026` | |
| `modules` | `lsmod` | không có `calc_safe`, `mb10p_hello`, `pm_inspect` | các module hệ thống khác tùy máy |
| `mod.<app>` | `lsmod` | `absent` | từ `loaded` trước reboot |
| `file./data/mb10p_com.m0tral.calc_safe.elf` | size:adler32 | **không đổi** (6256:13a93070) | file còn nhưng không tự nạp |
| `file./data/calc_logo_112.png` | size:adler32 | không đổi (19531:fc37a033) | icon app tham chiếu theo đường dẫn |
| `file./data/app/launcher/launcher.db` | size:adler32 (+ nếu >128 KiB chỉ băm 128 KiB đầu) | **quan trọng**: ghi lại có đổi sau INSTALL hay không | nếu đổi sau INSTALL và còn đổi sau reboot → launcher lưu id app |
| `file./data/persist.db` | size | ghi nhận | cơ sở kvdb chung |
| `file./data/nobusiness` | tồn tại? | **`absent`** | nếu `present` thì dừng: UI không khởi động lại |
| `prop.persist.record_app_install` / `app_func_bitmap` / `app_capability` / `launcher.guide` | `getprop` | ghi lại; so S0 ↔ S2 ↔ S5 | khóa có thể rỗng nếu `getprop` không hỗ trợ |
| `dmesg.<app>` | số dòng có tag `[calc_safe]`… | `0` | ring RAM bị xóa khi reboot; nếu `dmesg=n/a` thì mọi VERIFY chỉ là UNKNOWN |

Dòng log ngoài diff (không so tự động): `LS launcher:` (liệt kê `/data/app/launcher`), `FREE:` (đầu ra `free`),
`LSMOD[…] raw:` (nguyên văn `lsmod`, để xác nhận giả định cột `NEXPORTS`).

## Tiêu chí

| Kết luận | Điều kiện |
|---|---|
| **SẠCH** | S5 `boot=NEW`; S6 tất cả `absent`; S7 launcher bình thường; `file.*` của ta không đổi; `nobusiness=absent`; S8 cài lại được; S9 `free` ổn định |
| **SẠCH, CÓ DẤU VẾT** | Như trên nhưng `launcher.db` hoặc `persist.*` khác cơ sở: ghi lại thay đổi, theo dõi qua nhiều chu kỳ trước khi coi là vô hại |
| **KHÔNG SẠCH – DỪNG** | Module còn trong `lsmod` sau reboot; icon vẫn còn/launcher lỗi; `nobusiness=present`; SNAP/SCAN báo lỗi không đọc được; đồng hồ treo hoặc tự reboot khi mở launcher |

Ngoài snapshot, hãy ghi lại (bằng mắt): thời điểm Calculator xuất hiện sau INSTALL; hành vi khi nhấn icon sau khi gỡ (không có); độ
trễ khi mở launcher; có thông báo lạ trong danh sách thông báo hay không.

## Thông tin còn thiếu chỉ module mới trả lời được (G1)

`pm_inspect` ghi `NODE`/`PAGE` vào syslog: `flags` (xác nhận recoverable), con trỏ callback (xác nhận còn vào code module), số page,
`state/layer/kind/async_destroy/root/prev/next` của page ở trạng thái đóng và mở. Cần `dmesg`; nếu không có, hãy ghi "dmesg n/a"
và không suy diễn trạng thái callback.
