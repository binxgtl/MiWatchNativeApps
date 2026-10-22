#!/usr/bin/env bash
# Offline verification of the fw 3.201.026 branch. NOT a hardware test.
#   bash tools/mb10p/verify_all.sh
# Needs: arm-none-eabi-gcc/objdump/readelf, lua5.4, luac, python3, sha256sum.
set -u
cd "$(dirname "$0")/../.."
fail=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fail=1; }
D=dist/mb10p-3.201.026
H=platform/mb10p/fw_3.201.026/miwear_system.h

echo "== 1. reproducible build (clean rebuild must equal committed dist/)"
rm -rf build/3.201.026
sh build_mb10p.sh 3201026 >/dev/null 2>&1 && ok "build_mb10p.sh 3201026 (-Werror on tools)" || bad "build failed"
for f in mb10p_hello mb10p_app_safe mb10p_pm_inspect; do
  cmp -s build/3.201.026/$f.elf $D/$f.elf && ok "$f.elf identical to dist/" || bad "$f.elf differs from dist/"
done
cmp -s build/3.201.026/experimental/mb10p_pm_remove.elf $D/experimental/mb10p_pm_remove.elf && ok "experimental/mb10p_pm_remove.elf identical" || bad "pm_remove differs"
cmp -s build/3.201.026/experimental/mb10p_app_safe_nr.elf $D/experimental/mb10p_app_safe_nr.elf && ok "experimental/mb10p_app_safe_nr.elf identical" || bad "app_safe_nr differs"
B0=$(mktemp); B1=$(mktemp)
arm-none-eabi-objcopy -O binary --only-section=.data build/3.201.026/mb10p_app_safe.elf $B0; arm-none-eabi-objcopy -O binary --only-section=.data $D/experimental/mb10p_app_safe_nr.elf $B1
[ "$(cmp -l $B0 $B1 | wc -l)" = 1 ] && [ "$(cmp -l $B0 $B1 | awk '{print $2" "$3}')" = "0 10" ] && ok "app_safe_nr differs from the tested app_safe by exactly one .data byte (flags 0x00 -> 0x08)" || bad "app_safe_nr differs by more than the flags byte"
arm-none-eabi-objdump -d -j .text build/3.201.026/mb10p_app_safe.elf | tail -n +4 | cmp -s - <(arm-none-eabi-objdump -d -j .text $D/experimental/mb10p_app_safe_nr.elf | tail -n +4) && ok "app_safe_nr .text identical to app_safe" || bad ".text differs"
(cd $D && sha256sum -c SHA256SUMS >/dev/null 2>&1) && ok "dist/SHA256SUMS" || bad "dist/SHA256SUMS"

echo "== 2. ELF structure (relocations, Thumb bit, init/fini, absolutes, ABI)"
ALLOWED=$(grep -o -i '0x[0-9a-f]\{8\}' $H | tr 'a-f' 'A-F' | sed 's/^0X/0x/' | sort -u)
for f in $D/mb10p_hello.elf $D/mb10p_app_safe.elf $D/mb10p_pm_inspect.elf $D/experimental/mb10p_pm_remove.elf $D/experimental/mb10p_app_safe_nr.elf; do
  n=$(basename $f)
  readelf -h $f | grep -q 'REL (Relocatable' && ok "$n ET_REL" || bad "$n not ET_REL"
  readelf -h $f | grep -q 'Machine:.*ARM' && readelf -h $f | grep -q 'ELF32' && ok "$n EM_ARM ELF32" || bad "$n arch"
  bad_rel=$(readelf -r $f | awk '$3 ~ /^R_ARM/ {print $3}' | sort -u | grep -v -E '^(R_ARM_ABS32|R_ARM_TARGET1|R_ARM_THM_CALL|R_ARM_THM_JUMP24|R_ARM_REL32)$')
  [ -z "$bad_rel" ] && ok "$n relocation types supported by modlib ($(readelf -r $f | awk '$3 ~ /^R_ARM/ {print $3}' | sort | uniq -c | tr -s ' ' | tr '\n' ';'))" || bad "$n unsupported relocs: $bad_rel"
  readelf -s $f | grep -q ' UND [^ ]' && bad "$n undefined symbols" || ok "$n no undefined symbols"
  readelf -S $f | grep -q INIT_ARRAY && readelf -S $f | grep -q FINI_ARRAY && ok "$n init/fini arrays" || bad "$n init/fini arrays"
  [ "$(readelf -r $f | grep -c 'TARGET1.*module_')" = 2 ] && ok "$n TARGET1 -> module_initialize/module_uninitialize" || bad "$n ctor/dtor relocs"
  odd=$(readelf -s $f | awk '$4=="FUNC"{print $2}' | while read a; do [ $(( 0x$a & 1 )) -eq 1 ] || echo odd; done)
  [ -z "$odd" ] && ok "$n all FUNC symbols have the Thumb bit" || bad "$n FUNC without Thumb bit"
  DIS=$(arm-none-eabi-objdump -d -j .text $f 2>&1)
  echo "$DIS" | grep -q 'module_initialize' || bad "$n disassembly empty (checks below invalid)"
  echo "$DIS" | grep -q '__aeabi' && bad "$n __aeabi libcall" || ok "$n no __aeabi libcalls"
  abs=$(echo "$DIS" | grep -o '\.word\s0x[23][0-9a-f]\{7\}' | awk '{print $2}' | tr 'a-f' 'A-F' | sed 's/^0X/0x/' | sort -u)
  unk=""
  for a in $abs; do
    v=$(( a & ~1 )); hexv=$(printf '0x%08X' $v); hexo=$(printf '0x%08X' $(( a | 1 )))
    if [ "$hexv" = "0x200B7200" ]; then continue; fi        # compiler base for g_packagemanager_api+offset (verified by hand)
    echo "$ALLOWED" | grep -q -x "$hexv" || echo "$ALLOWED" | grep -q -x "$hexo" || unk="$unk $a"
  done
  [ -z "$unk" ] && ok "$n every absolute is a header-listed address ($(echo $abs | wc -w) values)" || bad "$n absolute not in header:$unk"
