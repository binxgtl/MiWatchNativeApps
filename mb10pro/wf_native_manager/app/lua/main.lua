-- Native App Manager for Xiaomi Smart Band 10 Pro Global 3.201.026
-- (installer pattern from m0tral/MiWatchNativeApps; manager logic added here)
--
-- Nothing runs until a button is pressed. The only command executed when the
-- watchface opens is `getprop ro.build.version`; no native code is loaded.
--   APP      select the app (no command)
--   SCAN     firmware identity, known modules in lsmod, dmesg availability    read-only
--   SNAP     before/after-reboot snapshot diffed against the previous one     read-only (*)
--   VERIFY   the selected app's own syslog lines since this manager loaded it  read-only
--   INSTALL  manifest -> copy -> byte check -> insmod -> lsmod evidence
--   REMOVE   rmmod only for kind=transient modules whose lsmod row equals the
--            row recorded at INSTALL. kind=registering: refused, reboot only.
-- (*) SNAP writes only its own files (/tmp marker, /data/mb10p_snap.*).
-- Read-only actions stay usable when the firmware gate fails, for diagnosis.
-- INSTALL/REMOVE re-read the gate every time and refuse on any doubt.
--
-- Never: package-manager calls, watchface delete/reset, firmware writes,
-- reboot, rm of system files, /data/nobusiness, automatic retries.
-- State lives in /tmp (tmpfs): a reboot clears it, like the loaded modules.

local lvgl = require("lvgl")

-- Shown at open and logged by SCAN, so a reinstalled package can be told apart.
local MGR_BUILD = "r2 2026-10-23 (pm_inspect LDRH fix, calc_dec)"

local EXPECT_FW = "3.201.026"
-- From /etc/build.prop of the GL 3.201.026 image (vela_ap.bin):
--   ro.build.version=3.201.026
--   ro.build.customer_version=CONBINE_LTALM080_T3.201.026_09041709
--   ro.sf.lcd_density=336ro.build.id=CONBINE_LTALM080_3.201.026
-- The last line has no newline before ro.build.id, so ro.build.id is
-- probably not set at run time. Only an exact customer_version mismatch
-- blocks; an empty or unreadable value is UNKNOWN and only warns.
local ID_PROPS = {
    { key = "ro.build.customer_version", short = "cust", blocking = true,
      want = "CONBINE_LTALM080_T3.201.026_09041709" },
    { key = "ro.build.id", short = "id", blocking = false,
      want = "CONBINE_LTALM080_3.201.026" },
}
local DIAG_PROPS = { "ro.sf.lcd_density" }   -- logged by SCAN (shows the glued line)

local LOG_FILE, LOG_MAX = "/data/mb10p_manager.log", 65536    -- rotated to .1
local SNAP_LAST = "/data/mb10p_snap.last"
local SNAP_LOG, SNAP_LOG_MAX = "/data/mb10p_snap.log", 65536   -- rotated to .1
local STATE_FILE = "/tmp/mb10p_mgr.state"     -- key|module|lsmod row|dmesg mark
local LOCK_FILE  = "/tmp/mb10p_mgr.lock"      -- set after an ambiguous result
local PENDING    = "/tmp/mb10p_mgr.pending"   -- journal of a running INSTALL/REMOVE
local MARKER     = "/tmp/mb10p_boot_marker"
local DM_ACC     = "/tmp/mb10p_mgr_dm.acc"    -- our tagged dmesg lines this boot
local DM_PREV    = "/tmp/mb10p_mgr_dm.prev"   -- our tagged lines of the last dump
local T_LSMOD, T_DMESG, T_MISC = "/tmp/mb10p_mgr_lsmod.txt", "/tmp/mb10p_mgr_dmesg.txt", "/tmp/mb10p_mgr_cmd.txt"
local DM_READ_MAX, DM_LINE_MAX, DM_KEEP = 262144, 300, 200
local PKG_MAX = 1048576

-- BEGIN MANIFEST (rewritten by tools/mb10p/gen_manifest.py; size + adler32 of each packaged file)
local MANIFEST = {
    ["mb10p_hello_3.201.026.elf"] = { size = 1388, adler = "9a3983d4" },
    ["mb10p_app_safe_3.201.026.elf"] = { size = 6256, adler = "13a93070" },
    ["mb10p_calc_dec_3.201.026.elf"] = { size = 7836, adler = "ec5115de" },
    ["mb10p_pm_inspect_3.201.026.elf"] = { size = 2968, adler = "ebf55792" },
    ["calc_logo_112.png"] = { size = 19531, adler = "fc37a033" },
}
-- END MANIFEST

-- kind = "transient":   leaves no pointer into its own memory once finished -> rmmod allowed
-- kind = "registering": registers with the package manager -> removal is by reboot only
-- dst: files owned by this manager (other watchfaces use other /data names).
-- conflicts: module names that must not be loaded when installing.
-- expect / fail: checks on the app's own syslog lines (plain text, or a
-- capture compared with `equals` / `notequals`).
-- Every calculator build registers app 0xC1 and logs as [calc_safe]; all of
-- them (and the Calc safe / Calc fix / Calc dec watchfaces) use module name
-- calc_safe, so each loader sees the others. mb10p_app: upstream calculator.
local CALC_CONFLICTS = { "calc_safe", "mb10p_app" }
local CALC_EXPECT = { { plain = "[calc_safe] loaded" }, { plain = "[calc_safe] timer fired" },
                      { cap = "%[calc_safe%] pm install%(.-%) rc=(%-?%d+)", equals = "0" },
                      { plain = "[calc_safe] app_launcher_add rc=" },
                      { plain = "[calc_safe] registered" } }
local CALC_FAIL = { { plain = "[calc_safe] app 0x" },   -- "app 0x.. already registered, skip"
                    { cap = "%[calc_safe%] pm install%(.-%) rc=(%-?%d+)", notequals = "0" } }
local LOGO = { { src = "calc_logo_112.png", dst = "/data/calc_logo_112.png", shared = true } }

