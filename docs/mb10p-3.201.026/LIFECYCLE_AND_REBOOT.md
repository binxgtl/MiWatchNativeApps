# Vòng đời module, hành vi sau reboot và thiết kế gỡ cài đặt an toàn (fw 3.201.026)

Nhãn bằng chứng dùng trong tài liệu:
- **[FW]** suy ra bằng đọc disassembly/script khởi động của `vela_ap.bin` 3.201.026 (không chạy trên máy).
- **[HW]** chủ thiết bị đã xác nhận trên đồng hồ (xem `MILESTONE.md`).
- **[?]** chưa biết; cần quan sát (xem `OBSERVATION_CHECKLIST.md`).

Địa chỉ nằm trong `SYMBOLS.tsv`. Địa chỉ `0x0C…` là bí danh XIP của `0x2C…`.

## 1. Luồng khởi động: không có gì nạp module tự động [FW]

`/etc/init.d/rc.sysinit` và `rcS` (ROMFS nhúng trong `vela_ap.bin`) thực hiện: mount `/proc`, `tmpfs` tại `/tmp`,
`/resource` (romfs), **`/data` là yaffs trên `/dev/nand_data` với `-o autoformat`**, các phân vùng littlefs `/misc`
và `/mode`, rồi khởi động dịch vụ (`miwear`, `bluetoothd`, …) trừ khi tồn tại thư mục `/data/nobusiness`.
Không có lệnh `insmod`, không quét `/data` tìm `.elf`. Chuỗi `insmod` duy nhất trong firmware là tên lệnh NSH.
Hệ quả [FW]: registry của `modlib` (cấp phát `zalloc`, chỉ nằm trong RAM) rỗng sau mỗi lần khởi động.

Hai điều cần tránh vì chúng làm thay đổi khởi động:
- **Không bao giờ tạo `/data/nobusiness`** (UI `miwear` sẽ không khởi động). Snapshot ghi nhận sự có mặt của nó.
- `/data` được mount với `autoformat`: nếu hệ thống tệp hỏng, firmware có thể format lại. Đừng ghi liên tục
  vào `/data` (Manager giới hạn log ở 64 KiB).

## 2. Package manager: những gì đọc được từ disassembly [FW]

Trạng thái ở `0x200B72C0` (`pm_state`): `+0x00` đầu danh sách app đã đăng ký (`0x200B7280`), `+0x04` đầu danh sách
"đã gỡ/có thể khôi phục" (`0x200B7240`), `+0x18` bảng thao tác (rodata `0x2CA75534`). Bảng
`g_packagemanager_api` (`0x200B72E0`) theo thứ tự: install `0x2C7ABB68`, recover `0x2C7ABD24`, uninstall
`0x2C7ABDFC`, unregister `0x2C7AB8E0`, update_notify, widgets_add, widgets_remove, set_hidden, is_hidden.

| Hàm | Hành vi đọc được |
|---|---|
| `install(app, pages, n)` | Bỏ qua nếu `app->name == NULL` hoặc `app_id` đã có. Cấp phát nút 0x40 byte trên **heap**, **sao chép** descriptor (0x40 byte), `strdup` `name`, `icon`, `+0x14`, `+0x18`. Cấp mảng page tại `node+0x30` và lưu **chính con trỏ page** (struct page của module, không sao chép), đồng thời gọi *page register* (`0x200B7304+0x0C`) cho từng page. Phát sự kiện `0x1C`. Lỗi → giải phóng nút và chuỗi. |
| `unregister(node)` | Gọi *page unregister* (`0x200B7304+0x10`) cho từng page; `on_signal(app, 4)` nếu `node+0x38 != NULL`; phát sự kiện `0x1D(name)`. Rồi rẽ nhánh theo `is_recoverable = !(flags & 0x08)` (`flags` là `u16` tại `node+0x12`): **recoverable** → nút *và mảng page* được giữ lại trong danh sách "đã gỡ" (chuỗi log "recoverable app add uninstall app list"); **không recoverable** → giải phóng mảng page, mảng widget và chính nút (`free`). |
| `uninstall(app)` | Nếu `node+0x28` có handler thì gọi `handler(name)`, ngược lại gọi `unregister` mặc định. |
| `app_launcher_del(app_id)` (`0x2C48C4CC`) | Tìm entry launcher theo id, gỡ khỏi hai danh sách, giải phóng, cập nhật bố cục. Không có tác dụng nếu không có entry. |
| `app_lookup(id)` / `0x2C7AB1D4` | Tìm trong danh sách đăng ký / danh sách "đã gỡ"; trả về nút heap hoặc 0. |

