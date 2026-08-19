-- tests/storify_scan_test.lua
-- Test suite for Disk Discovery & Update Management for Side-Loaded Plugins

local Manifest = require("core/storify_manifest")
local Matcher = require("core/storify_matcher")
local Installs = require("data/storify_installs")

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

print("--> [Test Suite] storify_scan_test")

-- Create isolated sandbox directory on disk for testing
local tmp_test_dir = "/tmp/storify_scan_test_" .. tostring(os.time())
os.execute(string.format("mkdir -p %q", tmp_test_dir))
local dir_a = tmp_test_dir .. "/lookup_a"
local dir_b = tmp_test_dir .. "/lookup_b"
os.execute(string.format("mkdir -p %q %q", dir_a, dir_b))

-- Helper to cleanup test dir on exit
local function cleanup()
    os.execute(string.format("rm -rf %q", tmp_test_dir))
end

-- =========================================================================
-- 1. Testing Manifest Version Extraction & Plugin Directory Inspection
-- =========================================================================
print("\n--- 1. Testing Manifest: extractVersionFromMain & inspectPluginDirectory ---")

do
    -- Create dummy plugin with _meta.lua
    local plug1_dir = dir_a .. "/sample.koplugin"
    os.execute(string.format("mkdir -p %q", plug1_dir))
    local f1 = io.open(plug1_dir .. "/_meta.lua", "w")
    f1:write([[
        return {
            name = "sample",
            fullname = "Sample Plugin",
            version = "1.2.3",
            description = "A sample plugin for testing.",
        }
    ]])
    f1:close()

    local info1 = Manifest.inspectPluginDirectory(plug1_dir)
    assert_true(info1 ~= nil, "inspectPluginDirectory returned info table")
    assert_eq(info1.name, "sample", "Plugin name matched")
    assert_eq(info1.fullname, "Sample Plugin", "Plugin fullname matched")
    assert_eq(info1.version, "1.2.3", "Plugin version matched from _meta.lua")
    assert_eq(info1.description, "A sample plugin for testing.", "Plugin description matched")
    assert_eq(info1.dir_path, plug1_dir, "Plugin dir_path matched")
    assert_eq(info1.id, "sample", "Plugin id matched")

    -- Create dummy plugin without _meta.lua, but with main.lua defining version = "2.4.0"
    local plug2_dir = dir_a .. "/fallback_ver.koplugin"
    os.execute(string.format("mkdir -p %q", plug2_dir))
    local f2 = io.open(plug2_dir .. "/main.lua", "w")
    f2:write([[
        local Widget = require("ui/widget/widget")
        local FallbackPlugin = Widget:extend{
            name = "fallback_ver",
            version = "2.4.0",
        }
        return FallbackPlugin
    ]])
    f2:close()

    local v_extracted = Manifest.extractVersionFromMain(plug2_dir .. "/main.lua")
    assert_eq(v_extracted, "2.4.0", "extractVersionFromMain correctly extracted version")

    local info2 = Manifest.inspectPluginDirectory(plug2_dir)
    assert_true(info2 ~= nil, "inspectPluginDirectory returned info for fallback plugin")
    assert_eq(info2.version, "2.4.0", "inspectPluginDirectory fell back to main.lua version")
    assert_eq(info2.name, "fallback_ver", "inspectPluginDirectory derived name from directory")

    -- Test uppercase VERSION = '3.0.1' extraction
    local plug3_dir = dir_a .. "/upper_ver.koplugin"
    os.execute(string.format("mkdir -p %q", plug3_dir))
    local f3 = io.open(plug3_dir .. "/main.lua", "w")
    f3:write([[
        local VERSION = '3.0.1'
        return { version = VERSION }
    ]])
    f3:close()

    local v3_extracted = Manifest.extractVersionFromMain(plug3_dir .. "/main.lua")
    assert_eq(v3_extracted, "3.0.1", "extractVersionFromMain extracted single-quoted uppercase VERSION")

    -- Non-existent directory returns nil
    local info_nil = Manifest.inspectPluginDirectory(dir_a .. "/nonexistent.koplugin")
    assert_true(info_nil == nil, "Nonexistent plugin directory returns nil")
end

-- =========================================================================
-- 2. Testing Matcher: scanInstalledPlugins
-- =========================================================================
print("\n--- 2. Testing Matcher: scanInstalledPlugins ---")

