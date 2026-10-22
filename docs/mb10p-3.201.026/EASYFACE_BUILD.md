# Build Native App Manager bằng EasyFace (Windows) và watchface ID

## 1. Thư mục project

```
mb10pro/wf_native_manager/
  module.fprj                      DeviceType="567" (Band 10 Pro), Screen Title="NativeMgr", 336x480
  images/preview.png               336x480 (ảnh dựng bố cục, chỉ để làm thumbnail)
  app/lua/main.lua                 Manager
  app/lua/mb10p_hello_3.201.026.elf
  app/lua/mb10p_app_safe_3.201.026.elf
  app/lua/mb10p_pm_inspect_3.201.026.elf
  app/lua/calc_logo_112.png
```

`module.fprj` cùng định dạng với Hello / Calc safe mà bạn đã build thành công bằng EasyFace v4.23. Không có ELF thử nghiệm
(`pm_remove`, `app_safe_nr`) trong gói (kiểm bởi `verify_all.sh`).

## 2. Các bước

1. Trên Linux (hoặc WSL): `bash tools/mb10p/verify_all.sh` phải in `ALL CHECKS PASSED`.
2. Chép cả thư mục `mb10pro/wf_native_manager` sang Windows. Mở `module.fprj` bằng EasyFace v4.23, thiết bị Mi Band 10 Pro,
   build ra `NativeMgr.face`. **Chưa cài lên đồng hồ.**
3. Đặt ID `193824672` (mục 3), rồi kiểm tra (cần Python 3 trên Windows: `py`):
   ```
   py tools\mb10p\face_id.py show  NativeMgr.face
   py tools\mb10p\face_id.py set   NativeMgr.face NativeMgr_193824672.face --id 193824672 --title NativeMgr
   py tools\mb10p\face_id.py check NativeMgr_193824672.face --id 193824672 --title NativeMgr
   py tools\mb10p\face_id.py extract NativeMgr_193824672.face out
   ```
4. Đối chiếu SHA-256 do `extract` in ra với `dist/mb10p-3.201.026/SHA256SUMS` (3 ELF) và `main.lua` trong repo. Khác → không cài.
5. Cài `NativeMgr_193824672.face`, rồi làm theo `HARDWARE_TEST_MANAGER_HELLO.md`.

## 3. Watchface ID: EasyFace lưu ở đâu

Phân tích hai gói EasyFace v4.23 thật của bạn (`Hello.face` 658 916 B, `Calc safe.face` 676 400 B), toàn bộ byte đều giải thích
được, **không có checksum hay chữ ký**:

| Offset | Nội dung |
|---|---|
| `0x000` | magic `0x1234A55A` |
| `0x020`, `0x0AC` | `E` = cuối vùng tệp |
| `0x028` (64 B) | **ID**, chuỗi ASCII thập phân, đệm NUL (cả hai gói: `167210065`) |
| `0x068` (68 B) | Title (`Hello`, `Calc safe`) = `Screen Title` trong `module.fprj` |
| `0x0D8` | số tệp |
| `0x110` | bảng bản ghi 16 B (type, 0, offset, size) + bản ghi kết thúc |
| offset | tệp: `u32 (size \| namelen<<24)`, 16 B 0, tên (`lua/main.lua`…), nội dung; căn 4 byte, kết thúc đúng tại `E` |
| `E` | `0, 336, 480, 336*480*4`, rồi ảnh preview thô |

Hai gói này cùng mang ID `167210065`, chứng tỏ EasyFace v4.23 dùng ID mặc định khi project không đặt ID. `module.fprj` của các
project này không có trường ID, và công cụ chuyển đổi `Fprj_to_wfDef` (Pzqqt) cũng để trống `id` và yêu cầu điền tay,
nên mình **không** thêm thuộc tính ID mò vào `module.fprj`.

- Nếu giao diện EasyFace của bạn có ô nhập ID (bạn đã đổi được Calculator sang `193824671`): đặt `193824672` ở đó, rồi chỉ chạy
  `face_id.py check …` để xác nhận.
- Nếu không: dùng `face_id.py set` như trên.

`face_id.py` kiểm tra toàn bộ cấu trúc ở bảng trên và **từ chối** mọi gói không khớp (sai magic, offset lệch, bảng tệp hỏng,
ID không phải số, rác sau NUL, preview sai kích thước, cắt cụt). `set` không sửa tại chỗ: ghi tệp mới, phân tích lại, và
chứng minh chỉ các byte trong `0x28..0x67` thay đổi. Nó từ chối ID không đủ 9 chữ số, ID đã thuộc package khác trong
`tools/mb10p/face_ids.tsv`, và gói có Title khác `NativeMgr`.

Đã kiểm offline: chạy trên chính hai gói của bạn (đổi bản sao `Calc safe.face` → `193824671`: 8 byte đổi, đều trong vùng ID;
gói cắt cụt và gói bị sửa 1 byte trong bảng tệp đều bị từ chối) và 16 kiểm tra trên gói tổng hợp
(`tools/mb10p/test_face_id.py`). **Chưa kiểm:** đồng hồ có nhận gói đã đổi ID bằng công cụ này hay không. Hai gói `.face`
của bạn không được đưa vào repo.

## 4. Không ghi đè Hello / Calc safe

- ID khác nhau (`face_ids.tsv`: `167210065` Hello, `193824671` Calc safe, `193824672` NativeMgr), Title khác nhau.
- Tệp `/data` của Manager có tên riêng (`/data/mb10p_mgr_*.elf`); logo dùng chung chỉ được chép khi chưa có, giữ nguyên nếu giống
  hệt, không ghi đè nếu khác.
- Watchface Hello gốc (upstream) chạy `rmmod mb10p_hello` rồi `insmod` khi mở: đừng mở nó trong lúc thử Manager, vì nó sẽ gỡ
  module Hello mà Manager đã nạp (Manager sẽ thấy hàng `lsmod` khác và từ chối REMOVE).

## 5. Đóng gói không cần EasyFace (`tools/mb10p/face_pack.py`) – CHƯA dùng trong pipeline

- Wine + `compile.exe`: chưa thử được — `compile.exe` (bản phát hành EasyFace) không có trong môi trường này và
  không tải được qua proxy; repo `m0tral/EasyFace` chỉ có README.
- `face_pack.py PROJECT OUT.face --id <9 chữ số>`: chỉ cho đúng dạng project ở đây (DeviceType 567, một widget Lua
  `app_lua%2Fmain.lua` 336×480, tệp phẳng trong `app/lua`, preview PNG 8-bit RGB/RGBA 336×480), chỉ dùng thư viện
  chuẩn Python. Phần header còn lại (bảng mục ở 0xB0, bản ghi kết thúc trỏ tới `main.lua`, preview BGRA alpha thẳng)
  được suy ra từ hai gói EasyFace v4.23 thật.
- `python3 tools/mb10p/test_face_pack.py <thư mục chứa Hello.face, Calc_safe.face>`: dựng lại cả hai gói từ nguồn
  ở commit `6d9ad0f` → **trùng từng byte** với bản EasyFace; thêm 14 kiểm tra (định dạng, tất định, từ chối project lạ).
- Chưa kiểm: preview RGB (không alpha) so với EasyFace; đồng hồ có nhận gói do Python tạo hay không. Gói thử:
  `Hello py` (ID `193824675`) = `Hello.face` đã cài thành công, chỉ khác ID/Title. Chỉ đưa packer vào pipeline tự động
  sau khi gói này được xác nhận trên máy.
