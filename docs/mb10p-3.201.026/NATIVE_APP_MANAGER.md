# Native App Manager (`mb10pro/wf_native_manager`)

**Trạng thái:** 172 kiểm tra logic với shell/hệ tệp/LVGL giả (`tools/mb10p/test_manager.lua`) và 43 đột biến
(`tools/mb10p/mutate_manager.py`: đưa lại từng lỗi đã sửa hoặc bỏ từng chốt an toàn → test phải fail; cả 43 đều bị bắt).

**Phần cứng:**
- Bản **EasyFace** của Manager (mã nguồn trước `45629d2`, chưa có `calc_dec`): **PASS** trên Smart Band 10 Pro Global
  3.201.026 (chủ thiết bị báo).
- Bản **r2** (`MGR_BUILD = "r2 2026-10-23 (pm_inspect LDRH fix, calc_dec)"`), đóng gói bằng `build_faces.py --target native_mgr`
  (`native_mgr_193824672.face`, SHA-256 `d3a5818a…`): **PASS** 2026-10-23 trên máy (chủ thiết bị báo: quy trình cập nhật ở
  mục 8 và cả 13 bước thử, gồm `calc_dec` và `pm_inspect`). Khác bản đã PASS: `mb10p_pm_inspect.elf` mới (đọc `flags` u16 bằng LDRH), mục `calc_dec`,
  SNAP thêm đường dẫn, khóa SNAP theo module/tag, dòng phiên bản lúc mở và trong log SCAN. Cập nhật: mục 8.
- Preview của gói là PNG RGB; packer luôn ghi preview dạng BGRA (alpha 255 với RGB), cùng dạng với các gói packer đã PASS.
Thứ tự thử trên máy: [HARDWARE_TEST_MANAGER_HELLO.md](HARDWARE_TEST_MANAGER_HELLO.md). Đóng gói và ID: [EASYFACE_BUILD.md](EASYFACE_BUILD.md).

## Màn hình 336×480

```
 24..70   App: hello (transient)          <- app đang chọn
          Mod: absent  fw: OK             <- trạng thái module (lsmod gần nhất) + kết quả kiểm firmware lúc mở
 76..266  [ APP  ] [ SCAN   ]             3 hàng × 2 nút, mỗi nút 150×58 px
          [ SNAP ] [ VERIFY ]             xanh = chỉ đọc
          [INSTALL][ REMOVE ]             xanh lá / cam = thay đổi trạng thái (xám khi firmware sai lúc mở)
 274..330 PASS: insmod ok + listed        kết luận, tô màu: PASS/OK xanh, FAIL/REFUSED/LOCKED đỏ,
                                          UNKNOWN/WARN/INCOMPLETE/UNCERTAIN/ANOMALY vàng
 335..459 ┌ log của thao tác hiện tại ┐   4 dòng/trang + "-- 1/3 tap for more --"; chạm để lật trang
```

Các vùng cố định và không chồng nhau (test kiểm hình học). Chữ được Lua cắt/ngắt trước khi hiển thị (log 28 cột,
kết luận 2 dòng × 22 cột), nên log dài không thể đè lên nút. Kết luận dài hơn 2 dòng được rút gọn ở vùng kết luận
và hiện **đầy đủ** ở đầu vùng log (`> REFUSED: …`). Mọi dòng cũng được ghi vào `/data/mb10p_manager.log`.
Không có animation.

## Nút