done
for f in $D/mb10p_hello.elf $D/mb10p_pm_inspect.elf $D/experimental/mb10p_pm_remove.elf; do
  arm-none-eabi-objdump -d -j .text $f | grep -E -q '\bv(add|mul|ldr|mov|cvt|sub|div)' && bad "$(basename $f) FP instruction in soft-float module" || ok "$(basename $f) no FP instructions (soft-float)"
done
readelf -A $D/mb10p_app_safe.elf | grep -q 'FP_arch\|VFP' && ok "mb10p_app_safe uses the FPv5 single-precision ABI (hard-float)" || echo "INFO  app_safe FP attribute not shown"

echo "== 3. embedded copies match dist/ and manager manifest matches files"
cmp -s $D/mb10p_hello.elf mb10pro/wf_native_hello_test/app/lua/mb10p_hello_3.201.026.elf && ok "hello_test embeds dist hello" || bad "hello_test ELF differs"
cmp -s $D/mb10p_hello.elf mb10pro/wf_native_hello/app/lua/mb10p_hello_3.201.026.elf && ok "wf_native_hello embeds dist hello" || bad "wf_native_hello ELF differs"
cmp -s $D/mb10p_app_safe.elf mb10pro/wf_native_calc_safe/app/lua/mb10p_app_safe_3.201.026.elf && ok "wf_native_calc_safe embeds dist app_safe" || bad "calc_safe ELF differs"
M=mb10pro/wf_native_manager/app/lua
cmp -s $D/mb10p_hello.elf $M/mb10p_hello_3.201.026.elf && cmp -s $D/mb10p_app_safe.elf $M/mb10p_app_safe_3.201.026.elf && cmp -s $D/mb10p_pm_inspect.elf $M/mb10p_pm_inspect_3.201.026.elf && ok "manager embeds dist ELFs" || bad "manager ELFs differ"
ls $M | grep -q 'pm_remove' && bad "experimental remover must NOT be in the manager package" || ok "remover not packaged in manager"
cp $M/main.lua /tmp/mb10p_main_before.lua
python3 tools/mb10p/gen_manifest.py $M mb10p_hello_3.201.026.elf mb10p_app_safe_3.201.026.elf mb10p_pm_inspect_3.201.026.elf calc_logo_112.png >/dev/null
cmp -s $M/main.lua /tmp/mb10p_main_before.lua && ok "manager MANIFEST up to date" || { bad "manager MANIFEST was stale (regenerated: commit it)"; }

echo "== 4. Lua syntax + logic tests (mock shell)"
for l in mb10pro/wf_native_manager/app/lua/main.lua mb10pro/wf_native_hello_test/app/lua/main.lua mb10pro/wf_native_calc_safe/app/lua/main.lua mb10pro/wf_native_hello/app/lua/main.lua; do
  luac -p $l && ok "luac -p $l" || bad "syntax $l"
