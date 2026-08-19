local socket_url = require("socket.url")

local function getSettings()
    local ok, s = pcall(require, "storify_settings")
    if ok and s then return s end
    ok, s = pcall(require, "data/storify_settings")
    if ok and s then return s end
    return {
        readSetting = function() end,
        saveSetting = function() end,
        flush = function() end,
    }
end

local function getGettext()
    local ok, gt = pcall(require, "storify_gettext")
    if ok and gt then return gt end
    ok, gt = pcall(require, "l10n/storify_gettext")
    if ok and gt then return gt end
    return setmetatable({}, { __call = function(_, msg) return msg end })
end

local function getConfig()
    local ok, cfg = pcall(require, "storify_configuration")
    if ok and type(cfg) == "table" then return cfg end
    return {}
end

local SETTING_PRESET_KEY = "download_mirror_preset"
local SETTING_CUSTOM_URL_KEY = "download_mirror_custom_url"
-- Alongside each setting, a copy of what storify_configuration.lua held the
-- last time it was read. See syncFromConfig() at the bottom of this file.
local SETTING_PRESET_FROM_CONFIG_KEY = "download_mirror_preset_from_config"
local SETTING_CUSTOM_URL_FROM_CONFIG_KEY = "download_mirror_custom_url_from_config"

-- Only these hosts get the mirror prefix.
local MIRRORED_HOSTS = {
    ["github.com"] = true,
    ["www.github.com"] = true,
    ["api.github.com"] = true,
    ["codeload.github.com"] = true,
    ["raw.githubusercontent.com"] = true,
    ["objects.githubusercontent.com"] = true,
    ["gist.githubusercontent.com"] = true,
}

local _ = getGettext()

local PRESET_DEFS = {
    { id = "direct", name = _("Direct (GitHub)"), prefix = "" },
    { id = "gh_proxy_com", name = "gh-proxy.com", prefix = "https://gh-proxy.com/" },
    { id = "gh_ddlc_top", name = "gh.ddlc.top", prefix = "https://gh.ddlc.top/" },
    { id = "ghproxy_net", name = "ghproxy.net", prefix = "https://ghproxy.net/" },
    { id = "custom", name = _("Custom"), prefix = nil },
}

local Mirror = {}

local function findPreset(preset_id)
    for idx = 1, #PRESET_DEFS do
        local preset = PRESET_DEFS[idx]
        if preset.id == preset_id then
            return preset
        end
    end
end

function Mirror.normalizeCustomUrl(value)
    if type(value) ~= "string" then
        return nil
    end
    value = value:match("^%s*(.-)%s*$")
    if value == "" or value:find("%s") then
        return nil
    end

    local scheme, authority, path_and_more = value:match("^([a-zA-Z0-9+.-]+)://([^/?#]+)(.*)$")
    if not scheme or not authority or authority == "" then
        return nil
    end

    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then
        return nil
    end

    -- Reject query string, fragment, or embedded parameters
    if value:find("?") or value:find("#") then
        return nil
    end

    -- Reject user credentials
    if authority:find("@") then
        return nil
    end

    -- Parse host and port
    local host, port_str = authority:match("^([^:]+):?(%d*)$")
    if not host or host == "" then
        return nil
    end

    if port_str and port_str ~= "" then
        local port = tonumber(port_str)
        if not port or port < 1 or port > 65535 then
            return nil
        end
    elseif authority:find(":") then
        -- Has colon without valid digits
        return nil
    end

    -- Also check socket_url.parse if it is available and has rich fields
    local parsed = socket_url and socket_url.parse and socket_url.parse(value)
    if parsed then
        if parsed.user or parsed.password or parsed.query or parsed.fragment or parsed.params then
            return nil
        end
        if parsed.port then
            local port = tonumber(parsed.port)
            if not port or port < 1 or port > 65535 then
                return nil
            end
        end
    end

    if not value:match("/$") then
        value = value .. "/"
    end
    return value
end

function Mirror.getPresets()
    local list = {}
    for index = 1, #PRESET_DEFS do
        local item = PRESET_DEFS[index]
        table.insert(list, {
            id = item.id,
            name = item.name,
            prefix = item.prefix,
        })
    end
    return list
end