Hai điều rút ra:
1. Sau `install`, firmware **không** trỏ vào `g_calc_app` của module (đó là bản sao), nhưng bản sao vẫn giữ
   `app_get_name`, `on_uninstall`, `on_signal`… là con trỏ **vào code module**, và mảng page giữ **con trỏ tới
   `g_calc_page` trong `.data` module**.
2. Với `flags = 0` (bản đã chạy trên máy), `unregister` thuộc nhánh *recoverable*: nút và mảng page **vẫn còn**
   trong danh sách "đã gỡ" → vẫn trỏ vào module. Vì vậy ngay cả `unregister` đúng quy trình cũng chưa làm cho `rmmod`
   an toàn. Phải dùng bản `flags = 0x08` (xem mục 5) hoặc reboot.

Giả định chưa kiểm chứng: `free` ở `0x2C1C51B4` là `free(heap, p)` (suy từ 3355 caller và đuôi gọi `mm_free`);
ý nghĩa cụ thể của bit `0x08` ngoài hàm `is_recoverable` [?] (có thể còn nơi khác đọc nó).

## 3. Hành vi sau reboot: dự đoán và cách kiểm tra

| Đối tượng | Dự đoán sau reboot | Căn cứ | Độ tin cậy | Quan sát bằng |
|---|---|---|---|---|
| Module ELF đã nạp (`lsmod`) | **Không còn** | registry RAM, không có autoload (mục 1) | cao [FW] | `lsmod` (SCAN/SNAP) |
| Đăng ký package manager (nút heap, danh sách) | **Không còn** | danh sách trong RAM, dựng lại lúc boot từ app có sẵn | cao [FW] | PMInspect → `NONE`; icon biến mất |
| Entry launcher trong RAM (`0x200A1ED4/EC`) | Không còn | như trên | cao [FW] | quan sát launcher |
| `/data/app/launcher/launcher.db` (bố cục launcher) | **Chưa biết có chứa id `0xC1` hay không**; nếu có, hiệu ứng với app vắng mặt chưa rõ | chuỗi đường dẫn có trong firmware; `app_launcher_add` không thấy ghi tệp trực tiếp | không biết [?] | SNAP: kích thước + adler32 trước/sau; nhìn launcher có ô trống/lỗi |
| Khóa kvdb `persist.record_app_install`, `persist.app_func_bitmap`, `persist.app_capability`, `persist.launcher.guide` | Có thể đã đổi khi cài [?] | tên khóa có trong firmware, chưa rõ ai ghi | không biết [?] | SNAP (`getprop`) so trước/sau |
| `/data/mb10p_com.m0tral.calc_safe.elf`, `/data/calc_logo_112.png` | **Còn** (yaffs bền) | `/data` là flash | cao [FW] | SNAP: size + adler32 |
| `/tmp/*` (trạng thái Manager, khóa, marker) | **Mất** | tmpfs | cao [FW] | SNAP: `boot=NEW` |
| Watchface cài đặt (qua Mi Fitness) | Còn cho đến khi bạn xóa; không làm gì cho tới khi bấm nút | thiết kế loader | cao | quan sát |
| Log `dmesg` của module | Mất (ring RAM); `offline_log` có thể giữ bản nén `.gz` | `rc.sysinit` chạy `offline_log start -w` | trung bình [FW] | SNAP: `dmesg.<app>=0` |

Tiêu chí "sạch sau reboot": `lsmod` không có module của ta; PMInspect báo `NONE`; icon Calculator biến mất khỏi launcher;
launcher không lỗi; các tệp `/data` của ta còn nhưng không có gì nạp chúng; `free` không giảm sau nhiều chu kỳ.

## 4. Vì sao hiện tại gỡ = reboot

`mb10p_app_safe.elf` (flags 0, đã thử trên máy) sau đăng ký để lại: nút heap giữ callback vào code module; mảng page
giữ con trỏ vào `.data` module; (khi trang đang mở) đối tượng LVGL của `calc_page` có `calc_on_press` làm event callback;
biến static của `calc_page.c`. `rmmod` giải phóng toàn bộ code/data đó trong khi các con trỏ trên còn sống.
Không có cách nào để hàm hủy (`.fini_array`, kiểu `void`) phủ quyết `rmmod`.

## 5. Thiết kế gỡ cài đặt an toàn (phân tầng)

### Tầng 0 – Hỗ trợ chính thức: reboot
Native App Manager **từ chối** `rmmod` mọi module `kind="registering"` và hướng dẫn reboot. Không dùng khóa/lệnh nào khác.
Cài lại sau reboot dùng nút INSTALL bình thường (module vắng mặt).

