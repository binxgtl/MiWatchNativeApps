#!/usr/bin/env python3
"""Mutation check for tools/mb10p/test_manager.lua.

Each mutant re-introduces one bug (or removes one safety check) in a copy of
mb10pro/wf_native_manager/app/lua/main.lua. The test suite must FAIL on every
mutant; a surviving mutant means a safety rule is not covered by a test.
usage: python3 tools/mb10p/mutate_manager.py   (from the repo root)
"""
import os, shutil, subprocess, sys, tempfile

SRC = 'mb10pro/wf_native_manager/app/lua'
TEST = 'tools/mb10p/test_manager.lua'

M = [
 ('stale tmp file reused (output file not reset)',
  '    if spit(file, NO_OUT) then return true end', '    if true then return true end'),
 ('version compared by numeric prefix',
  'return v == EXPECT_FW and "OK" or "MISMATCH"', 'return (v:match("^%s*([%d._]+)") == EXPECT_FW) and "OK" or "MISMATCH"'),
 ('ro.build.id made blocking',
  '{ key = "ro.build.id", short = "id", blocking = false,', '{ key = "ro.build.id", short = "id", blocking = true,'),
 ('customer_version mismatch not blocking',
  '{ key = "ro.build.customer_version", short = "cust", blocking = true,', '{ key = "ro.build.customer_version", short = "cust", blocking = false,'),
 ('empty id value treated as a mismatch',
  '        elseif v == "" then st, reason = "UNKNOWN", "not set"\n', ''),
 ('SCAN refused when the firmware gate fails',
  'local function do_scan()\n    begin("SCAN")', 'local function do_scan()\n    begin("SCAN")\n    if fw_status(fw_boot) ~= "OK" then verdict("REFUSED", "x") return end'),
 ('insmod failed + lsmod unreadable treated as FAIL',
  '    elseif not after then', '    elseif false then'),
 ('insmod ok accepted without lsmod evidence',
  '    if ins_ok and row then', '    if ins_ok then'),
 ('duplicate module not refused',
  '        if rows[c] then\n            say(c .. " already loaded: "', '        if false then\n            say(c .. " already loaded: "'),
 ('dmesg mark ignored (old lines count)',
  '    for i = mark - base + 1, #acc do', '    for i = 1, #acc do'),
 ('dmesg dumps not aligned (duplicates)',
  '    if #prev > 0 then\n        local lastp', '    if false then\n        local lastp'),
 ('grown syslog line ignored',
  '        if grown ~= "" then new[#new + 1] = grown end', ''),
 ('history overflow not detected',
  '    if mark < base then return nil, "dmesg history overflowed since INSTALL" end', ''),
 ('interrupted action not adopted at open',
  'adopt_pending()\nlocal fw_ok', 'local fw_ok'),
 ('no lock after a Lua error in INSTALL/REMOVE',
  '                set_lock("Lua error during " .. text .. ": " .. tostring(message))', ''),
 ('journal not written before insmod',
  '    journal("INSTALL", a.key, "insmod")\n', ''),
 ('SNAP incomplete reported as OK',
  '    elseif #unknown > 0 then verdict("INCOMPLETE"', '    elseif false then verdict("INCOMPLETE"'),
 ('SNAP diff includes UNKNOWN values',
  ' and not v:find("^UNKNOWN") and not tostring(pm[k]):find("^UNKNOWN")', ''),
 ('directory reported as a file in SNAP',
  '                if is_dir_err(rerr, rcode) then return { state = "dir" } end\n', ''),
 ('shared logo overwritten',
  '        if d.state ~= "absent" then\n            return false, dst .. " exists, differs', '        if false then\n            return false, dst .. " exists, differs'),
 ('copy not verified',
  '    if d.cut or d.size ~= m.size or d.adler ~= m.adler then return false, "copy differs: " .. fp_str(d) end\n    local eq, why = files_equal(src, dst)\n    if not eq then',
  '    local eq, why = true, nil\n    if not eq then'),
 ('manifest size 0 accepted',
  'm.size <= 0 or ', ''),
 ('registered app removable with rmmod',
  '    if a.kind == "registering" then\n        local st = load_state()[a.key]', '    if false then\n        local st = load_state()[a.key]'),
 ('REMOVE without identity check',
  '    if not mine or mine.row ~= rows[a.module] then', '    if false then'),
 ('inspector removable before DONE',
  '        if not check_expect(lines, { plain = a.done }) then', '        if false then'),
 ('registered app vanished not treated as anomaly',
  '    if a.kind == "registering" and st[a.key] then', '    if false then'),
 ('upstream calculator not treated as a conflict',
  'local CALC_CONFLICTS = { "calc_safe", "mb10p_app" }', 'local CALC_CONFLICTS = { "calc_safe" }'),
 ('calc_dec does not conflict with calc_safe',
  'dst = "/data/mb10p_mgr_calc_dec.elf",\n      extra = LOGO, conflicts = CALC_CONFLICTS,',
  'dst = "/data/mb10p_mgr_calc_dec.elf",\n      extra = LOGO, conflicts = { "mb10p_app" },'),
 ('calc_dec copied over the Calc dec watchface file',
  'dst = "/data/mb10p_mgr_calc_dec.elf",', 'dst = "/data/mb10p_com.m0tral.calc_dec.elf",'),
 ('calc_dec loaded under its own module name (old loaders cannot see it)',
  '{ key = "calc_dec", label = "CalcDec", module = "calc_safe", kind = "registering",',
  '{ key = "calc_dec", label = "CalcDec", module = "calc_dec", kind = "registering",'),
 ('calc_dec treated as transient (rmmod allowed)',
  '{ key = "calc_dec", label = "CalcDec", module = "calc_safe", kind = "registering",',
  '{ key = "calc_dec", label = "CalcDec", module = "calc_safe", kind = "transient",'),
 ('calc_dec packages the float Calc Safe ELF',
  'elf = "mb10p_calc_dec_3.201.026.elf", dst', 'elf = "mb10p_app_safe_3.201.026.elf", dst'),
 ('module loaded as another app shown as unknown',
  '        if b ~= a and b.module == a.module and o and o.row == rows[a.module] then return "loaded(as " .. b.key .. ")" end\n', ''),
 ('SNAP keys per app instead of per module',
  'for _, a in ipairs(MODS) do put("mod." .. a.module, rows[a.module] and "loaded" or "absent") end',
  'for _, a in ipairs(APPS) do put("mod." .. a.key, rows[a.module] and "loaded" or "absent") end'),
 ('SNAP misses the Calc dec watchface file',
  '    "/data/mb10p_com.m0tral.calc_dec.elf", "/data/mb10p_hello_3.201.026.elf",', '    "/data/mb10p_hello_3.201.026.elf",'),
 ('manager build not shown at open',
  'say("NativeMgr " .. MGR_BUILD)\n', ''),
 ('calc_safe failure lines ignored',
  '        for _, e in ipairs(a.fail or {}) do', '        for _, e in ipairs({}) do'),
 ('VERIFY ignores a changed lsmod row',
  '    if st.row ~= row then verdict("UNKNOWN", "lsmod row changed since INSTALL") return end\n', ''),
 ('log not rotated while running',
  '    if log_bytes + #text > LOG_MAX then', '    if false then'),
 ('snapshot log unbounded',
  '    rotate(SNAP_LOG, SNAP_LOG_MAX, #now + 20)\n', ''),
 ('log panel overlaps the buttons',
  'align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 157 },', 'align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 120 },'),
 ('verdict not clamped to two lines',
  '    if #vl > 2 then vl =', '    if false then vl ='),
 ('command at open besides getprop',
  'local fw_ok = fw_status(fw_boot) == "OK"', 'local fw_ok = fw_status(fw_boot) == "OK"\nrun("lsmod > /tmp/x")'),
]

def main():
    base = open(os.path.join(SRC, 'main.lua')).read()
    killed, survived = 0, []
    for name, old, new in M:
        n = base.count(old)
        if n != 1:
            print('BROKEN  %s (pattern found %d times)' % (name, n))
            survived.append(name + ' [pattern]')
            continue
        d = tempfile.mkdtemp(prefix='mb10p_mut_')
        try:
            for f in os.listdir(SRC):
                shutil.copy(os.path.join(SRC, f), d)
            open(os.path.join(d, 'main.lua'), 'w').write(base.replace(old, new))
            r = subprocess.run(['lua5.4', TEST, d], capture_output=True, text=True)
            if r.returncode != 0:
                killed += 1
                first = next((l for l in r.stdout.splitlines() if l.startswith('FAIL')), r.stderr.strip()[:120])
                print('KILLED  %s  <- %s' % (name, first[:110]))
            else:
                survived.append(name)
                print('SURVIVED %s' % name)
        finally:
            shutil.rmtree(d)
    print('%d/%d mutants killed' % (killed, len(M)))
    sys.exit(0 if not survived else 1)

if __name__ == '__main__':
    main()
