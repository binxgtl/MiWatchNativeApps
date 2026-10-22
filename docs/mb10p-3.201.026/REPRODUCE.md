# Tái tạo build và kiểm tra (fw 3.201.026)

## Yêu cầu
`arm-none-eabi-gcc` (đã dùng bản có `-mcpu=cortex-m33`, `fpv5-sp-d16`), `binutils` ARM, `lua5.4`, `luac`, `python3`, `sha256sum`.
EasyFace (Windows, v4.23 hoặc tương thích) chỉ cần để đóng gói watchface; không có trong repo.

## Lệnh
```sh
git checkout mb10p-global-3.201.026
sh build_mb10p.sh 3201026          # build/3.201.026/{mb10p_hello,mb10p_app_safe,mb10p_pm_inspect,mb10p_app}.elf
                                   # build/3.201.026/experimental/{mb10p_pm_remove,mb10p_app_safe_nr}.elf
bash tools/mb10p/verify_all.sh     # build sạch + so với dist/ + kiểm tra ELF + manifest + Lua + vệ sinh repo
```
Build chính xác (cờ trong `build_mb10p.sh`): `-mcpu=cortex-m33 -mthumb -ffreestanding -nostdlib -fno-jump-tables -fno-stack-protector -Os
-DMB10P_FW_VERSION=3201026`; hello/pm-tool soft-float, app hard-float `fpv5-sp-d16`; liên kết `ld -r -T mb10pro/mb10pro.ld` (ET_REL).
`mb10p_app.elf` (bản gốc có xóa watchface) vẫn được build nhưng **không** nằm trong `dist/` và không được đóng gói.

## SHA-256 (`dist/mb10p-3.201.026/SHA256SUMS`)
| File | Vai trò | Trạng thái |
|---|---|---|
| `mb10p_hello.elf` | log "loaded/hello/unloaded" | chạy trên máy [HW] (theo báo cáo) |
| `mb10p_app_safe.elf` | Calculator không đụng watchface | chạy trên máy [HW] |
| `mb10p_pm_inspect.elf` | đọc trạng thái package manager | **chưa chạy** |
| `experimental/mb10p_pm_remove.elf` | gỡ đăng ký (luôn từ chối trong bản dựng này) | **chưa chạy, thử nghiệm** |
| `experimental/mb10p_app_safe_nr.elf` | như app_safe nhưng `flags=0x08` (chỉ khác 1 byte `.data`) | **chưa chạy, thử nghiệm** |

## Watchface và manifest
```sh
# sau khi thay ELF trong mb10pro/wf_native_manager/app/lua/:
python3 tools/mb10p/gen_manifest.py mb10pro/wf_native_manager/app/lua \
  mb10p_hello_3.201.026.elf mb10p_app_safe_3.201.026.elf mb10p_pm_inspect_3.201.026.elf calc_logo_112.png
```
Thư mục watchface: `wf_native_hello` (upstream, thêm hàng 3.201.026), `wf_native_hello_test` (loader quan sát được), `wf_native_calc_safe`,
`wf_native_manager`. Mỗi cái cần **ID package duy nhất** khi biên dịch (xem `MILESTONE.md`, mục D).

## Ánh xạ địa chỉ
`platform/mb10p/fw_3.201.026/miwear_system.h` (đầu vào của build) và `SYMBOLS.tsv` (dạng bảng, kèm bằng chứng). Phương pháp:
khớp chữ ký có mặt nạ, bỏ phiếu theo call-site từ firmware China 3.101.043, so sánh thân hàm đích của veneer; các ký hiệu không khớp
duy nhất là `MB10P_UNRESOLVED` (11) và gây lỗi *biên dịch* nếu dùng. Mục `pm_*`/`app_launcher_del` lấy từ đọc disassembly 3.201.026.

## Cố ý KHÔNG đưa vào repo
Firmware (`vela_*.bin`, gói OTA), tài nguyên trích xuất (romfs, font, hình), kết xuất disassembly/chuỗi, các file `.face` đã build,
báo cáo phân tích đầy đủ (`mb10pro_fw_analysis.md`, giữ riêng vì chứa nhiều chuỗi/cấu trúc trích từ firmware). Repo chỉ chứa mã nguồn
của dự án, ELF do chính mã đó biên dịch, và các địa chỉ cần để biên dịch.

## Giới hạn của việc kiểm tra offline
Không có emulator Cortex-M33/NuttX nên không thể chạy `insmod` ở đây: kiểm tra ELF là tĩnh (cấu trúc, relocation, ABI, địa chỉ), kiểm tra Lua
là logic với shell giả. Hành vi thật của nsh (`lsmod`, `dmesg`, `cp`, mã trả về) và firmware chỉ biết được từ log thật trên đồng hồ.
