# Milestone: Hardware PASS – Xiaomi Smart Band 10 Pro Global 3.201.026

Ngày ghi nhận: 2026-10-22. Thiết bị: Smart Band 10 Pro Global (p67gl), firmware `3.201.026`
(`CONBINE_LTALM080_T3.201.026_09041709`).

**Mức bằng chứng của tài liệu này:** phần phần cứng dưới đây là *chủ thiết bị báo lại*. Phiên làm việc của
mình không nhận được log, ảnh chụp màn hình hay file `.face` nào từ đồng hồ, nên mình không tự xác nhận
được chúng; mình ghi nguyên văn những gì bạn báo và không suy diễn thêm.

## A. Đã xác nhận trên thiết bị thật (chủ thiết bị báo)

| # | Kết quả | Ghi chú |
|---|---|---|
| A1 | Hello ELF: CHECK / LOAD / UNLOAD đều PASS | loader `mb10pro/wf_native_hello_test` |
| A2 | EasyFace v4.23 build thành công `Hello.face` và `Calc safe.face` | package `.face` không nằm trong repo |
| A3 | Hai watchface trùng ID `167210065` → Calculator bị từ chối ở `preInstall code=5` | nguyên nhân: trùng ID package |
| A4 | Đổi ID Calculator thành `193824671` → cài watchface thành công | |
| A5 | Calculator Safe: LOAD PASS | loader `mb10pro/wf_native_calc_safe` |
| A6 | Calculator xuất hiện như một ứng dụng riêng trong launcher của đồng hồ (bạn gọi là HyperOS), không chỉ chạy bên trong watchface | |
| A7 | Mở Calculator, thao tác cảm ứng và tính toán bình thường | |
| A9 | 2026-10-23: `Calc dec` (`193824674`), gói tạo bằng `face_pack.py` trên Linux: cài, START, 13/13 phép thử Decimal Calculator đúng, bàn phím không trễ; số 17 ký tự (`0.666666666666667`) bị khung hiển thị cắt chữ số cuối | ELF `f6251c33…` = `8600e41` + dòng `"%s"` (không phải binary của PR); gói `abcb50dc…` |
| A10 | Native App Manager, bản build bằng EasyFace (mã nguồn trước `45629d2`): PASS | bạn báo; bản r2 đóng gói bằng packer chưa thử |
| A8 | 2026-10-23: `Hello py` (`193824675`), gói `.face` tạo bằng `tools/mb10p/face_pack.py` **không qua EasyFace**: cài, mở, CHECK / LOAD / UNLOAD PASS | SHA-256 `0e2491eb…3078c50`; phạm vi: `EASYFACE_BUILD.md` mục 5 |

Điều này chứng minh trên máy thật: nạp ELF `ET_REL` bằng `insmod`, gọi đúng các địa chỉ firmware đã port
(`syslog`, `lv_timer_*`, `app_lookup`, `g_packagemanager_api->install`, `app_launcher_add`, các hàm LVGL của
`calc_page`) và đăng ký được app vào package manager và launcher của 3.201.026.

## B. Chưa thực hiện – KHÔNG được coi là đã kiểm chứng

- `rmmod` Calculator (cố ý không làm: xem `LIFECYCLE_AND_REBOOT.md`).
- Khởi động lại sau khi cài Calculator; trạng thái sau reboot (module, đăng ký, icon launcher, tệp trong `/data`).
- Cài lại sau reboot, nhiều chu kỳ cài–reboot–cài, rò rỉ bộ nhớ.
- Gỡ ứng dụng (bất kỳ cơ chế nào ngoài reboot).
- Có `dmesg` hay không, và syslog của module có xuất hiện ở đó không (Manager/Inspector dựa vào điều này
  để *xác minh*, nên chưa dùng được làm bằng chứng cho tới khi bạn thử).
