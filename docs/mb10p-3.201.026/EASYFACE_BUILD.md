# Đóng gói watchface MB10 Pro (fw 3.201.026): `build_faces.py`, EasyFace dự phòng, watchface ID

## 1. Hai cách đóng gói

| | Cách A – mặc định: `tools/mb10p/build_faces.py` | Cách B – dự phòng: EasyFace v4.23 (Windows) |
|---|---|---|
| Chạy trên | Linux / WSL / Windows, Python 3, chỉ thư viện chuẩn | Windows, EasyFace v4.23 |
| Dạng project | **chỉ** DeviceType 567, một widget Lua `app_lua%2Fmain.lua` 336×480, tệp phẳng trong `app/lua`, preview PNG 8-bit 336×480 | mọi dạng EasyFace hỗ trợ |
| ID | lấy từ `face_targets.tsv` / `face_ids.tsv`, ghi thẳng vào gói | ô ID của EasyFace, hoặc `face_id.py set` sau khi build |
| Trên máy | `Hello py` (193824675) **PASS** 2026-10-23 (mục 5) | `Hello`, `Calc safe` đã cài và chạy |

Project nào không đúng dạng ở cột A (DeviceType khác, nhiều widget, thư mục con, preview khác 336×480 hoặc không phải PNG
8-bit RGB/RGBA…) đều bị `face_pack.py` **từ chối**; khi đó dùng cách B.

## 2. Cách A: build bằng `build_faces.py`

```sh
git checkout mb10p-global-3.201.026
bash tools/mb10p/verify_all.sh            # phải in ALL CHECKS PASSED
python3 tools/mb10p/build_faces.py        # -> build/faces/3.201.026/
```

Kết quả (`build/faces/3.201.026/`, không đưa vào git):

| Tệp | ID | Title | Nguồn | Trạng thái phần cứng |
|---|---|---|---|---|
| `hello_py_193824675.face` | 193824675 | Hello py | `wf_native_hello` (fprj, preview) + `wf_native_hello_test` (`app/lua`) | **PASS** – chính tệp này (SHA-256 `0e2491eb…3078c50`) |
| `calc_safe_193824671.face` | 193824671 | Calc safe | `wf_native_calc_safe` | gói do packer tạo **chưa cài**; build với ID `167210065` thì trùng từng byte `Calc_safe.face` của EasyFace |
| `native_mgr_193824672.face` | 193824672 | NativeMgr | `wf_native_manager` | **PASS** – bản r2, chính tệp này (SHA-256 `d3a5818a…4dc523ebe`); bản EasyFace trước đó cũng PASS; preview PNG RGB |
| `calc_dec_193824674.face` | 193824674 | Calc dec | `wf_native_calc_dec` | **PASS** – chính tệp này (SHA-256 `abcb50dc…7f127f8f`); số 17 ký tự bị khung hiển thị cắt chữ số cuối |

cùng `SHA256SUMS` và `BUILD_INFO.txt` (commit nguồn, danh sách tệp, trạng thái phần cứng từng gói).

- Chỉ một vài gói: `python3 tools/mb10p/build_faces.py --target native_mgr` (lặp `--target` được).
- Thư mục khác: `--out DIR`. **DIR không được tồn tại**: không bao giờ ghi đè; muốn build lại thì tự xóa thư mục cũ.
- Windows: `py tools\mb10p\build_faces.py` (cùng lệnh, cùng kết quả).

`build_faces.py` dừng (mã 2, `BUILD REFUSED: …`, không để lại tệp nào) khi:
- thư mục kết quả đã tồn tại (mọi gói được build trong thư mục tạm cạnh đó, chỉ đổi tên vào chỗ khi **tất cả** đạt);
- ID của gói không có trong `face_ids.tsv`; Title của gói luôn là Title đăng ký cho ID đó;
- một `.elf` trong project khác bản trong `dist/mb10p-3.201.026` (theo `SHA256SUMS`, tên bỏ hậu tố `_3.201.026`), hoặc không có bản
  tương ứng ở đó (ví dụ ELF thử nghiệm);
- `app/lua` có symlink, tệp ẩn, thư mục con; project nằm ngoài `mb10pro/wf_native_*`; `module.fprj` không đúng dạng ở mục 1;
- kiểm lại sau khi đóng gói thất bại: `face_id.parse`, tệp trong gói khác nguồn, preview khác PNG;
- `hello_py` không còn trùng từng byte với gói đã PASS trên máy → packer hoặc nguồn Hello Test đã đổi (lưới an toàn cho packer).

