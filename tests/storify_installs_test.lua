-- tests/storify_installs_test.lua
-- Unit tests for storify_installs

local function json_encode(val)
    if type(val) == "table" then
        local is_array = #val > 0
        local parts = {}
        if is_array then
            for _, v in ipairs(val) do
                table.insert(parts, json_encode(v))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do
                table.insert(parts, string.format("%q:%s", tostring(k), json_encode(v)))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    elseif type(val) == "string" then
        return string.format("%q", val)
    elseif type(val) == "number" or type(val) == "boolean" then
        return tostring(val)
    elseif val == nil then
        return "null"
    end
    return '"' .. tostring(val) .. '"'
end

local function json_decode(str)
    if not str or str == "" or str == "null" then return nil end
    local s = str:gsub("%[", "{"):gsub("%]", "}")
    s = s:gsub("\"([^\"]-)\"%s*:", "[\"%1\"]="):gsub("null", "nil")
    local f = loadstring("return " .. s)
    if f then
        local ok, res = pcall(f)
        if ok and type(res) == "table" then return res end
    end
    return nil
end

local mock_json = {
    encode = json_encode,
    decode = json_decode,
}
package.preload["json"] = function() return mock_json end
package.loaded["json"] = mock_json

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local json = require("json")

local failures = 0
local total_checks = 0

local function check(label, cond, msg)
    total_checks = total_checks + 1
    if cond then
        print("  ✓ PASS: " .. label)
    else
        failures = failures + 1
        print("  ❌ FAIL: " .. label .. (msg and (" (" .. tostring(msg) .. ")") or ""))
    end
end

local function freshModule()
    package.loaded["storify_installs"] = nil
    package.loaded["data.storify_installs"] = nil
    return require("storify_installs")
end

print("--> [Test Suite] storify_installs")

local M = freshModule()

-- 1. Initial state
M.clear()
check("initial list is empty table", type(M.list()) == "table" and next(M.list()) == nil)
check("initial listPatches is empty table", type(M.listPatches()) == "table" and next(M.listPatches()) == nil)
local gen0 = M.getGeneration()
check("generation is non-negative number", type(gen0) == "number" and gen0 >= 0)

-- 2. Upsert plugin
local record1 = {
    repo_id = 12345,
    tag_name = "v1.0.0",
    installed_at = 1600000000,
    commit_sha = "abc1234",
    install_path = "/tmp/plugins/myplugin.koplugin",
}
local ok = M.upsert("myplugin.koplugin", record1)
check("upsert plugin returns true", ok == true)
check("generation increments on upsert", M.getGeneration() > gen0)
local gen1 = M.getGeneration()

local fetched = M.get("myplugin.koplugin")
check("get returns stored record", fetched and fetched.repo_id == 12345 and fetched.tag_name == "v1.0.0")
check("list contains stored plugin", M.list()["myplugin.koplugin"] ~= nil)

-- 3. Upsert patch & SHA preservation
local patch1 = {
    repo_id = 999,
    filename = "2-test-patch.lua",
    sha = "deadbeef1234",
    installed_at = 1600000100,
}
ok = M.upsertPatch("2-test-patch.lua", patch1)
check("upsertPatch returns true", ok == true)
check("generation increments on patch upsert", M.getGeneration() > gen1)
local gen2 = M.getGeneration()

local fetched_patch = M.getPatch("2-test-patch.lua")
check("getPatch returns stored patch", fetched_patch and fetched_patch.sha == "deadbeef1234")
check("listPatches contains stored patch", M.listPatches()["2-test-patch.lua"] ~= nil)

-- Test SHA preservation when upserting match without SHA
local patch1_update = {
    repo_id = 999,
    filename = "2-test-patch.lua",
    matched_at = 1600000200,
    -- no sha provided
}
M.upsertPatch("2-test-patch.lua", patch1_update)
local patch_preserved = M.getPatch("2-test-patch.lua")
check("upsertPatch preserves existing SHA when new record lacks sha", patch_preserved and patch_preserved.sha == "deadbeef1234")