local APPS = {
    { key = "hello", label = "Hello", module = "mb10p_hello", kind = "transient",
      elf = "mb10p_hello_3.201.026.elf", dst = "/data/mb10p_mgr_hello.elf",
      conflicts = { "mb10p_hello" }, tag = "[hello_module]",
      expect = { { plain = "[hello_module] loaded" }, { plain = "[hello_module] hello" } } },
    { key = "calc_safe", label = "CalcSafe", module = "calc_safe", kind = "registering",
      elf = "mb10p_app_safe_3.201.026.elf", dst = "/data/mb10p_mgr_calc_safe.elf",
      extra = LOGO, conflicts = CALC_CONFLICTS, tag = "[calc_safe]", expect = CALC_EXPECT, fail = CALC_FAIL },
    -- decimal calculator: the module that passed on the band (f6251c33.., mb10pro/ui_dec)
    { key = "calc_dec", label = "CalcDec", module = "calc_safe", kind = "registering",
      elf = "mb10p_calc_dec_3.201.026.elf", dst = "/data/mb10p_mgr_calc_dec.elf",
      extra = LOGO, conflicts = CALC_CONFLICTS, tag = "[calc_safe]", expect = CALC_EXPECT, fail = CALC_FAIL },
    { key = "pm_inspect", label = "PMInspect", module = "pm_inspect", kind = "transient",
      elf = "mb10p_pm_inspect_3.201.026.elf", dst = "/data/mb10p_mgr_pm_inspect.elf",
      conflicts = { "pm_inspect" }, tag = "[pm_inspect]", done = "[pm_inspect] DONE" },
}

local TEST = MB10P_TEST_EXPORT          -- nil on the band; set only by tools/mb10p/test_manager.lua

---------------------------------------------------------------- text, log, files

local LOG_COLS, VERDICT_COLS, LOG_ROWS = 28, 22, 4   -- MiSans 16/20 px in a 300 px box
local MAX_OUT = 60                      -- screen lines kept per action

local function printable(s)
    return (tostring(s):gsub("[^\32-\126]", "?"))
end