### Tầng 1 – Quan sát chỉ đọc: `mb10p_pm_inspect.elf` (có trong Manager, chưa chạy trên máy)
Nạp được ở mọi lúc, mỗi giây đọc nút của `app_id 0xC1` và log (chỉ khi thay đổi): `flags`, các con trỏ callback,
mảng page, `lifecycle_state` của page, danh sách "đã gỡ", rồi tự dừng timer sau 90 giây và ghi `DONE`.
Không đăng ký gì, không để lại con trỏ → được phép `rmmod` sau `DONE` (Manager kiểm tra điều này).
Mở và đóng Calculator trong 90 giây để biết giá trị `state` của page khi đóng/mở.

### Tầng 2 – Thử nghiệm có chốt (mã nguồn có, **chưa nối vào Manager, chưa chạy trên máy**)
Điều kiện tiên quyết: ứng dụng phải dùng bản **`mb10p_app_safe_nr.elf`** (`-DCALC_APP_FLAGS=0x08`, khác bản đã
thử đúng 1 byte `.data`) để `unregister` đi nhánh *giải phóng* thay vì *giữ lại*.
`mb10p_pm_remove.elf` (bản dựng hiện tại **luôn từ chối** vì `PM_TOOL_PAGE_IDLE` chưa biết) thực hiện, trong luồng LVGL:

1. Kiểm tra: nút tồn tại; `flags & 0x08` đã set (ngược lại từ chối `recoverable_app_reboot_required`);
   mọi page ở trạng thái "nhàn rỗi" quan sát được (ngược lại từ chối).
2. `app_launcher_del(id)` – xóa entry launcher **trước**, vì entry có thể tham chiếu chuỗi `strdup` của nút sẽ bị giải phóng.
3. Vô hiệu hóa callback trong nút (`+0x1C,0x20,0x24,0x28,0x38 = 0`) để dù nút còn sót cũng không gọi vào module.
4. `g_packagemanager_api->unregister(node)`: gỡ page khỏi page-manager, giải phóng mảng page và nút.
5. Kiểm tra: `app_lookup(id) == 0` và danh sách "đã gỡ" cũng `0`; log `RESULT … clean=1`.
6. Chỉ khi `clean=1`: dừng timer (đã dừng), rồi mới cho phép `rmmod` module của app – và `rmmod` chính công cụ remover
   (nó không để lại con trỏ).

Không `rmmod` trong cả quá trình nếu bước 1 hoặc 5 báo lỗi: reboot.

### Cổng nâng cấp từ tầng 2 lên "hỗ trợ"
| Cổng | Cần quan sát | Đạt khi |
|---|---|---|
| G1 | PMInspect trên bản flags 0 | `NODE` có `flags=0x0000`, `cb1c≠0`, 1 page; ghi lại `state` khi đóng và khi mở |
| G2 | ≥3 chu kỳ cài–reboot–SNAP | SNAP "sạch" mỗi lần, `free` không giảm |
| G3 | `app_safe_nr` + PMInspect | `flags=0x0008`, app chạy như bản đã thử |
| G4 | `pm_remove` build với `PM_TOOL_PAGE_IDLE=<state G1>`, app **đóng** | `clean=1`, icon biến mất, không treo; PMInspect báo `NONE` |
| G5 | Nạp lại app trong cùng lần boot, lặp lại | không rò rỉ, không treo |

Mỗi cổng phải có log thật. Nếu một cổng thất bại hoặc đồng hồ treo: reboot, giữ tầng 0.

## 6. Rủi ro chưa loại bỏ được

- Handler của sự kiện `0x1C/0x1D` (launcher và các nơi khác) chưa đọc; có thể giữ tham chiếu bất đồng bộ tới nút/chuỗi. [?]
- `launcher.db` có thể lưu id `0xC1` bền vững. [?]
- Page đang mở hoặc vừa đóng có thể còn được page-manager/scheduler tham chiếu (`scheduler_*`, `activity_context`). [?]
- Nếu đóng page nhưng đối tượng LVGL còn tồn tại, `calc_on_press` vẫn nằm trong module. [?]
- `lv_timer_create` gọi từ luồng shell trong lúc luồng LVGL đang chạy (race tiềm ẩn, kế thừa từ upstream).
- Cấu hình `lsmod` (cột `NEXPORTS`) và `dmesg` chưa được xác nhận trên máy: Manager *fail closed* khi không đọc được.