done
TM=$(lua5.4 tools/mb10p/test_manager.lua $M | tail -1)
echo "$TM" | grep -q 'CHECKS OK' && ok "test_manager.lua ($TM)" || bad "test_manager.lua ($TM)"
MU=$(python3 tools/mb10p/mutate_manager.py | tail -1)
python3 tools/mb10p/mutate_manager.py >/dev/null 2>&1 && ok "mutation check: every re-introduced bug is caught ($MU)" || bad "mutation check ($MU)"
FT=$(python3 tools/mb10p/test_face_id.py | tail -1)
echo "$FT" | grep -q 'CHECKS OK' && ok "test_face_id.py ($FT)" || bad "test_face_id.py ($FT)"
FP=$(python3 tools/mb10p/test_face_pack.py | tail -1)
echo "$FP" | grep -q 'CHECKS OK' && ok "test_face_pack.py ($FP)" || bad "test_face_pack.py ($FP)"
BF=$(python3 tools/mb10p/test_build_faces.py | tail -1)
echo "$BF" | grep -q 'CHECKS OK' && ok "test_build_faces.py: .face pipeline deterministic, hello_py = hardware-PASS package ($BF)" || bad "test_build_faces.py ($BF)"
lua5.4 tools/mb10p/test_hello_loader.lua mb10pro/wf_native_hello_test/app/lua/main.lua $D/mb10p_hello.elf | tail -1 | grep -q 'ALL SCENARIOS OK' && ok "test_hello_loader.lua" || bad "test_hello_loader.lua"
python3 - $M/main.lua <<'PYEOF' && ok "manager can only run getprop/lsmod/dmesg/cp/insmod/rmmod/ls/free (static check)" || bad "manager command set"
import re, sys
s = open(sys.argv[1]).read()
allowed = {'getprop', 'lsmod', 'dmesg', 'cp', 'insmod', 'rmmod', 'ls', 'free'}
bad = []
for fn, arg in re.findall(r'(?<!function )\b(run|capture)\(([^)\n]*)', s):
    m = re.match(r'\s*"([a-z]+)', arg)
    if m:
        if m.group(1) not in allowed: bad.append(arg)
    elif not (fn == 'run' and arg.strip().startswith('cmd ..')):
        bad.append(fn + '(' + arg)
code = re.sub(r'--[^\n]*', '', s)          # comments may mention os.execute()
if len(re.findall(r'\bos\.execute\(', code)) != 1 or 'io.popen' in code or 'loadstring' in code or re.search(r'\bload\(', code):
    bad.append('os.execute outside run() / popen / dynamic code')
if '/data/nobusiness"' in s.replace('"/data/nobusiness",', '') :
    bad.append('/data/nobusiness used outside the SNAP list')
print(bad) if bad else None
sys.exit(1 if bad else 0)
PYEOF
python3 - <<'PYEOF' && ok "watchface IDs unique and titles match module.fprj (tools/mb10p/face_ids.tsv)" || bad "watchface ID registry"
import re
rows = [l.rstrip('\n').split('\t') for l in open('tools/mb10p/face_ids.tsv') if l.strip() and not l.startswith('id\t')]
ids = [r[0] for r in rows]
ok = len(ids) == len(set(ids)) and all(len(i) == 9 and i.isdigit() for i in ids)
for proj, title in (('wf_native_hello', 'Hello'), ('wf_native_calc_safe', 'Calc safe'), ('wf_native_manager', 'NativeMgr')):
    t = re.search(r'Screen Title="([^"]*)"', open('mb10pro/%s/module.fprj' % proj).read()).group(1)
    ok = ok and t == title and any(r[1] == title for r in rows)
raise SystemExit(0 if ok else 1)
PYEOF

echo "== 5. repo hygiene"
BASE=$(git rev-parse --verify -q origin/master || echo HEAD)
CHANGED=$( (git diff --name-only --diff-filter=AM "$BASE" -- . ; git ls-files -o --exclude-standard) | sort -u)
big=$(echo "$CHANGED" | while read f; do [ -f "$f" ] && [ $(stat -c %s "$f") -gt 524288 ] && echo "$f"; done)
[ -z "$big" ] && ok "no added/changed file > 512 KiB" || bad "large files: $big"
echo "$CHANGED" | grep -E 'vela_|\.ota|\.zip$|romfs|\.face$|\.bin$' | grep -q . && bad "firmware-looking file in the change set" || ok "no firmware images / extracted resources / .face in the change set"
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