-- 4. Remove plugin
ok = M.remove("myplugin.koplugin")
check("remove returns true", ok == true)
check("get returns nil after remove", M.get("myplugin.koplugin") == nil)
check("generation increments on remove", M.getGeneration() > gen2)
local gen3 = M.getGeneration()

-- Removing nonexistent plugin with invalid name
check("remove empty plugin_id returns false", M.remove("") == false)
check("remove nil plugin_id returns false", M.remove(nil) == false)
check("generation unchanged on invalid remove", M.getGeneration() == gen3)

-- 5. Remove patch
ok = M.removePatch("2-test-patch.lua")
check("removePatch returns true", ok == true)
check("getPatch returns nil after remove", M.getPatch("2-test-patch.lua") == nil)
check("generation increments on patch remove", M.getGeneration() > gen3)
local gen4 = M.getGeneration()

-- 6. Bulk save and savePatches
local plugins_bulk = {
    ["plug_a.koplugin"] = { repo_id = 1, tag_name = "v1" },
    ["plug_b.koplugin"] = { repo_id = 2, tag_name = "v2" },
}
M.save(plugins_bulk)
check("save updates plugins", M.get("plug_a.koplugin") ~= nil and M.get("plug_b.koplugin") ~= nil)
check("generation increments on bulk save", M.getGeneration() > gen4)
local gen5 = M.getGeneration()

local patches_bulk = {
    ["patch_a.lua"] = { repo_id = 1, filename = "patch_a.lua" },
    ["patch_b.lua"] = { repo_id = 2, filename = "patch_b.lua" },
}
M.savePatches(patches_bulk)
check("savePatches updates patches", M.getPatch("patch_a.lua") ~= nil and M.getPatch("patch_b.lua") ~= nil)
check("generation increments on bulk savePatches", M.getGeneration() > gen5)
local gen6 = M.getGeneration()

-- 7. Clear patches vs Clear all
M.clearPatches()
check("clearPatches empties patches", next(M.listPatches()) == nil)
check("clearPatches keeps plugins intact", M.get("plug_a.koplugin") ~= nil)
check("generation increments on clearPatches", M.getGeneration() > gen6)
local gen7 = M.getGeneration()

M.clear()
check("clear empties plugins", next(M.list()) == nil)
check("clear empties patches", next(M.listPatches()) == nil)
check("generation increments on clear", M.getGeneration() > gen7)

-- 8. Resilient decoding / legacy structure normalization
local settings_path = DataStorage:getSettingsDir() .. "/storify_installs.lua"
local raw_settings = LuaSettings:open(settings_path)

-- Simulate legacy format where 'installs' was a flat plugins table
raw_settings:saveSetting("installs", json.encode({
    ["legacy.koplugin"] = { repo_id = 777, version = "1.0" }
}))
raw_settings:flush()

local M2 = freshModule()
check("legacy format decoded into plugins correctly", M2.get("legacy.koplugin") ~= nil and M2.get("legacy.koplugin").repo_id == 777)
check("legacy format initializes empty patches table", type(M2.listPatches()) == "table" and next(M2.listPatches()) == nil)

-- Simulate corrupt json
raw_settings:saveSetting("installs", "{ invalid json corrupt content !!!")
raw_settings:flush()

local M3 = freshModule()
check("corrupt json does not crash and defaults to empty list", type(M3.list()) == "table" and next(M3.list()) == nil)
check("corrupt json does not crash and defaults to empty listPatches", type(M3.listPatches()) == "table" and next(M3.listPatches()) == nil)

if failures > 0 then
    error(string.format("%d of %d assertions failed in storify_installs_test", failures, total_checks))
end
print(string.format("All %d assertions passed in storify_installs_test", total_checks))