function Mirror.getCurrentPresetId()
    local StorifySettings = getSettings()
    local preset_id = StorifySettings:readSetting(SETTING_PRESET_KEY)
    if not preset_id or preset_id == "" or not findPreset(preset_id) then
        return "direct"
    end
    if preset_id == "custom" and Mirror.getCustomUrl() == "" then
        return "direct"
    end
    return preset_id
end

function Mirror.getCustomUrl()
    local StorifySettings = getSettings()
    return Mirror.normalizeCustomUrl(StorifySettings:readSetting(SETTING_CUSTOM_URL_KEY)) or ""
end

function Mirror.getCurrentPrefix()
    local current_id = Mirror.getCurrentPresetId()
    if current_id == "custom" then
        return Mirror.getCustomUrl()
    end
    local preset = findPreset(current_id)
    return preset and preset.prefix or ""
end

function Mirror.getCurrentLabel()
    local current_id = Mirror.getCurrentPresetId()
    local _ = getGettext()
    if current_id == "custom" then
        local custom_url = Mirror.getCustomUrl()
        return string.format(_("Custom (%s)"), custom_url)
    end
    local preset = findPreset(current_id) or PRESET_DEFS[1]
    return preset.name
end

function Mirror.setPreset(preset_id, custom_url)
    if not findPreset(preset_id) then
        return false, "unknown preset"
    end
    local StorifySettings = getSettings()
    if preset_id == "custom" then
        custom_url = Mirror.normalizeCustomUrl(custom_url or Mirror.getCustomUrl())
        if not custom_url then
            return false, "invalid custom URL"
        end
        StorifySettings:saveSetting(SETTING_CUSTOM_URL_KEY, custom_url)
    end
    StorifySettings:saveSetting(SETTING_PRESET_KEY, preset_id)
    StorifySettings:flush()
    return true
end

--- True for a prefix that uses plain, unencrypted http.
function Mirror.isInsecurePrefix(prefix)
    return type(prefix) == "string" and prefix:lower():find("^http://") ~= nil
end

-- Host of an http(s) URL, without any port or userinfo, lowercased.
local function urlHost(url)
    local authority = url:match("^https?://([^/?#]+)")
    if not authority then
        return nil
    end
    return authority:gsub("^[^@]*@", ""):gsub(":%d+$", ""):lower()
end

function Mirror.apply(url)
    if not url or url == "" then
        return url
    end
    local prefix = Mirror.getCurrentPrefix()
    if not prefix or prefix == "" then
        return url
    end
    -- Avoid duplicate prefixing
    if url:sub(1, #prefix) == prefix then
        return url
    end
    if not MIRRORED_HOSTS[urlHost(url) or ""] then
        return url
    end
    -- Convert GitHub's API zipball URL to a form supported by download mirrors.
    local owner, repo_name, ref = url:match("^https://api%.github%.com/repos/([^/]+)/([^/]+)/zipball/?([^?#]*)$")
    if owner and repo_name then
        if ref == "" then
            ref = "HEAD"
        end
        url = string.format("https://github.com/%s/%s/archive/%s.zip", owner, repo_name, ref)
    end
    return prefix .. url
end

local function syncSettingFromConfig(config_value, setting_key, from_config_key, transform)
    local StorifySettings = getSettings()
    if config_value == StorifySettings:readSetting(from_config_key) then
        return false
    end
    StorifySettings:saveSetting(from_config_key, config_value)
    if config_value ~= nil and transform then
        config_value = transform(config_value)
    end
    StorifySettings:saveSetting(setting_key, config_value)
    return true
end

local function syncFromConfig()
    local StorifyConfig = getConfig()
    local config_preset = StorifyConfig.download_mirror_preset
    if not config_preset and StorifyConfig.download_mirror_prefix then
        config_preset = "custom"
    end
    local changed = syncSettingFromConfig(config_preset, SETTING_PRESET_KEY,
        SETTING_PRESET_FROM_CONFIG_KEY)
    changed = syncSettingFromConfig(StorifyConfig.download_mirror_prefix, SETTING_CUSTOM_URL_KEY,
        SETTING_CUSTOM_URL_FROM_CONFIG_KEY, Mirror.normalizeCustomUrl) or changed
    if changed then
        local StorifySettings = getSettings()
        StorifySettings:flush()
    end
end

syncFromConfig()

return Mirror