do
    -- Create hidden directory (should be ignored)
    local hidden_dir = dir_a .. "/.hidden_plugin.koplugin"
    os.execute(string.format("mkdir -p %q", hidden_dir))

    -- Create non-plugin directory (should be ignored)
    local non_plugin = dir_a .. "/some_other_folder"
    os.execute(string.format("mkdir -p %q", non_plugin))

    -- Create symlink in dir_b pointing to sample.koplugin in dir_a (should be deduplicated)
    local symlink_plug = dir_b .. "/sample_symlink.koplugin"
    os.execute(string.format("ln -s %q %q", dir_a .. "/sample.koplugin", symlink_plug))

    -- Create distinct plugin in dir_b
    local plug_b = dir_b .. "/unique_b.koplugin"
    os.execute(string.format("mkdir -p %q", plug_b))
    local fb = io.open(plug_b .. "/_meta.lua", "w")
    fb:write([[
        return {
            name = "unique_b",
            version = "0.9.0",
        }
    ]])
    fb:close()

    local scanned = Matcher.scanInstalledPlugins({ dir_a, dir_b })
    assert_true(type(scanned) == "table", "Scanned result is a table")

    local scanned_by_id = {}
    for _, p in ipairs(scanned) do
        scanned_by_id[p.name or p.id] = p
    end

    assert_true(scanned_by_id["sample"] ~= nil, "Found sample plugin")
    assert_true(scanned_by_id["fallback_ver"] ~= nil, "Found fallback_ver plugin")
    assert_true(scanned_by_id["unique_b"] ~= nil, "Found unique_b plugin")
    assert_false(scanned_by_id[".hidden_plugin"], "Ignored hidden plugin")
    assert_false(scanned_by_id["some_other_folder"], "Ignored non-koplugin folder")

    -- Verify deduplication of symlink: only one instance of sample plugin scanned
    local sample_count = 0
    for _, p in ipairs(scanned) do
        if p.name == "sample" or p.id == "sample" then
            sample_count = sample_count + 1
        end
    end
    assert_eq(sample_count, 1, "Symlinked duplicate plugin was deduplicated")
end

-- =========================================================================
-- 3. Testing Matcher: linkScannedPlugins
-- =========================================================================
print("\n--- 3. Testing Matcher: linkScannedPlugins ---")

do
    local scanned = {
        {
            id = "sample",
            name = "sample",
            fullname = "Sample Plugin",
            version = "1.2.3",
            dirname = "sample.koplugin",
            dir_path = dir_a .. "/sample.koplugin",
        },
        {
            id = "sideloaded_unknown",
            name = "sideloaded_unknown",
            version = "0.1.0",
            dirname = "sideloaded_unknown.koplugin",
            dir_path = dir_a .. "/sideloaded_unknown.koplugin",
        },
        {
            id = "already_tracked",
            name = "already_tracked",
            version = "2.0.0",
            dirname = "already_tracked.koplugin",
            dir_path = dir_a .. "/already_tracked.koplugin",
        },
    }

    local cached_repos = {
        {
            name = "sample",
            owner = "koreader-dev",
            full_name = "koreader-dev/sample",
            latest_tag = "v1.3.0",
        },
        {
            name = "some_other_repo",
            owner = "author",
            full_name = "author/some_other_repo",
        },
    }

    local existing_installs = {
        ["already_tracked.koplugin"] = {
            id = "already_tracked",
            name = "already_tracked",
            repo_owner = "upstream",
            repo_name = "already_tracked",
            repo_full_name = "upstream/already_tracked",
            version = "1.9.0",
        },
    }

    local linked, unlinked = Matcher.linkScannedPlugins(scanned, cached_repos, existing_installs)

    assert_true(type(linked) == "table", "Linked result is a table")
    assert_true(type(unlinked) == "table", "Unlinked result is a table")

    -- 'sample' matched cached repo 'koreader-dev/sample'
    local sample_linked = linked["sample"] or linked["sample.koplugin"]
    assert_true(sample_linked ~= nil, "Auto-linked 'sample' to catalog")
    assert_eq(sample_linked.repo.full_name, "koreader-dev/sample", "Linked to correct repo")

    -- 'already_tracked' preserved existing install mapping
    local tracked_linked = linked["already_tracked"] or linked["already_tracked.koplugin"]
    assert_true(tracked_linked ~= nil, "Retained link for 'already_tracked'")

    -- 'sideloaded_unknown' has no catalog match -> unlinked
    local unknown_unlinked = unlinked["sideloaded_unknown"] or unlinked["sideloaded_unknown.koplugin"]
    assert_true(unknown_unlinked ~= nil, "Marked 'sideloaded_unknown' as unlinked")
