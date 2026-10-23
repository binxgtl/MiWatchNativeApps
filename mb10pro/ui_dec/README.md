# Decimal calculator page (pinned copy)

`calc_page.c` here is `mb10pro/ui/calc_page.c` of commit `8600e41` (branch `fix-calc-decimal-precision`, the upstream PR
"Improve Calculator precision with decimal arithmetic") with **one line changed** (line 284):

```diff
-            lvx_btn_set_text_fmt(btn, lbl);
+            lvx_btn_set_text_fmt(btn, "%s", lbl);   /* as in the hardware-tested build */
```

`common/misc/decimal.h` is that commit's file, unchanged. Both are kept byte-for-byte (no added comments), because
`build_mb10p.sh 3201026` must reproduce the module that passed on the band:

| | SHA-256 |
|---|---|
| `mb10p_calc_dec.elf` = `mb10p_app_safe.c` (this branch) + this `calc_page.c` (hardware PASS 2026-10-23, Smart Band 10 Pro Global 3.201.026) | `f6251c3358363147172c8fb3a0b1b17abd4f223df135c7b8ae131c18dcecc496` |
| same, with the PR's line instead (never run on a device) | `380c8bdc217ad3bb93fec79e3ed61b92fc3037f721f9b5f40fb0ade69e5074d0` |

The float calculator in `mb10pro/ui/calc_page.c` (used by `mb10p_app_safe.elf`, `mb10p_app.elf`) is not affected.
Do not edit these copies; update them from the PR branch when it changes, and record the new hashes.
