-- data/storify_settings.lua
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local ffiUtil = (pcall(require, "ffi/util") and require("ffi/util"))
    or (pcall(require, "ffiutil") and require("ffiutil"))
    or require("ffiUtil")

local settings_dir = DataStorage:getSettingsDir()
local settings_path = settings_dir .. "/storify.lua"
local legacy_settings_path = settings_dir .. "/appstore.lua"

-- Migrate legacy settings if storify.lua does not exist yet
local f = io.open(settings_path, "r")
if f then
    f:close()
else
    local leg_f = io.open(legacy_settings_path, "r")
    if leg_f then
        leg_f:close()
        if ffiUtil and ffiUtil.copyFile then
            pcall(ffiUtil.copyFile, legacy_settings_path, settings_path)
        end
    end
end

return LuaSettings:open(settings_path)