end

-- =========================================================================
-- 4. Testing Installs: syncFromDisk
-- =========================================================================
print("\n--- 4. Testing Installs: syncFromDisk ---")

do
    Installs.clear()
    local initial_gen = Installs.getGeneration()

    local scanned = {
        {
            id = "sample.koplugin",
            name = "sample",
            fullname = "Sample Plugin",
            version = "1.2.3",
            dirname = "sample.koplugin",
            dir_path = dir_a .. "/sample.koplugin",
        },
        {
            id = "custom_sideload.koplugin",
            name = "custom_sideload",
            version = "0.0.1",
            dirname = "custom_sideload.koplugin",
            dir_path = dir_a .. "/custom_sideload.koplugin",
        },
    }

    local cached_repos = {
        {
            name = "sample",
            owner = "koreader-dev",
            full_name = "koreader-dev/sample",
            latest_tag = "v1.3.0",
        },
    }

    local ok, res = Installs.syncFromDisk(scanned, cached_repos)
    assert_true(ok == true, "syncFromDisk succeeded")
    assert_true(Installs.getGeneration() > initial_gen, "Generation incremented after sync")

    local list = Installs.list()
    local sample_inst = list["sample.koplugin"] or list["sample"]
    assert_true(sample_inst ~= nil, "sample.koplugin added to Installs")
    assert_eq(sample_inst.version, "1.2.3", "sample version saved")
    assert_eq(sample_inst.repo_full_name, "koreader-dev/sample", "sample repo_full_name linked")
    assert_eq(sample_inst.side_loaded, true, "marked as side_loaded")

    local custom_inst = list["custom_sideload.koplugin"] or list["custom_sideload"]
    assert_true(custom_inst ~= nil, "custom_sideload added to Installs")
    assert_eq(custom_inst.unlinked, true, "custom_sideload marked as unlinked")
    assert_eq(custom_inst.side_loaded, true, "custom_sideload marked as side_loaded")
end

-- =========================================================================
-- 5. Testing Dialogs: showManualLinkDialog
-- =========================================================================
print("\n--- 5. Testing Dialogs: showManualLinkDialog ---")

do
    local Dialogs = require("ui/storify_dialogs")
    local linked_full_name = nil
    local link_item = {
        id = "sample.koplugin",
        name = "sample",
        dirname = "sample.koplugin",
    }
    local cached_repos = {
        { name = "sample", owner = "koreader-dev", full_name = "koreader-dev/sample" },
    }

    local dlg = Dialogs.showManualLinkDialog(link_item, cached_repos, {
        on_link = function(full_name)
            linked_full_name = full_name
        end,
    })

    assert_true(dlg ~= nil, "showManualLinkDialog instantiated dialog")
    assert_true(dlg.buttons ~= nil and #dlg.buttons > 0, "dialog has action buttons")

    -- Test candidate link button callback
    local candidate_button = dlg.buttons[1] and dlg.buttons[1][1]
    assert_true(candidate_button ~= nil, "First button exists")
    if candidate_button and candidate_button.callback then
        candidate_button.callback()
        assert_eq(linked_full_name, "koreader-dev/sample", "on_link called with candidate repo")
    end
end

-- =========================================================================
-- 6. Testing main.lua Storify scanDiskPlugins & handleManualLink
-- =========================================================================
print("\n--- 6. Testing main.lua Storify Lifecycle ---")

do
    local Storify = require("main")
    local app = Storify:new()

    local scan_completed = false
    app:scanDiskPlugins(function(scanned)
        scan_completed = true
        assert_true(type(scanned) == "table", "scanDiskPlugins returned scanned list")
    end)
    assert_true(scan_completed, "scanDiskPlugins executed on_complete")

    -- Test handleManualLink
    local unlinked_item = {
        id = "manual_link_test.koplugin",
        name = "manual_link_test",
        dirname = "manual_link_test.koplugin",
        version = "1.0.0",
    }
    app:handleManualLink(unlinked_item)
end

cleanup()
print("\n🎉 [storify_scan_test] ALL TESTS PASSED!")
