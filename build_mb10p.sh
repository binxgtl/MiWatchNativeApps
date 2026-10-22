#!/bin/sh
# Offline build of the mb10pro modules for one firmware version.
# Mirrors the compile/link flags of .vscode/tasks.json (ET_REL via `ld -r`).
#
#   ./build_mb10p.sh 3201026        -> build/3.201.026/{mb10p_hello,mb10p_app,mb10p_app_safe,mb10p_pm_inspect}.elf
#                                      build/3.201.026/experimental/mb10p_pm_remove.elf
set -eu
V="${1:-3201026}"
case "$V" in
  3101043) TAG=3.101.043 ;;
  3201016) TAG=3.201.016 ;;
  3201026) TAG=3.201.026 ;;
  *) echo "unknown firmware $V" >&2; exit 2 ;;
esac
CC=arm-none-eabi-gcc
OUT="build/$TAG"
mkdir -p "$OUT"
COMMON="-mcpu=cortex-m33 -mthumb -ffreestanding -fno-common -fno-builtin -nostdlib \
 -fno-jump-tables -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables \
 -fdata-sections -fno-function-sections -Os -I. -Imb10pro -DMB10P_FW_VERSION=$V -Wall -Wextra"
SOFT="-mfloat-abi=soft"
HARD="-mfloat-abi=hard -mfpu=fpv5-sp-d16"

# hello: syslog only, soft-float (as in tasks.json)
$CC $COMMON $SOFT -c mb10pro/mb10p_hello.c -o "$OUT/mb10p_hello.o"
$CC -mcpu=cortex-m33 -mthumb $SOFT -r -T mb10pro/mb10pro.ld -o "$OUT/mb10p_hello.elf" "$OUT/mb10p_hello.o"

# calculator app: hard-float FPU
$CC $COMMON $HARD -Werror -c mb10pro/ui/calc_page.c -o "$OUT/calc_page.o"
$CC $COMMON $HARD -c mb10pro/mb10p_app.c -o "$OUT/mb10p_app.o"
$CC -mcpu=cortex-m33 -mthumb $HARD -r -T mb10pro/mb10pro.ld -o "$OUT/mb10p_app.elf" "$OUT/mb10p_app.o" "$OUT/calc_page.o"

# lifecycle-test variant: no watchface read/delete/reset, notification off
$CC $COMMON $HARD -Werror -c mb10pro/mb10p_app_safe.c -o "$OUT/mb10p_app_safe.o"
$CC -mcpu=cortex-m33 -mthumb $HARD -r -T mb10pro/mb10pro.ld -o "$OUT/mb10p_app_safe.elf" "$OUT/mb10p_app_safe.o" "$OUT/calc_page.o"

# package-manager inspector (read-only) and EXPERIMENTAL remover: fw 3.201.026 only
if [ "$V" = 3201026 ]; then
  $CC $COMMON $SOFT -Werror -DPM_TOOL_INSPECT -c mb10pro/mb10p_pm_tool.c -o "$OUT/mb10p_pm_inspect.o"
  $CC -mcpu=cortex-m33 -mthumb $SOFT -r -T mb10pro/mb10pro.ld -o "$OUT/mb10p_pm_inspect.elf" "$OUT/mb10p_pm_inspect.o"
  mkdir -p "$OUT/experimental"
  # EXPERIMENTAL calc variant whose package-manager node is non-recoverable (flags 0x08)
  $CC $COMMON $HARD -Werror -DCALC_APP_FLAGS=0x08 -c mb10pro/mb10p_app_safe.c -o "$OUT/experimental/mb10p_app_safe_nr.o"
  $CC -mcpu=cortex-m33 -mthumb $HARD -r -T mb10pro/mb10pro.ld -o "$OUT/experimental/mb10p_app_safe_nr.elf" "$OUT/experimental/mb10p_app_safe_nr.o" "$OUT/calc_page.o"
  $CC $COMMON $SOFT -Werror -DPM_TOOL_REMOVE -c mb10pro/mb10p_pm_tool.c -o "$OUT/experimental/mb10p_pm_remove.o"
  $CC -mcpu=cortex-m33 -mthumb $SOFT -r -T mb10pro/mb10pro.ld -o "$OUT/experimental/mb10p_pm_remove.elf" "$OUT/experimental/mb10p_pm_remove.o"
fi

ls -l "$OUT"/*.elf
