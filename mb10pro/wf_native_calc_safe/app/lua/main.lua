-- based on m0tral's native app installer (2026-09-04)
-- lifecycle-test installer for mb10p_app_safe.elf
--
-- Differences from wf_native_calculator:
--   * never runs rmmod: unloading a module whose app is registered frees
--     memory the package manager still points to (use-after-free);
--   * refuses to insmod when the module is already loaded this boot, or when
--     lsmod cannot be read (fail closed) -> reboot to install again;
--   * the installed module does not delete this watchface.

local lvgl = require("lvgl")

local LOGO_NAME   = "calc_logo_112.png"

-- Firmware -> app ELF. Only builds whose address table was verified.
local FW_TO_APP = {
    ["3.201.026"] = "mb10p_app_safe_3.201.026.elf",
}

local function detect_fw_version()
    os.execute("getprop ro.build.version > /tmp/device_version")
    local f = io.open("/tmp/device_version", "r")
    if not f then return nil end
    local raw = f:read("*l") or ""
    f:close()
    return (raw:match("^%s*([%d._]+)") or ""):gsub("%s+", "")
end

local fw     = detect_fw_version()
local APP_NAME = FW_TO_APP[fw]
local LOAD_ERROR = nil
if not APP_NAME then
    LOAD_ERROR = "unsupported firmware: " .. tostring(fw)
    APP_NAME = ""
end

local MODULE_NAME = "calc_safe"

local APP_SRC     = SCRIPT_PATH .. APP_NAME
local APP_DST     = "/data/mb10p_com.m0tral.calc_safe.elf"

local LOGO_SRC    = SCRIPT_PATH .. LOGO_NAME
local LOGO_DST    = "/data/" .. LOGO_NAME

-- true / false, or nil when lsmod output could not be read
local function module_loaded(name)
    os.execute("lsmod > /tmp/lsmod_calc_safe")
    local f = io.open("/tmp/lsmod_calc_safe", "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    -- lsmod always prints its header ("NAME INIT UNINIT ARG NEXPORTS ...");
    -- without it we cannot tell, so fail closed.
    if not text or not text:find("NEXPORTS", 1, true) then return nil end
    for line in text:gmatch("[^\n]+") do
        if line:match("^%s*" .. name .. "%s") or line:match("^%s*" .. name .. "$") then
            return true
        end
    end
    return false
end

local rootbase = lvgl.Object(nil, {
    w = lvgl.HOR_RES(), h = lvgl.VER_RES(), bg_color = 0x07111F,
    bg_opa = lvgl.OPA(100), border_width = 0,
})
rootbase:clear_flag(lvgl.FLAG.SCROLLABLE)
rootbase:add_flag(lvgl.FLAG.EVENT_BUBBLE)
local root = lvgl.Object(rootbase, {
    w = lvgl.HOR_RES(), h = lvgl.VER_RES(), bg_color = 0x07111F,
    bg_opa = lvgl.OPA(100),
    border_width = 0, pad_all = 0, align = lvgl.ALIGN.CENTER,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)
root:add_flag(lvgl.FLAG.EVENT_BUBBLE)

local status
local function set_status(text, color)
    if status then status:set { text = tostring(text), text_color = color or 0xBFD9FF } end
end

local function make_button(text, y, color, on_clicked)
    local button = lvgl.Object(root, {
        w = 320, h = 80, bg_color = color, bg_opa = lvgl.OPA(100),
        radius = 16,
        align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = y },
    })
    button:clear_flag(lvgl.FLAG.SCROLLABLE)
    button:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    button:add_flag(lvgl.FLAG.CLICKABLE)
    lvgl.Label(button, {
        text = text, text_color = 0xFFFFFF, align = lvgl.ALIGN.CENTER,
        text_font = lvgl.Font("MiSans-Demibold", 28, "normal")
    })
    button:onClicked(function()
        local ok, message = pcall(on_clicked)
        if not ok then set_status("Error: " .. tostring(message), 0xFF9A9A) end
    end)
    return button
end

local run_button = make_button("START", -20,
    LOAD_ERROR and 0x555555 or 0x14508A,
    function()
        if LOAD_ERROR then
            set_status(LOAD_ERROR, 0xFF9A9A)
            return
        end
        local loaded = module_loaded(MODULE_NAME)
        if loaded == nil then
            set_status("cannot read lsmod; not installing", 0xFF9A9A)
            return
        elseif loaded then
            set_status("already loaded this boot.\nreboot to install again", 0xFFD58A)
            return
        end
        local cp_ok = os.execute("cp " .. APP_SRC .. " " .. APP_DST)
        if cp_ok ~= true and cp_ok ~= 0 then
            set_status("cp failed (code=" .. tostring(cp_ok) .. ")", 0xFF9A9A)
            return
        end
        os.execute("cp " .. LOGO_SRC .. " " .. LOGO_DST)
        local ok = os.execute("insmod " .. APP_DST .. " " .. MODULE_NAME)
        if ok == true or ok == 0 then
            set_status("loaded. wait ~1 s, then check apps.\nremove = reboot", 0x8FF0A4)
        else
            set_status("insmod failed (code=" .. tostring(ok) .. ")", 0xFF9A9A)
        end
    end)

if LOAD_ERROR then
    run_button:clear_flag(lvgl.FLAG.CLICKABLE)
end

status = lvgl.Label(root, {
    text = LOAD_ERROR
        or ("Ready\nfw=" .. (fw or "?") .. "\nmodule=" .. MODULE_NAME),
    text_color = LOAD_ERROR and 0xFF9A9A or 0xBFD9FF,
    width = 300, height = 160,
    text_font = lvgl.Font("MiSans-Demibold", 20, "normal"),
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 112 },
})
