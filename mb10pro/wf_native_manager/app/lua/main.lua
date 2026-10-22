-- Native App Manager for Xiaomi Smart Band 10 Pro Global 3.201.026
-- (installer pattern from m0tral/MiWatchNativeApps; manager logic added here)
--
-- What it does, only when a button is pressed (nothing runs at boot, and the
-- only command executed when the watchface opens is `getprop`):
--   SCAN     firmware gate, which known modules are loaded, dmesg availability
--   INSTALL  copy + byte-verify + insmod + lsmod evidence for the selected app
--   VERIFY   read the app's own syslog lines from dmesg (callback/registration)
--   REMOVE   rmmod, but ONLY for modules that leave no pointers behind
--            (kind=transient) and only when the lsmod row still equals the row
--            recorded at install. Registering apps are refused: reboot.
--   SNAP     before/after-reboot snapshot, diffed against the previous one
--
-- It never touches the package manager directly, never deletes or resets a
-- watchface, never writes firmware and never issues reboot.
--
-- Persistent state is kept ONLY in /tmp (tmpfs): it is cleared by a reboot,
-- exactly like the loaded modules it describes.

local lvgl = require("lvgl")

local EXPECT_FW  = "3.201.026"
local EXPECT_ID  = "CONBINE_LTALM080_3.201.026"      -- ro.build.id (warn-only if unreadable)
local LOG_FILE   = "/data/mb10p_manager.log"
local LOG_MAX    = 65536
local STATE_FILE = "/tmp/mb10p_mgr.state"           -- key|module|lsmod row (cleared by reboot)
local LOCK_FILE  = "/tmp/mb10p_mgr.lock"            -- set after an ambiguous result
local MARKER     = "/tmp/mb10p_boot_marker"
local SNAP_LAST  = "/data/mb10p_snap.last"
local SNAP_LOG   = "/data/mb10p_snap.log"
local T_LSMOD, T_DMESG, T_MISC = "/tmp/mb10p_mgr_lsmod.txt", "/tmp/mb10p_mgr_dmesg.txt", "/tmp/mb10p_mgr_cmd.txt"

-- BEGIN MANIFEST (rewritten by tools/mb10p/gen_manifest.py; size + adler32 of each packaged file)
local MANIFEST = {
    ["mb10p_hello_3.201.026.elf"] = { size = 1388, adler = "9a3983d4" },
    ["mb10p_app_safe_3.201.026.elf"] = { size = 6256, adler = "13a93070" },
    ["mb10p_pm_inspect_3.201.026.elf"] = { size = 3028, adler = "6eba5cfb" },
    ["calc_logo_112.png"] = { size = 19531, adler = "fc37a033" },
}
-- END MANIFEST

-- kind = "transient": leaves no pointer into its own memory once finished -> rmmod allowed
-- kind = "registering": registers with the package manager -> removal is by reboot only
local APPS = {
    { key = "hello", label = "Hello", module = "mb10p_hello", kind = "transient",
      elf = "mb10p_hello_3.201.026.elf", dst = "/data/mb10p_hello_3.201.026.elf",
      tag = "[hello_module]", expect = { "loaded", "hello" } },
    { key = "calc_safe", label = "CalcSafe", module = "calc_safe", kind = "registering",
      elf = "mb10p_app_safe_3.201.026.elf", dst = "/data/mb10p_com.m0tral.calc_safe.elf",
      extra = { { src = "calc_logo_112.png", dst = "/data/calc_logo_112.png" } },
      tag = "[calc_safe]", expect = { "loaded", "pm install(", "rc=0", "app_launcher_add rc=", "registered" } },
    { key = "pm_inspect", label = "PMInspect", module = "pm_inspect", kind = "transient",
      elf = "mb10p_pm_inspect_3.201.026.elf", dst = "/data/mb10p_pm_inspect.elf",
      tag = "[pm_inspect]", done = "DONE" },
}

---------------------------------------------------------------- logging / shell

local ring, seq = {}, 0
local TEST = MB10P_TEST_EXPORT          -- nil on the band; set only by tools/mb10p/test_manager.lua

local function trunc_log()
    local f = io.open(LOG_FILE, "rb")
    if not f then return end
    local data = f:read(LOG_MAX + 1)
    f:close()
    if data and #data > LOG_MAX then
        local w = io.open(LOG_FILE, "wb")
        if w then w:write("-- log truncated at start --\n") w:close() end
    end
end

