-- Hello ELF load/unload test for Xiaomi Smart Band 10 Pro Global 3.201.026
-- (installer pattern from m0tral/MiWatchNativeApps, rewritten to be observable)
--
-- Scope: loads ONE module (mb10p_hello) and optionally unloads that same module.
-- It never touches the package manager, never deletes/changes any watchface,
-- never writes firmware, and never runs anything at boot. Nothing happens
-- until a button is pressed. Every external command is logged with its real
-- return value to /data/mb10p_hello_test.log and the last lines are shown.
--
-- "insmod returned success" is NOT treated as proof: PASS requires lsmod to
-- show the module afterwards (and to stop showing it after rmmod).

local lvgl = require("lvgl")

local EXPECTED_FW = "3.201.026"
local ELF_NAME    = "mb10p_hello_3.201.026.elf"   -- file shipped next to this script
local MODULE_NAME = "mb10p_hello"
local ELF_SRC     = (SCRIPT_PATH or "") .. ELF_NAME
local ELF_DST     = "/data/" .. ELF_NAME          -- same path for cp, compare and insmod
local LOG_FILE    = "/data/mb10p_hello_test.log"
local TMP_LSMOD   = "/tmp/hello_lsmod.txt"
local TMP_DMESG   = "/tmp/hello_dmesg.txt"
local TMP_FW      = "/tmp/hello_fw.txt"

---------------------------------------------------------------- logging

local ring, seq = {}, 0