Trước khi cài một gói: `python3 tools/mb10p/face_id.py check <gói> --id <ID> --title <Title>` và `face_id.py extract` để đối chiếu
SHA-256 với `dist/mb10p-3.201.026/SHA256SUMS`, như cách B.

Kiểm offline (đã nằm trong `verify_all.sh`):
```sh
python3 tools/mb10p/test_face_pack.py     # 17 kiểm tra packer (thêm: <thư mục chứa Hello.face, Calc_safe.face> -> 19, so từng byte với EasyFace)
python3 tools/mb10p/test_build_faces.py   # 22 kiểm tra: build hết, tất định, hello_py và calc_dec = gói PASS, các trường hợp từ chối
```

## 2b. Cách B (dự phòng): EasyFace v4.23

Thư mục project, ví dụ `mb10pro/wf_native_manager/`:

```
mb10pro/wf_native_manager/
  module.fprj                      DeviceType="567" (Band 10 Pro), Screen Title="NativeMgr", 336x480
  images/preview.png               336x480 (ảnh dựng bố cục, chỉ để làm thumbnail)
  app/lua/main.lua                 Manager
  app/lua/mb10p_hello_3.201.026.elf
  app/lua/mb10p_app_safe_3.201.026.elf
  app/lua/mb10p_calc_dec_3.201.026.elf
  app/lua/mb10p_pm_inspect_3.201.026.elf
  app/lua/calc_logo_112.png
```

Không có ELF thử nghiệm (`pm_remove`, `app_safe_nr`) trong gói (kiểm bởi `verify_all.sh`).

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
4. Đối chiếu SHA-256 do `extract` in ra với `dist/mb10p-3.201.026/SHA256SUMS` (4 ELF) và `main.lua` trong repo. Khác → không cài.
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

## 5. `face_pack.py`: nguồn gốc định dạng và kết quả trên máy

- `face_pack.py PROJECT OUT.face --id <9 chữ số>` là bộ đóng gói mà `build_faces.py` gọi. Chỉ dùng thư viện chuẩn Python, chỉ
  nhận dạng project ở mục 1, kiểm lại gói vừa tạo bằng `face_id.parse`, không ghi đè tệp có sẵn (kể cả symlink trỏ tới chỗ trống).
  Phần header còn lại (bảng mục ở 0xB0, bản ghi kết thúc trỏ tới `main.lua`, preview BGRA alpha thẳng) suy ra từ hai gói
  EasyFace v4.23 thật; `test_face_pack.py <thư mục chứa Hello.face, Calc_safe.face>` dựng lại cả hai từ nguồn ở commit `6d9ad0f`
  → **trùng từng byte**.
- Wine + `compile.exe`: không thử được (`compile.exe` không có trong môi trường này, không tải được qua proxy; repo
  `m0tral/EasyFace` chỉ có README). Không cần nữa cho dạng project ở mục 1.

**Đã xác nhận trên phần cứng (chủ thiết bị báo, 2026-10-23):** `HelloPy_193824675.face`
(SHA-256 `0e2491ebcd77ef8cb6294b326008a90b25d912510acbce2bcafe27d7e3078c50`, 658 916 B), tạo bằng `face_pack.py`, không qua EasyFace,
trên Smart Band 10 Pro Global `3.201.026`: cài được, mở được, CHECK PASS, LOAD PASS, UNLOAD PASS. `build_faces.py` tạo lại
đúng tệp này (`hello_py_193824675.face`) từ nguồn hiện tại.

Phạm vi của kết quả đó – **chưa** được chứng minh trên máy:
- **Preview từ PNG RGB:** đã PASS qua `native_mgr` r2 (PNG RGB → BGRA alpha 255). Chưa so với một gói EasyFace dựng từ PNG RGB.
- **Gói nhiều tệp:** đã PASS `Hello py` (2 tệp), `Calc dec` (3 tệp), `native_mgr` r2 (6 tệp, 4 ELF). `calc_safe` bản packer chưa cài.
- **Dạng project khác** (DeviceType khác 567, nhiều widget, ảnh/tài nguyên EasyFace khác, thư mục con…): packer từ chối, dùng EasyFace.
- Firmware khác `3.201.026`: chưa thử.