local function wrap(s, cols)            -- split into <= cols character pieces
    local parts = {}
    s = printable(s)
    if s == "" then return { "" } end
    while #s > cols do
        local cut, win = cols, s:sub(1, cols)
        local sp = win:match("^.*() ")              -- last space: break there, drop it
        local us = win:match("^.*()[_./=]")         -- else after a separator, keep it
        if sp and sp > cols / 2 then cut = sp - 1
        elseif us and us > cols / 2 then cut = us end
        parts[#parts + 1] = s:sub(1, cut)
        s = s:sub(cut + 1):gsub("^ ", "")
    end
    parts[#parts + 1] = s
    return parts
end

local function fsize(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local n = f:seek("end") or 0
    f:close()
    return n
end

-- os.remove / os.rename are not proven in the band's Lua sandbox: optional.
local os_remove = type(os.remove) == "function" and os.remove or nil
local os_rename = type(os.rename) == "function" and os.rename or nil

local function spit(path, text, mode)
    local f = io.open(path, mode or "wb")
    if not f then return false end
    local ok = f:write(text)
    f:close()
    return ok ~= nil and ok ~= false
end

-- Keep at most `max` bytes in path plus one rotated copy path.1.
local function rotate(path, max, incoming)
    if fsize(path) + (incoming or 0) <= max then return end
    if os_remove then os_remove(path .. ".1") end
    if not (os_rename and os_rename(path, path .. ".1")) then spit(path, "") end
end

local seq, log_bytes = 0, nil
local function log(line)
    seq = seq + 1
    local text = string.format("%03d %s\n", seq, printable(line):sub(1, 600))
    if not log_bytes then log_bytes = fsize(LOG_FILE) end
    if log_bytes + #text > LOG_MAX then
        rotate(LOG_FILE, 0, 1)
        log_bytes = 0
    end
    if spit(LOG_FILE, text, "a") then log_bytes = log_bytes + #text end
end

local function squash(s) return (tostring(s):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end

-- Returns data, or nil, err, code. An empty file returns "".
local function slurp(path, limit)
    local f, err, code = io.open(path, "rb")
    if not f then return nil, err, code end
    local d, rerr, rcode = f:read(limit or "*a")
    f:close()
    if d == nil and rerr then return nil, rerr, rcode end
    return d or ""
end

-- Normalise os.execute() results (Lua 5.1 numeric and 5.2+ tuple styles).
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

-- Output files are pre-filled with a marker: the shell's `>` truncates the
-- file, so finding the marker afterwards means the command never wrote it.
-- A stale file from an earlier command is never read as this command's output.
local NO_OUT = "\0mb10p:no-output\0"
local function reset_file(file)
    if spit(file, NO_OUT) then return true end
    if os_remove then os_remove(file) end
    return slurp(file, 1) == nil
end

local function capture(cmd, file, limit)
    if not reset_file(file) then return false, nil, nil, "cannot reset " .. file end
    local ok, code = run(cmd .. " > " .. file)
    local text, err = slurp(file, limit)
    if text == NO_OUT then text, err = nil, "no output" end
    return ok, code, text, err
end

-- Value of a property: trimmed first line; nil + reason when it cannot be read.
local function getprop(name)
    local ok, code, text, err = capture("getprop " .. name, T_MISC, 512)
    if not text then return nil, "no output (" .. tostring(err) .. ", code=" .. tostring(code) .. ")" end
    local v = (text:match("^([^\r\n]*)") or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not ok and v == "" then return nil, "getprop code=" .. tostring(code) end
    return v
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

local function is_dir_err(err, code)
    return code == 21 or (type(err) == "string" and err:lower():find("is a directory", 1, true) ~= nil)
end
local function is_missing_err(err, code)
    return code == 2 or (type(err) == "string" and err:lower():find("no such file", 1, true) ~= nil)
end

-- { state = "ok"|"absent"|"dir"|"error", size, adler, cut, err }
local function fingerprint(path, cap)
    local f, err, code = io.open(path, "rb")
    if not f then
        if is_missing_err(err, code) then return { state = "absent" } end
        if is_dir_err(err, code) then return { state = "dir" } end
        return { state = "error", err = "open: " .. tostring(err) .. " (" .. tostring(code) .. ")" }
    end
    local a, b, n, cut = 1, 0, 0, false
    while true do
        local chunk, rerr, rcode = f:read(4096)
        if not chunk then
            if rerr then
                f:close()
                if is_dir_err(rerr, rcode) then return { state = "dir" } end
                return { state = "error", err = "read: " .. tostring(rerr) .. " (" .. tostring(rcode) .. ")" }
            end
            break
        end
        if n + #chunk > cap then chunk = chunk:sub(1, cap - n) cut = true end
        a, b = adler32(chunk, a, b)
        n = n + #chunk
        if cut then break end
    end
    local size = n
    if cut then size = f:seek("end") end
    f:close()
    if not size then return { state = "error", err = "size unknown" } end
    return { state = "ok", size = size, adler = string.format("%04x%04x", b, a), cut = cut }
end

local function fp_str(fp)
    if fp.state ~= "ok" then return fp.state:upper() .. (fp.err and (" " .. fp.err) or "") end
    return fp.size .. ":" .. fp.adler .. (fp.cut and "+" or "")
end

local function files_equal(pa, pb)
    local fa, ea = io.open(pa, "rb")
    if not fa then return false, "open " .. pa .. ": " .. tostring(ea) end
    local fb, eb = io.open(pb, "rb")
    if not fb then fa:close() return false, "open " .. pb .. ": " .. tostring(eb) end
    local same, why, total = true, nil, 0
    while true do
        local ca, ra = fa:read(4096)
        local cb, rb = fb:read(4096)
        if ra or rb then same, why = false, "read error " .. tostring(ra or rb) break end
        if ca ~= cb then same, why = false, "differ near byte " .. total break end
        if not ca then break end
        total = total + #ca
    end
    fa:close() fb:close()
    return same, why
end

---------------------------------------------------------------- screen text

local GREEN, RED, AMBER, BLUE, GREY = 0x8FF0A4, 0xFF9A9A, 0xFFD58A, 0xBFD9FF, 0x9AA4B2
local KIND_COLOR = { PASS = GREEN, OK = GREEN, FAIL = RED, REFUSED = RED, LOCKED = RED,
                     UNKNOWN = AMBER, WARN = AMBER, INCOMPLETE = AMBER, UNCERTAIN = AMBER,
                     ANOMALY = AMBER, INFO = BLUE }

local out, page = {}, 1
local verdict_kind, verdict_msg = "INFO", "ready; press a button"
local render = function() end           -- replaced once the UI exists

local function begin(action)
    out, page = {}, 1
    log("== " .. action)
end

local function say(line)                 -- log + screen (wrapped, paged)
    log(line)
    for _, p in ipairs(wrap(line, LOG_COLS)) do
        if #out < MAX_OUT then out[#out + 1] = p
        elseif #out == MAX_OUT then out[#out + 1] = "(more lines in log)" end
    end
end

-- The verdict area holds two lines; a longer verdict is shortened there and
-- shown in full at the top of the log panel, so nothing is lost on screen.
local function verdict(kind, msg)
    verdict_kind, verdict_msg = kind, msg
    log("VERDICT " .. kind .. ": " .. msg)
    if #wrap(kind .. ": " .. msg, VERDICT_COLS) > 2 then
        local full = wrap("> " .. kind .. ": " .. msg, LOG_COLS)
        for i = #full, 1, -1 do table.insert(out, 1, full[i]) end
        page = 1
    end
    render()
end

---------------------------------------------------------------- state, lock, journal

local function load_state()
    local t = {}
    local d = slurp(STATE_FILE, 8192) or ""
    for l in d:gmatch("[^\n]+") do
        local k, m, row, mark = l:match("^([^|]+)|([^|]+)|([^|]*)|([^|]*)$")
        if k then t[k] = { module = m, row = row, mark = tonumber(mark) } end
    end
    return t
end

local function save_state(t)
    local lines = {}
    for k, v in pairs(t) do
        lines[#lines + 1] = k .. "|" .. v.module .. "|" .. v.row .. "|" .. tostring(v.mark or "NA")
    end
    table.sort(lines)
    return spit(STATE_FILE, table.concat(lines, "\n") .. "\n")
end

local function lock_reason() local d = slurp(LOCK_FILE, 300) return d and d:gsub("%s+$", "") end
local function set_lock(why)
    spit(LOCK_FILE, printable(why) .. "\n")
    log("LOCKED: " .. why)
end

local function journal(action, key, stage)
    if not spit(PENDING, action .. " " .. key .. " at " .. stage .. "\n") then
        return false
    end
    return true
end
local function journal_clear()
    if not (os_remove and os_remove(PENDING)) then spit(PENDING, "") end
end

-- An INSTALL/REMOVE that did not reach its end (Lua error, watchface closed,
-- band froze) leaves PENDING behind: the outcome is unknown -> lock.
local function adopt_pending()
    local p = slurp(PENDING, 300)
    if p and p ~= "" then
        set_lock("interrupted " .. p:gsub("%s+$", ""))
        journal_clear()
        return true
    end
    return false
end

---------------------------------------------------------------- lsmod

local last_rows = nil                   -- rows from the latest lsmod (for the header line)

-- Returns nil, why when lsmod is unusable (fail closed), else rows[name]=row and names.
local function lsmod_rows(tag)
    local ok, code, text, err = capture("lsmod", T_LSMOD, 16384)
    if not text then return nil, "lsmod output unreadable (" .. tostring(err) .. ")" end
    log("LSMOD[" .. tag .. "] raw: " .. squash(text):sub(1, 400))
    if not ok then return nil, "lsmod code=" .. tostring(code) end
    if not text:find("NEXPORTS", 1, true) then return nil, "lsmod header missing" end
    local rows, names, first = {}, {}, true
    for l in text:gmatch("[^\r\n]+") do
        if first then first = false
        else
            local n = l:match("^%s*(%S+)")
            if n then rows[n] = squash(l) names[#names + 1] = n end
        end
    end
    last_rows = rows
    return rows, names
end

---------------------------------------------------------------- dmesg (merged)

-- NuttX `dmesg` may or may not clear the RAM log when read, and the ring
-- wraps. Each read is aligned against the previous one and only new lines
-- carrying one of our tags are appended to DM_ACC (absolute line numbers,
-- "#base N" = lines dropped from the front). A mark taken just before
-- insmod lets VERIFY look only at lines produced after it.

local TAGS, MODS = {}, {}                -- distinct tags; first app of each module (SNAP)
do
    local seen_t, seen_m = {}, {}
    for _, a in ipairs(APPS) do
        if not seen_t[a.tag] then seen_t[a.tag] = true TAGS[#TAGS + 1] = a.tag end
        if not seen_m[a.module] then seen_m[a.module] = true MODS[#MODS + 1] = a end
    end
end

local function ours(line)
    for _, t in ipairs(TAGS) do if line:find(t, 1, true) then return true end end
    return false
end

local function read_lines(path)
    local d = slurp(path, 131072)
    local t = {}
    if not d then return t end
    for l in d:gmatch("[^\n]+") do t[#t + 1] = l end
    return t
end

local function read_acc()
    local t = read_lines(DM_ACC)
    local base = 0
    if t[1] and t[1]:match("^#base %d+$") then
        base = tonumber(t[1]:match("%d+"))
        table.remove(t, 1)
    end
    return base, t
end

-- Returns { total = absolute count of lines, added = n } or nil, why.
local function dmesg_merge()
    local ok, code, text, err = (function()
        if not reset_file(T_DMESG) then return false, nil, nil, "cannot reset " .. T_DMESG end
        local ok2, code2 = run("dmesg > " .. T_DMESG)
        local f, e = io.open(T_DMESG, "rb")
        if not f then return ok2, code2, nil, e end
        local size = f:seek("end") or 0
        f:seek("set", size > DM_READ_MAX and (size - DM_READ_MAX) or 0)
        local d = f:read("*a")
        f:close()
        if d == NO_OUT then return ok2, code2, nil, "no output" end
        return ok2, code2, d, nil
    end)()
    if not ok then return nil, "dmesg code=" .. tostring(code) end
    if not text then return nil, "dmesg output unreadable (" .. tostring(err) .. ")" end
    local cur = {}
    for l in text:gmatch("[^\r\n]+") do
        if ours(l) then cur[#cur + 1] = printable(l):sub(1, DM_LINE_MAX) end
    end
    local prev = read_lines(DM_PREV)
    -- Find the last position p in cur where the tail of the previous dump
    -- ends: cur[p-j] == prev[#prev-j] for every j < min(#prev, p). The line
    -- at p may have grown (syslog calls without "\n" continue a line).
    -- Taking the LAST such p means a coincidence can only hide new lines
    -- (VERIFY then says INCOMPLETE), never resurrect old ones.
    local p_end, grown = 0, nil
    if #prev > 0 then
        local lastp = prev[#prev]
        for p = #cur, 1, -1 do
            local c = cur[p]
            if c == lastp or c:sub(1, #lastp) == lastp then
                local match = true
                for j = 1, math.min(#prev, p) - 1 do
                    if cur[p - j] ~= prev[#prev - j] then match = false break end
                end
                if match then p_end = p break end
            end
        end
    end
    local new = {}
    if p_end > 0 and cur[p_end] ~= prev[#prev] then
        grown = cur[p_end]:sub(#prev[#prev] + 1)
        if grown ~= "" then new[#new + 1] = grown end
    end
    for j = p_end + 1, #cur do new[#new + 1] = cur[j] end
    local overlap = p_end
    local keep = {}
    for j = math.max(1, #cur - DM_KEEP + 1), #cur do keep[#keep + 1] = cur[j] end
    spit(DM_PREV, table.concat(keep, "\n") .. (#keep > 0 and "\n" or ""))
    local base, acc = read_acc()
    for _, l in ipairs(new) do acc[#acc + 1] = l end
    if #acc > DM_KEEP then
        local drop = #acc - DM_KEEP
        local t = {}
        for j = drop + 1, #acc do t[#t + 1] = acc[j] end
        acc, base = t, base + drop
    end
    spit(DM_ACC, "#base " .. base .. "\n" .. table.concat(acc, "\n") .. (#acc > 0 and "\n" or ""))
    log(string.format("DMESG merge: dump=%d ours=%d prev=%d overlap=%d new=%d total=%d",
        #text, #cur, #prev, overlap, #new, base + #acc))
    return { total = base + #acc, added = #new }
end

-- Lines of `tag` with absolute index > mark. nil, why when that window is lost.
local function lines_since(mark, tag)
    local base, acc = read_acc()
    if type(mark) ~= "number" then return nil, "no dmesg baseline at INSTALL" end
    if mark < base then return nil, "dmesg history overflowed since INSTALL" end
    if mark > base + #acc then return nil, "dmesg history lost since INSTALL" end
    local t = {}
    for i = mark - base + 1, #acc do
        if acc[i] and acc[i]:find(tag, 1, true) then t[#t + 1] = acc[i] end
    end
    return t
end

local function check_expect(lines, e)
    for _, l in ipairs(lines) do
        if e.plain then
            if l:find(e.plain, 1, true) then return true end
        else
            for v in l:gmatch(e.cap) do
                if e.equals and v == e.equals then return true end
                if e.notequals and v ~= e.notequals then return true end
            end
        end
    end
    return false
end
local function exp_name(e) return e.plain or (e.cap:gsub("%%", "") .. (e.equals and ("==" .. e.equals) or ("!=" .. e.notequals))) end

---------------------------------------------------------------- firmware gate

local function fw_status(v)
    if v == nil or v == "" then return "UNKNOWN" end
    return v == EXPECT_FW and "OK" or "MISMATCH"
end

local function id_checks()
    local res = {}
    for _, s in ipairs(ID_PROPS) do
        local v, why = getprop(s.key)
        local st, reason
        if v == nil then st, reason = "UNKNOWN", why
        elseif v == "" then st, reason = "UNKNOWN", "not set"
        elseif v == s.want then st, reason = "MATCH", nil
        else st, reason = (s.blocking and "MISMATCH" or "WARN"), "got '" .. v .. "' want '" .. s.want .. "'" end
        log(string.format("ID %s actual='%s' expected='%s' -> %s%s", s.key, tostring(v), s.want, st,
            reason and (" (" .. reason .. ")") or ""))
        res[#res + 1] = { spec = s, value = v, status = st, reason = reason }
    end
    return res
end

local fw_boot, fw_boot_why = nil, nil
local function detect_fw()                 -- the ONLY command run at load time
    fw_boot, fw_boot_why = getprop("ro.build.version")
end

-- Gate for INSTALL / REMOVE. Re-reads every property; strict comparisons only.
local function gate(kind)
    local v, why = getprop("ro.build.version")
    local st = fw_status(v)
    if st ~= "OK" then
        return false, "fw " .. st .. ": '" .. tostring(v) .. "' need " .. EXPECT_FW .. (why and (" (" .. why .. ")") or "")
    end
    for _, r in ipairs(id_checks()) do
        if r.status == "MISMATCH" then return false, r.spec.short .. " MISMATCH: " .. r.reason end
        if r.status ~= "MATCH" then say("warn: " .. r.spec.short .. " " .. r.status .. (r.reason and (" " .. r.reason) or "")) end
    end
    if kind == "install" and type(SCRIPT_PATH) ~= "string" then
        return false, "SCRIPT_PATH missing: packaged files unreachable"
    end
    if adopt_pending() then return false, "previous action was interrupted; reboot" end
    local lk = lock_reason()
    if lk then return false, "LOCKED (" .. lk .. "); reboot the band" end
    return true
end

---------------------------------------------------------------- actions

local sel = 1
local function app() return APPS[sel] end

local function module_mark(a, rows)
    if not rows then return "?" end
    if not rows[a.module] then return "absent" end
    local all = load_state()
    local st = all[a.key]
    if st and st.row == rows[a.module] then return "loaded(ours)" end
    for _, b in ipairs(APPS) do         -- same module name, loaded by this manager as another app
        local o = all[b.key]
        if b ~= a and b.module == a.module and o and o.row == rows[a.module] then return "loaded(as " .. b.key .. ")" end
    end
    return "loaded(?)"
end

local function do_scan()
    begin("SCAN")
    log("MANAGER " .. MGR_BUILD)
    local v, why = getprop("ro.build.version")
    local fst = fw_status(v)
    say("fw: " .. tostring(v ~= nil and (v ~= "" and v or "(empty)") or "?") .. " " .. fst ..
        (fst ~= "OK" and (" want " .. EXPECT_FW) or "") .. (why and (" " .. why) or ""))
    local blocking = (fst ~= "OK") and ("fw " .. fst) or nil
    local warn = nil
    for _, r in ipairs(id_checks()) do
        say(r.spec.short .. ": " .. r.status .. (r.reason and (" - " .. r.reason) or ""))
        if r.value and r.value ~= "" and r.status ~= "MISMATCH" then say("  =" .. r.value) end
        if r.status == "MISMATCH" then blocking = blocking or (r.spec.short .. " MISMATCH") end
        if r.status ~= "MATCH" then warn = warn or (r.spec.short .. " " .. r.status) end
    end
    for _, p in ipairs(DIAG_PROPS) do
        local dv, dwhy = getprop(p)
        log("DIAG " .. p .. "='" .. tostring(dv) .. "'" .. (dwhy and (" " .. dwhy) or ""))
    end
    if type(SCRIPT_PATH) ~= "string" then say("SCRIPT_PATH missing (INSTALL off)") end
    local p = slurp(PENDING, 300)
    if p and p ~= "" then say("interrupted: " .. p:gsub("%s+$", "")) end
    local lk = lock_reason()
    if lk then say("LOCK: " .. lk) end
    local rows, names_or_why = lsmod_rows("scan")
    if not rows then
        say("lsmod: " .. tostring(names_or_why))
        verdict("UNKNOWN", "lsmod unreadable")
        return
    end
    local known = {}
    for _, a in ipairs(APPS) do
        known[a.module] = true
        say(a.key .. ": " .. module_mark(a, rows))
    end
    for _, a in ipairs(APPS) do
        for _, c in ipairs(a.conflicts) do
            if not known[c] and rows[c] then say("conflict for " .. a.key .. ": " .. c .. " loaded") end
        end
    end
    local others = 0
    for _, n in ipairs(names_or_why) do if not known[n] then others = others + 1 end end
    say("other modules: " .. others)
    local dm, dwhy = dmesg_merge()
    say("dmesg: " .. (dm and ("ok, " .. dm.total .. " tagged lines") or ("UNKNOWN (" .. tostring(dwhy) .. ")")))
    if blocking then say("INSTALL/REMOVE blocked") verdict("REFUSED", blocking)
    elseif lk or (p and p ~= "") then verdict("LOCKED", "reboot before INSTALL/REMOVE")
    elseif warn or not dm then verdict("WARN", "fw OK; " .. (warn or "dmesg UNKNOWN"))
    else verdict("OK", "fw " .. EXPECT_FW .. " identity matches") end
end

-- copy one packaged file to dst with full verification; never leaves a
-- half-verified file as "ok"
local function deploy(name, dst, shared)
    local m = MANIFEST[name]
    if type(m) ~= "table" or type(m.size) ~= "number" or m.size <= 0 or type(m.adler) ~= "string" then
        return false, "manifest entry invalid: " .. name
    end
    local src = SCRIPT_PATH .. name
    local s = fingerprint(src, PKG_MAX)
    if s.state ~= "ok" then return false, "packaged " .. name .. ": " .. fp_str(s) end
    if s.cut or s.size ~= m.size or s.adler ~= m.adler then
        return false, string.format("%s corrupt: %s (want %d:%s)", name, fp_str(s), m.size, m.adler)
    end
    if shared then
        local d = fingerprint(dst, PKG_MAX)
        if d.state == "ok" and not d.cut and d.size == m.size and d.adler == m.adler and files_equal(src, dst) then
            say("kept " .. dst .. " (identical)")
            return true
        end
        if d.state ~= "absent" then
            return false, dst .. " exists, differs (" .. fp_str(d) .. "): not overwritten"
        end
    end
    local ok, code = run("cp " .. src .. " " .. dst)
    local d = fingerprint(dst, PKG_MAX)
    log("COPY " .. name .. " -> " .. dst .. " src=" .. fp_str(s) .. " dst=" .. fp_str(d))
    if not ok then return false, "cp failed code=" .. tostring(code) end
    if d.state ~= "ok" then return false, "copy " .. fp_str(d) end
    if d.cut or d.size ~= m.size or d.adler ~= m.adler then return false, "copy differs: " .. fp_str(d) end
    local eq, why = files_equal(src, dst)
    if not eq then return false, "copy not byte-identical: " .. tostring(why) end
    say("copied " .. name .. " (" .. fp_str(d) .. ")")
    return true
end

local function do_install()
    local a = app()
    begin("INSTALL " .. a.key)
    local ok, why = gate("install")
    if not ok then verdict("REFUSED", why) return end
    local rows, rwhy = lsmod_rows("before")
    if not rows then verdict("REFUSED", "lsmod unreadable: " .. tostring(rwhy)) return end
    for _, c in ipairs(a.conflicts) do
        if rows[c] then
            say(c .. " already loaded: " .. rows[c])
            say("no duplicate; reboot to reset")
            verdict("REFUSED", c .. " already loaded")
            return
        end
    end
    local st = load_state()
    if a.kind == "registering" and st[a.key] then
        set_lock(a.key .. " was installed this boot and is no longer listed")
        verdict("ANOMALY", a.key .. " vanished after registering. Reboot.")
        return
    end
    local dm, dwhy = dmesg_merge()                -- baseline before insmod
    if not dm then say("dmesg UNKNOWN (" .. tostring(dwhy) .. "): VERIFY will be UNKNOWN") end
    if not journal("INSTALL", a.key, "copy") then verdict("REFUSED", "cannot write " .. PENDING) return end
    local files = { { a.elf, a.dst, false } }
    for _, x in ipairs(a.extra or {}) do files[#files + 1] = { x.src, x.dst, x.shared } end
    for _, f in ipairs(files) do
        local c_ok, c_why = deploy(f[1], f[2], f[3])
        if not c_ok then
            journal_clear()
            say(c_why)
            verdict("FAIL", "file not verified: no insmod. " .. c_why)
            return
        end
    end
    journal("INSTALL", a.key, "insmod")
    local ins_ok, ins_code = run("insmod " .. a.dst .. " " .. a.module)
    local after, awhy = lsmod_rows("after-insmod")
    local row = after and after[a.module]
    if ins_ok and row then
        st[a.key] = { module = a.module, row = row, mark = dm and dm.total or nil }
        if not save_state(st) then
            set_lock("state not saved after insmod of " .. a.module)
            journal_clear()
            verdict("UNCERTAIN", "loaded, state not saved. Reboot.")
            return
        end
        journal_clear()
        say(a.module .. " listed: " .. row)
        say(a.kind == "registering" and "next: wait 2 s, VERIFY. Remove = reboot." or "next: VERIFY")
        verdict("PASS", "insmod ok + listed")
    elseif ins_ok then
        set_lock("insmod ok but " .. a.module .. " not confirmed (" .. tostring(awhy or "not listed") .. ")")
        journal_clear()
        verdict("UNCERTAIN", "insmod ok, lsmod does not confirm. Reboot.")
    elseif row then
        set_lock("insmod code=" .. tostring(ins_code) .. " yet " .. a.module .. " listed")
        journal_clear()
        verdict("ANOMALY", "insmod code " .. tostring(ins_code) .. " but listed. Reboot.")
    elseif not after then
        set_lock("insmod code=" .. tostring(ins_code) .. ", lsmod unreadable after")
        journal_clear()
        verdict("UNCERTAIN", "insmod code " .. tostring(ins_code) .. ", state unknown. Reboot.")
    else
        journal_clear()
        say("insmod failed code=" .. tostring(ins_code))
        verdict("FAIL", "insmod code=" .. tostring(ins_code) .. ", not listed.")
    end
end

local function do_verify()
    local a = app()
    begin("VERIFY " .. a.key)
    local rows, rwhy = lsmod_rows("verify")
    if not rows then verdict("UNKNOWN", "lsmod unreadable: " .. tostring(rwhy)) return end
    local st = load_state()[a.key]
    local row = rows[a.module]
    say(a.module .. ": " .. module_mark(a, rows))
    local dm, dwhy = dmesg_merge()
    if not dm then
        say("callback/registration state unknown")
        verdict("UNKNOWN", "dmesg n/a")
        say(tostring(dwhy))
        return
    end
    if not st then verdict("UNKNOWN", "not installed by this manager this boot") return end
    if not row then verdict("FAIL", a.module .. " no longer listed") return end
    if st.row ~= row then verdict("UNKNOWN", "lsmod row changed since INSTALL") return end
    local lines, lwhy = lines_since(st.mark, a.tag)
    if not lines then verdict("UNKNOWN", lwhy) return end
    say(#lines .. " " .. a.tag .. " lines since INSTALL")
    for i = math.max(1, #lines - 40), #lines do log("DMESG " .. lines[i]) end
    if a.expect then
        for _, e in ipairs(a.fail or {}) do
            if check_expect(lines, e) then say("fail line: " .. exp_name(e)) verdict("FAIL", "app reported: " .. exp_name(e)) return end
        end
        local miss = {}
        for _, e in ipairs(a.expect) do if not check_expect(lines, e) then miss[#miss + 1] = exp_name(e) end end
        for _, l in ipairs(lines) do
            local rc = l:match("app_launcher_add rc=(%-?%d+)")
            if rc then say("app_launcher_add rc=" .. rc) end
        end
        if #miss == 0 then verdict("PASS", "all expected log lines present")
        else
            for _, m in ipairs(miss) do say("missing: " .. m) end
            verdict("INCOMPLETE", #miss .. " line(s) missing; wait, VERIFY again")
        end
    elseif a.done then
        local last_node, last_page, finished = nil, nil, false
        for _, l in ipairs(lines) do
            if l:find(" NODE ", 1, true) then last_node = l end
            if l:find(" PAGE ", 1, true) then last_page = l end
            if l:find(a.done, 1, true) then finished = true end
        end
        if last_node then
            local fl = last_node:match("flags=0x(%x+)")
            local function nz(k) local v = last_node:match(k .. "=0x(%x+)") return (v and tonumber(v, 16) ~= 0) and "set" or "0" end
            say("flags 0x" .. tostring(fl) .. " rec=" .. ((fl and math.floor(tonumber(fl, 16) / 8) % 2 == 0) and "yes" or "no"))
            say("cb name:" .. nz("cb1c") .. " sig:" .. nz("cb38") .. " pages:" .. nz("pages"))
        else
            say("no NODE line (app not registered?)")
        end
        if last_page then say("page state " .. (last_page:match("state=(%d+)") or "?")) end
        if finished then verdict("PASS", "inspector finished (DONE)")
        else verdict("INCOMPLETE", "inspector running; wait for DONE") end
    end
end

local function do_remove()
    local a = app()
    begin("REMOVE " .. a.key)
    if a.kind == "registering" then
        local st = load_state()[a.key]
        log("REMOVE refused: " .. a.module .. " registers with the package manager; the firmware keeps pointers into the module (callbacks/pages). rmmod would free them.")
        say("registered app: reboot only")
        say("only a reboot removes it")
        verdict("REFUSED", a.label .. " is registered")
        if st then say("installed this boot by this manager") end
        return
    end
    local ok, why = gate("remove")
    if not ok then verdict("REFUSED", why) return end
    local rows, rwhy = lsmod_rows("before-rmmod")
    if not rows then verdict("REFUSED", "lsmod unreadable: " .. tostring(rwhy)) return end
    if not rows[a.module] then verdict("INFO", a.module .. " not loaded: nothing to remove") return end
    local st = load_state()
    local mine = st[a.key]
    if not mine or mine.row ~= rows[a.module] then
        log("REMOVE refused: identity not confirmed (state=" .. tostring(mine and mine.row) .. " now=" .. tostring(rows[a.module]) .. ")")
        verdict("REFUSED", "cannot confirm this manager loaded it")
        return
    end
    if a.done then
        local dm, dwhy = dmesg_merge()
        if not dm then verdict("REFUSED", "dmesg n/a: cannot confirm DONE") say(tostring(dwhy)) return end
        local lines, lwhy = lines_since(mine.mark, a.tag)
        if not lines then verdict("REFUSED", lwhy) return end
        if not check_expect(lines, { plain = a.done }) then
            verdict("REFUSED", a.module .. " not finished (no DONE yet)")
            return
        end
    end
    if not journal("REMOVE", a.key, "rmmod") then verdict("REFUSED", "cannot write " .. PENDING) return end
    local rm_ok, rm_code = run("rmmod " .. a.module)
    local after = lsmod_rows("after-rmmod")
    if rm_ok and after and not after[a.module] then
        st[a.key] = nil
        save_state(st)
        journal_clear()
        verdict("PASS", "rmmod ok + no longer listed")
    elseif after and after[a.module] then
        set_lock("rmmod code=" .. tostring(rm_code) .. ", " .. a.module .. " still listed")
        journal_clear()
        verdict("FAIL", "still listed (code=" .. tostring(rm_code) .. "). Reboot.")
    else
        set_lock("rmmod code=" .. tostring(rm_code) .. ", lsmod unreadable/unclear after")
        journal_clear()
        verdict("UNCERTAIN", "rmmod code=" .. tostring(rm_code) .. ". Reboot.")
    end
end

-- Snapshot keys for "is the system clean after reboot?". Only read.
local SNAP_FILES = {
    "/data/mb10p_mgr_hello.elf", "/data/mb10p_mgr_calc_safe.elf", "/data/mb10p_mgr_calc_dec.elf",
    "/data/mb10p_mgr_pm_inspect.elf", "/data/calc_logo_112.png",
    "/data/mb10p_com.m0tral.calc_safe.elf", "/data/mb10p_com.m0tral.calc_fix.elf",   -- other watchfaces
    "/data/mb10p_com.m0tral.calc_dec.elf", "/data/mb10p_hello_3.201.026.elf",
    "/data/app/launcher/launcher.db", "/data/persist.db", "/data/nobusiness",
}
local SNAP_PROPS = { "persist.record_app_install", "persist.app_func_bitmap",
                     "persist.app_capability", "persist.launcher.guide" }

local function do_snap()
    begin("SNAP")
    local kv, unknown = {}, {}
    local function put(k, v, known)
        kv[#kv + 1] = k .. "=" .. tostring(v)
        if known == false then unknown[#unknown + 1] = k end
    end
    local fresh = slurp(MARKER, 4) == nil
    if fresh and not spit(MARKER, "1\n") then
        put("boot", "UNKNOWN", false)
        fresh = nil
    else
        put("boot", fresh and "NEW" or "same")
    end
    local fv = getprop("ro.build.version")
    put("fw", (fv and fv ~= "") and fv or "UNKNOWN", fv ~= nil and fv ~= "")
    local rows, names = lsmod_rows("snap")
    if rows then
        table.sort(names)
        put("modules", table.concat(names, ","))
        for _, a in ipairs(MODS) do put("mod." .. a.module, rows[a.module] and "loaded" or "absent") end
    else
        put("modules", "UNKNOWN", false)
        for _, a in ipairs(MODS) do put("mod." .. a.module, "UNKNOWN", false) end
    end
    for _, p in ipairs(SNAP_FILES) do
        local fp = fingerprint(p, 131072)
        if fp.state == "error" then put("file." .. p, "UNKNOWN " .. fp_str(fp), false)
        else put("file." .. p, fp_str(fp)) end
    end
    for _, p in ipairs(SNAP_PROPS) do
        local v, why = getprop(p)
        put("prop." .. p, v or ("UNKNOWN " .. tostring(why)), v ~= nil)
    end
    local dm = dmesg_merge()
    if dm then
        local _, acc = read_acc()
        for _, t in ipairs(TAGS) do
            local n = 0
            for _, l in ipairs(acc) do if l:find(t, 1, true) then n = n + 1 end end
            put("dmesg." .. t:gsub("[%[%]]", ""), n)
        end
    else
        put("dmesg", "UNKNOWN", false)
    end
    local lok, _, ltxt = capture("ls -l /data/app/launcher", T_MISC, 800)
    log("LS launcher: " .. (lok and squash(ltxt or "?") or "UNKNOWN"))
    local fok, _, ftxt = capture("free", T_MISC, 400)
    log("FREE: " .. (fok and squash(ftxt or "?") or "UNKNOWN"))

    local now = table.concat(kv, "\n") .. "\n"
    local prev = slurp(SNAP_LAST, 16384)
    local diffs = {}
    if prev then
        local pm = {}
        for l in prev:gmatch("[^\n]+") do local k, v = l:match("^([^=]+)=(.*)$") if k then pm[k] = v end end
        for _, l in ipairs(kv) do
            local k, v = l:match("^([^=]+)=(.*)$")
            if k ~= "boot" and pm[k] ~= v and not v:find("^UNKNOWN") and not tostring(pm[k]):find("^UNKNOWN") then
                diffs[#diffs + 1] = k .. ": " .. tostring(pm[k]) .. " -> " .. v
            end
        end
    end
    rotate(SNAP_LOG, SNAP_LOG_MAX, #now + 20)
    spit(SNAP_LOG, "---- snapshot ----\n" .. now, "a")
    local saved = spit(SNAP_LAST, now)
    say("boot: " .. (fresh == nil and "UNKNOWN (marker not writable)" or (fresh and "NEW since last marker" or "same boot")))
    say("modules: " .. (rows and #names or "UNKNOWN"))
    for _, k in ipairs(unknown) do say("unknown: " .. k) end
    if not prev then say("first snapshot (no diff)")
    elseif #diffs == 0 then say("no change vs previous")
    else
        for _, x in ipairs(diffs) do say(x) log("DIFF " .. x) end
    end
    if not saved then verdict("FAIL", "snapshot not written: " .. SNAP_LAST)
    elseif #unknown > 0 then verdict("INCOMPLETE", #unknown .. " item(s) UNKNOWN; not a clean result")
    else verdict("OK", "snapshot complete, saved") end
end

if TEST then
    TEST.adler32 = adler32
    TEST.fingerprint = fingerprint
    TEST.wrap = wrap
    TEST.cols = { log = LOG_COLS, verdict = VERDICT_COLS, rows = LOG_ROWS }
end

---------------------------------------------------------------- UI (336 x 480)
-- Fixed regions, top to bottom; nothing overlaps whatever the text length:
--   info 24..70 | buttons 76..266 (3 rows x 2, 150 x 58) | verdict 274..330 | log 335..459

detect_fw()            -- log() rotates an oversized log on its first line
adopt_pending()
local fw_ok = fw_status(fw_boot) == "OK"

local W, H = lvgl.HOR_RES(), lvgl.VER_RES()
local rootbase = lvgl.Object(nil, {
    w = W, h = H, bg_color = 0x07111F, bg_opa = lvgl.OPA(100), border_width = 0,
})
rootbase:clear_flag(lvgl.FLAG.SCROLLABLE)
rootbase:add_flag(lvgl.FLAG.EVENT_BUBBLE)
local root = lvgl.Object(rootbase, {
    w = W, h = H, bg_color = 0x07111F, bg_opa = lvgl.OPA(100), border_width = 0, pad_all = 0,
    align = lvgl.ALIGN.CENTER,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)
root:add_flag(lvgl.FLAG.EVENT_BUBBLE)

local FONT16 = lvgl.Font("MiSans-Demibold", 16, "normal")
local FONT20 = lvgl.Font("MiSans-Demibold", 20, "normal")

local info_label = lvgl.Label(root, {
    text = "", text_color = BLUE, width = 300, height = 46, text_font = FONT16,
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = -193 },
})
local verdict_label = lvgl.Label(root, {
    text = "", text_color = BLUE, width = 300, height = 56, text_font = FONT20,
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 62 },
})
local log_panel = lvgl.Object(root, {
    w = 316, h = 124, bg_color = 0x0E1C30, bg_opa = lvgl.OPA(100), radius = 12, border_width = 0,
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 157 },
})
log_panel:clear_flag(lvgl.FLAG.SCROLLABLE)
log_panel:add_flag(lvgl.FLAG.CLICKABLE)
local log_label = lvgl.Label(log_panel, {
    text = "", text_color = GREY, width = 300, height = 116, text_font = FONT16,
    align = lvgl.ALIGN.CENTER,
})

local function pages() return math.max(1, math.ceil(#out / LOG_ROWS)) end

render = function()
    local a = app()
    local mod = module_mark(a, last_rows)
    info_label:set { text = "App: " .. a.key .. " (" .. a.kind .. ")\n" ..
        "Mod: " .. mod .. "  fw: " .. (fw_ok and "OK" or fw_status(fw_boot)) }
    local vl = wrap(verdict_kind .. ": " .. verdict_msg, VERDICT_COLS)
    if #vl > 2 then vl = { vl[1], vl[2]:sub(1, VERDICT_COLS - 2) .. ".." } end
    verdict_label:set { text = table.concat(vl, "\n"), text_color = KIND_COLOR[verdict_kind] or BLUE }
    local np = pages()
    if page > np then page = 1 end
    local shown = {}
    for i = (page - 1) * LOG_ROWS + 1, math.min(#out, page * LOG_ROWS) do shown[#shown + 1] = out[i] end
    if np > 1 then shown[#shown + 1] = string.format("-- %d/%d tap for more --", page, np) end
    log_label:set { text = table.concat(shown, "\n") }
end

local MUTATING = { INSTALL = true, REMOVE = true }
local function make_button(text, x, y, color, fn)
    local button = lvgl.Object(root, {
        w = 150, h = 58, bg_color = color, bg_opa = lvgl.OPA(100), radius = 14, border_width = 0,
        align = { type = lvgl.ALIGN.CENTER, x_ofs = x, y_ofs = y },
    })
    button:clear_flag(lvgl.FLAG.SCROLLABLE)
    button:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    button:add_flag(lvgl.FLAG.CLICKABLE)
    lvgl.Label(button, { text = text, text_color = 0xFFFFFF, align = lvgl.ALIGN.CENTER, text_font = FONT20 })
    button:onClicked(function()
        local ok, message = pcall(fn)
        if not ok then
            log("LUA ERROR in " .. text .. ": " .. tostring(message))
            if MUTATING[text] then
                -- the outcome of a half-run INSTALL/REMOVE is unknown: fail closed, never retry
                set_lock("Lua error during " .. text .. ": " .. tostring(message))
                journal_clear()
            end
            say("Lua error: " .. tostring(message))
            verdict(MUTATING[text] and "LOCKED" or "FAIL", "Lua error in " .. text .. (MUTATING[text] and "; locked, reboot" or ""))
        end
        render()
    end)
    return button
end

local function do_select()
    sel = sel % #APPS + 1
    begin("SELECT " .. app().key)
    say("selected " .. app().key .. " [" .. app().kind .. "]")
    if app().kind == "registering" then say("REMOVE is refused for it; reboot removes it") end
    verdict("INFO", "selected " .. app().label)
end

local DIM = 0x444A55
make_button("APP",      -80, -135, 0x3A4A66, do_select)
make_button("SCAN",      80, -135, 0x14508A, do_scan)
make_button("SNAP",     -80,  -69, 0x14508A, do_snap)
make_button("VERIFY",    80,  -69, 0x14508A, do_verify)
make_button("INSTALL",  -80,   -3, fw_ok and 0x1B6B3A or DIM, do_install)
make_button("REMOVE",    80,   -3, fw_ok and 0x8A4B14 or DIM, do_remove)

log_panel:onClicked(function()
    page = page % pages() + 1
    render()
end)

begin("OPEN")
say("NativeMgr " .. MGR_BUILD)
say("Log: " .. LOG_FILE)
if not fw_ok then
    say("fw '" .. tostring(fw_boot) .. "'" .. (fw_boot_why and (" " .. fw_boot_why) or "") .. " need " .. EXPECT_FW)
    say("SCAN/SNAP/VERIFY still work")
    verdict("REFUSED", "fw " .. fw_status(fw_boot) .. ": INSTALL/REMOVE off")
else
    local lk = lock_reason()
    if lk then say("LOCK: " .. lk) verdict("LOCKED", "reboot before INSTALL/REMOVE")
    else verdict("INFO", "ready; press a button") end
end
if type(SCRIPT_PATH) ~= "string" then say("SCRIPT_PATH missing: INSTALL off") end
render()
