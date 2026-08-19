-- tests/storify_mirror_test.lua
-- Unit tests for storify_mirror.lua

local store = {}
local mock_settings = {
    readSetting = function(_, key) return store[key] end,
    saveSetting = function(_, key, value) store[key] = value end,
    flush = function() end,
}
package.loaded["storify_settings"] = mock_settings
package.loaded["data/storify_settings"] = mock_settings
package.preload["storify_settings"] = function() return mock_settings end
package.preload["data/storify_settings"] = function() return mock_settings end

package.preload["storify_gettext"] = function()
    return setmetatable({}, { __call = function(_, msgid) return msgid end })
end
package.preload["l10n/storify_gettext"] = package.preload["storify_gettext"]

local config = {}
package.loaded["storify_configuration"] = config
package.preload["storify_configuration"] = function() return config end

package.loaded["storify_mirror"] = nil
package.loaded["net/storify_mirror"] = nil
local Mirror = require("storify_mirror")

local failures = 0
local function check(label, got, expected)
    if got == expected then
        print(string.format("  ✓ PASS: %s", label))
    else
        failures = failures + 1
        print(string.format("  ❌ FAIL: %s | expected: %s, got: %s", label, tostring(expected), tostring(got)))
    end
end

local function restart()
    package.loaded["storify_mirror"] = nil
    package.loaded["net/storify_mirror"] = nil
    package.loaded["storify_configuration"] = config
    package.loaded["storify_settings"] = mock_settings
    package.loaded["data/storify_settings"] = mock_settings
    Mirror = require("storify_mirror")
end

print("\n--- Testing storify_mirror: Custom URL Normalization ---")
check("trailing slash added", Mirror.normalizeCustomUrl("https://gh-proxy.com"), "https://gh-proxy.com/")
check("http accepted (self-hosted mirrors)", Mirror.normalizeCustomUrl("http://192.168.1.10:8080/"), "http://192.168.1.10:8080/")
check("whitespace trimmed", Mirror.normalizeCustomUrl("  https://x.dev/  "), "https://x.dev/")
check("scheme required", Mirror.normalizeCustomUrl("gh-proxy.com"), nil)
check("only http(s)", Mirror.normalizeCustomUrl("ftp://x.dev/"), nil)
check("query string rejected", Mirror.normalizeCustomUrl("https://x.dev/?url="), nil)
check("credentials rejected", Mirror.normalizeCustomUrl("https://u:p@x.dev/"), nil)
check("out-of-range port rejected", Mirror.normalizeCustomUrl("https://x.dev:99999/"), nil)
check("empty rejected", Mirror.normalizeCustomUrl(""), nil)
check("non-string rejected", Mirror.normalizeCustomUrl(42), nil)

print("\n--- Testing storify_mirror: Security Flags ---")
check("http is flagged insecure", Mirror.isInsecurePrefix("http://x.dev/"), true)
check("https is not flagged insecure", Mirror.isInsecurePrefix("https://x.dev/"), false)

print("\n--- Testing storify_mirror: Direct Default Behavior ---")
local RAW = "https://raw.githubusercontent.com/o/r/HEAD/README.md"
local ZIPBALL = "https://api.github.com/repos/o/r/zipball"
check("default preset is direct", Mirror.getCurrentPresetId(), "direct")
check("direct leaves raw URLs alone", Mirror.apply(RAW), RAW)
check("direct leaves zipball alone", Mirror.apply(ZIPBALL), ZIPBALL)

print("\n--- Testing storify_mirror: Prefixing & Transformations ---")
check("custom preset stored", Mirror.setPreset("custom", "https://mirror.test/"), true)
check("custom preset active", Mirror.getCurrentPresetId(), "custom")
check("raw URL prefixed", Mirror.apply(RAW), "https://mirror.test/" .. RAW)
check("zipball rewritten to archive", Mirror.apply(ZIPBALL),
    "https://mirror.test/https://github.com/o/r/archive/HEAD.zip")
check("zipball ref preserved", Mirror.apply("https://api.github.com/repos/o/r/zipball/v1.2.3"),
    "https://mirror.test/https://github.com/o/r/archive/v1.2.3.zip")
