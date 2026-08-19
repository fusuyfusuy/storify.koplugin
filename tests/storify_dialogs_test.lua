-- tests/storify_dialogs_test.lua
-- Unit tests for ui/storify_dialogs.lua — confirm/restart dialog option
-- semantics and mirror dialog wiring (regression for the UI-drive findings:
-- the install confirm never ran because on_confirm/confirm_text were ignored,
-- and the mirror dialog was a dead stub with no presets).

package.preload["storify_gettext"] = function()
    return setmetatable({}, { __call = function(_, msgid) return msgid end })
end
package.preload["l10n/storify_gettext"] = package.preload["storify_gettext"]

local shown = {}
local UIManager = require("ui/uimanager")
UIManager.show = function(_, dialog)
    table.insert(shown, dialog)
end
UIManager.close = function() end

local restarted = false
local device_mod = require("device")
if type(device_mod) == "table" then
    local orig_restart = device_mod.restartKOReader
    device_mod.restartKOReader = function(...)
        restarted = true
        if orig_restart then orig_restart(...) end
    end
end

local Dialogs = require("ui/storify_dialogs")

local failures = 0
local function check(label, got, expected)
    if got == expected then
        print(string.format("  ✓ PASS: %s", label))
    else
        failures = failures + 1
        print(string.format("  ❌ FAIL: %s | expected: %s, got: %s", label, tostring(expected), tostring(got)))
    end
end

local function findButton(dialog, text_fragment)
    for _, row in ipairs(dialog.buttons or {}) do
        for _, btn in ipairs(row) do
            if type(btn.text) == "string" and btn.text:find(text_fragment, 1, true) then
                return btn
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- 1. showRestartDialog: the install flow uses confirm_text + on_confirm
-- ---------------------------------------------------------------------
shown = {}
local install_ran = false
Dialogs.showRestartDialog("Do you want to install X?", {
    confirm_text = "Install",
    on_confirm = function() install_ran = true end,
})
check("install confirm button label honored", shown[1].ok_text, "Install")
check("default cancel label is Later", shown[1].cancel_text, "Later")
shown[1].ok_callback()
check("install on_confirm runs instead of restart", install_ran, true)
check("no restart triggered by confirm action", restarted, false)

-- ---------------------------------------------------------------------
-- 2. showRestartDialog: default path still says Restart Now and restarts
-- ---------------------------------------------------------------------
shown = {}
Dialogs.showRestartDialog("Installation successful!")
check("default ok label is Restart Now", shown[1].ok_text, "Restart Now")
shown[1].ok_callback()
check("default ok action restarts the device", restarted, true)

-- ---------------------------------------------------------------------
-- 3. showRestartDialog: legacy option names still work (on_restart/on_later)
-- ---------------------------------------------------------------------
shown = {}
local later_ran = false
local restart_ran = false
Dialogs.showRestartDialog("Any message", {
    on_restart = function() restart_ran = true end,
    on_later = function() later_ran = true end,
})
shown[1].ok_callback()
check("legacy on_restart honored", restart_ran, true)
shown[1].cancel_callback()
check("legacy on_later honored", later_ran, true)

-- ---------------------------------------------------------------------
-- 4. showMirrorDialog: renders presets and fires on_select_preset
-- ---------------------------------------------------------------------
shown = {}
local selected_preset
local custom_requested = false
Dialogs.showMirrorDialog{
    presets = {
        { id = "direct", name = "GitHub (direct)", prefix = "" },
        { id = "ghfast", name = "ghfast.top", prefix = "https://ghfast.top/" },
    },
    current_preset = "direct",
    on_select_preset = function(id) selected_preset = id end,
    on_custom_url = function() custom_requested = true end,
}
local mirror_dialog = shown[1]
local preset_btn = findButton(mirror_dialog, "GitHub (direct)")
check("mirror dialog lists presets", preset_btn ~= nil, true)
if preset_btn then preset_btn.callback() end
check("preset selection wired", selected_preset, "direct")

-- ---------------------------------------------------------------------
-- 5. Mirror dialog: custom URL row fires on_custom_url; unwired is safe
-- ---------------------------------------------------------------------
local custom_btn = findButton(mirror_dialog, "Custom mirror URL")
check("custom URL row present", custom_btn ~= nil, true)
custom_btn.callback()
check("custom URL callback wired", custom_requested, true)

shown = {}
Dialogs.showMirrorDialog{ presets = {} }
local d2 = shown[1]
local safe = true
for _, row in ipairs(d2.buttons or {}) do
    for _, btn in ipairs(row) do
        if type(btn.callback) == "function" then
            local ok = pcall(btn.callback)
            if not ok then safe = false end
        end
    end
end
check("unwired mirror buttons are safe no-ops", safe, true)

-- ---------------------------------------------------------------------
-- 6. showInfoMessage surfaces text through InfoMessage
-- ---------------------------------------------------------------------
shown = {}
Dialogs.showInfoMessage("hello")
check("info message shown with text", shown[1] ~= nil and shown[1].text == "hello", true)

if failures > 0 then
    error(string.format("%d test(s) failed in storify_dialogs_test.lua", failures))
end
