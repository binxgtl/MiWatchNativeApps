-- Offline logic test for mb10pro/wf_native_manager/app/lua/main.lua
-- Mock shell + mock filesystem + mock LVGL. This exercises DECISION LOGIC
-- only; it is NOT a hardware test and says nothing about how the real
-- band's nsh, dmesg or LVGL behave.
-- usage: lua5.4 test_manager.lua <wf_native_manager/app/lua dir>

local DIR = assert(arg[1], "need the app/lua directory"):gsub("/$", "")
local function readfile(p) local f = assert(io.open(p, "rb")) local d = f:read("*a") f:close() return d end
local MAIN = readfile(DIR .. "/main.lua")
local PKGNAMES = { "mb10p_hello_3.201.026.elf", "mb10p_app_safe_3.201.026.elf",
                   "mb10p_pm_inspect_3.201.026.elf", "calc_logo_112.png" }
local PKG = {}
for _, n in ipairs(PKGNAMES) do PKG["/pkg/" .. n] = readfile(DIR .. "/" .. n) end

local SCREEN_W, SCREEN_H = 336, 480
local ALLOWED = { getprop = true, lsmod = true, dmesg = true, cp = true, insmod = true, rmmod = true, ls = true, free = true }
local READONLY = { getprop = true, lsmod = true, dmesg = true, ls = true, free = true }
local results, fails = {}, 0
local real_exec, real_open, real_remove, real_rename = os.execute, io.open, os.remove, os.rename