local function log(line)
    seq = seq + 1
    local text = string.format("%03d %s", seq, line)
    local f = io.open(LOG_FILE, "a")
    if f then f:write(text, "\n") f:close() end
    return text
end

local function say(line)                      -- log + keep a short on-screen tail
    local t = log(line)
    ring[#ring + 1] = t:sub(1, 44)
    if #ring > 6 then table.remove(ring, 1) end
end

local function squash(s) return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end

local function slurp(path, limit)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read(limit or "*a")
    f:close()
    return d
end

local function spit(path, text, mode)
    local f = io.open(path, mode or "wb")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

-- Normalise os.execute() results (Lua 5.1 numeric and 5.3+ tuple styles).
local function run(cmd)
    local a, b, c = os.execute(cmd)
    local ok, code
    if type(a) == "number" then ok, code = (a == 0), a
    elseif a == true then ok, code = true, (type(c) == "number" and c or 0)
    else ok, code = false, (type(c) == "number" and c or a) end
    log(string.format("CMD %s -> ok=%s code=%s (raw=%s,%s,%s)", cmd, tostring(ok),
        tostring(code), tostring(a), tostring(b), tostring(c)))
    return ok, code
end

local function getprop(name)
    run("getprop " .. name .. " > " .. T_MISC)
    local v = slurp(T_MISC, 512) or ""
    return (v:gsub("%s+$", ""))
end

-- Adler-32, pure arithmetic (no bit operators: unknown Lua build on the band).
local function adler32(s, a, b)
    a, b = a or 1, b or 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return a, b
end

local function fingerprint(path, cap)         -- size, adler32 hex, truncated?
    local f = io.open(path, "rb")
    if not f then return nil end
    local a, b, n, cut = 1, 0, 0, false
    while true do
        local chunk = f:read(4096)
        if not chunk then break end
        if n + #chunk > cap then chunk = chunk:sub(1, cap - n) cut = true end
        a, b = adler32(chunk, a, b)
        n = n + #chunk
        if cut then break end
    end
    local size = n
    if cut then local rest = f:seek("end") size = rest or n end
    f:close()
    return size, string.format("%04x%04x", b, a), cut
end

---------------------------------------------------------------- module state

-- Returns nil when lsmod is unusable (fail closed), else rows[name]=normalised row and list.
local function lsmod_rows(tag)
    local ok = run("lsmod > " .. T_LSMOD)
    local text = slurp(T_LSMOD, 16384)
    if not text then say("lsmod[" .. tag .. "] unreadable file") return nil end
    log("LSMOD[" .. tag .. "] raw: " .. squash(text):sub(1, 400))
    if not ok then say("lsmod[" .. tag .. "] command failed") return nil end
    if not text:find("NEXPORTS", 1, true) then say("lsmod[" .. tag .. "] no header") return nil end
    local rows, names = {}, {}
    local first = true
    for l in text:gmatch("[^\r\n]+") do
        if first then first = false                   -- header line
        else
            local n = l:match("^%s*(%S+)")
            if n then rows[n] = squash(l) names[#names + 1] = n end
        end
    end
    return rows, names
end

local function dmesg_text()
    local ok = run("dmesg > " .. T_DMESG)
    if not ok then return nil end
    local f = io.open(T_DMESG, "rb")
    if not f then return nil end
    local size = f:seek("end") or 0
    if size > 262144 then f:seek("set", size - 262144) else f:seek("set", 0) end
    local d = f:read("*a")
    f:close()
    return d
end

local function load_state()
    local t = {}
    local d = slurp(STATE_FILE, 8192) or ""
    for l in d:gmatch("[^\n]+") do
        local k, m, row = l:match("^([^|]+)|([^|]+)|(.*)$")
        if k then t[k] = { module = m, row = row } end
    end
    return t
end

local function save_state(t)
    local out = {}
    for k, v in pairs(t) do out[#out + 1] = k .. "|" .. v.module .. "|" .. v.row end
    table.sort(out)
    spit(STATE_FILE, table.concat(out, "\n") .. "\n")
end

local function locked() return slurp(LOCK_FILE, 8) ~= nil end
local function set_lock(why) spit(LOCK_FILE, why .. "\n") say("LOCKED: " .. why) end

---------------------------------------------------------------- firmware gate

local fw, fw_id = "", ""
local fatal
local function detect_fw()
    run("getprop ro.build.version > " .. T_MISC)
    local raw = slurp(T_MISC, 256) or ""
    fw = raw:match("^%s*([%d._]+)") or ""
    if fw ~= EXPECT_FW then
        fatal = "unsupported firmware: '" .. fw .. "' (need " .. EXPECT_FW .. ")"
    elseif not SCRIPT_PATH then
        fatal = "SCRIPT_PATH missing"
    end
end
detect_fw()                       -- the ONLY command run at load time

local function gate()                    -- re-checked before every INSTALL / REMOVE
    if fatal then return false, fatal end
    fw_id = getprop("ro.build.id")
    if fw_id ~= "" and fw_id ~= EXPECT_ID then
        return false, "build id '" .. fw_id .. "' != " .. EXPECT_ID
    end
    if locked() then return false, "locked after anomaly: reboot the band" end
    return true
end

---------------------------------------------------------------- actions

local sel = 1
local function app() return APPS[sel] end
local function status() end   -- replaced once the UI exists
local function headline(text, color) status(text, color) end
local GREEN, RED, AMBER, BLUE = 0x8FF0A4, 0xFF9A9A, 0xFFD58A, 0xBFD9FF

local function manifest_ok(path_src, name)
    local m = MANIFEST[name]
    local size, ad = fingerprint(path_src, 262144)
    if not size then return false, "packaged file missing: " .. name end
    if not m then return false, "no manifest entry for " .. name end
    if size ~= m.size or ad ~= m.adler then
        return false, string.format("%s corrupt: size %s adler %s (want %s %s)", name, tostring(size), ad, tostring(m.size), m.adler)
    end
    return true
end

local function copy_verified(src, dst, name)
    local ok, why = manifest_ok(src, name)
    if not ok then return false, why end
    local cp_ok, cp_code = run("cp " .. src .. " " .. dst)
    local a, b = slurp(src), slurp(dst)
    log(string.format("COPY %s size src=%d dst=%s identical=%s", name, #a, tostring(b and #b), tostring(a == b)))
    if not cp_ok then return false, "cp failed code=" .. tostring(cp_code) end
    if a ~= b then return false, "copy differs from source" end
    return true
end

local function do_scan()
    log("== SCAN")
    local g_ok, g_why = gate()
    say("fw " .. fw .. " id " .. (fw_id ~= "" and fw_id or "?"))
    if not g_ok then say("GATE: " .. g_why) end
    local rows, names = lsmod_rows("scan")
    if not rows then headline("SCAN: lsmod unreadable. No action allowed.", RED) return end
    local st = load_state()
    local ours, parts = {}, {}
    for _, a in ipairs(APPS) do
        ours[a.module] = true
        local mark = rows[a.module] and (st[a.key] and st[a.key].row == rows[a.module] and "LOADED(ours)" or "LOADED(?)") or "absent"
        parts[#parts + 1] = a.key .. ":" .. mark
        say(a.key .. " " .. mark)
    end
    local others = 0
    for _, n in ipairs(names) do if not ours[n] then others = others + 1 end end
    say("other modules: " .. others)
    local d = dmesg_text()
    say("dmesg: " .. (d and ("ok " .. #d .. "B") or "n/a"))
    headline(g_ok and "SCAN done." or ("SCAN: " .. g_why), g_ok and GREEN or AMBER)
end

local function classify_load(a, ins_ok, ins_code, after)
    if ins_ok and after and after.row then
        local st = load_state()
        st[a.key] = { module = a.module, row = after.row }
        save_state(st)
        log("LOAD PASS row: " .. after.row)
        return "pass"
    elseif ins_ok then
        set_lock("insmod ok but " .. a.module .. " not confirmed by lsmod")
        return "uncertain"
    elseif after and after.row then
        set_lock("insmod failed code=" .. tostring(ins_code) .. " yet module listed")
        return "anomaly"
    end
    return "fail"
end

local function do_install()
    local a = app()
    log("== INSTALL " .. a.key)
    local ok, why = gate()
    if not ok then headline("INSTALL refused: " .. why, RED) say(why) return end
    local rows = lsmod_rows("before")
    if not rows then headline("INSTALL refused: lsmod unreadable.", RED) return end
    if rows[a.module] then
        headline("INSTALL refused: " .. a.module .. " already loaded.\nDuplicate not allowed. Reboot to reset.", AMBER)
        say("duplicate " .. a.module)
        return
    end
    if a.kind == "registering" then
        local st = load_state()
        if st[a.key] then log("stale state entry for " .. a.key .. " ignored (module absent)") end
    end
    local c_ok, c_why = copy_verified(SCRIPT_PATH .. a.elf, a.dst, a.elf)
    if not c_ok then headline("INSTALL FAIL: " .. c_why .. "\nNo insmod run.", RED) say(c_why) return end
    for _, x in ipairs(a.extra or {}) do
        local e_ok, e_why = copy_verified(SCRIPT_PATH .. x.src, x.dst, x.src)
        if not e_ok then headline("INSTALL FAIL: " .. e_why .. "\nNo insmod run.", RED) say(e_why) return end
    end
    local ins_ok, ins_code = run("insmod " .. a.dst .. " " .. a.module)
    local after_rows = lsmod_rows("after-insmod")
    local after = after_rows and { row = after_rows[a.module] } or nil
    local r = classify_load(a, ins_ok, ins_code, after)
    if r == "pass" then
        say(a.key .. " loaded+listed")
        headline(a.kind == "registering"
            and "INSTALL PASS (insmod ok + listed).\nWait 2 s, press VERIFY. Remove = reboot."
            or "INSTALL PASS (insmod ok + listed).", GREEN)
    elseif r == "uncertain" then
        headline("UNCERTAIN: insmod ok, lsmod does not confirm.\nNo further action. Reboot.", AMBER)
    elseif r == "anomaly" then
        headline("ANOMALY: insmod code " .. tostring(ins_code) .. " but listed.\nDo not retry. Reboot.", AMBER)
    else
        say("insmod code " .. tostring(ins_code))
        headline("INSTALL FAIL: insmod code=" .. tostring(ins_code) .. ", not listed.", RED)
    end
end

-- Parse the app's own syslog lines out of dmesg.
local function tag_lines(text, tag)
    local out = {}
    for l in text:gmatch("[^\r\n]*") do
        if l:find(tag, 1, true) then out[#out + 1] = l end
    end
    return out
end

local function do_verify()
    local a = app()
    log("== VERIFY " .. a.key)
    local rows = lsmod_rows("verify")
    if not rows then headline("VERIFY: lsmod unreadable.", RED) return end
    say(a.module .. (rows[a.module] and " listed" or " not listed"))
    local d = dmesg_text()
    if not d then
        headline("VERIFY: dmesg n/a - callback/registration state UNKNOWN.\nCheck the launcher by hand.", AMBER)
        return
    end
    local lines = tag_lines(d, a.tag)
    say(#lines .. " " .. a.tag .. " lines")
    for i = math.max(1, #lines - 40), #lines do log("DMESG " .. squash(lines[i]):sub(1, 160)) end
    local all = table.concat(lines, "\n")
    if a.expect then
        local miss = {}
        for _, tok in ipairs(a.expect) do
            if not all:find(tok, 1, true) then miss[#miss + 1] = tok end
        end
        if #miss == 0 then headline("VERIFY PASS: all expected log lines present.", GREEN)
        else headline("VERIFY: missing " .. table.concat(miss, ", "), AMBER) end
    elseif a.done then
        local last_node, last_page
        for _, l in ipairs(lines) do
            if l:find(" NODE ", 1, true) then last_node = l end
            if l:find(" PAGE ", 1, true) then last_page = l end
        end
        local finished = all:find(" " .. a.done .. " ", 1, true) ~= nil
        if last_node then
            local fl = last_node:match("flags=0x(%x+)")
            local function nz(k) local v = last_node:match(k .. "=0x(%x+)") return (v and tonumber(v, 16) ~= 0) and "set" or "0" end
            say("flags 0x" .. tostring(fl) .. " rec=" .. ((fl and math.floor(tonumber(fl, 16) / 8) % 2 == 0) and "yes" or "no"))
            say("cb name:" .. nz("cb1c") .. " sig:" .. nz("cb38") .. " pages:" .. nz("pages"))
        else
            say("no NODE line (app not registered?)")
        end
        if last_page then say("page state " .. (last_page:match("state=(%d+)") or "?")) end
        headline(finished and "VERIFY: inspector finished." or "VERIFY: inspector still running (wait for DONE).", finished and GREEN or AMBER)
    end
end

local function do_remove()
    local a = app()
    log("== REMOVE " .. a.key)
    local ok, why = gate()
    if not ok then headline("REMOVE refused: " .. why, RED) say(why) return end
    local rows = lsmod_rows("before-rmmod")
    if not rows then headline("REMOVE refused: lsmod unreadable.", RED) return end
    if not rows[a.module] then headline("Nothing to remove: " .. a.module .. " not loaded.", AMBER) return end
    if a.kind == "registering" then
        say("registered app: reboot")
        log("REMOVE refused: " .. a.module .. " registers with the package manager; the firmware keeps pointers into the module (callbacks/pages). rmmod would free them. Reboot the band.")
        headline("REMOVE refused: " .. a.label .. " is registered.\nOnly a reboot removes it safely.", AMBER)
        return
    end
    local st = load_state()
    local mine = st[a.key]
    if not mine or mine.row ~= rows[a.module] then
        log("REMOVE refused: identity not confirmed (state=" .. tostring(mine and mine.row) .. " now=" .. tostring(rows[a.module]) .. ")")
        headline("REMOVE refused: cannot confirm this module is the one\nthis manager loaded.", AMBER)
        return
    end
    if a.done then
        local d = dmesg_text()
        if not d then headline("REMOVE refused: dmesg n/a, cannot confirm\n" .. a.module .. " finished.", AMBER) return end
        local all = table.concat(tag_lines(d, a.tag), "\n")
        if not all:find(" " .. a.done .. " ", 1, true) then
            headline("REMOVE refused: " .. a.module .. " not finished (no " .. a.done .. ").", AMBER)
            return
        end
    end
    local rm_ok, rm_code = run("rmmod " .. a.module)
    local after = lsmod_rows("after-rmmod")
    if rm_ok and after and not after[a.module] then
        st[a.key] = nil
        save_state(st)
        log("REMOVE PASS")
        headline("REMOVE PASS (rmmod ok + not listed).", GREEN)
    elseif after and after[a.module] then
        set_lock("rmmod code=" .. tostring(rm_code) .. " module still listed")
        headline("REMOVE FAIL: still listed (code=" .. tostring(rm_code) .. "). Reboot.", RED)
    else
        set_lock("rmmod code=" .. tostring(rm_code) .. " lsmod unreadable/unclear")
        headline("UNCERTAIN: rmmod code=" .. tostring(rm_code) .. ".", AMBER)
    end
end

-- Snapshot keys that matter for "is the system clean after reboot?"
local SNAP_FILES = {
    "/data/mb10p_com.m0tral.calc_safe.elf", "/data/calc_logo_112.png",
    "/data/mb10p_hello_3.201.026.elf", "/data/mb10p_pm_inspect.elf",
    "/data/app/launcher/launcher.db", "/data/persist.db", "/data/nobusiness",
}
local SNAP_PROPS = { "persist.record_app_install", "persist.app_func_bitmap",
                     "persist.app_capability", "persist.launcher.guide" }

local function do_snap()
    log("== SNAP")
    local kv = {}
    local function put(k, v) kv[#kv + 1] = k .. "=" .. tostring(v) end
    local fresh = slurp(MARKER, 4) == nil
    if fresh then spit(MARKER, "1\n") end
    put("boot", fresh and "NEW" or "same")
    put("fw", fw)
    local rows, names = lsmod_rows("snap")
    if rows then
        table.sort(names)
        put("modules", table.concat(names, ","))
        for _, a in ipairs(APPS) do put("mod." .. a.key, rows[a.module] and "loaded" or "absent") end
    else
        put("modules", "UNREADABLE")
    end
    for _, p in ipairs(SNAP_FILES) do
        local size, ad, cut = fingerprint(p, 131072)
        put("file." .. p, size and (size .. ":" .. ad .. (cut and "+" or "")) or "absent")
    end
    for _, p in ipairs(SNAP_PROPS) do put("prop." .. p, getprop(p)) end
    local d = dmesg_text()
    if d then
        for _, a in ipairs(APPS) do put("dmesg." .. a.key, #tag_lines(d, a.tag)) end
    else
        put("dmesg", "n/a")
    end
    run("ls -l /data/app/launcher > " .. T_MISC)
    log("LS launcher: " .. squash(slurp(T_MISC, 800) or "?"))
    run("free > " .. T_MISC)
    log("FREE: " .. squash(slurp(T_MISC, 400) or "?"))

    local now = table.concat(kv, "\n") .. "\n"
    local prev = slurp(SNAP_LAST, 8192)
    local diffs = {}
    if prev then
        local pm = {}
        for l in prev:gmatch("[^\n]+") do local k, v = l:match("^([^=]+)=(.*)$") if k then pm[k] = v end end
        for _, l in ipairs(kv) do
            local k, v = l:match("^([^=]+)=(.*)$")
            if k ~= "boot" and pm[k] ~= v then diffs[#diffs + 1] = k .. ": " .. tostring(pm[k]) .. " -> " .. v end
        end
    end
    spit(SNAP_LOG, "---- snapshot ----\n" .. now, "a")
    spit(SNAP_LAST, now)
    say("boot: " .. (fresh and "NEW since last marker" or "same boot"))
    say("modules: " .. (rows and #names or "?"))
    if not prev then say("first snapshot (no diff)")
    elseif #diffs == 0 then say("no change vs previous")
    else
        for i = 1, math.min(#diffs, 4) do say(diffs[i]:sub(1, 44)) end
        if #diffs > 4 then say("+" .. (#diffs - 4) .. " more in log") end
        for _, x in ipairs(diffs) do log("DIFF " .. x) end
    end
    headline("SNAP saved (" .. SNAP_LAST .. ")", GREEN)
end

if TEST then
    TEST.adler32 = adler32
    TEST.fingerprint = fingerprint
end

---------------------------------------------------------------- UI

trunc_log()
local rootbase = lvgl.Object(nil, {
    w = lvgl.HOR_RES(), h = lvgl.VER_RES(), bg_color = 0x07111F,
    bg_opa = lvgl.OPA(100), border_width = 0,
})
rootbase:clear_flag(lvgl.FLAG.SCROLLABLE)
rootbase:add_flag(lvgl.FLAG.EVENT_BUBBLE)
local root = lvgl.Object(rootbase, {
    w = lvgl.HOR_RES(), h = lvgl.VER_RES(), bg_color = 0x07111F,
    bg_opa = lvgl.OPA(100), border_width = 0, pad_all = 0, align = lvgl.ALIGN.CENTER,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)
root:add_flag(lvgl.FLAG.EVENT_BUBBLE)

local status_label
local function show(text, color)
    if not status_label then return end
    status_label:set { text = text .. "\n" .. table.concat(ring, "\n"), text_color = color or BLUE }
end
status = show

local function make_button(text, x, y, w, color, on_clicked)
    local button = lvgl.Object(root, {
        w = w, h = 56, bg_color = color, bg_opa = lvgl.OPA(100), radius = 14,
        align = { type = lvgl.ALIGN.CENTER, x_ofs = x, y_ofs = y },
    })
    button:clear_flag(lvgl.FLAG.SCROLLABLE)
    button:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    button:add_flag(lvgl.FLAG.CLICKABLE)
    local label = lvgl.Label(button, {
        text = text, text_color = 0xFFFFFF, align = lvgl.ALIGN.CENTER,
        text_font = lvgl.Font("MiSans-Demibold", 20, "normal"),
    })
    button:onClicked(function()
        local ok, message = pcall(on_clicked)
        if not ok then
            log("LUA ERROR " .. tostring(message))
            show("Lua error: " .. tostring(message), RED)
        end
    end)
    return button, label
end

local function guarded(fn)
    return function()
        if fatal then show(fatal, RED) else fn() end
    end
end

local off = fatal and 0x555555
local sel_btn, sel_label
sel_btn, sel_label = make_button("APP: " .. app().key, 0, -200, 310, off or 0x3A4A66, function()
    sel = sel % #APPS + 1
    sel_label:set { text = "APP: " .. app().key .. " (" .. app().kind .. ")" }
    show("Selected " .. app().key .. " [" .. app().kind .. "]", BLUE)
end)
local b_scan    = make_button("SCAN",    -80, -135, 148, off or 0x14508A, guarded(do_scan))
local b_snap    = make_button("SNAP",     80, -135, 148, off or 0x14508A, guarded(do_snap))
local b_install = make_button("INSTALL", -80,  -70, 148, off or 0x1B6B3A, guarded(do_install))
local b_verify  = make_button("VERIFY",   80,  -70, 148, off or 0x1B6B3A, guarded(do_verify))
local b_remove  = make_button("REMOVE",    0,   -5, 310, off or 0x8A4B14, guarded(do_remove))

if fatal then
    for _, b in ipairs({ sel_btn, b_scan, b_snap, b_install, b_verify, b_remove }) do
        b:clear_flag(lvgl.FLAG.CLICKABLE)
    end
end

status_label = lvgl.Label(root, {
    text = fatal or ("Native App Manager\nfw " .. fw .. "\nNothing runs until you press a button.\nLog: " .. LOG_FILE),
    text_color = fatal and RED or BLUE,
    width = 316, height = 230,
    text_font = lvgl.Font("MiSans-Demibold", 16, "normal"),
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 140 },
})

if fatal then log("FATAL " .. fatal) end
