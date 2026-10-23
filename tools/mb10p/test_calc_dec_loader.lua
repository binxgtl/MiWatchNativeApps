-- mock harness for mb10pro/wf_native_calc_dec/app/lua/main.lua (decision logic only, not a hardware test)
-- usage: lua5.4 tools/mb10p/test_calc_dec_loader.lua mb10pro/wf_native_calc_dec/app/lua/main.lua
local script = arg[1]
local fails, total = 0, 0
local function check(name, cond, info)
  total = total + 1
  print((cond and "PASS " or "FAIL ") .. name .. (cond and "" or ("  [" .. tostring(info) .. "]")))
  if not cond then fails = fails + 1 end
end
local LSMOD_HDR = "NAME                 INIT   UNINIT      ARG NEXPORTS     TEXT     BSS     DATA\n"
local function scenario(opt)
  local cmds, files, status, clicked = {}, {}, nil, nil
  local obj = {}
  obj.__index = obj
  function obj.clear_flag() end function obj.add_flag() end
  function obj:set(t) if t.text then status = t.text end end
  function obj:onClicked(f) clicked = clicked or f end
  local function new(_, t) local o = setmetatable({}, obj); if t and t.text then o.text = t.text end; return o end
  package.loaded.lvgl = {
    Object = new, Label = function(p, t) local o = new(p, t); status = t.text; return o end,
    HOR_RES = function() return 336 end, VER_RES = function() return 480 end,
    OPA = function(x) return x end, Font = function() return {} end,
    FLAG = { SCROLLABLE = 1, EVENT_BUBBLE = 2, CLICKABLE = 4 }, ALIGN = { CENTER = 0 },
  }
  SCRIPT_PATH = "/res/wf/193824674/lua/"
  os.execute = function(c)
    cmds[#cmds + 1] = c
    if c:match("^getprop ro.build.version") then files["/tmp/device_version"] = opt.fw .. "\n"
    elseif c:match("^lsmod") then files["/tmp/lsmod_calc_safe"] = opt.lsmod
    elseif c:match("^cp ") then return opt.cp == nil and true or opt.cp
    elseif c:match("^insmod") then return true end
    return true
  end
  io.open = function(p)
    local d = files[p]; if d == nil then return nil end
    return { read = function(_, fmt) if fmt == "*l" then return (d:match("^[^\n]*")) end return d end, close = function() end }
  end
  dofile(script)
  local initial = status
  if opt.click and clicked then clicked() end
  return cmds, status, initial
end
local function has(cmds, pat) for _, c in ipairs(cmds) do if c:match(pat) then return c end end end

local c, s, init = scenario{ fw = "3.201.026", lsmod = LSMOD_HDR .. "mb10p_hello   0 0 0 0\n", click = true }
check("ready text names the decimal build", init:find("Calc dec ready (decimal 8600e41)", 1, true), init)
check("clean boot: copies the own ELF to its own /data file",
  has(c, "^cp /res/wf/193824674/lua/mb10p_calc_dec_3%.201%.026%.elf /data/mb10p_com%.m0tral%.calc_dec%.elf$"), table.concat(c, " | "))
check("clean boot: insmod own file as module calc_safe", has(c, "^insmod /data/mb10p_com%.m0tral%.calc_dec%.elf calc_safe$"), table.concat(c, " | "))
check("loaded message", s:find("loaded", 1, true), s)
check("never touches Calc safe's /data ELF", not has(c, "calc_safe%.elf"), table.concat(c, " | "))
for _, m in ipairs({ "calc_safe", "mb10p_app" }) do
  c, s = scenario{ fw = "3.201.026", lsmod = LSMOD_HDR .. m .. "   0x1 0x2 0 0 100 0 0\n", click = true }
  check(m .. " loaded: refuses, no cp, no insmod", not has(c, "^cp") and not has(c, "^insmod") and s:find(m .. " already loaded", 1, true), s)
end
c, s = scenario{ fw = "3.201.026", lsmod = "garbage\n", click = true }
check("unreadable lsmod: fail closed", not has(c, "^insmod") and s:find("cannot read lsmod", 1, true), s)
c, s = scenario{ fw = "3.201.026", lsmod = LSMOD_HDR, click = true, cp = false }
check("cp failure: no insmod", not has(c, "^insmod") and s:find("cp failed", 1, true), s)
c, s, init = scenario{ fw = "3.201.016", lsmod = LSMOD_HDR, click = true }
check("other firmware: gated, nothing run", not has(c, "^lsmod") and not has(c, "^cp") and not has(c, "^insmod") and init:find("unsupported firmware: 3.201.016", 1, true), init)
c, s, init = scenario{ fw = "3.201.0260", lsmod = LSMOD_HDR, click = true }
check("near-miss firmware string gated", not has(c, "^insmod"), init)
for _, cc in ipairs({ scenario{ fw = "3.201.026", lsmod = LSMOD_HDR, click = true } }) do end
c = scenario{ fw = "3.201.026", lsmod = LSMOD_HDR .. "calc_safe 1 2 0 0\n", click = true }
check("no rmmod in any path", not has(c, "rmmod"))
print(fails == 0 and ("ALL " .. total .. " CHECKS OK") or ("FAILURES: " .. fails .. " of " .. total))
os.exit(fails == 0 and 0 or 1)
