-- Offline logic test for watchface_src/app/lua/main.lua (mock shell, mock LVGL).
-- This exercises the decision logic only. It is NOT a hardware test.
-- usage: lua5.4 test_loader.lua <path/to/main.lua> <path/to/elf>

local MAIN, ELF = arg[1], arg[2]
local elf_bytes = assert(io.open(ELF, "rb")):read("*a")
local src_main = assert(io.open(MAIN, "rb")):read("*a")

local ALLOWED = { getprop = true, lsmod = true, cp = true, insmod = true, rmmod = true, dmesg = true }
local results, fails = {}, 0

local function scenario(name, opt, steps, expect)
    opt = opt or {}
    local fs = { ["/pkg/mb10p_hello_3.201.026.elf"] = elf_bytes }
    local mods = {}                       -- name -> row
    if opt.preloaded then mods[opt.preloaded] = opt.preloaded .. " 0x2c0a1b01 0x2c0a1b21 0 0 0" end
    local cmds = {}
    local old_exec, old_open = os.execute, io.open

    local function result(ok, code)
        if opt.numeric then return ok and 0 or code end
        if ok then return true, "exit", 0 end
        return nil, "exit", code
    end

    os.execute = function(cmd)
        local prog = cmd:match("^(%S+)")
        cmds[#cmds + 1] = cmd
        if not ALLOWED[prog] then error("FORBIDDEN COMMAND: " .. cmd) end
        if prog == "getprop" then
            fs["/tmp/hello_fw.txt"] = (opt.fw or "3.201.026") .. " release-keys\n"
            return result(true)
        elseif prog == "lsmod" then
            if opt.lsmod_fail then return result(false, 1) end
            local out = opt.lsmod_noheader and "garbage\n" or "NAME INIT UNINIT ARG NEXPORTS NSYMBOLS\n"
            for _, row in pairs(mods) do out = out .. row .. "\n" end
            if opt.row_changes and next(mods) then
                for k in pairs(mods) do out = out .. "" ; mods[k] = k .. " 0xDEADBEEF 0 0 0 0" end
            end
            fs[cmd:match(">%s*(%S+)")] = out
            return result(true)
        elseif prog == "dmesg" then
            fs[cmd:match(">%s*(%S+)")] = ""
            return result(true)
        elseif prog == "cp" then
            local s, d = cmd:match("^cp (%S+) (%S+)$")
            if opt.cp_fail then return result(false, 1) end
            fs[d] = opt.cp_corrupt and (fs[s]:sub(1, 100)) or fs[s]
            return result(true)
        elseif prog == "insmod" then
            local p, n = cmd:match("^insmod (%S+) (%S+)$")
            assert(fs[p], "insmod of a path that was not deployed: " .. tostring(p))
            if opt.insmod_fail then return result(false, 255) end
            if not opt.insmod_silent then mods[n] = n .. " 0x2c0a1b01 0x2c0a1b21 0 0 0" end
            return result(true)
        elseif prog == "rmmod" then
            local n = cmd:match("^rmmod (%S+)$")
            if opt.rmmod_stuck then return result(true) end
            if mods[n] then mods[n] = nil; return result(true) end
            return result(false, 2)
        end
    end

    io.open = function(path, mode)
        mode = mode or "r"
        if mode:find("a") then
            return { write = function(_, ...) fs[path] = (fs[path] or "") .. table.concat({ ... }) end,
                     close = function() end }
        end
        if not fs[path] then return nil end
        return { read = function(_, n) if n == "*a" or n == nil then return fs[path] end
                     return fs[path]:sub(1, n) end,
                 close = function() end }
    end

    local buttons, labels = {}, {}
    local function obj()
        return setmetatable({}, { __index = function(t, k)
            if k == "onClicked" then return function(_, fn) buttons[#buttons + 1] = fn end end
            if k == "set" then return function(self, tbl) self.text = tbl.text end end
            return function() end end })
    end
    local lvgl = setmetatable({
        FLAG = setmetatable({}, { __index = function() return 0 end }),
        ALIGN = setmetatable({ CENTER = 0 }, { __index = function() return 0 end }),
        HOR_RES = function() return 336 end, VER_RES = function() return 480 end,
        OPA = function(x) return x end, Font = function() return 0 end,
        Object = function() return obj() end,
        Label = function(_, t) local o = obj(); o.text = t.text; labels[#labels + 1] = o; return o end,
    }, {})
    local env = setmetatable({ require = function() return lvgl end, SCRIPT_PATH = "/pkg/" },
        { __index = _G })
    local chunk = assert(load(src_main, "main.lua", "t", env))
    chunk()
    local status = labels[#labels]
    local names = { "check", "load", "unload" }
    local notes = {}
    for _, s in ipairs(steps) do
        local idx = ({ check = 1, load = 2, unload = 3 })[s]
        buttons[idx]()
        notes[#notes + 1] = s .. ": " .. (status.text:match("^[^\n]*") or "")
    end
    os.execute, io.open = old_exec, old_open

    local function count(prog) local n = 0
        for _, c in ipairs(cmds) do if c:match("^" .. prog .. " ") or c == prog then n = n + 1 end end
        return n end
    local verdicts = {}
    for k, v in pairs(expect) do
        local got
        if k == "insmod" or k == "rmmod" or k == "cp" then got = count(k)
        elseif k == "last" then got = notes[#notes]
        elseif k == "loaded_after" then got = next(mods) ~= nil end
        local ok = (type(v) == "string") and (got and got:find(v, 1, true) ~= nil) or got == v
        if not ok then fails = fails + 1; verdicts[#verdicts + 1] = string.format("   MISMATCH %s: want %s got %s", k, tostring(v), tostring(got)) end
    end
    results[#results + 1] = string.format("%s %s", #verdicts == 0 and "PASS" or "FAIL", name)
    for _, v in ipairs(verdicts) do results[#results + 1] = v end
end

-- A: normal cycle, twice (the "START twice" requirement); rmmod only after verified load
scenario("A happy path load/unload/load/unload", nil,
    { "check", "load", "unload", "load", "unload" },
    { insmod = 2, rmmod = 2, cp = 2, last = "UNLOAD PASS", loaded_after = false })
scenario("A2 same with Lua 5.1-style numeric os.execute", { numeric = true },
    { "check", "load", "unload" }, { insmod = 1, rmmod = 1, last = "UNLOAD PASS" })
-- B: module of that name already present (cannot prove it is ours)
scenario("B module pre-existing: no insmod, no blind rmmod", { preloaded = "mb10p_hello" },
    { "check", "load", "unload" }, { insmod = 0, rmmod = 0, cp = 0, last = "UNLOAD refused" })
scenario("C lsmod without header: fail closed", { lsmod_noheader = true },
    { "check", "load", "unload" }, { insmod = 0, rmmod = 0, cp = 0 })
scenario("C2 lsmod command fails: fail closed", { lsmod_fail = true },
    { "load" }, { insmod = 0, cp = 0 })
scenario("D insmod ok but not listed: UNCERTAIN, then locked", { insmod_silent = true },
    { "load", "load", "unload" }, { insmod = 1, rmmod = 0, last = "UNLOAD refused" })
scenario("E insmod fails: reported, never rmmod", { insmod_fail = true },
    { "load", "unload" }, { insmod = 1, rmmod = 0, last = "UNLOAD refused" })
scenario("F lsmod row changed before rmmod: refuse", { row_changes = true },
    { "load", "unload" }, { insmod = 1, rmmod = 0, last = "UNLOAD refused" })
scenario("G cp corrupts file: no insmod", { cp_corrupt = true },
    { "load" }, { insmod = 0, cp = 1, last = "LOAD FAIL" })
scenario("G2 cp fails: no insmod", { cp_fail = true }, { "load" }, { insmod = 0 })
scenario("H rmmod ok but still listed: FAIL then locked", { rmmod_stuck = true },
    { "load", "unload", "load" }, { insmod = 1, rmmod = 1, last = "LOCKED" })
scenario("I wrong firmware: nothing runs", { fw = "3.101.043" },
    { "check", "load", "unload" }, { insmod = 0, cp = 0, rmmod = 0 })

for _, r in ipairs(results) do print(r) end
print(fails == 0 and "ALL SCENARIOS OK" or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