local function check(name, cond, detail)
    results[#results + 1] = (cond and "PASS " or "FAIL ") .. name .. ((not cond and detail) and ("  [" .. tostring(detail) .. "]") or "")
    if not cond then fails = fails + 1 end
end

---------------------------------------------------------------- mock world

local function new_world(opt)
    opt = opt or {}
    local W = { fs = {}, dirs = { ["/data/app"] = true, ["/data/app/launcher"] = true }, noread = {}, nowrite = {},
                mods = {}, order = {}, kbuf = "", cmds = {}, writes = {}, opt = opt, t = 0 }
    for k, v in pairs(PKG) do W.fs[k] = v end
    W.fs["/data/app/launcher/launcher.db"] = string.rep("L", 5000)
    W.fs["/data/persist.db"] = string.rep("P", 3000)
    function W.reboot()
        for k in pairs(W.fs) do if k:sub(1, 5) == "/tmp/" then W.fs[k] = nil end end
        W.mods, W.order, W.kbuf = {}, {}, ""
    end
    function W.syslog(msg)                    -- raw append, like the RAM log
        W.t = W.t + 1
        local pre = opt.timestamps and string.format("[%8.3f] ", W.t / 10) or ""
        W.kbuf = W.kbuf .. pre .. msg
        if opt.ring then                       -- keep only the last `ring` bytes, cut at a line start
            while #W.kbuf > opt.ring do
                local nl = W.kbuf:find("\n", 1, true)
                if not nl then break end
                W.kbuf = W.kbuf:sub(nl + 1)
            end
        end
    end
    function W.noise(n) for i = 1, n do W.syslog("[system] tick " .. i .. " xxxxxxxxxxxxxxxx\n") end end
    local function row(n) return n .. " 0x2c0a" .. string.format("%04x", #n * 17 + (W.loads or 0)) .. " 0x2c0b0000 0 0 0" end
    local function result(ok, code)
        if opt.numeric then return ok and 0 or code end
        if ok then return true, "exit", 0 end
        return nil, "exit", code
    end
    local function out_to(cmd, text)
        local p = cmd:match(">%s*(%S+)")
        if p then W.fs[p] = text W.writes[#W.writes + 1] = "cmd>" .. p end
    end
    local function app_log(n, phase)
        if n == "calc_safe" then
            if phase == "load" then
                W.syslog("[calc_safe] loaded\n")
                W.syslog("[calc_safe] lv_timer_create -> 0x20400000\n")
                if not opt.calc_no_timer then
                    W.syslog("[calc_safe] timer fired\n")
                    if opt.calc_already then
                        W.syslog("[calc_safe] app 0xc1 already registered, skip\n")
                    else
                        W.syslog("[calc_safe] pm install(com.m0tral.calculator) rc=" .. (opt.calc_rc or "0") .. "\n")
                        W.syslog("[calc_safe] app_launcher_add rc=0\n")
                        W.syslog("[calc_safe] registered; remove by reboot, NOT rmmod\n")
                    end
                end
            end
        elseif n == "mb10p_hello" then
            if opt.hello_silent_after and (W.hello_loads or 0) >= 1 and phase == "load" then return end
            if phase == "load" then
                W.hello_loads = (W.hello_loads or 0) + 1
                W.syslog("[hello_module] loaded")     -- no "\n": continues the line, as in mb10p_hello.c
                W.syslog("[hello_module] hello")
            else W.syslog("[hello_module] unloaded") end
        elseif n == "pm_inspect" and phase == "load" then
            W.syslog("[pm_inspect] BEGIN id=0xc1 period_ms=1000 ticks=90\n")
            W.syslog("[pm_inspect] NODE seq=1 node=0x20401230 flags=0x0000 name=0x20401280 icon=0x204012a0 cb1c=0x2c0a1b01 cb20=0x00000000 cb24=0x00000000 cb28=0x00000000 cb38=0x00000000 pages=0x204012c0 unin=0x00000000\n")
            W.syslog("[pm_inspect] PAGE seq=1 i=0 page=0x2c0a2000 pid=0 state=3 layer=1 kind=0 adestroy=0x0 root=0x00000000 prev=0x20401300 next=0x20401300\n")
        end
    end
    W.finish_inspector = function() W.syslog("[pm_inspect] DONE seq=90\n") end
    os.execute = function(cmd)
        local prog = cmd:match("^(%S+)")
        W.cmds[#W.cmds + 1] = cmd
        if not ALLOWED[prog] then error("FORBIDDEN COMMAND: " .. cmd) end
        if opt.throw_on and cmd:match(opt.throw_on) then error("injected failure in " .. cmd) end
        if prog == "getprop" then
            local key = cmd:match("^getprop (%S+)")
            if opt.getprop_fail then return result(false, 127) end
            if opt.getprop_nofile and opt.getprop_nofile[key] then return result(true) end
            local props = { ["ro.build.version"] = opt.fw or "3.201.026",
                            ["ro.build.customer_version"] = opt.cust or "CONBINE_LTALM080_T3.201.026_09041709",
                            ["ro.build.id"] = opt.build_id or "",
                            ["ro.sf.lcd_density"] = "336ro.build.id=CONBINE_LTALM080_3.201.026",
                            ["persist.record_app_install"] = opt.prop or "" }
            out_to(cmd, (props[key] or "") .. "\n")
            return result(true)
        elseif prog == "lsmod" then
            if opt.lsmod_fail or (opt.lsmod_fail_after and W.insmods and W.insmods >= opt.lsmod_fail_after) then
                return result(false, 1)
            end
            local t = opt.lsmod_noheader and "garbage\n" or "NAME INIT UNINIT ARG NEXPORTS NSYMBOLS\n"
            for _, n in ipairs(W.order) do if W.mods[n] then t = t .. W.mods[n] .. "\n" end end
            out_to(cmd, t)
            return result(true)
        elseif prog == "dmesg" then
            if opt.no_dmesg then return result(false, 127) end
            out_to(cmd, W.kbuf)
            if opt.destructive then W.kbuf = "" end
            return result(true)
        elseif prog == "cp" then
            local s, d = cmd:match("^cp (%S+) (%S+)$")
            W.copies = (W.copies or 0) + 1
            if opt.cp_fail then return result(false, 1) end
            if opt.cp_nowrite then return result(true) end
            if W.dirs[d] then return result(false, 1) end
            W.fs[d] = opt.cp_corrupt and W.fs[s]:sub(1, 100) or W.fs[s]
            W.writes[#W.writes + 1] = "cp>" .. d
            if opt.dst_unreadable then W.noread[d] = true end
            return result(true)
        elseif prog == "insmod" then
            local p, n = cmd:match("^insmod (%S+) (%S+)$")
            assert(W.fs[p], "insmod of a path that was not deployed: " .. tostring(p))
            W.insmods = (W.insmods or 0) + 1
            W.pending_at_insmod = W.fs["/tmp/mb10p_mgr.pending"]
            if W.mods[n] then return result(false, 17) end            -- EEXIST
            if opt.insmod_fail then return result(false, 255) end
            W.loads = (W.loads or 0) + 1
            if not opt.insmod_silent then
                W.mods[n] = row(n) .. (opt.row_salt or "")
                W.order[#W.order + 1] = n
            end
            app_log(n, "load")
            return result(true)
        elseif prog == "rmmod" then
            local n = cmd:match("^rmmod (%S+)$")
            if opt.rmmod_stuck then return result(true) end
            if W.mods[n] then W.mods[n] = nil app_log(n, "unload") return result(true) end
            return result(false, 2)
        elseif prog == "ls" then out_to(cmd, "-rw-r--r-- 1 0 0 4096 launcher.db\n") return result(true)
        elseif prog == "free" then out_to(cmd, "total used free\n 100 50 50\n") return result(true)
        end
    end
    os.remove = function(p)
        if W.fs[p] then W.fs[p] = nil W.writes[#W.writes + 1] = "rm>" .. p return true end
        return nil, p .. ": No such file or directory", 2
    end
    os.rename = function(a, b)
        if not W.fs[a] then return nil, "No such file or directory", 2 end
        W.fs[b], W.fs[a] = W.fs[a], nil
        W.writes[#W.writes + 1] = "mv>" .. b
        return true
    end
    io.open = function(path, mode)
        mode = mode or "r"
        if mode:find("[wa]") then
            W.writes[#W.writes + 1] = "open>" .. path
            if W.nowrite[path] or W.dirs[path] then return nil, path .. ": Permission denied", 13 end
            if mode:find("w") then W.fs[path] = "" end
            W.fs[path] = W.fs[path] or ""
            return { write = function(self, ...) W.fs[path] = W.fs[path] .. table.concat({ ... }) return self end,
                     close = function() return true end }
        end
        if W.dirs[path] then
            return { read = function() return nil, "Is a directory", 21 end, seek = function() return nil, "Is a directory", 21 end,
                     close = function() return true end }
        end
        if W.noread[path] and W.fs[path] then return nil, path .. ": Permission denied", 13 end
        if W.fs[path] == nil then return nil, path .. ": No such file or directory", 2 end
        local pos = 0
        return {
            read = function(_, n)
                local d = W.fs[path] or ""
                if n == "*a" or n == "a" or n == nil then local r = d:sub(pos + 1) pos = #d return r end
                if pos >= #d then return nil end
                local r = d:sub(pos + 1, pos + n) pos = pos + #r return r
            end,
            seek = function(_, whence, off)
                local d = W.fs[path] or ""
                if whence == "end" then pos = #d + (off or 0) return pos end
                pos = (off or 0) return pos
            end,
            close = function() return true end,
        }
    end
    return W
end

---------------------------------------------------------------- mock LVGL

local function boot(W, env_over)
    W.ui = { objects = {}, buttons = {}, labels = {} }
    local function mk(kind, parent, props)
        local o = { kind = kind, parent = parent, props = props or {}, text = props and props.text }
        W.ui.objects[#W.ui.objects + 1] = o
        o.set = function(self, t) for k, v in pairs(t) do self.props[k] = v end if t.text then self.text = t.text end end
        o.clear_flag = function() end
        o.add_flag = function() end
        o.onClicked = function(self, fn) self.click = fn end
        return o
    end
    local lvgl = {
        FLAG = setmetatable({}, { __index = function() return 0 end }),
        ALIGN = setmetatable({ CENTER = "CENTER" }, { __index = function(_, k) return k end }),
        HOR_RES = function() return SCREEN_W end, VER_RES = function() return SCREEN_H end,
        OPA = function(x) return x end, Font = function(_, size) return size end,
        Object = function(parent, props) return mk("obj", parent, props) end,
        Label = function(parent, props)
            local o = mk("label", parent, props)
            W.ui.labels[#W.ui.labels + 1] = o
            if parent and parent.kind == "obj" and props and props.text and props.text ~= "" and not parent.name then parent.name = props.text end
            return o
        end,
    }
    local env = setmetatable({ require = function() return lvgl end, SCRIPT_PATH = "/pkg/",
                               MB10P_TEST_EXPORT = W.export }, { __index = _G })
    if env_over then for k, v in pairs(env_over) do env[k] = v end end
    if env_over and env_over.NO_SCRIPT_PATH then env.SCRIPT_PATH = nil end
    if env_over and env_over.NO_OS_FILE_OPS then          -- sandbox without os.remove / os.rename
        env.os = { execute = os.execute, time = os.time, clock = os.clock, date = os.date, getenv = os.getenv }
    end
    W.cmds = {}
    local chunk = assert(load(MAIN, "main.lua", "t", env))
    chunk()
    for _, o in ipairs(W.ui.objects) do
        if o.click and o.name then W.ui.buttons[o.name] = o end
    end
    for _, o in ipairs(W.ui.objects) do
        if o.click and not o.name then W.ui.panel = o end
    end
    -- the three top-level labels, in creation order: info, verdict, log (inside the panel)
    local top = {}
    for _, l in ipairs(W.ui.labels) do if l.props.width then top[#top + 1] = l end end
    W.info, W.verdict, W.log = top[1], top[2], top[3]
end

local function vtext(W) return W.verdict.text or "" end
local function press(W, name, times)
    for _ = 1, times or 1 do
        assert(W.ui.buttons[name], "no button " .. name).click()
        W.presses = (W.presses or 0) + 1
        -- every screen state must fit its region
        local function lines(s) local t = {} for l in ((s or "") .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end return t end
        local v, lg, inf = lines(W.verdict.text), lines(W.log.text), lines(W.info.text)
        local bad
        if #v > 2 then bad = "verdict " .. #v .. " lines" end
        for _, l in ipairs(v) do if #l > 22 then bad = "verdict line too long: " .. l end end
        if #lg > 5 then bad = "log " .. #lg .. " lines" end
        for _, l in ipairs(lg) do if #l > 28 then bad = "log line too long: " .. l end end
        if #inf > 2 then bad = "info " .. #inf .. " lines" end
        for _, l in ipairs(inf) do if #l > 34 then bad = "info line too long: " .. l end end
        if bad then W.textfail = (W.textfail or "") .. bad .. "; " end
    end
    return vtext(W):gsub("\n", " ")
end
local function count(W, prog)
    local n = 0
    for _, c in ipairs(W.cmds) do if c:match("^" .. prog .. " ") or c == prog or c:match("^" .. prog .. "$") then n = n + 1 end end
    return n
end
local function mutations(W) return count(W, "cp") + count(W, "insmod") + count(W, "rmmod") end
local function pick(W, key)
    for _ = 1, 3 do
        if (W.info.text or ""):find("App: " .. key .. " ", 1, true) then return end
        press(W, "APP")
    end
    assert((W.info.text or ""):find("App: " .. key .. " ", 1, true), "cannot select " .. key)
end
local function screen(W) return (W.verdict.text or "") .. "\n" .. (W.log.text or "") end
local function all_pages(W)                  -- tap the log panel through every page
    local seen, first = {}, W.log.text
    for _ = 1, 20 do
        seen[#seen + 1] = W.log.text
        W.ui.panel.click()
        if W.log.text == first then break end
    end
    return table.concat(seen, "\n")
end
-- Is `needle` on screen (any page)? Wrapped lines are re-joined and spaces
-- ignored, because the screen wraps long lines at 32 columns.
local function has(W, needle)
    local t = all_pages(W):gsub("%-%- %d+/%d+ tap for more %-%-", "")
    t = t:gsub("[%s]", "")
    return t:find((needle:gsub("[%s]", "")), 1, true) ~= nil
end

local function with_world(opt, fn, env)
    local W = new_world(opt)
    W.export = {}
    local ok, err = pcall(function() boot(W, env) fn(W) end)
    os.execute, io.open, os.remove, os.rename = real_exec, real_open, real_remove, real_rename
    if not ok then check("scenario crashed: " .. tostring(err), false) end
    if W.textfail then check("screen text fits its region (" .. (opt and next(opt) and "opts" or "default") .. ")", false, W.textfail) end
    return W
end

---------------------------------------------------------------- scenarios

do  -- adler32 known vector ("Wikipedia" -> 0x11E60398)
    with_world(nil, function(W)
        local a, b = W.export.adler32("Wikipedia")
        check("adler32 test vector", string.format("%04x%04x", b, a) == "11e60398")
    end)
end

with_world(nil, function(W)
    check("load-time commands: getprop ro.build.version only", #W.cmds == 1 and W.cmds[1]:match("^getprop ro.build.version"), table.concat(W.cmds, ";"))
    check("nothing loaded at open", next(W.mods) == nil and count(W, "insmod") == 0)
    check("info shows selected app and module state", (W.info.text or ""):find("App: hello", 1, true) and (W.info.text or ""):find("Mod: ?", 1, true), W.info.text)
end)

-- UI geometry: six buttons, regions inside 336x480, no overlaps, touch size
with_world(nil, function(W)
    local need = { "APP", "SCAN", "SNAP", "INSTALL", "VERIFY", "REMOVE" }
    local have = 0
    for _, n in ipairs(need) do if W.ui.buttons[n] then have = have + 1 end end
    check("six buttons APP/SCAN/SNAP/INSTALL/VERIFY/REMOVE", have == 6)
    local rects = {}
    local function rect(o)
        local p = o.props
        local w, h = p.w or p.width, p.h or p.height
        local al = type(p.align) == "table" and p.align or { x_ofs = 0, y_ofs = 0 }
        local cx, cy = SCREEN_W / 2 + (al.x_ofs or 0), SCREEN_H / 2 + (al.y_ofs or 0)
        return { x0 = cx - w / 2, y0 = cy - h / 2, x1 = cx + w / 2, y1 = cy + h / 2, w = w, h = h }
    end
    for n, b in pairs(W.ui.buttons) do rects[#rects + 1] = { name = n, r = rect(b) } end
    rects[#rects + 1] = { name = "info", r = rect(W.info) }
    rects[#rects + 1] = { name = "verdict", r = rect(W.verdict) }
    rects[#rects + 1] = { name = "logpanel", r = rect(W.ui.panel) }
    local inside, overlap, small = true, nil, nil
    for _, a in ipairs(rects) do
        local r = a.r
        if r.x0 < 8 or r.x1 > SCREEN_W - 8 or r.y0 < 20 or r.y1 > SCREEN_H - 20 then inside = false end
        if W.ui.buttons[a.name] and (r.w < 48 or r.h < 48) then small = a.name end
        for _, b in ipairs(rects) do
            if a ~= b then
                local s = b.r
                if r.x0 < s.x1 and s.x0 < r.x1 and r.y0 < s.y1 and s.y0 < r.y1 then overlap = a.name .. "/" .. b.name end
            end
        end
    end
    check("all regions inside 336x480 with corner margins", inside)
    check("no region overlaps another (log cannot cover buttons)", overlap == nil, overlap)
    check("buttons are >= 48 px in both directions", small == nil, small)
end)

-- firmware gate
with_world({ fw = "3.101.043" }, function(W)
    press(W, "INSTALL") press(W, "REMOVE")
    check("wrong firmware: INSTALL/REMOVE run no cp/insmod/rmmod", mutations(W) == 0, table.concat(W.cmds, ";"))
    check("wrong firmware: verdict says REFUSED with the reason", vtext(W):find("REFUSED", 1, true) ~= nil, vtext(W))
    local m = press(W, "SCAN")
    local ro = true
    for _, c in ipairs(W.cmds) do if not READONLY[c:match("^(%S+)")] then ro = false end end
    check("wrong firmware: SCAN still works, read-only commands only", count(W, "lsmod") >= 1 and ro and m:find("REFUSED", 1, true), m)
    check("wrong firmware: SCAN shows actual and expected version", has(W, "fw: 3.101.043 MISMATCH want 3.201.026"), all_pages(W))
    press(W, "SNAP")
    check("wrong firmware: SNAP still works", W.fs["/data/mb10p_snap.last"] ~= nil and mutations(W) == 0)
end)
for _, bad in ipairs({ "3.201.026 release-keys", "3.201.0261", "3.201.026-test", "V3.201.026", "3.201.02" }) do
    with_world({ fw = bad }, function(W)
        pick(W, "hello")
        press(W, "INSTALL")
        check("strict version compare refuses '" .. bad .. "'", count(W, "insmod") == 0 and count(W, "cp") == 0)
    end)
end
with_world({ getprop_fail = true }, function(W)
    local m = press(W, "INSTALL")
    check("firmware unreadable: INSTALL refused as UNKNOWN", mutations(W) == 0 and m:find("UNKNOWN", 1, true), m)
    m = press(W, "SCAN")
    check("firmware unreadable: SCAN runs and reports UNKNOWN", count(W, "lsmod") == 1 and has(W, "fw: ? UNKNOWN"), all_pages(W))
end)

-- build identity
with_world({ cust = "CONBINE_LTALM078_T3.201.026_01010000" }, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("customer_version MISMATCH refuses install", count(W, "insmod") == 0 and m:find("cust MISMATCH", 1, true), m)
    press(W, "SCAN")
    local m2 = press(W, "INSTALL")
    check("long verdict shortened but shown in full on the panel", has(W, "> REFUSED: cust MISMATCH: got 'CONBINE_LTALM078_T3.201.026_01010000' want"), all_pages(W))
    press(W, "SCAN")
    check("SCAN shows cust actual, expected and reason", has(W, "cust: MISMATCH - got 'CONBINE_LTALM078_T3.201.026_01010000' want 'CONBINE_LTALM080_T3.201.026_09041709'"), all_pages(W))
end)
with_world({ build_id = "OTHER_BUILD" }, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("ro.build.id different: WARN only, install proceeds", m:find("PASS", 1, true) and count(W, "insmod") == 1, m)
end)
with_world({ build_id = "", cust = "" }, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("build ids empty: UNKNOWN warns, does not block a correct version", m:find("PASS", 1, true), m)
    press(W, "SCAN")
    check("SCAN shows id UNKNOWN (not set)", has(W, "id: UNKNOWN - not set"), all_pages(W))
end)
with_world({ build_id = "CONBINE_LTALM080_3.201.026" }, function(W)
    press(W, "SCAN")
    check("SCAN all identity MATCH -> OK verdict", vtext(W):find("^OK") ~= nil, vtext(W))
end)
with_world({ getprop_nofile = { ["ro.build.id"] = true } }, function(W)
    pick(W, "hello")
    press(W, "SCAN")
    local log = W.fs["/data/mb10p_manager.log"] or ""
    check("stale tmp output is never reused as a property value", log:find("ID ro.build.id actual='nil'", 1, true) ~= nil, log:match("ID ro.build.id[^\n]*"))
end)

-- hello lifecycle
with_world(nil, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("hello install PASS", m:find("PASS", 1, true) and count(W, "insmod") == 1, m)
    check("hello deployed to manager-owned path", W.fs["/data/mb10p_mgr_hello.elf"] == PKG["/pkg/mb10p_hello_3.201.026.elf"])
    check("info shows module loaded(ours)", (W.info.text or ""):find("loaded(ours)", 1, true) ~= nil, W.info.text)
    check("journal written before insmod", (W.pending_at_insmod or ""):find("INSTALL hello at insmod", 1, true) ~= nil, W.pending_at_insmod)
    check("journal cleared after a definite result", (W.fs["/tmp/mb10p_mgr.pending"] or "") == "")
    m = press(W, "INSTALL")
    check("duplicate install refused (no second insmod)", count(W, "insmod") == 1 and m:find("already loaded", 1, true), m)
    m = press(W, "VERIFY")
    check("hello verify PASS (lines without newline)", m:find("PASS", 1, true), m)
    m = press(W, "REMOVE")
    check("hello remove PASS (rmmod ok + not listed)", m:find("PASS", 1, true) and count(W, "rmmod") == 1, m)
    m = press(W, "SCAN")
    check("scan after remove: hello absent", has(W, "hello: absent"), all_pages(W))
    m = press(W, "INSTALL")
    check("hello reinstall after remove", m:find("PASS", 1, true) and count(W, "insmod") == 2, m)
    m = press(W, "VERIFY")
    check("verify after reinstall PASS", m:find("PASS", 1, true), m)
end)

-- stale lines from an earlier load must not make VERIFY pass
for _, mode in ipairs({ { name = "non-destructive" }, { name = "destructive", destructive = true },
                        { name = "ring", ring = 900 }, { name = "timestamps", timestamps = true } }) do
    local o = { hello_silent_after = true, destructive = mode.destructive, ring = mode.ring, timestamps = mode.timestamps }
    with_world(o, function(W)
        pick(W, "hello")
        press(W, "INSTALL")
        W.noise(5)
        local m1 = press(W, "VERIFY")
        press(W, "SCAN")
        press(W, "REMOVE")
        W.noise(5)
        press(W, "INSTALL")                 -- second load prints nothing in this scenario
        local m2 = press(W, "VERIFY")
        check("dmesg " .. mode.name .. ": first VERIFY PASS", m1:find("PASS", 1, true), m1)
        check("dmesg " .. mode.name .. ": old lines never make the second VERIFY pass", not m2:find("PASS", 1, true), m2)
    end)
end
with_world({ destructive = true }, function(W)
    pick(W, "calc_safe")
    press(W, "INSTALL")
    press(W, "SCAN")                        -- consumes the RAM log
    local m = press(W, "VERIFY")
    check("destructive dmesg: lines read by SCAN still count for VERIFY", m:find("PASS", 1, true), m)
end)
with_world({ ring = 600 }, function(W)
    pick(W, "pm_inspect")
    press(W, "INSTALL")
    for i = 1, 30 do W.syslog("[pm_inspect] NODE seq=" .. (i + 1) .. " flags=0x0000\n") end
    W.noise(3)
    local m = press(W, "VERIFY")
    W.noise(3)
    local m2 = press(W, "VERIFY")
    local acc = W.fs["/tmp/mb10p_mgr_dm.acc"] or ""
    local seen, dup, n = {}, nil, 0
    for l in acc:gmatch("[^\n]+") do
        if not l:match("^#base") then n = n + 1 if seen[l] then dup = l end seen[l] = true end
    end
    check("wrapping ring: no duplicated lines in the history", dup == nil and n > 0, dup or ("lines=" .. n))
    check("wrapping ring: VERIFY still reports running", m:find("INCOMPLETE", 1, true) and m2:find("INCOMPLETE", 1, true), m .. " / " .. m2)
end)
with_world(nil, function(W)
    pick(W, "pm_inspect")
    press(W, "INSTALL")
    for i = 1, 260 do W.syslog("[pm_inspect] NODE seq=" .. (i + 1) .. " flags=0x0000\n") end
    W.finish_inspector()
    local m = press(W, "VERIFY")
    check("history overflow since INSTALL -> UNKNOWN, not PASS", m:find("UNKNOWN", 1, true), m)
    m = press(W, "REMOVE")
    check("history overflow: inspector not removed", count(W, "rmmod") == 0, m)
end)

-- calc_safe lifecycle
with_world(nil, function(W)
    pick(W, "calc_safe")
    local m = press(W, "INSTALL")
    check("calc_safe install PASS + logo copied", m:find("PASS", 1, true) and W.fs["/data/calc_logo_112.png"] == PKG["/pkg/calc_logo_112.png"], m)
    m = press(W, "VERIFY")
    check("calc_safe verify PASS (registration lines)", m:find("PASS", 1, true), m)
    m = press(W, "REMOVE")
    check("calc_safe remove REFUSED, never rmmod", m:find("REFUSED", 1, true) and count(W, "rmmod") == 0, m)
    m = press(W, "INSTALL")
    check("calc_safe second install refused (duplicate)", count(W, "insmod") == 1, m)
    W.reboot()
    press(W, "SCAN")
    check("scan after reboot: calc_safe absent", has(W, "calc_safe: absent"), all_pages(W))
    m = press(W, "INSTALL")
    check("calc_safe installs again after reboot", m:find("PASS", 1, true) and count(W, "insmod") == 2, m)
end)
with_world({ lsmod_fail = true }, function(W)
    pick(W, "calc_safe")
    local m = press(W, "REMOVE")
    check("calc_safe REMOVE refused even when lsmod fails; no rmmod", count(W, "rmmod") == 0 and m:find("REFUSED", 1, true), m)
end)
with_world({ calc_rc = "-5" }, function(W)
    pick(W, "calc_safe")
    press(W, "INSTALL")
    local m = press(W, "VERIFY")
    check("calc_safe pm install rc!=0 -> VERIFY FAIL (no rc=0 confusion)", m:find("FAIL", 1, true), m)
end)
with_world({ calc_already = true }, function(W)
    pick(W, "calc_safe")
    press(W, "INSTALL")
    local m = press(W, "VERIFY")
    check("calc_safe 'already registered, skip' -> VERIFY FAIL", m:find("FAIL", 1, true), m)
end)
with_world({ calc_no_timer = true }, function(W)
    pick(W, "calc_safe")
    press(W, "INSTALL")
    local m = press(W, "VERIFY")
    check("calc_safe before timer fired -> INCOMPLETE, not PASS", m:find("INCOMPLETE", 1, true), m)
end)
with_world(nil, function(W)
    W.mods["mb10p_app"] = "mb10p_app 0x2c0a9999 0x2c0b0000 0 0 0"
    W.order = { "mb10p_app" }
    pick(W, "calc_safe")
    local m = press(W, "INSTALL")
    check("upstream calculator loaded -> calc_safe install refused (conflict)", count(W, "insmod") == 0 and count(W, "cp") == 0, m)
end)
with_world(nil, function(W)
    pick(W, "calc_safe")
    press(W, "INSTALL")
    W.mods["calc_safe"] = nil                -- someone removed it behind our back
    local m = press(W, "INSTALL")
    check("registered app vanished -> ANOMALY + lock, no reinstall", count(W, "insmod") == 1 and m:find("ANOMALY", 1, true), m)
    pick(W, "hello")
    press(W, "INSTALL")
    check("...and the lock blocks other installs until reboot", count(W, "insmod") == 1)
end)

-- shared logo is never overwritten
with_world(nil, function(W)
    W.fs["/data/calc_logo_112.png"] = PKG["/pkg/calc_logo_112.png"]
    pick(W, "calc_safe")
    local m = press(W, "INSTALL")
    check("identical logo kept (one cp only, for the ELF)", m:find("PASS", 1, true) and count(W, "cp") == 1, m)
end)
with_world(nil, function(W)
    W.fs["/data/calc_logo_112.png"] = "someone else's file"
    pick(W, "calc_safe")
    local m = press(W, "INSTALL")
    check("different logo not overwritten, no insmod", W.fs["/data/calc_logo_112.png"] == "someone else's file" and count(W, "insmod") == 0 and m:find("FAIL", 1, true), m)
    check("...and no pending journal left behind", W.fs["/tmp/mb10p_mgr.pending"] == nil)
end)

-- lsmod problems
with_world({ lsmod_fail = true }, function(W)
    local m = press(W, "INSTALL") press(W, "REMOVE")
    check("lsmod failure: no cp/insmod/rmmod", mutations(W) == 0, m)
end)
with_world({ lsmod_noheader = true }, function(W)
    press(W, "INSTALL")
    check("lsmod without header: fail closed", mutations(W) == 0)
end)

-- package / copy problems
with_world(nil, function(W)
    W.fs["/pkg/mb10p_hello_3.201.026.elf"] = W.fs["/pkg/mb10p_hello_3.201.026.elf"]:sub(1, 600)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("corrupt packaged ELF rejected before cp/insmod", count(W, "cp") == 0 and count(W, "insmod") == 0 and m:find("FAIL", 1, true), m)
end)
with_world(nil, function(W)
    W.fs["/pkg/mb10p_hello_3.201.026.elf"] = nil
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("missing packaged ELF: FAIL, no cp", count(W, "cp") == 0 and m:find("FAIL", 1, true), m)
end)
with_world(nil, function(W)
    W.noread["/pkg/mb10p_hello_3.201.026.elf"] = true
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("unreadable packaged ELF: FAIL, no cp", count(W, "cp") == 0 and m:find("FAIL", 1, true), m)
end)
with_world(nil, function(W)
    W.fs["/pkg/mb10p_hello_3.201.026.elf"] = ""
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("empty packaged ELF: FAIL, no cp", count(W, "cp") == 0 and m:find("FAIL", 1, true), m)
end)
with_world({ cp_corrupt = true }, function(W)
    pick(W, "hello")
    press(W, "INSTALL")
    check("bad copy rejected before insmod", count(W, "insmod") == 0 and count(W, "cp") == 1)
end)
with_world({ cp_fail = true }, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("cp failure (code) -> FAIL, no insmod", count(W, "insmod") == 0 and m:find("FAIL", 1, true), m)
end)
with_world({ cp_nowrite = true }, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("cp says ok but nothing written -> FAIL, no insmod", count(W, "insmod") == 0 and m:find("FAIL", 1, true), m)
end)
with_world({ dst_unreadable = true }, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("destination unreadable after cp -> FAIL, no insmod", count(W, "insmod") == 0 and m:find("FAIL", 1, true), m)
end)
with_world(nil, function(W)
    W.dirs["/data/mb10p_mgr_hello.elf"] = true
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("destination is a directory -> FAIL, no insmod", count(W, "insmod") == 0 and m:find("FAIL", 1, true), m)
end)
do  -- manifest problems (edit the MANIFEST block of a copy of main.lua)
    local saved = MAIN
    for _, case in ipairs({ { "size mismatch", '{ size = 1388,', '{ size = 1389,' },
                            { "missing entry", '    ["mb10p_hello_3.201.026.elf"] = { size = 1388, adler = "9a3983d4" },\n', '' },
                            { "zero size", '{ size = 1388, adler = "9a3983d4" }', '{ size = 0, adler = "00000001" }', empty = true } }) do
        local a, b = case[2], case[3]
        local i = MAIN:find(a, 1, true)
        assert(i, "manifest fixture not found: " .. case[1])
        MAIN = MAIN:sub(1, i - 1) .. b .. MAIN:sub(i + #a)
        with_world(nil, function(W)
            if case.empty then W.fs["/pkg/mb10p_hello_3.201.026.elf"] = "" end   -- file and manifest agree on 0 bytes
            pick(W, "hello")
            local m = press(W, "INSTALL")
            check("manifest " .. case[1] .. " -> FAIL, no cp/insmod", count(W, "cp") == 0 and count(W, "insmod") == 0 and m:find("FAIL", 1, true), m)
        end)
        MAIN = saved
    end
end
with_world(nil, function(W)
    local m = press(W, "INSTALL")
    check("missing SCRIPT_PATH: INSTALL refused, nothing copied", mutations(W) == 0 and m:find("SCRIPT_PATH", 1, true), m)
    m = press(W, "SCAN")
    check("missing SCRIPT_PATH: SCAN still works", count(W, "lsmod") == 1, m)
    press(W, "SNAP")
    check("missing SCRIPT_PATH: SNAP still works", W.fs["/data/mb10p_snap.last"] ~= nil)
end, { NO_SCRIPT_PATH = true })

-- insmod outcomes
with_world({ insmod_silent = true }, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("insmod ok but not listed -> UNCERTAIN", m:find("UNCERTAIN", 1, true), m)
    press(W, "INSTALL") press(W, "REMOVE")
    check("lock blocks further install/remove", count(W, "insmod") == 1 and count(W, "rmmod") == 0)
    W.reboot()
    local m2 = press(W, "INSTALL")
    check("lock cleared by reboot (tmpfs)", count(W, "insmod") == 2, m2)
end)
with_world({ insmod_fail = true }, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("insmod failure reports real code, no rmmod", m:find("code=255", 1, true) and count(W, "rmmod") == 0, m)
    local log = W.fs["/data/mb10p_manager.log"] or ""
    check("real insmod code in the log", log:find("CMD insmod /data/mb10p_mgr_hello.elf mb10p_hello -> ok=false code=255", 1, true) ~= nil)
end)
with_world({ lsmod_fail_after = 1 }, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("insmod ok + lsmod unreadable after -> UNCERTAIN + lock", m:find("UNCERTAIN", 1, true) and W.fs["/tmp/mb10p_mgr.lock"] ~= nil, m)
end)
with_world({ lsmod_fail_after = 1, insmod_fail = true }, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("insmod failed + lsmod unreadable after -> UNCERTAIN + lock (not FAIL)", m:find("UNCERTAIN", 1, true) and W.fs["/tmp/mb10p_mgr.lock"] ~= nil, m)
end)

-- pre-existing / changed modules
with_world(nil, function(W)
    W.mods["mb10p_hello"] = "mb10p_hello 0x2c0a1111 0x2c0b0000 0 0 0"
    W.order = { "mb10p_hello" }
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("pre-existing module: install refused", count(W, "insmod") == 0, m)
    m = press(W, "REMOVE")
    check("pre-existing module: remove refused (identity unknown), no blind rmmod", count(W, "rmmod") == 0 and m:find("REFUSED", 1, true), m)
end)
with_world(nil, function(W)
    pick(W, "hello")
    press(W, "INSTALL")
    W.mods["mb10p_hello"] = "mb10p_hello 0xDEADBEEF 0 0 0 0"
    local m = press(W, "REMOVE")
    check("changed lsmod row: remove refused", count(W, "rmmod") == 0, m)
end)
with_world(nil, function(W)
    pick(W, "hello")
    press(W, "INSTALL")
    W.mods["mb10p_hello"] = "mb10p_hello 0xDEADBEEF 0 0 0 0"
    local m = press(W, "VERIFY")
    check("VERIFY with a changed lsmod row -> UNKNOWN, not PASS", m:find("UNKNOWN", 1, true), m)
    W.mods["mb10p_hello"] = nil
    m = press(W, "VERIFY")
    check("VERIFY after the module vanished -> FAIL", m:find("FAIL", 1, true), m)
end)
with_world(nil, function(W)
    pick(W, "hello")
    local m = press(W, "VERIFY")
    check("VERIFY of a module this manager did not load -> UNKNOWN", m:find("UNKNOWN", 1, true), m)
end)
with_world({ rmmod_stuck = true }, function(W)
    pick(W, "hello")
    press(W, "INSTALL")
    local m = press(W, "REMOVE")
    check("rmmod ok but still listed -> FAIL + lock", m:find("FAIL", 1, true) and count(W, "rmmod") == 1, m)
    press(W, "REMOVE")
    check("lock blocks second rmmod", count(W, "rmmod") == 1)
end)

-- inspector
with_world(nil, function(W)
    pick(W, "pm_inspect")
    local m = press(W, "INSTALL")
    check("pm_inspect install PASS", m:find("PASS", 1, true), m)
    m = press(W, "REMOVE")
    check("pm_inspect remove refused before DONE", count(W, "rmmod") == 0, m)
    m = press(W, "VERIFY")
    check("verify: inspector still running", m:find("INCOMPLETE", 1, true), m)
    check("verify shows recoverable flag + callback state", has(W, "rec=yes") and has(W, "name:set") and has(W, "page state 3"), all_pages(W))
    W.finish_inspector()
    m = press(W, "VERIFY")
    check("verify: finished after DONE", m:find("PASS", 1, true), m)
    m = press(W, "REMOVE")
    check("pm_inspect remove allowed after DONE", m:find("PASS", 1, true) and count(W, "rmmod") == 1, m)
end)
with_world({ no_dmesg = true }, function(W)
    pick(W, "pm_inspect")
    press(W, "INSTALL")
    local m = press(W, "VERIFY")
    check("dmesg n/a: verify says UNKNOWN", m:find("UNKNOWN", 1, true), m)
    m = press(W, "REMOVE")
    check("dmesg n/a: inspector never removed blind", count(W, "rmmod") == 0, m)
    press(W, "SCAN")
    check("dmesg n/a: SCAN reports dmesg UNKNOWN", has(W, "dmesg: UNKNOWN"), all_pages(W))
end)

-- interruption / Lua errors: fail closed, never retried
with_world({ throw_on = "^insmod" }, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("Lua error during INSTALL -> LOCKED", m:find("LOCKED", 1, true) and W.fs["/tmp/mb10p_mgr.lock"] ~= nil, m)
    W.opt.throw_on = nil
    local n = #W.cmds
    boot(W)                                    -- close + reopen the watchface (same boot)
    check("reopen after Lua error: no command but getprop, no retry", #W.cmds == 1 and count(W, "insmod") == 0)
    local m2 = press(W, "INSTALL")
    check("reopen: INSTALL refused while locked", count(W, "insmod") == 0 and m2:find("REFUSED", 1, true), m2)
    W.reboot()
    boot(W)
    local m3 = press(W, "INSTALL")
    check("after reboot the lock is gone and INSTALL works", m3:find("PASS", 1, true), m3)
end)
with_world(nil, function(W)
    W.fs["/tmp/mb10p_mgr.pending"] = "INSTALL hello at insmod\n"
    boot(W)                                    -- watchface reopened after being killed mid-INSTALL
    check("interrupted INSTALL found at open -> locked, only getprop ran", #W.cmds == 1 and W.fs["/tmp/mb10p_mgr.lock"] ~= nil)
    check("open screen says LOCKED", vtext(W):find("LOCKED", 1, true) ~= nil, vtext(W))
    pick(W, "hello")
    press(W, "INSTALL")
    check("interrupted INSTALL is not retried", count(W, "insmod") == 0)
end)
with_world(nil, function(W)
    pick(W, "hello")
    press(W, "INSTALL")
    boot(W)                                    -- reopen: state survives in /tmp
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("reopen: duplicate still refused", count(W, "insmod") == 0 and m:find("already loaded", 1, true), m)
    m = press(W, "REMOVE")
    check("reopen: REMOVE uses the identity saved before", m:find("PASS", 1, true) and count(W, "rmmod") == 1, m)
end)
with_world(nil, function(W)
    pick(W, "hello")
    press(W, "INSTALL")
    W.reboot()
    boot(W)
    pick(W, "hello")
    local m = press(W, "REMOVE")
    check("after reboot: state gone, nothing to remove, no rmmod", count(W, "rmmod") == 0 and m:find("not loaded", 1, true), m)
end)

-- SNAP
with_world(nil, function(W)
    pick(W, "calc_safe")
    press(W, "SNAP")
    check("first snapshot saved, complete", W.fs["/data/mb10p_snap.last"] and vtext(W):find("^OK") and has(W, "first snapshot"), screen(W))
    press(W, "INSTALL")
    press(W, "SNAP")
    check("snapshot after install shows module diff", has(W, "mod.calc_safe: absent -> loaded"), all_pages(W))
    W.reboot()
    boot(W)
    press(W, "SNAP")
    check("post-reboot snapshot: NEW boot, module gone", has(W, "NEW since last marker") and has(W, "mod.calc_safe: loaded -> absent"), all_pages(W))
    check("snapshot recorded the manager file fingerprint", (W.fs["/data/mb10p_snap.last"] or ""):find("file./data/mb10p_mgr_calc_safe.elf=6256:", 1, true) ~= nil)
    check("snapshot records /data/nobusiness as absent", (W.fs["/data/mb10p_snap.last"] or ""):find("file./data/nobusiness=ABSENT", 1, true) ~= nil)
end)
with_world({ lsmod_fail = true }, function(W)
    local m = press(W, "SNAP")
    check("SNAP with lsmod unreadable -> INCOMPLETE, never OK", m:find("INCOMPLETE", 1, true), m)
end)
with_world({ no_dmesg = true }, function(W)
    local m = press(W, "SNAP")
    check("SNAP with dmesg n/a -> INCOMPLETE", m:find("INCOMPLETE", 1, true), m)
end)
with_world(nil, function(W)
    W.fs["/data/persist.db"] = "x"
    W.noread["/data/persist.db"] = true
    W.dirs["/data/nobusiness"] = true
    local m = press(W, "SNAP")
    local s = W.fs["/data/mb10p_snap.last"] or ""
    check("SNAP: unreadable file -> UNKNOWN + INCOMPLETE", s:find("file./data/persist.db=UNKNOWN", 1, true) and m:find("INCOMPLETE", 1, true), s)
    check("SNAP: a directory is reported as DIR, not as a file", s:find("file./data/nobusiness=DIR", 1, true) ~= nil, s)
end)
with_world(nil, function(W)
    W.nowrite["/tmp/mb10p_boot_marker"] = true
    local m = press(W, "SNAP")
    check("SNAP: marker not writable -> boot UNKNOWN, INCOMPLETE", (W.fs["/data/mb10p_snap.last"] or ""):find("boot=UNKNOWN", 1, true) and m:find("INCOMPLETE", 1, true), m)
end)
with_world(nil, function(W)
    press(W, "SNAP")
    W.opt.lsmod_fail = true
    press(W, "SNAP")
    check("SNAP diff never reports a change for UNKNOWN values", not has(W, "-> UNKNOWN") and has(W, "no change vs previous"), all_pages(W))
end)

-- logs stay bounded
with_world(nil, function(W)
    W.fs["/data/mb10p_manager.log"] = string.rep("x", 100000)
    W.fs["/data/mb10p_snap.log"] = string.rep("y", 70000)
    boot(W)
    check("oversized log rotated at open", #(W.fs["/data/mb10p_manager.log"] or "") < 65536 and W.fs["/data/mb10p_manager.log.1"] ~= nil)
    for _ = 1, 40 do press(W, "SCAN") press(W, "SNAP") end
    check("log stays <= 64 KiB after many actions", #(W.fs["/data/mb10p_manager.log"] or "") <= 65536, #(W.fs["/data/mb10p_manager.log"] or ""))
    check("snapshot log stays <= 64 KiB", #(W.fs["/data/mb10p_snap.log"] or "") <= 65536, #(W.fs["/data/mb10p_snap.log"] or ""))
end)

-- paging
with_world({ fw = "3.101.043" }, function(W)
    press(W, "SCAN")
    local first = W.log.text
    W.ui.panel.click()
    check("log panel pages on tap", W.log.text ~= first and (first or ""):find("tap for more", 1, true) ~= nil, first)
end)

-- writes and commands stay in their lanes (across a busy session)
with_world(nil, function(W)
    pick(W, "hello")
    press(W, "SCAN") press(W, "SNAP") press(W, "INSTALL") press(W, "VERIFY") press(W, "REMOVE")
    pick(W, "calc_safe")
    press(W, "INSTALL") press(W, "VERIFY") press(W, "REMOVE") press(W, "SNAP")
    W.reboot() boot(W) press(W, "SNAP")
    local okw, bad = true, nil
    local allowed = { ["/data/mb10p_manager.log"] = true, ["/data/mb10p_manager.log.1"] = true,
                      ["/data/mb10p_snap.last"] = true, ["/data/mb10p_snap.log"] = true, ["/data/mb10p_snap.log.1"] = true,
                      ["/data/mb10p_mgr_hello.elf"] = true, ["/data/mb10p_mgr_calc_safe.elf"] = true,
                      ["/data/mb10p_mgr_pm_inspect.elf"] = true, ["/data/calc_logo_112.png"] = true }
    for _, w in ipairs(W.writes) do
        local p = w:match(">(.*)$")
        if not (allowed[p] or p:match("^/tmp/mb10p_")) then okw, bad = false, w end
    end
    check("writes only to manager files (/tmp/mb10p_*, own /data files)", okw, bad)
    check("/data/nobusiness never created", W.fs["/data/nobusiness"] == nil)
    check("launcher.db and persist.db untouched", W.fs["/data/app/launcher/launcher.db"] == string.rep("L", 5000) and W.fs["/data/persist.db"] == string.rep("P", 3000))
    check("other watchfaces' /data files never written", W.fs["/data/mb10p_com.m0tral.calc_safe.elf"] == nil and W.fs["/data/mb10p_hello_3.201.026.elf"] == nil)
end)

-- Lua sandbox without os.remove / os.rename
with_world({ getprop_nofile = { ["ro.build.id"] = true } }, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("no os.remove/rename: install still PASS", m:find("PASS", 1, true), m)
    check("no os.remove/rename: missing output still not reused", (W.fs["/data/mb10p_manager.log"] or ""):find("ID ro.build.id actual='nil'", 1, true) ~= nil)
    m = press(W, "VERIFY")
    check("no os.remove/rename: verify PASS", m:find("PASS", 1, true), m)
    m = press(W, "REMOVE")
    check("no os.remove/rename: remove PASS, journal emptied", m:find("PASS", 1, true) and (W.fs["/tmp/mb10p_mgr.pending"] or "") == "", m)
    W.fs["/data/mb10p_manager.log"] = string.rep("z", 70000)
    boot(W, { NO_OS_FILE_OPS = true })
    press(W, "SCAN")
    check("no os.remove/rename: log truncated instead of rotated", #(W.fs["/data/mb10p_manager.log"] or "") < 65536)
end, { NO_OS_FILE_OPS = true })

with_world({ numeric = true }, function(W)
    pick(W, "hello")
    local m = press(W, "INSTALL")
    check("Lua 5.1-style numeric os.execute", m:find("PASS", 1, true), m)
end)

for _, r in ipairs(results) do print(r) end
print(fails == 0 and ("ALL " .. #results .. " CHECKS OK") or ("FAILURES: " .. fails .. " of " .. #results))
os.exit(fails == 0 and 0 or 1)
