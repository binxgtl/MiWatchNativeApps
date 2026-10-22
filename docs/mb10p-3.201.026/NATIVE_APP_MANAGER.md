# Native App Manager (`mb10pro/wf_native_manager`)

**Trạng thái:** đã qua 42 kiểm tra logic với shell giả (`tools/mb10p/test_manager.lua`) và kiểm tra đột biến cho từng chốt an toàn.
**Chưa chạy trên đồng hồ. Chưa biên dịch bằng EasyFace** (không có compiler trong môi trường này).

## Nó làm gì (chỉ khi bạn bấm nút)

| Nút | Hành động | Chốt an toàn |
|---|---|---|
| `APP:` | chọn `hello` / `calc_safe` / `pm_inspect` | – |
| SCAN | cổng firmware; module nào đang nạp (`ours` nếu hàng `lsmod` khớp bản ghi, `?` nếu không); số module khác; `dmesg` dùng được không | `lsmod` không đọc được → báo lỗi, không hành động |
| INSTALL | kiểm tra cổng → `lsmod` → **từ chối nếu module trùng tên** → kiểm tra manifest (size + adler32) của file đóng gói → `cp` → so sánh từng byte với bản đích → `insmod` → `lsmod` lần nữa | PASS chỉ khi `insmod` ok **và** `lsmod` liệt kê module; mơ hồ → khóa |
| VERIFY | đọc dòng log của app trong `dmesg`: Hello/CalcSafe kiểm tra chuỗi mong đợi; PMInspect tóm tắt `flags`, callback, page, `DONE` | `dmesg` không dùng được → "UNKNOWN", không suy diễn |
| REMOVE | `kind=transient` (hello, pm_inspect): `rmmod`; `kind=registering` (calc_safe): **từ chối, chỉ reboot** | chỉ `rmmod` khi hàng `lsmod` hiện tại **bằng** hàng ghi lúc INSTALL; pm_inspect còn phải có `DONE`; sau `rmmod` phải thấy module biến mất |
| SNAP | snapshot trước/sau reboot, diff với lần trước (xem `OBSERVATION_CHECKLIST.md`) | chỉ đọc |

Cổng firmware (mỗi lần INSTALL/REMOVE): `ro.build.version == 3.201.026`; nếu đọc được `ro.build.id` thì phải bằng
`CONBINE_LTALM080_3.201.026` (không đọc được thì chỉ cảnh báo trong log).

## Những điều nó cố ý KHÔNG làm

- Không nạp module khi khởi động. Khi mở watchface, lệnh duy nhất chạy là `getprop ro.build.version`.
- Không `reboot`, không `rm`, không đụng package manager, không xóa/đặt lại watchface, không ghi firmware.
- Không `rmmod` mò: không xác nhận được danh tính module thì từ chối.
- Không chạy `mb10p_pm_remove.elf` / `mb10p_app_safe_nr.elf` (thử nghiệm; không đóng gói trong Manager).

## Trạng thái bền và khóa

Trạng thái (`/tmp/mb10p_mgr.state`: `key|module|hàng lsmod`) và khóa (`/tmp/mb10p_mgr.lock`) nằm trong **tmpfs** nên
**mất khi reboot, đúng như các module đã nạp**. Khóa đặt ra sau mọi kết quả mơ hồ (`UNCERTAIN`, `ANOMALY`, rmmod còn thấy module…)
và chặn INSTALL/REMOVE cho tới khi reboot; SCAN/VERIFY/SNAP vẫn dùng được.

## Thông báo lỗi và mã thật

Mọi lệnh được ghi vào log dạng `CMD <lệnh> -> ok=… code=… (raw=…)`; `insmod` thất bại hiện `code=` trên màn hình (ví dụ 17 = `EEXIST`:
trùng tên; 255 = lỗi chung). `os.execute` không bắt stderr: mã trả về là bằng chứng chính, nhưng giả định cột `NEXPORTS` của `lsmod` (nếu
sai Manager từ chối mọi thao tác thay đổi).

## Đóng gói

1. `bash tools/mb10p/verify_all.sh` phải in `ALL CHECKS PASSED`.
2. Biên dịch `mb10pro/wf_native_manager` bằng EasyFace (v4.23 hoặc tương thích, thiết bị Band 10 Pro). **Đặt ID package duy nhất**
   (xem bảng trong `MILESTONE.md`, mục D).
3. Nếu giải nén được package, kiểm tra 4 file nhúng (`mb10p_*_3.201.026.elf`, `calc_logo_112.png`) khớp `dist/…/SHA256SUMS` và manifest
   trong `main.lua`; không kiểm tra được thì ghi "chưa xác minh nhúng".
4. Nếu bạn sửa/đổi file nhúng, chạy lại `tools/mb10p/gen_manifest.py` (xem `REPRODUCE.md`); Manager từ chối file có size/adler32 sai.

## Thêm một app mới vào Manager

Thêm một dòng vào `APPS` (module, ELF, `dst`, `tag`, kiểu `transient`/`registering`), thêm file vào thư mục `app/lua` và vào lệnh
`gen_manifest.py`, thêm kịch bản vào `test_manager.lua`. Chỉ đánh dấu `transient` khi module **không để lại con trỏ nào vào bộ nhớ của nó**
sau khi hoàn tất (không đăng ký package manager, không timer/callback còn sống).
