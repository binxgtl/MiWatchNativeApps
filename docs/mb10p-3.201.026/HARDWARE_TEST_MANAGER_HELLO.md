# Thử Native App Manager trên máy – giai đoạn 1: chỉ Hello

Thiết bị: Smart Band 10 Pro Global, firmware `3.201.026`. Gói: `native_mgr_193824672.face` (r2) từ `python3 tools/mb10p/build_faces.py`
(PASS 2026-10-23; cập nhật từ bản đã cài: `NATIVE_APP_MANAGER.md` mục 8), hoặc bản EasyFace (`EASYFACE_BUILD.md`; bản EasyFace
trước r2 đã PASS theo bạn báo). Lỗi cài → ghi nguyên văn mã lỗi, không thử lại.
**Chưa thử `calc_safe` hay `pm_inspect` qua Manager cho tới khi giai đoạn này PASS.**

Trước khi bắt đầu:
- Nên reboot đồng hồ để bắt đầu từ trạng thái sạch. Không mở watchface Hello/Calculator khác trong lúc thử.
- **Chụp màn hình sau mỗi bước, gồm mọi trang của vùng log** (chạm vào vùng log để lật trang `1/3`, `2/3`…).
- Bất kỳ kết luận nào không có trong cột "Mong đợi": **dừng**, chụp màn hình, không bấm lại, gửi ảnh cho mình.

| # | Thao tác | Mong đợi | Nếu khác |
|---|---|---|---|
| 1 | Mở watchface NativeMgr | `INFO: ready; press a button`; dòng trên cùng `App: hello (transient)`, `Mod: ? fw: OK`; log (r2) có `NativeMgr r2 2026-10-23 …` | `REFUSED: fw …` → dừng (firmware không phải 3.201.026). `LOCKED` → reboot rồi làm lại từ đầu |
| 2 | **SCAN** | `WARN: fw OK; id UNKNOWN` (hoặc `OK`). Log: `fw: 3.201.026 OK`, `cust: MATCH`, `id: UNKNOWN - not set` (dự đoán từ build.prop), `hello: absent`, `calc_safe: absent`, `calc_dec: absent` (r2), `pm_inspect: absent`, `dmesg: ok, …` | `REFUSED` (MISMATCH) → dừng. `dmesg: UNKNOWN` → ghi lại, vẫn đi tiếp (VERIFY sẽ là UNKNOWN) |
| 3 | **SNAP** | `OK: snapshot complete, saved` | `INCOMPLETE` → ghi lại mục `unknown: …` (vd. dmesg), vẫn đi tiếp. `FAIL` → dừng |
| 4 | **INSTALL** (app đang chọn là `hello`) | `PASS: insmod ok + listed`; `Mod: loaded(ours)`; log có `copied mb10p_hello_3.201.026.elf (1388:9a3983d4)` | `FAIL` → ghi mã lỗi (`code=…`), dừng. `UNCERTAIN`/`ANOMALY`/`LOCKED` → không bấm lại, reboot, gửi ảnh |
| 5 | **VERIFY** | `PASS: all expected log lines present` | `INCOMPLETE` → đợi 2 giây, VERIFY **một** lần nữa. `UNKNOWN: dmesg n/a` → ghi lại (Hello vẫn có thể đúng, nhưng thiếu bằng chứng log) |
| 6 | **REMOVE** | `PASS: rmmod ok + no longer listed`; `Mod: absent` | `REFUSED` → chụp lý do, dừng. `FAIL`/`UNCERTAIN` → reboot, gửi ảnh |
| 7 | **SCAN** lại | `hello: absent`, không có dòng `LOCK:` hay `interrupted:` | khác → gửi ảnh |

**Giai đoạn 1 PASS** khi bước 1, 2, 4, 6, 7 đúng như mong đợi và bước 5 là `PASS` (hoặc `UNKNOWN` vì không có `dmesg`, ghi
rõ như vậy). Còn lại: FAIL, gửi ảnh từng bước.

Nếu đồng hồ treo: giữ nút cứng để khởi động lại theo hướng dẫn Xiaomi. Sau khi khởi động, mở Manager → **SCAN** → **SNAP**,
chụp màn hình, **không INSTALL lại**. Manager không bao giờ tự nạp module khi mở hay khi khởi động.

Log đầy đủ nằm ở `/data/mb10p_manager.log` (≤ 64 KiB, bản cũ ở `.log.1`); hiện chưa có cách lấy ra từ điện thoại, nên
ảnh chụp là bằng chứng chính.