- Hello: chu kỳ nạp → gỡ → nạp lại lần hai (bạn chỉ báo "CHECK / LOAD / UNLOAD PASS").
- Phím `%` đã sửa (`"%s"`) và các phép tính khác ngoài những gì bạn đã thử; độ ổn định lâu dài, pin, nhiệt.
- `mb10p_app.elf` gốc (xóa watchface hiện tại) – không chạy và không nên chạy.
- Tùy chọn thông báo `CALC_NOTIFY_ON_INSTALL`.
- Bất kỳ firmware nào khác (`3.101.043`, `3.201.016`…): bảng địa chỉ không được kiểm trên các bản đó trong nhánh này.
- Toàn bộ công cụ mới trong nhánh này: `wf_native_manager`, `mb10p_pm_inspect.elf` và các ELF trong
  `experimental/` **chưa chạy trên đồng hồ**.

## C. Kiểm tra offline do mình thực hiện (không phải phần cứng)

`bash tools/mb10p/verify_all.sh` → `ALL CHECKS PASSED`, gồm:
- Build sạch từ checkout mới của nhánh cho ra ELF **trùng từng byte** với `dist/` (hello `d1a2ca7d…a89369`,
  app_safe `48d810ed…007473`, tức đúng hai ELF bạn đã chạy nếu bạn dùng gói testkit trước).
- Từng ELF: `ET_REL`, ARM, các loại relocation (`ABS32`, `TARGET1`, `THM_CALL`) nằm trong bảng trình nạp
  hỗ trợ, không symbol UND, `.init_array`/`.fini_array` trỏ bằng `TARGET1`, mọi hàm có bit Thumb, không `__aeabi_*`,
  mọi địa chỉ tuyệt đối nằm trong bảng ánh xạ, soft-float (hello/tools) hoặc FPv5 một độ chính xác (app).
- Logic Lua với shell giả (tại thời điểm milestone; số hiện tại xem `NATIVE_APP_MANAGER.md`): 42 kiểm tra cho Manager (cộng phép thử đột biến: bỏ từng chốt an toàn thì ít nhất
  một kiểm tra fail) và 12 kịch bản cho loader Hello.

**Hãy xác nhận:** bạn đã chạy đúng hai ELF có SHA-256 ở trên (không phải bản biên dịch lại khác). Nếu không,
milestone chỉ áp dụng cho bản bạn thực sự chạy.

## D. ID package EasyFace (rút ra từ lỗi `preInstall code=5`)

Mỗi package watchface phải có **ID duy nhất**. Hai package sinh từ cùng một mẫu mang cùng ID `167210065`
và cái thứ hai bị từ chối. ID nằm trong gói `.face` (chuỗi ASCII ở offset `0x28`, xem `EASYFACE_BUILD.md`);
`module.fprj` không có trường ID. Bảng ID chính thức: `tools/mb10p/face_ids.tsv` (kiểm bởi `verify_all.sh`).

| Package | ID | Nguồn |
|---|---|---|
| Hello (bản đã build) | `167210065` | bạn báo (ID mặc định của EasyFace) |
| Calculator Safe | `193824671` | bạn đặt |
| Native App Manager | `193824672` | bản EasyFace đã cài, PASS (A10); r2 (packer) chưa thử |
| Calc dec | `193824674` | đóng gói bằng `build_faces.py`; PASS trên máy (A9) |
| Hello py (Hello Test, packer) | `193824675` | đóng gói bằng `build_faces.py`; PASS trên máy (A8) |
| Hello Test | *chọn ID mới, chưa dùng* | – |

## E. Điều chỉnh so với báo cáo trước của mình

- Báo cáo trước ghi "package manager giữ con trỏ vào bộ nhớ module (descriptor của app)". Đọc lại disassembly
  `install` cho thấy chính xác hơn: descriptor app được **sao chép vào heap** (cả `name`/`icon` được `strdup`),
  nhưng con trỏ callback trong bản sao và **con trỏ tới struct page** (không sao chép) vẫn trỏ vào bộ nhớ module.
  Kết luận "không `rmmod` sau khi đăng ký" vẫn đúng; lý do chi tiết đã sửa trong `LIFECYCLE_AND_REBOOT.md`.
- Số ký hiệu chưa giải quyết (`MB10P_UNRESOLVED`) là **11** định nghĩa, không phải 14 như mình ghi trước.