| Nút | Loại | Làm gì | Chốt an toàn |
|---|---|---|---|
| `APP` | – | chọn `hello` / `calc_safe` / `calc_dec` / `pm_inspect` | không chạy lệnh |
| `SCAN` | chỉ đọc | firmware version, build ID thực tế + giá trị kỳ vọng + lý do lệch; module nào đang nạp (`loaded(ours)` nếu hàng `lsmod` khớp bản ghi, `loaded(?)` nếu không); module xung đột; `dmesg` dùng được không | vẫn chạy khi firmware gate fail (để chẩn đoán) |
| `SNAP` | chỉ đọc (*) | snapshot trước/sau reboot, so với lần trước | thiếu dữ liệu → `INCOMPLETE`, không bao giờ `OK` |
| `VERIFY` | chỉ đọc | dòng syslog của app **từ sau lần INSTALL này** | `dmesg` không dùng được → `UNKNOWN` |
| `INSTALL` | thay đổi | gate → `lsmod` → từ chối trùng/xung đột → manifest → `cp` → so từng byte → `insmod` → `lsmod` | PASS chỉ khi `insmod` ok **và** `lsmod` liệt kê; mơ hồ → khóa |
| `REMOVE` | thay đổi | `rmmod` cho module `transient` do chính Manager nạp | `calc_safe`, `calc_dec`: luôn từ chối, chỉ reboot |

(*) SNAP chỉ ghi tệp của chính nó: `/tmp/mb10p_boot_marker`, `/data/mb10p_snap.last`, `/data/mb10p_snap.log`.

Lệnh duy nhất Manager có thể chạy: `getprop`, `lsmod`, `dmesg`, `cp`, `insmod`, `rmmod`, `ls`, `free` (kiểm tĩnh trong
`verify_all.sh` và kiểm động trong test). Khi mở watchface chỉ chạy `getprop ro.build.version`; không nạp native code.

## 1. Nhận diện firmware và build ID

Bằng chứng (đọc từ `/etc/build.prop` trong `vela_ap.bin` của 3.201.026 bạn cung cấp; giá trị lúc chạy **chưa quan sát trên máy**):

```
ro.build.version=3.201.026
ro.build.customer_version=CONBINE_LTALM080_T3.201.026_09041709
ro.product.device.screenshape=rect
ro.product.device.devicetype=band
ro.sf.lcd_density=336ro.build.id=CONBINE_LTALM080_3.201.026      <- thiếu "\n" trước ro.build.id
```

- Chuỗi metadata `CONBINE_LTALM080_T3.201.026_09041709` là **`ro.build.customer_version`**, không phải `ro.build.id`.
- `ro.build.id` trong ảnh là `CONBINE_LTALM080_3.201.026` (không có `T`, không có ngày), nhưng dòng này dính vào
  `ro.sf.lcd_density`. Trình nạp property (`kvdb`, danh sách `/etc/build.prop;/misc/factory.prop;/mode/app_nv.prop`)
  nhiều khả năng đọc thành `ro.sf.lcd_density = "336ro.build.id=CONBINE_LTALM080_3.201.026"` và **không có**
  `ro.build.id`. Bản CN 3.101.043 có xuống dòng đúng (`ro.build.id=CONBINE_LTALM078_T3.101.043`). Không có mã nào trong
  ảnh tự đặt `ro.build.id`. SCAN ghi thêm `ro.sf.lcd_density` vào log để kiểm chứng giả thuyết này trên máy.

| Thuộc tính | Kỳ vọng | Chặn INSTALL/REMOVE khi | Trống / không đọc được |
|---|---|---|---|
| `ro.build.version` | `3.201.026`, **khớp tuyệt đối** cả dòng (không nhận `3.201.026 xyz`, `3.201.0261`, `V3.201.026`) | khác hoặc không đọc được | `UNKNOWN` → **chặn** |
| `ro.build.customer_version` | `CONBINE_LTALM080_T3.201.026_09041709` | đọc được, khác kỳ vọng (`MISMATCH`) | `UNKNOWN` → cảnh báo, không chặn |
| `ro.build.id` | `CONBINE_LTALM080_3.201.026` | không bao giờ | `UNKNOWN` → cảnh báo; khác → `WARN` |

Gate đọc lại cả ba **mỗi lần** INSTALL/REMOVE. Mỗi lệnh ghi ra tệp tạm được "đặt mốc" trước (`> file` của shell xoá mốc);
nếu mốc còn nguyên thì lệnh không chạy → giá trị `nil`/`UNKNOWN`, không bao giờ đọc nhầm kết quả cũ của lệnh trước
(lỗi của bản cũ: `getprop ro.build.id` thất bại sẽ đọc lại `3.201.026` của lệnh trước).