local function log(line)
    seq = seq + 1
    local text = string.format("%03d %s", seq, line)
    ring[#ring + 1] = text
    if #ring > 9 then table.remove(ring, 1) end
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(text, "\n")
        f:close()
    end
end

---------------------------------------------------------------- helpers

-- Normalise os.execute() results: Lua 5.1 style (number) and 5.3+ style
-- (true|nil, "exit"|"signal", code). Returns ok, code, raw-description.
local function run(cmd)
    local a, b, c = os.execute(cmd)
    local ok, code
    if type(a) == "number" then
        ok, code = (a == 0), a
    elseif a == true then
        ok, code = true, (type(c) == "number" and c or 0)
    else
        ok, code = false, (type(c) == "number" and c or a)
    end
    log(string.format("CMD %s -> ok=%s code=%s (raw=%s,%s,%s)", cmd, tostring(ok),
        tostring(code), tostring(a), tostring(b), tostring(c)))
    return ok, code
end

local function slurp(path, limit)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read(limit or "*a")
    f:close()
    return data
end

local function squash(s) return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end

-- Returns nil when lsmod cannot be read reliably (fail closed), otherwise
-- { present = bool, line = normalised lsmod row or nil }.
local function lsmod_state(tag)
    local ok, code = run("lsmod > " .. TMP_LSMOD)
    local text = slurp(TMP_LSMOD, 16384)
    if not text then
        log("LSMOD[" .. tag .. "] cannot read output file")
        return nil
    end
    log("LSMOD[" .. tag .. "] raw: " .. squash(text):sub(1, 400))
    if not ok then
        log("LSMOD[" .. tag .. "] command failed, treating as unreadable")
        return nil
    end
    -- lsmod prints a header with NEXPORTS; without it we cannot interpret the output.
    if not text:find("NEXPORTS", 1, true) then
        log("LSMOD[" .. tag .. "] header (NEXPORTS) missing, treating as unreadable")
        return nil
    end
    for l in text:gmatch("[^\r\n]+") do
        local n = l:match("^%s*(%S+)")
        if n == MODULE_NAME then
            return { present = true, line = squash(l) }
        end
    end
    return { present = false }
end

-- Best-effort syslog evidence (optional; never required for PASS).
local function syslog_hits(tag)
    local ok = run("dmesg > " .. TMP_DMESG)
    local text = ok and slurp(TMP_DMESG, 65536) or nil
    if not text then
        log("SYSLOG[" .. tag .. "] dmesg not available")
        return
    end
    local n = 0
    for l in text:gmatch("[^\r\n]*%[hello_module%][^\r\n]*") do
        n = n + 1
        log("SYSLOG[" .. tag .. "] " .. squash(l):sub(1, 120))
    end
    if n == 0 then log("SYSLOG[" .. tag .. "] no [hello_module] line seen") end
end

---------------------------------------------------------------- state

local function detect_fw()
    os.execute("getprop ro.build.version > " .. TMP_FW)
    local raw = slurp(TMP_FW, 256) or ""
    return (raw:match("^%s*([%d._]+)") or "")
end

local fw = detect_fw()
local fatal = nil
if fw ~= EXPECTED_FW then
    fatal = "unsupported firmware: '" .. fw .. "' (need " .. EXPECTED_FW .. ")"
elseif not SCRIPT_PATH then
    fatal = "SCRIPT_PATH missing"
end

local loaded_by_us = false   -- set only after a verified LOAD in this run
local our_line     = nil     -- lsmod row recorded right after our verified LOAD
local locked       = false   -- set after any ambiguous result: no more LOAD attempts
local status                 -- label, assigned below

local function show(headline, color)
    if not status then return end
    local text = headline .. "\n" .. table.concat(ring, "\n")
    status:set { text = text, text_color = color or 0xBFD9FF }
end

local GREEN, RED, AMBER = 0x8FF0A4, 0xFF9A9A, 0xFFD58A

---------------------------------------------------------------- steps

local function step_check()
    log("== CHECK fw=" .. fw)
    local size_ok = slurp(ELF_SRC, 16) ~= nil
    log("ELF src " .. ELF_SRC .. " readable=" .. tostring(size_ok))
    local st = lsmod_state("check")
    if not st then
        show("CHECK: lsmod unreadable.\nNo load allowed. See log.", RED)
    elseif st.present then
        show("CHECK: " .. MODULE_NAME .. " ALREADY LOADED.\nLOAD refused; reboot to clear.", AMBER)
    elseif not size_ok then
        show("CHECK: ELF file missing in package.", RED)
    else
        show("CHECK OK: module absent, lsmod readable.", GREEN)
    end
end

local function step_load()
    log("== LOAD")
    if locked then
        show("LOCKED after earlier anomaly.\nReboot the band before retrying.", AMBER)
        return
    end
    if loaded_by_us then
        show("Already loaded by this test.\nUse UNLOAD.", AMBER)
        return
    end
    local before = lsmod_state("before")
    if not before then
        show("LOAD refused: lsmod unreadable.", RED)
        return
    end
    if before.present then
        locked = true
        show("LOAD refused: " .. MODULE_NAME .. " already listed.\nNot ours to remove; reboot.", AMBER)
        return
    end

    local src = slurp(ELF_SRC)
    if not src or #src < 64 or src:sub(1, 4) ~= "\127ELF" then
        log("ELF src missing or not ELF (size=" .. tostring(src and #src) .. ")")
        show("LOAD FAIL: packaged ELF missing/invalid.", RED)
        return
    end

    local cp_ok = run("cp " .. ELF_SRC .. " " .. ELF_DST)
    local dst = slurp(ELF_DST)
    log(string.format("COPY size src=%d dst=%s identical=%s", #src,
        tostring(dst and #dst), tostring(dst == src)))
    if not cp_ok or dst ~= src then
        show("LOAD FAIL: copy not verified.\nNo insmod run.", RED)
        return
    end

    local ins_ok, ins_code = run("insmod " .. ELF_DST .. " " .. MODULE_NAME)
    local after = lsmod_state("after-insmod")
    syslog_hits("after-insmod")

    if ins_ok and after and after.present then
        loaded_by_us, our_line = true, after.line
        log("LOAD PASS row: " .. our_line)
        show("LOAD PASS (insmod ok + listed).", GREEN)
    elseif ins_ok then
        locked = true
        log("LOAD UNCERTAIN insmod ok but module not confirmed in lsmod")
        show("UNCERTAIN: insmod ok, lsmod "
            .. (after and "does not list it" or "unreadable")
            .. ".\nNo auto action. Reboot.", AMBER)
    elseif after and after.present then
        locked = true
        log("LOAD ANOMALY insmod failed code=" .. tostring(ins_code) .. " but module listed")
        show("ANOMALY: insmod failed ("..tostring(ins_code)..") yet module listed.\nDo not retry. Reboot.", AMBER)
    else
        log("LOAD FAIL insmod code=" .. tostring(ins_code))
        show("LOAD FAIL: insmod code=" .. tostring(ins_code) .. ", not listed.", RED)
    end
end

local function step_unload()
    log("== UNLOAD")
    if not loaded_by_us or not our_line then
        show("UNLOAD refused: cannot confirm the\nmodule is the one this test loaded.", AMBER)
        return
    end
    local now = lsmod_state("before-rmmod")
    if not now then
        show("UNLOAD refused: lsmod unreadable.", RED)
        return
    end
    if not now.present then
        loaded_by_us, our_line = false, nil
        show("Module no longer listed (nothing to remove).", AMBER)
        return
    end
    if now.line ~= our_line then
        log("UNLOAD identity mismatch: now='" .. now.line .. "' ours='" .. our_line .. "'")
        show("UNLOAD refused: lsmod row differs from\nthe one recorded at LOAD.", RED)
        return
    end
    local rm_ok, rm_code = run("rmmod " .. MODULE_NAME)
    local after = lsmod_state("after-rmmod")
    syslog_hits("after-rmmod")
    if rm_ok and after and not after.present then
        loaded_by_us, our_line = false, nil
        log("UNLOAD PASS")
        show("UNLOAD PASS (rmmod ok + not listed).", GREEN)
    elseif after and after.present then
        locked = true
        log("UNLOAD FAIL rmmod code=" .. tostring(rm_code) .. " module still listed")
        show("UNLOAD FAIL: still listed (code=" .. tostring(rm_code) .. ").\nReboot.", RED)
    else
        locked = true
        log("UNLOAD UNCERTAIN rmmod code=" .. tostring(rm_code))
        show("UNCERTAIN: rmmod code=" .. tostring(rm_code) .. ", lsmod "
            .. (after and "not listing" or "unreadable") .. ".", AMBER)
    end
end

---------------------------------------------------------------- UI

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

local function make_button(text, y, color, on_clicked)
    local button = lvgl.Object(root, {
        w = 300, h = 60, bg_color = color, bg_opa = lvgl.OPA(100), radius = 14,
        align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = y },
    })
    button:clear_flag(lvgl.FLAG.SCROLLABLE)
    button:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    button:add_flag(lvgl.FLAG.CLICKABLE)
    lvgl.Label(button, {
        text = text, text_color = 0xFFFFFF, align = lvgl.ALIGN.CENTER,
        text_font = lvgl.Font("MiSans-Demibold", 24, "normal"),
    })
    button:onClicked(function()
        local ok, message = pcall(on_clicked)
        if not ok then
            log("LUA ERROR " .. tostring(message))
            show("Lua error: " .. tostring(message), RED)
        end
    end)
    return button
end

local btn_check  = make_button("1  CHECK",  -190, fatal and 0x555555 or 0x14508A, function()
    if fatal then show(fatal, RED) else step_check() end end)
local btn_load   = make_button("2  LOAD",   -120, fatal and 0x555555 or 0x1B6B3A, function()
    if fatal then show(fatal, RED) else step_load() end end)
local btn_unload = make_button("3  UNLOAD",  -50, fatal and 0x555555 or 0x8A4B14, function()
    if fatal then show(fatal, RED) else step_unload() end end)

if fatal then
    btn_check:clear_flag(lvgl.FLAG.CLICKABLE)
    btn_load:clear_flag(lvgl.FLAG.CLICKABLE)
    btn_unload:clear_flag(lvgl.FLAG.CLICKABLE)
end

status = lvgl.Label(root, {
    text = fatal or ("Hello test, fw " .. fw .. "\nPress 1 CHECK first.\nLog: " .. LOG_FILE),
    text_color = fatal and RED or 0xBFD9FF,
    width = 310, height = 280,
    text_font = lvgl.Font("MiSans-Demibold", 16, "normal"),
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 120 },
})

if fatal then log("FATAL " .. fatal) end
