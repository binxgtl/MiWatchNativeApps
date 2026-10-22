-- Offline logic test for mb10pro/wf_native_manager/app/lua/main.lua
-- Mock shell + mock LVGL. This exercises DECISION LOGIC only; it is NOT a
-- hardware test and says nothing about how the real band's nsh behaves.
-- usage: lua5.4 test_manager.lua <wf_native_manager/app/lua dir>

local DIR = assert(arg[1], "need the app/lua directory"):gsub("/$", "")
local function readfile(p) local f = assert(io.open(p, "rb")) local d = f:read("*a") f:close() return d end
local MAIN = readfile(DIR .. "/main.lua")
local PKG = {}
for _, n in ipairs({ "mb10p_hello_3.201.026.elf", "mb10p_app_safe_3.201.026.elf",
                     "mb10p_pm_inspect_3.201.026.elf", "calc_logo_112.png" }) do
    PKG["/pkg/" .. n] = readfile(DIR .. "/" .. n)
end

local ALLOWED = { getprop = true, lsmod = true, dmesg = true, cp = true, insmod = true, rmmod = true, ls = true, free = true }
local results, fails = {}, 0
local real_exec, real_open = os.execute, io.open

local function new_world(opt)
    opt = opt or {}
    local W = { fs = {}, mods = {}, dmesg = {}, cmds = {}, opt = opt, buttons = {}, label = nil }
    for k, v in pairs(PKG) do W.fs[k] = v end
    function W.reboot()
        for k in pairs(W.fs) do if k:sub(1, 5) == "/tmp/" then W.fs[k] = nil end end
        W.mods, W.dmesg = {}, {}
    end
    local function row(n) return n .. " 0x2c0a" .. string.format("%04x", #n * 17) .. " 0x2c0b0000 0 0 0" end
    local function result(ok, code)
        if opt.numeric then return ok and 0 or code end
        if ok then return true, "exit", 0 end
        return nil, "exit", code
    end
    local function out_to(cmd, text) local p = cmd:match(">%s*(%S+)") if p then W.fs[p] = text end end
    local function app_dmesg(n)
        if n == "calc_safe" then
            W.dmesg[#W.dmesg + 1] = "[calc_safe] loaded"
            W.dmesg[#W.dmesg + 1] = "[calc_safe] pm install(com.m0tral.calculator) rc=0"
            W.dmesg[#W.dmesg + 1] = "[calc_safe] app_launcher_add rc=0"
            W.dmesg[#W.dmesg + 1] = "[calc_safe] registered; remove by reboot, NOT rmmod"
        elseif n == "mb10p_hello" then
            W.dmesg[#W.dmesg + 1] = "[hello_module] loaded"
            W.dmesg[#W.dmesg + 1] = "[hello_module] hello"
        elseif n == "pm_inspect" then
            W.dmesg[#W.dmesg + 1] = "[pm_inspect] BEGIN id=0xc1 period_ms=1000 ticks=90"
            W.dmesg[#W.dmesg + 1] = "[pm_inspect] NODE seq=1 node=0x20401230 flags=0x0000 name=0x20401280 icon=0x204012a0 cb1c=0x2c0a1b01 cb20=0x00000000 cb24=0x00000000 cb28=0x00000000 cb38=0x00000000 pages=0x204012c0 unin=0x00000000"
            W.dmesg[#W.dmesg + 1] = "[pm_inspect] PAGE seq=1 i=0 page=0x2c0a2000 pid=0 state=3 layer=1 kind=0 adestroy=0x0 root=0x00000000 prev=0x20401300 next=0x20401300"
        end
    end
    W.finish_inspector = function() W.dmesg[#W.dmesg + 1] = "[pm_inspect] DONE seq=90" end
    os.execute = function(cmd)
        local prog = cmd:match("^(%S+)")
        W.cmds[#W.cmds + 1] = cmd
        if not ALLOWED[prog] then error("FORBIDDEN COMMAND: " .. cmd) end
        if prog == "getprop" then
            local key = cmd:match("^getprop (%S+)")
            local v = ({ ["ro.build.version"] = (opt.fw or "3.201.026") .. " release-keys",
                         ["ro.build.id"] = opt.build_id or "CONBINE_LTALM080_3.201.026",
                         ["persist.record_app_install"] = opt.prop or "" })[key] or ""
            out_to(cmd, v .. "\n")
            return result(true)
        elseif prog == "lsmod" then
            if opt.lsmod_fail then return result(false, 1) end
            local t = opt.lsmod_noheader and "garbage\n" or "NAME INIT UNINIT ARG NEXPORTS NSYMBOLS\n"
            for _, n in ipairs(W.order or {}) do if W.mods[n] then t = t .. W.mods[n] .. "\n" end end
            out_to(cmd, t)
            return result(true)
        elseif prog == "dmesg" then
            if opt.no_dmesg then return result(false, 127) end
            out_to(cmd, table.concat(W.dmesg, "\n") .. "\n")
            return result(true)
        elseif prog == "cp" then
            local s, d = cmd:match("^cp (%S+) (%S+)$")
            if opt.cp_fail then return result(false, 1) end
            W.fs[d] = opt.cp_corrupt and W.fs[s]:sub(1, 100) or W.fs[s]
            return result(true)
        elseif prog == "insmod" then
            local p, n = cmd:match("^insmod (%S+) (%S+)$")
            assert(W.fs[p], "insmod of a path that was not deployed: " .. tostring(p))
            if W.mods[n] then return result(false, 17) end            -- EEXIST
            if opt.insmod_fail then return result(false, 255) end
            if not opt.insmod_silent then
                W.mods[n] = row(n) .. (opt.row_salt or "")
                W.order = W.order or {}
                W.order[#W.order + 1] = n
            end
            app_dmesg(n)
            return result(true)
        elseif prog == "rmmod" then
            local n = cmd:match("^rmmod (%S+)$")
            if opt.rmmod_stuck then return result(true) end
            if W.mods[n] then W.mods[n] = nil return result(true) end
            return result(false, 2)
        elseif prog == "ls" then out_to(cmd, "-rw-r--r-- 1 0 0 4096 launcher.db\n") return result(true)
        elseif prog == "free" then out_to(cmd, "total used free\n 100 50 50\n") return result(true)
        end
    end
    io.open = function(path, mode)
        mode = mode or "r"
        if mode:find("a") then
            return { write = function(_, ...) W.fs[path] = (W.fs[path] or "") .. table.concat({ ... }) end, close = function() end }
        elseif mode:find("w") then
            W.fs[path] = ""
            return { write = function(_, ...) W.fs[path] = W.fs[path] .. table.concat({ ... }) end, close = function() end }
        end
        if W.fs[path] == nil then return nil end
        local pos = 0
        return {
            read = function(_, n)
                local d = W.fs[path]
                if n == "*a" or n == nil then local r = d:sub(pos + 1) pos = #d return r end
                if pos >= #d then return nil end
                local r = d:sub(pos + 1, pos + n) pos = pos + #r return r
            end,
            seek = function(_, whence, off)
                local d = W.fs[path]
                if whence == "end" then pos = #d + (off or 0) return #d end
                pos = (off or 0) return pos
            end,
            close = function() end,
        }
    end
    return W
end

local function obj()
    return setmetatable({}, { __index = function(_, k)
        if k == "set" then return function(self, t) if t.text then self.text = t.text end end end
        return function() end end })
end

local function boot(W, extra_env)
    W.buttons = {}
    local labels = {}
    local lvgl = {
        FLAG = setmetatable({}, { __index = function() return 0 end }),
        ALIGN = setmetatable({ CENTER = 0 }, { __index = function() return 0 end }),
        HOR_RES = function() return 336 end, VER_RES = function() return 480 end,
        OPA = function(x) return x end, Font = function() return 0 end,
        Object = function()
            local o = obj()
            o.onClicked = function(_, fn) W.buttons[#W.buttons + 1] = fn end
            return o
        end,
        Label = function(_, t) local o = obj() o.text = t.text labels[#labels + 1] = o return o end,
    }
    local env = setmetatable({ require = function() return lvgl end, SCRIPT_PATH = "/pkg/",
                               MB10P_TEST_EXPORT = extra_env }, { __index = _G })
    W.cmds = {}
    local chunk = assert(load(MAIN, "main.lua", "t", env))
    chunk()
    W.status = labels[#labels]
    W.sel_label = nil
end

local B = { select = 1, scan = 2, snap = 3, install = 4, verify = 5, remove = 6 }
local function press(W, name, times)
    for _ = 1, times or 1 do W.buttons[B[name]]() end
    return (W.status.text or ""):match("^[^\n]*")
end
local function count(W, prog)
    local n = 0
    for _, c in ipairs(W.cmds) do if c:match("^" .. prog .. " ") or c == prog then n = n + 1 end end
    return n
end
local function pick(W, key)               -- cycle the selector to the wanted app
    local want = ({ hello = 1, calc_safe = 2, pm_inspect = 3 })[key]
    for _ = 1, 3 do
        local t = W.status.text or ""
        press(W, "select")
        if (W.status.text or ""):find("Selected " .. key, 1, true) then return end
    end
    assert(false, "cannot select " .. key .. " want " .. want)
end

local function check(name, cond, detail)
    results[#results + 1] = (cond and "PASS " or "FAIL ") .. name .. ((not cond and detail) and ("  [" .. detail .. "]") or "")
    if not cond then fails = fails + 1 end
end

local function with_world(opt, fn)
    local W = new_world(opt)
    local ok, err = pcall(function() boot(W) fn(W) end)
    os.execute, io.open = real_exec, real_open
    if not ok then check("scenario crashed: " .. tostring(err), false) end
end

-- 0 adler32 known vector ("Wikipedia" -> 0x11E60398)
do
    local W = new_world()
    local ex = {}
    local ok = pcall(function() boot(W, ex) end)
    os.execute, io.open = real_exec, real_open
    local a, b = ex.adler32("Wikipedia")
    check("adler32 test vector", ok and string.format("%04x%04x", b, a) == "11e60398", string.format("%04x%04x", b or 0, a or 0))
end

with_world(nil, function(W)
    check("load-time commands: getprop only", #W.cmds == 1 and W.cmds[1]:match("^getprop"), table.concat(W.cmds, ";"))
    check("nothing loaded at open", next(W.mods) == nil and count(W, "insmod") == 0)
end)

with_world({ fw = "3.101.043" }, function(W)
    press(W, "install") press(W, "scan") press(W, "remove")
    check("wrong firmware: no command except getprop", #W.cmds == 1)
end)

with_world({ build_id = "OTHER_BUILD_3.201.026" }, function(W)
    local m = press(W, "install")
    check("build id mismatch refuses install", count(W, "insmod") == 0 and m:find("refused", 1, true))
end)

with_world(nil, function(W)
    pick(W, "hello")
    local m = press(W, "install")
    check("hello install PASS", m:find("INSTALL PASS", 1, true) and count(W, "insmod") == 1, m)
    m = press(W, "install")
    check("duplicate install refused (no second insmod)", count(W, "insmod") == 1 and m:find("already loaded", 1, true), m)
    m = press(W, "verify")
    check("hello verify PASS from dmesg", m:find("VERIFY PASS", 1, true), m)
    m = press(W, "remove")
    check("hello remove PASS (rmmod ok + not listed)", m:find("REMOVE PASS", 1, true) and count(W, "rmmod") == 1, m)
    m = press(W, "install")
    check("hello reinstall after remove", m:find("INSTALL PASS", 1, true) and count(W, "insmod") == 2, m)
end)

with_world(nil, function(W)
    pick(W, "calc_safe")
    local m = press(W, "install")
    check("calc_safe install PASS + logo copied", m:find("INSTALL PASS", 1, true) and W.fs["/data/calc_logo_112.png"] == PKG["/pkg/calc_logo_112.png"], m)
    m = press(W, "verify")
    check("calc_safe verify PASS (registration lines)", m:find("VERIFY PASS", 1, true), m)
    m = press(W, "remove")
    check("calc_safe remove REFUSED, never rmmod", m:find("refused", 1, true) and count(W, "rmmod") == 0, m)
    m = press(W, "install")
    check("calc_safe second install refused (duplicate)", count(W, "insmod") == 1, m)
    W.reboot()
    local W2 = W
    m = press(W2, "scan")
    check("scan after reboot: all absent", (W2.status.text or ""):find("calc_safe absent", 1, true) ~= nil, W2.status.text)
    m = press(W2, "install")
    check("calc_safe installs again after reboot", m:find("INSTALL PASS", 1, true) and count(W2, "insmod") == 2, m)
end)

with_world({ lsmod_fail = true }, function(W)
    local m = press(W, "install") press(W, "remove")
    check("lsmod failure: no cp/insmod/rmmod", count(W, "cp") == 0 and count(W, "insmod") == 0 and count(W, "rmmod") == 0, m)
end)
with_world({ lsmod_noheader = true }, function(W)
    press(W, "install")
    check("lsmod without header: fail closed", count(W, "cp") == 0 and count(W, "insmod") == 0)
end)

with_world(nil, function(W)
    W.fs["/pkg/mb10p_hello_3.201.026.elf"] = W.fs["/pkg/mb10p_hello_3.201.026.elf"]:sub(1, 600)
    pick(W, "hello")
    local m = press(W, "install")
    check("corrupt packaged ELF rejected before cp/insmod", count(W, "cp") == 0 and count(W, "insmod") == 0 and m:find("INSTALL FAIL", 1, true), m)
end)
with_world({ cp_corrupt = true }, function(W)
    pick(W, "hello")
    press(W, "install")
    check("bad copy rejected before insmod", count(W, "insmod") == 0 and count(W, "cp") == 1)
end)

with_world({ insmod_silent = true }, function(W)
    pick(W, "hello")
    local m = press(W, "install")
    check("insmod ok but not listed -> UNCERTAIN", m:find("UNCERTAIN", 1, true), m)
    press(W, "install") press(W, "remove")
    check("lock blocks further install/remove", count(W, "insmod") == 1 and count(W, "rmmod") == 0)
    W.reboot()
    local m2 = press(W, "install")
    check("lock cleared by reboot (tmpfs)", count(W, "insmod") == 2, m2)
end)

with_world({ insmod_fail = true }, function(W)
    pick(W, "hello")
    local m = press(W, "install")
    check("insmod failure reports real code, no rmmod", m:find("code=255", 1, true) and count(W, "rmmod") == 0, m)
end)

with_world(nil, function(W)                       -- module loaded by someone else
    W.mods["mb10p_hello"] = "mb10p_hello 0x2c0a1111 0x2c0b0000 0 0 0"
    W.order = { "mb10p_hello" }
    pick(W, "hello")
    local m = press(W, "install")
    check("pre-existing module: install refused", count(W, "insmod") == 0)
    m = press(W, "remove")
    check("pre-existing module: remove refused (identity unknown), no blind rmmod", count(W, "rmmod") == 0 and m:find("refused", 1, true), m)
end)

with_world(nil, function(W)                       -- row changes after install
    pick(W, "hello")
    press(W, "install")
    W.mods["mb10p_hello"] = "mb10p_hello 0xDEADBEEF 0 0 0 0"
    local m = press(W, "remove")
    check("changed lsmod row: remove refused", count(W, "rmmod") == 0, m)
end)

with_world({ rmmod_stuck = true }, function(W)
    pick(W, "hello")
    press(W, "install")
    local m = press(W, "remove")
    check("rmmod ok but still listed -> FAIL + lock", m:find("REMOVE FAIL", 1, true) and count(W, "rmmod") == 1, m)
    press(W, "remove")
    check("lock blocks second rmmod", count(W, "rmmod") == 1)
end)

with_world(nil, function(W)                       -- inspector lifecycle
    pick(W, "pm_inspect")
    local m = press(W, "install")
    check("pm_inspect install PASS", m:find("INSTALL PASS", 1, true), m)
    m = press(W, "remove")
    check("pm_inspect remove refused before DONE", count(W, "rmmod") == 0, m)
    m = press(W, "verify")
    check("verify: still running", m:find("still running", 1, true), m)
    local txt = W.status.text
    check("verify shows recoverable flag + callback state", txt:find("rec=yes", 1, true) and txt:find("name:set", 1, true) and txt:find("page state 3", 1, true), txt)
    W.finish_inspector()
    m = press(W, "verify")
    check("verify: finished after DONE", m:find("inspector finished", 1, true), m)
    m = press(W, "remove")
    check("pm_inspect remove allowed after DONE", m:find("REMOVE PASS", 1, true) and count(W, "rmmod") == 1, m)
end)

with_world({ no_dmesg = true }, function(W)
    pick(W, "pm_inspect")
    press(W, "install")
    local m = press(W, "verify")
    check("dmesg n/a: verify says UNKNOWN", m:find("UNKNOWN", 1, true), m)
    m = press(W, "remove")
    check("dmesg n/a: inspector never removed blind", count(W, "rmmod") == 0, m)
end)

with_world(nil, function(W)                       -- snapshots across a reboot
    pick(W, "calc_safe")
    local m1 = press(W, "snap")
    check("first snapshot saved, no diff", W.fs["/data/mb10p_snap.last"] and (W.status.text or ""):find("first snapshot", 1, true) ~= nil, W.status.text)
    press(W, "install")
    press(W, "snap")
    check("snapshot after install shows module diff", (W.status.text or ""):find("mod.calc_safe", 1, true) ~= nil, W.status.text)
    W.reboot()
    W.fs["/data/mb10p_com.m0tral.calc_safe.elf"] = W.fs["/data/mb10p_com.m0tral.calc_safe.elf"]  -- persists on /data
    press(W, "snap")
    local t = W.status.text or ""
    check("post-reboot snapshot: NEW boot, module gone, /data file kept", t:find("NEW since last marker", 1, true) and t:find("loaded -> absent", 1, true) and not t:find("calc.safe.elf", 1, true) , t)
    local log = W.fs["/data/mb10p_manager.log"] or ""
    check("snapshot recorded file fingerprint", (W.fs["/data/mb10p_snap.last"] or ""):find("file./data/mb10p_com.m0tral.calc_safe.elf=6256:", 1, true) ~= nil)
end)

with_world({ numeric = true }, function(W)
    pick(W, "hello")
    local m = press(W, "install")
    check("Lua 5.1-style numeric os.execute", m:find("INSTALL PASS", 1, true), m)
end)

for _, r in ipairs(results) do print(r) end
print(fails == 0 and ("ALL " .. #results .. " CHECKS OK") or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
