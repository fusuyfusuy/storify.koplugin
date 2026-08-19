-- data/storify_installs.lua
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local json = require("json")
local logger = require("logger")

local InstallStore = {}

local SETTINGS_DIR = DataStorage:getSettingsDir()
local SETTINGS_PATH = SETTINGS_DIR .. "/storify_installs.lua"
local settings = LuaSettings:open(SETTINGS_PATH)

local store_key = "installs"

-- Bumped on every successful write, so callers can cache derived data (e.g.
-- an installed-repo lookup) and only rebuild it when records actually change.
local generation = 0

local function normalizeData(data)
    if type(data) ~= "table" then
        data = {}
    end
    if data.plugins == nil then
        data = {
            plugins = data,
            patches = {},
        }
    else
        data.patches = data.patches or {}
        data.plugins = data.plugins or {}
    end
    return data
end

local function readStore()
    local encoded = settings:readSetting(store_key)
    if type(encoded) ~= "string" or encoded == "" then
        return normalizeData({})
    end
    local ok, decoded = pcall(function()
        return json.decode(encoded)
    end)
    if not ok or type(decoded) ~= "table" then
        logger.warn("storify installs decode error", decoded)
        return normalizeData({})
    end
    return normalizeData(decoded)
end

local function writeStore(data)
    local payload = normalizeData(data)
    local ok, encoded = pcall(function()
        return json.encode(payload)
    end)
    if not ok then
        logger.warn("storify installs encode error", encoded)
        return false
    end
    settings:saveSetting(store_key, encoded)
    settings:flush()
    generation = generation + 1
    return true
end

function InstallStore.list()
    return readStore().plugins
end

-- Monotonic counter bumped on every write, so callers can cache data derived
-- from the store (e.g. an installed-repo lookup) and know when to rebuild it.
function InstallStore.getGeneration()
    return generation
end

function InstallStore.listPatches()
    return readStore().patches
end

function InstallStore.save(entries)
    local data = readStore()
    data.plugins = entries or {}
    return writeStore(data)
end

function InstallStore.savePatches(entries)
    local data = readStore()
    data.patches = entries or {}
    return writeStore(data)
end

function InstallStore.upsert(plugin_id, record)
    if not plugin_id or plugin_id == "" then
        return false
    end
    local data = readStore()
    data.plugins[plugin_id] = record
    return writeStore(data)
end

function InstallStore.upsertPatch(filename, record)
    if not filename or filename == "" then
        return false
    end
    record = record or {}
    local data = readStore()
    local existing = data.patches[filename]
    -- Preserve existing SHA if new record doesn't have one (e.g., during match operation).
    -- This ensures install SHA is not lost when matching an already-installed patch.
    if existing and existing.sha and not record.sha then
        record.sha = existing.sha
    end
    data.patches[filename] = record
    return writeStore(data)
end

function InstallStore.remove(plugin_id)
    if not plugin_id or plugin_id == "" then
        return false
    end
    local data = readStore()
    if data.plugins[plugin_id] == nil then
        return false
    end
    data.plugins[plugin_id] = nil
    return writeStore(data)
end

function InstallStore.removePatch(filename)
    if not filename or filename == "" then
        return false
    end
    local data = readStore()
    if data.patches[filename] == nil then
        return false
    end
    data.patches[filename] = nil
    return writeStore(data)
end

function InstallStore.get(plugin_id)
    if not plugin_id or plugin_id == "" then
        return nil
    end
    local data = readStore()
    return data.plugins[plugin_id]
end

function InstallStore.getPatch(filename)
    if not filename or filename == "" then
        return nil
    end
    local data = readStore()
    return data.patches[filename]
end

function InstallStore.clear()
    return writeStore({ plugins = {}, patches = {} })
end

function InstallStore.clearPatches()
    local data = readStore()
    data.patches = {}
    return writeStore(data)
end

function InstallStore.syncFromDisk(scanned_plugins, cached_repos)
    scanned_plugins = scanned_plugins or {}
    cached_repos = cached_repos or {}
    local data = readStore()
    data.plugins = data.plugins or {}

    local Matcher = (pcall(require, "core/storify_matcher") and require("core/storify_matcher"))
        or (pcall(require, "storify_matcher") and require("storify_matcher")) or nil

    for _, plugin in ipairs(scanned_plugins) do
        local key = plugin.id or plugin.dirname or plugin.name
        if key and key ~= "" then
            local existing = data.plugins[key]
                or (plugin.dirname and data.plugins[plugin.dirname])
                or (plugin.name and data.plugins[plugin.name])

            if existing then
                if plugin.version and plugin.version ~= "" then
                    existing.version = plugin.version
                end
                if plugin.dir_path then
                    existing.dir_path = plugin.dir_path
                    existing.install_path = plugin.dir_path
                end
                if plugin.dirname then
                    existing.dirname = plugin.dirname
                end
                if plugin.name and not existing.name then
                    existing.name = plugin.name
                end
                if existing.unlinked or (not existing.repo_full_name and not existing.repo and not existing.repo_name) then
                    local matched = Matcher and Matcher.findMatchingRepo and Matcher.findMatchingRepo(plugin, cached_repos)
                    if matched then
                        existing.repo = matched.full_name or (matched.owner and matched.name and (matched.owner .. "/" .. matched.name))
                        existing.repo_owner = matched.owner
                        existing.repo_name = matched.name
                        existing.repo_full_name = matched.full_name or existing.repo
                        existing.unlinked = nil
                    end
                end
                data.plugins[key] = existing
            else
                local matched = Matcher and Matcher.findMatchingRepo and Matcher.findMatchingRepo(plugin, cached_repos)
                local rec = {
                    id = key,
                    name = plugin.name or key,
                    fullname = plugin.fullname or plugin.name or key,
                    dirname = plugin.dirname or key,
                    dir_path = plugin.dir_path,
                    install_path = plugin.dir_path,
                    version = plugin.version or "unknown",
                    description = plugin.description or "",
                    side_loaded = true,
                    installed_at = os.time(),
                }
                if matched then
                    rec.repo = matched.full_name or (matched.owner and matched.name and (matched.owner .. "/" .. matched.name))
                    rec.repo_owner = matched.owner
                    rec.repo_name = matched.name
                    rec.repo_full_name = matched.full_name or rec.repo
                    rec.unlinked = nil
                else
                    rec.unlinked = true
                end
                data.plugins[key] = rec
            end
        end
    end

    local saved = writeStore(data)
    return saved, data.plugins
end

return InstallStore