check("release asset prefixed", Mirror.apply("https://github.com/o/r/releases/download/v1/a.zip"),
    "https://mirror.test/https://github.com/o/r/releases/download/v1/a.zip")
check("already-prefixed URL left as is", Mirror.apply("https://mirror.test/" .. RAW),
    "https://mirror.test/" .. RAW)
check("nil passes through", Mirror.apply(nil), nil)
check("empty string passes through", Mirror.apply(""), "")

print("\n--- Testing storify_mirror: Host Allowlist ---")
check("foreign host untouched", Mirror.apply("https://example.com/x.zip"), "https://example.com/x.zip")
check("lookalike host untouched", Mirror.apply("https://github.com.evil.tld/x.zip"),
    "https://github.com.evil.tld/x.zip")
check("host match is case-insensitive", Mirror.apply("https://RAW.githubusercontent.com/o/r/HEAD/a"),
    "https://mirror.test/https://RAW.githubusercontent.com/o/r/HEAD/a")

print("\n--- Testing storify_mirror: Input Validation ---")
check("junk custom URL refused", Mirror.setPreset("custom", "not a url"), false)
check("unknown preset id refused", Mirror.setPreset("nope"), false)
store.download_mirror_custom_url = "garbage"
check("unusable stored URL falls back to direct", Mirror.getCurrentPresetId(), "direct")
check("fallback means no prefixing", Mirror.apply(RAW), RAW)

print("\n--- Testing storify_mirror: Built-in Presets ---")
store.download_mirror_custom_url = nil
check("preset selected", Mirror.setPreset("gh_proxy_com"), true)
check("preset prefix applied", Mirror.apply(RAW), "https://gh-proxy.com/" .. RAW)
check("preset label", Mirror.getCurrentLabel(), "gh-proxy.com")
check("back to direct", Mirror.setPreset("direct"), true)
check("direct again", Mirror.apply(RAW), RAW)

local preset_list = Mirror.getPresets()
check("preset list contains presets", #preset_list >= 5, true)

print("\n--- Testing storify_mirror: Config File vs UI Precedence ---")
store, config = {}, {}
restart()
check("no config, no setting -> direct", Mirror.getCurrentPresetId(), "direct")
check("absent config writes nothing", next(store), nil)

Mirror.setPreset("ghproxy_net")
restart()
check("UI choice survives a restart", Mirror.getCurrentPresetId(), "ghproxy_net")

store, config = {}, { download_mirror_preset = "gh_proxy_com" }
restart()
check("config applies when first seen", Mirror.getCurrentPresetId(), "gh_proxy_com")

Mirror.setPreset("direct")
restart()
check("UI overrides an unchanged config", Mirror.getCurrentPresetId(), "direct")

config = { download_mirror_preset = "gh_ddlc_top" }
restart()
check("edited config wins again", Mirror.getCurrentPresetId(), "gh_ddlc_top")

config = {}
restart()
check("removed config restores the default", Mirror.getCurrentPresetId(), "direct")
restart()
check("removal is not re-applied", Mirror.getCurrentPresetId(), "direct")

store, config = {}, { download_mirror_prefix = "https://cfg.test" }
restart()
check("bare prefix implies the custom preset", Mirror.getCurrentPresetId(), "custom")
check("config prefix normalized on the way in", Mirror.getCustomUrl(), "https://cfg.test/")
check("config prefix used", Mirror.apply(RAW), "https://cfg.test/" .. RAW)

Mirror.setPreset("custom", "https://ui.test/")
restart()
check("UI prefix overrides an unchanged config", Mirror.getCustomUrl(), "https://ui.test/")

config = { download_mirror_prefix = "not a url" }
restart()
check("unusable config prefix clears the setting", Mirror.getCustomUrl(), "")
check("unusable config prefix -> direct", Mirror.getCurrentPresetId(), "direct")
Mirror.setPreset("custom", "https://ui2.test/")
restart()
check("unusable config prefix not re-applied", Mirror.getCustomUrl(), "https://ui2.test/")

if failures > 0 then
    error(string.format("%d test(s) failed in storify_mirror_test.lua", failures))
end