Trên máy bạn, SCAN dự kiến hiện `WARN: fw OK; id UNKNOWN` (vì `ro.build.id` không được đặt) và vẫn cho INSTALL.

## 2. INSTALL

1. Gate: firmware, build ID, `SCRIPT_PATH`, khóa, hành động dở dang.
2. `lsmod` đọc được và có tiêu đề; từ chối nếu module trùng tên hoặc module xung đột đang nạp
   (`calc_safe` và `calc_dec`: module `calc_safe` – dù do Manager hay watchface Calc safe / Calc fix / Calc dec nạp –
   và `mb10p_app` của Calculator gốc, vì mọi bản Calculator đều dùng app id `0xC1`).
3. `calc_safe`/`calc_dec` đã được cài trong lần khởi động này mà nay không còn trong `lsmod` → `ANOMALY` + khóa (package manager có
   thể còn trỏ vào bộ nhớ đã giải phóng; chỉ reboot).
4. Đọc `dmesg` làm mốc (để VERIFY chỉ xét dòng mới).
5. Ghi nhật ký `/tmp/mb10p_mgr.pending` ("INSTALL hello at copy/insmod").
6. Mỗi tệp: kiểm manifest (size > 0 + adler32) của tệp đóng gói → `cp` → kiểm size+adler32 bản đích → so **từng byte**.
   Tệp không tồn tại / không đọc được / rỗng / là thư mục / `cp` lỗi / `cp` báo ok nhưng không ghi / bản đích khác →
   `FAIL`, **không `insmod`**. Logo dùng chung `/data/calc_logo_112.png`: giống hệt thì giữ, chưa có thì chép, khác thì từ chối
   (không ghi đè tệp của watchface khác).
7. `insmod /data/mb10p_mgr_<app>.elf <module>` rồi `lsmod`:

| `insmod` | `lsmod` sau đó | Kết quả |
|---|---|---|
| ok | liệt kê module | `PASS`, lưu hàng `lsmod` + mốc dmesg vào `/tmp/mb10p_mgr.state` |
| ok | không liệt kê / không đọc được | `UNCERTAIN` + khóa |
| lỗi | liệt kê | `ANOMALY` + khóa |
| lỗi | không đọc được | `UNCERTAIN` + khóa (bản cũ báo nhầm FAIL) |
| lỗi | không liệt kê | `FAIL code=<mã thật>` |

Tệp ELF của Manager nằm ở `/data/mb10p_mgr_hello.elf`, `/data/mb10p_mgr_calc_safe.elf`, `/data/mb10p_mgr_calc_dec.elf`,
`/data/mb10p_mgr_pm_inspect.elf`, khác tên với tệp của các watchface Hello / Calc safe / Calc fix / Calc dec
(`/data/mb10p_com.m0tral.calc_*.elf`) nên không ghi đè lẫn nhau. `cp` của INSTALL **ghi đè** tệp đích của Manager
(bản cũ còn lại từ lần cài trước được thay rồi kiểm lại từng byte), vì vậy đích luôn là tên riêng của Manager.

## 3. Khóa, nhật ký dở dang, lỗi Lua

- Trạng thái, khóa, nhật ký đều ở **tmpfs** (`/tmp`): mất khi reboot, đúng như module đã nạp.
- Khóa đặt sau mọi kết quả mơ hồ và chặn INSTALL/REMOVE tới khi reboot; SCAN/SNAP/VERIFY vẫn dùng được.
- Nhật ký dở dang: nếu watchface bị đóng/treo giữa chừng INSTALL/REMOVE, lần mở sau thấy `pending` → **khóa**, không làm lại.
- Lỗi Lua trong INSTALL/REMOVE → khóa (kết quả không rõ), hiện `LOCKED`, **không tự chạy lại**. Lỗi Lua ở nút chỉ đọc → `FAIL`.
- `os.remove`/`os.rename` chưa được chứng minh có trong sandbox Lua của đồng hồ nên là tùy chọn (không có thì ghi đè rỗng).

