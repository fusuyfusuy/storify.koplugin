-- tests/storify_matcher_test.lua
-- Unit tests for core/storify_matcher.lua

local Matcher = require("storify_matcher")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

local function assert_true(cond, msg)
    if not cond then
        error(msg or "expected true, got false/nil", 2)
    end
end

local function assert_false(cond, msg)
    if cond then
        error(msg or "expected false, got true", 2)
    end
end

print("--> [storify_matcher_test] Starting test suite...")

-- 1. normalizeIdentifier
do
    assert_eq(Matcher.normalizeIdentifier("koreader-plugin-coverimage"), "coverimage", "Strip koreader-plugin- prefix")
    assert_eq(Matcher.normalizeIdentifier("koreader-coverimage"), "coverimage", "Strip koreader- prefix")
    assert_eq(Matcher.normalizeIdentifier("coverimage.koplugin"), "coverimage", "Strip .koplugin suffix")
    assert_eq(Matcher.normalizeIdentifier("plugin-wallpapers"), "wallpapers", "Strip plugin- prefix")
    assert_eq(Matcher.normalizeIdentifier("My_Special_Plugin.koplugin"), "my-special-plugin", "Normalize underscore and case")
    assert_eq(Matcher.normalizeIdentifier(nil), "", "Nil returns empty string")
end

-- 2. findMatchingRepo
do
    local repos = {
        { id = 1, name = "koreader-plugin-calibre", owner = "koreader", full_name = "koreader/koreader-plugin-calibre" },
        { id = 2, name = "wallpapers.koplugin", owner = "author2", full_name = "author2/wallpapers.koplugin" },
        { id = 3, name = "coverimage", owner = "author3", full_name = "author3/coverimage" },
    }

    -- Match by exact dirname
    local p1 = { dirname = "wallpapers.koplugin", name = "Wallpapers" }
    local m1 = Matcher.findMatchingRepo(p1, repos)
    assert_true(m1 ~= nil, "Found match for wallpapers")
    assert_eq(m1.id, 2, "Matched repo id 2")

    -- Match by normalized prefix/suffix
    local p2 = { dirname = "calibre.koplugin", name = "Calibre" }
    local m2 = Matcher.findMatchingRepo(p2, repos)
    assert_true(m2 ~= nil, "Found match for calibre")
    assert_eq(m2.id, 1, "Matched koreader-plugin-calibre")

    -- Match by installed record owner/repo
    local p3 = { dirname = "custom_cover.koplugin", record = { owner = "author3", repo = "coverimage" } }
    local m3 = Matcher.findMatchingRepo(p3, repos)
    assert_true(m3 ~= nil, "Found match for owner/repo record")
    assert_eq(m3.id, 3, "Matched coverimage repo")

    -- Non matching
    local p4 = { dirname = "unknown.koplugin", name = "Unknown" }
    local m4 = Matcher.findMatchingRepo(p4, repos)
    assert_eq(m4, nil, "Unknown plugin returns nil")
end

-- 3. isUpdateAvailable
do
    -- Case A: Semver update available
    local local_p = { dirname = "coverimage.koplugin", version = "1.2.0", latest_mtime = 1000 }
    local remote_r = { release_tag_name = "v1.3.0", release_published_at = 2000 }
    local has_update, reason = Matcher.isUpdateAvailable(local_p, remote_r)
    assert_true(has_update, "1.3.0 is update over 1.2.0")

    -- Case B: Up to date semver
    local local_p2 = { dirname = "coverimage.koplugin", version = "1.3.0", latest_mtime = 2000 }
    local remote_r2 = { release_tag_name = "v1.3.0", release_published_at = 2000 }
    local has_update2 = Matcher.isUpdateAvailable(local_p2, remote_r2)
    assert_false(has_update2, "1.3.0 is not update over 1.3.0")

    -- Case C: Ignored version tag
    local has_update3 = Matcher.isUpdateAvailable(local_p, remote_r, "v1.3.0")
    assert_false(has_update3, "Ignored version suppresses update")

    -- Case D: Date based update
    local local_p4 = { dirname = "wallpapers.koplugin", version = "2026.01.01", latest_mtime = 1000 }
    local remote_r4 = { release_tag_name = "v2026.08.18", release_published_at = 2000 }
    local has_update4 = Matcher.isUpdateAvailable(local_p4, remote_r4)
    assert_true(has_update4, "Date update available")

    -- Case E: Timestamp based update when no version in local plugin
    local local_p5 = { dirname = "custom.koplugin", version = nil, latest_mtime = 1500 }
    local remote_r5 = { release_tag_name = nil, release_published_at = 2000, remote_repo_ts = 2000 }
    local has_update5 = Matcher.isUpdateAvailable(local_p5, remote_r5)
    assert_true(has_update5, "Timestamp update available when no local version")
end

-- 4. reconcileUpdates
do
    local installed = {
        { dirname = "plugin1.koplugin", name = "Plugin One", version = "1.0.0", latest_mtime = 100 },
        { dirname = "plugin2.koplugin", name = "Plugin Two", version = "2.0.0", latest_mtime = 200 },
        { dirname = "plugin3.koplugin", name = "Plugin Three", version = "1.0.0", latest_mtime = 300 },
    }
    local remote_info_map = {
        ["plugin1.koplugin"] = { release_tag_name = "v1.1.0", release_published_at = 500 },
        ["plugin2.koplugin"] = { release_tag_name = "v2.0.0", release_published_at = 200 },
        ["plugin3.koplugin"] = { release_tag_name = "v1.5.0", release_published_at = 600 },
    }
    local ignored_map = {
        ["plugin3.koplugin"] = "v1.5.0",
    }

    local reconciled = Matcher.reconcileUpdates(installed, remote_info_map, ignored_map)
    assert_eq(reconciled.total_count, 3, "Total installed count")
    assert_eq(reconciled.updates_count, 1, "Only plugin1 has unignored update (plugin3 is ignored)")
    assert_eq(#reconciled.items, 3, "All items returned in reconciliation")

    assert_true(reconciled.items[1].has_update, "plugin1 has update")
    assert_false(reconciled.items[2].has_update, "plugin2 is up to date")
    assert_false(reconciled.items[3].has_update, "plugin3 update was ignored")
end

print("✓ [storify_matcher_test] All matcher tests passed successfully.")
return true