## 4. REMOVE

- `calc_safe`, `calc_dec` (đăng ký package manager + LVGL): **luôn từ chối**, không chạy lệnh nào, hướng dẫn reboot.
- `hello`: chỉ khi gate qua, hàng `lsmod` hiện tại **bằng** hàng ghi lúc INSTALL của chính Manager; sau `rmmod` phải thấy
  module biến mất, nếu không → `FAIL`/`UNCERTAIN` + khóa.
- `pm_inspect`: như trên, thêm điều kiện có dòng `[pm_inspect] DONE` **sau mốc INSTALL** (DONE được in sau `lv_timer_delete`,
  nên không còn callback trỏ vào module; Manager chạy trên luồng LVGL nên không chạy song song với callback của nó).
  `dmesg` không dùng được hoặc lịch sử bị tràn → từ chối.
- Không có `pm_remove` trong gói Manager; không đụng firmware hay cơ chế khởi động.

## 5. dmesg và VERIFY

Theo tài liệu NuttX nsh, `dmesg` "dump (and clear)" RAM log; bản Vela trên máy có thể giữ lại. Vòng đệm còn bị ghi đè. Manager không
dựa vào giả định nào: mỗi lần đọc được căn với lần trước, chỉ các dòng **mới** mang tag của ta (`[hello_module]`,
`[calc_safe]`, `[pm_inspect]`) được nối vào `/tmp/mb10p_mgr_dm.acc` (giữ 200 dòng, đánh số tuyệt đối). Dòng syslog không có
`\n` (như của Hello) nối tiếp cùng dòng; phần mọc thêm được tính là mới. VERIFY chỉ xét dòng sau mốc INSTALL, nên dòng của
lần nạp trước không thể làm VERIFY PASS. Nếu căn sai do trùng hợp thì chỉ có thể **thiếu** dòng (→ `INCOMPLETE`), không thể
lấy lại dòng cũ.

| App | VERIFY PASS khi (sau mốc, module còn liệt kê và đúng hàng của Manager) |
|---|---|
| hello | có `[hello_module] loaded` và `[hello_module] hello` |
| calc_safe | `loaded`, `timer fired`, `pm install(...) rc=0` (đúng `0`), `app_launcher_add rc=`, `registered`; có `app 0x.. already registered` hoặc `pm install rc≠0` → `FAIL` |
| calc_dec | như `calc_safe` (cùng phần app `mb10p_app_safe.c`, cùng tag `[calc_safe]`) |
| pm_inspect | có `DONE`; trước đó `INCOMPLETE` + tóm tắt `flags`/callback/page |

`calc_safe` và `calc_dec` log cùng tag, nên VERIFY không tự phân biệt hai binary; nó dựa vào việc INSTALL đã từ chối mọi
module calculator khác trong lần khởi động này và hàng `lsmod` vẫn là hàng ghi lúc INSTALL. Trên màn Calculator: `99999*99999=`
ra `9999800001` là bản decimal, `9999800320` là bản float.

`dmesg` lỗi → `UNKNOWN`. Không có mốc (dmesg lỗi lúc INSTALL) → `UNKNOWN`. Lịch sử tràn → `UNKNOWN`.

## 6. SNAP

Khóa trong snapshot: `boot` (mốc `/tmp`: `NEW` sau reboot), `fw`, `modules`, `mod.<module>` (một khóa cho mỗi tên module:
`calc_safe` và `calc_dec` dùng chung `mod.calc_safe`), `file.<đường dẫn>`, `prop.persist.*`, `dmesg.<tag>` (vd. `dmesg.calc_safe`).
Bản r2 đổi khóa từ `mod.<app>`/`dmesg.<app>`: snapshot đầu tiên sau khi cập nhật sẽ hiện các khóa mới như thay đổi. Tệp được phân biệt `ABSENT` (không tồn tại), `DIR` (là thư mục), `UNKNOWN …` (không mở/đọc được) và
`size:adler32` (đọc tối đa 128 KiB, `+` nếu bị cắt). `launcher.db`, `persist.db` chỉ được mở để đọc; `/data/nobusiness` chỉ
được kiểm tra, không bao giờ tạo (test theo dõi mọi lần ghi). Mục nào `UNKNOWN` → kết luận `INCOMPLETE`; so sánh với
snapshot trước bỏ qua giá trị `UNKNOWN`.

Log `/data/mb10p_manager.log` và `/data/mb10p_snap.log` giữ tối đa 64 KiB mỗi tệp (+ một bản `.1`); đọc `dmesg` tối đa
256 KiB cuối, `lsmod` 16 KiB.

## 7. Những điều Manager cố ý KHÔNG làm

- Không nạp module khi khởi động hay khi mở watchface; không `reboot`; không `rm` tệp hệ thống.
- Không gọi package manager, không xoá/đặt lại watchface, không ghi firmware.
- Không `rmmod` mò; không `rmmod` `calc_safe`/`calc_dec`; không dùng ELF thử nghiệm.
- Không tự thử lại sau lỗi.

## Thêm một app

Thêm một dòng vào `APPS` (module, ELF, `dst` riêng `/data/mb10p_mgr_*.elf`, `conflicts`, `tag`, `expect`/`fail`/`done`,
kiểu `transient`/`registering`), thêm tệp vào `app/lua` và vào lệnh `gen_manifest.py`, thêm kịch bản vào `test_manager.lua`.
Chỉ đánh dấu `transient` khi module **không để lại con trỏ nào vào bộ nhớ của nó** sau khi xong.

## 8. Cập nhật watchface NativeMgr đã cài (EasyFace → r2 bằng packer)

Gói mới dùng **cùng ID `193824672`** và Title `NativeMgr`. Hai gói cùng ID từng bị từ chối khi cài song song
(`preInstall code=5`, MILESTONE A3), nên gỡ bản cũ trước:

1. **Reboot** vòng: gỡ mọi module đã nạp (Hello, PMInspect, Calculator) và xóa trạng thái `/tmp` của Manager. Không `rmmod`.
2. Sau reboot **không mở** NativeMgr, Calc safe, Calc fix, Calc dec hay Calculator gốc.
3. Gỡ watchface NativeMgr cũ bằng cách bạn vẫn xóa watchface trên vòng/ứng dụng.
4. Cài `native_mgr_193824672.face` mới. Lỗi cài → ghi nguyên văn mã lỗi, không thử lại; có thể cài lại bản EasyFace cũ.
5. Mở NativeMgr: vùng log phải có `NativeMgr r2 2026-10-23 …`. Không thấy → đang chạy bản cũ.
6. **SCAN**, rồi **SNAP**: snapshot đầu tiên sẽ báo các khóa mới (`mod.calc_safe`, `dmesg.calc_safe`, `file./data/mb10p_mgr_calc_dec.elf`…)
   là thay đổi; đó là đổi định dạng, không phải sự cố.

Tệp lưu lâu dài giữ nguyên qua cập nhật và không cần xóa: `/data/mb10p_manager.log*`, `/data/mb10p_snap.*`,
`/data/mb10p_mgr_*.elf` (INSTALL tiếp theo chép đè và kiểm từng byte theo MANIFEST mới; `mb10p_mgr_pm_inspect.elf` cũ
3028 B sẽ được thay bằng bản 2968 B), `/data/calc_logo_112.png` (giống hệt, được giữ).
Rồi làm theo `HARDWARE_TEST_MANAGER_HELLO.md`. Thử `calc_dec` qua Manager: sau reboot, chọn `calc_dec` → INSTALL → VERIFY →
mở Calculator; REMOVE bị từ chối, gỡ bằng reboot.
