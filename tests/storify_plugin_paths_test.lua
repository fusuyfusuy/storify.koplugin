-- tests/storify_plugin_paths_test.lua
-- Unit tests for storify_plugin_paths

local ffi = require("ffi")

-- Ensure accurate lfs attributes in test environment using stat FFI
local ok_stat, _ = pcall(ffi.cdef, [[
    typedef struct stat_test_s {
        unsigned long st_dev;
        unsigned long st_ino;
        unsigned long st_nlink;
        unsigned int st_mode;
        unsigned int st_uid;
        unsigned int st_gid;
        unsigned int __pad0;
        unsigned long st_rdev;
        long st_size;
        long st_blksize;
        long st_blocks;
        long st_atime;
        unsigned long st_atime_nsec;
        long st_mtime;
        unsigned long st_mtime_nsec;
        long st_ctime;
        unsigned long st_ctime_nsec;
        long __unused[3];
    } stat_test_t;
    int stat(const char *pathname, stat_test_t *buf);
]])

local mock_lfs = {
    attributes = function(filepath, req)
        if not filepath then return nil end
        if filepath == "plugins" then
            local attr = { mode = "directory", size = 4096, modification = os.time() }
            if req then return attr[req] end
            return attr
        end
        local buf = ffi.new("stat_test_t")
        local res = ffi.C.stat(filepath, buf)
        if res ~= 0 then return nil end
        local is_dir = bit.band(buf.st_mode, 0xF000) == 0x4000
        local is_file = bit.band(buf.st_mode, 0xF000) == 0x8000
        local mode_str = is_dir and "directory" or (is_file and "file" or "other")
        local attr = {
            mode = mode_str,
            size = tonumber(buf.st_size),
            modification = tonumber(buf.st_mtime),
        }
        if req then return attr[req] end
        return attr
    end,
    dir = function(dirpath)
        local p = io.popen(string.format("ls -a %q 2>/dev/null", dirpath))
        if not p then return function() return nil end end
        local lines = {}
        for l in p:lines() do table.insert(lines, l) end
        p:close()
        local i = 0
        return function()
            i = i + 1
            return lines[i]
        end
    end,
    mkdir = function(dirpath)
        return os.execute(string.format("mkdir -p %q", dirpath)) ~= nil
    end,
    rmdir = function(dirpath)
        return os.execute(string.format("rmdir %q 2>/dev/null", dirpath)) ~= nil
    end,
}

package.preload["lfs"] = function() return mock_lfs end
package.preload["libs/libkoreader-lfs"] = function() return mock_lfs end
package.loaded["lfs"] = mock_lfs
package.loaded["libs/libkoreader-lfs"] = mock_lfs

local scratch = "/tmp/storify_plugin_paths_test_" .. tostring(os.time())
os.execute("rm -rf " .. scratch .. " && mkdir -p " .. scratch .. "/custom_a " .. scratch .. "/custom_b")

local failures = 0
local total_checks = 0

local function check(label, got, expected)
    total_checks = total_checks + 1
    local ok
    if type(expected) == "table" then
        ok = type(got) == "table" and #got == #expected
        if ok then
            for i = 1, #expected do
                if got[i] ~= expected[i] then ok = false end
            end
        end
    else
        ok = got == expected
    end
    if ok then
        print("  ✓ PASS: " .. label)
    else
        failures = failures + 1
        print(string.format("  ❌ FAIL: %s | expected: %s | got: %s", label, tostring(expected), tostring(got)))
    end
end

local function freshModule()
    package.loaded["storify_plugin_paths"] = nil
    package.loaded["data.storify_plugin_paths"] = nil
    return require("storify_plugin_paths")
end

print("--> [Test Suite] storify_plugin_paths")

-- Scenario 1: no extra_plugin_paths configured at all.
G_reader_settings = { readSetting = function() return nil end }
local M = freshModule()
check("no extra paths -> lookup is just 'plugins'", M.getLookupPaths(), { "plugins" })
check("no extra paths -> no custom paths", #M.getCustomLookupPaths(), 0)
local dest, prompt = M.resolveInstallDestination(nil, nil)
check("no custom paths -> falls back to default root", dest, M.getDefaultPluginsRoot())
check("no custom paths -> no prompt needed", prompt, false)

-- Scenario 1b: extra_plugin_paths set to auto-populated default (with trailing slash).
G_reader_settings = { readSetting = function() return nil end }
local M_temp = freshModule()
local default_root = M_temp.getDefaultPluginsRoot()
G_reader_settings = { readSetting = function() return { default_root .. "/" } end }
M = freshModule()
check("auto-populated default with trailing slash -> no custom paths", #M.getCustomLookupPaths(), 0)
dest, prompt = M.resolveInstallDestination(nil, nil)
check("auto-populated default -> falls back to default root", dest, M.getDefaultPluginsRoot())
check("auto-populated default -> no prompt needed", prompt, false)

-- Scenario 2: a single custom extra_plugin_paths entry.
G_reader_settings = { readSetting = function() return scratch .. "/custom_a" end }
M = freshModule()
check("single custom path (string) -> included in lookup", M.getLookupPaths(), { "plugins", scratch .. "/custom_a" })
check("single custom path -> exactly one custom path", #M.getCustomLookupPaths(), 1)
dest, prompt = M.resolveInstallDestination(nil, nil)
check("single custom path -> installs there with no prompt", dest, scratch .. "/custom_a")
check("single custom path -> no prompt needed", prompt, false)

-- Scenario 3: a nonexistent directory in extra_plugin_paths is skipped.
G_reader_settings = { readSetting = function() return scratch .. "/does_not_exist" end }
M = freshModule()
check("nonexistent extra path is skipped", M.getLookupPaths(), { "plugins" })

-- Scenario 4: two custom paths -> ambiguous, caller must prompt.
G_reader_settings = { readSetting = function() return { scratch .. "/custom_a", scratch .. "/custom_b" } end }
M = freshModule()
check("two custom paths -> two entries in custom list", #M.getCustomLookupPaths(), 2)
dest, prompt = M.resolveInstallDestination(nil, nil)
check("two custom paths, no override -> ambiguous", prompt, true)
check("two custom paths, no override -> no destination yet", dest, nil)

-- Scenario 5: config override picks a path directly, even when ambiguous.
dest, prompt = M.resolveInstallDestination(scratch .. "/custom_b", nil)
check("config override resolves ambiguity", dest, scratch .. "/custom_b")
check("config override -> no prompt", prompt, false)

-- Scenario 6: an override that isn't a real lookup path is ignored.
dest, prompt = M.resolveInstallDestination("/not/a/configured/path", nil)
check("invalid config override falls through to prompt", prompt, true)

-- Scenario 7: a remembered choice from a previous prompt short-circuits future ones.
dest, prompt = M.resolveInstallDestination(nil, scratch .. "/custom_a")
check("remembered choice resolves ambiguity", dest, scratch .. "/custom_a")
check("remembered choice -> no prompt", prompt, false)

-- Scenario 8: a stale remembered choice (no longer configured) is discarded.
G_reader_settings = { readSetting = function() return scratch .. "/custom_a" end }
M = freshModule()
dest, prompt = M.resolveInstallDestination(nil, scratch .. "/custom_b")
check("stale remembered choice falls back to single custom path", dest, scratch .. "/custom_a")
check("stale remembered choice -> no prompt (single custom path remains)", prompt, false)

-- Scenario 9: aliasing dedup -- two different path strings resolving to the same real directory.
os.execute("mkdir -p " .. scratch .. "/real_dir")
os.execute("ln -sfn " .. scratch .. "/real_dir " .. scratch .. "/alias_link")
G_reader_settings = { readSetting = function()
    return { scratch .. "/real_dir", scratch .. "/alias_link" }
end }
M = freshModule()
check("aliased paths dedup to a single lookup entry", #M.getLookupPaths(), 2)

-- Scenario 10: differently formatted same-real-path remembered choice resolves without prompting.
G_reader_settings = { readSetting = function() return scratch .. "/real_dir" end }
M = freshModule()
local remembered = M.getLookupPaths()[2]
check("configured custom entry is present for scenario 10", remembered, scratch .. "/real_dir")
local differently_formatted = scratch .. "/real_dir/."
dest, prompt = M.resolveInstallDestination(nil, differently_formatted)
check("differently-formatted same-real-path remembered choice resolves", dest, differently_formatted)
check("differently-formatted same-real-path remembered choice -> no prompt", prompt, false)

-- Scenario 11: isPathHidden matching.
check("isPathHidden: nil hidden_paths -> not hidden", M.isPathHidden(scratch .. "/custom_a", nil), false)
check("isPathHidden: empty hidden_paths -> not hidden", M.isPathHidden(scratch .. "/custom_a", {}), false)
check("isPathHidden: exact match -> hidden", M.isPathHidden(scratch .. "/custom_a", { scratch .. "/custom_a" }), true)
check("isPathHidden: no match -> not hidden", M.isPathHidden(scratch .. "/custom_a", { scratch .. "/custom_b" }), false)
check("isPathHidden: realpath-equivalent match", M.isPathHidden(scratch .. "/real_dir", { scratch .. "/alias_link" }), true)

-- Scenario 12: single custom path, hidden -> all_hidden signal.
G_reader_settings = { readSetting = function() return scratch .. "/custom_a" end }
M = freshModule()
local candidates, all_hidden
dest, prompt, candidates, all_hidden = M.resolveInstallDestination(nil, nil, { scratch .. "/custom_a" })
check("single custom path, hidden -> all_hidden", all_hidden, true)
check("single custom path, hidden -> no destination", dest, nil)
check("single custom path, hidden -> no prompt", prompt, false)

-- Scenario 13: two custom paths, one hidden -> resolves to visible one.
G_reader_settings = { readSetting = function() return { scratch .. "/custom_a", scratch .. "/custom_b" } end }
M = freshModule()
dest, prompt, candidates, all_hidden = M.resolveInstallDestination(nil, nil, { scratch .. "/custom_a" })
check("two custom paths, one hidden -> resolves to the visible one", dest, scratch .. "/custom_b")
check("two custom paths, one hidden -> no prompt", prompt, false)
check("two custom paths, one hidden -> not all_hidden", all_hidden, false)

-- Scenario 14: two custom paths, both hidden -> all_hidden signal.
dest, prompt, candidates, all_hidden = M.resolveInstallDestination(nil, nil, { scratch .. "/custom_a", scratch .. "/custom_b" })
check("two custom paths, both hidden -> all_hidden", all_hidden, true)
check("two custom paths, both hidden -> no prompt", prompt, false)

-- Scenario 15: hidden config override falls through to visible path resolution.
dest, prompt, candidates, all_hidden = M.resolveInstallDestination(scratch .. "/custom_a", nil, { scratch .. "/custom_a" })
check("hidden config override falls through to visible-path resolution", dest, scratch .. "/custom_b")
check("hidden config override -> not all_hidden (one path still visible)", all_hidden, false)

-- Scenario 16: hidden remembered path falls through to visible path resolution.
dest, prompt, candidates, all_hidden = M.resolveInstallDestination(nil, scratch .. "/custom_b", { scratch .. "/custom_b" })
check("hidden remembered path falls through to visible-path resolution", dest, scratch .. "/custom_a")

-- Scenario 17: zero custom paths configured at all -> hidden_paths is ignored.
G_reader_settings = { readSetting = function() return nil end }
M = freshModule()
dest, prompt, candidates, all_hidden = M.resolveInstallDestination(nil, nil, { "/some/irrelevant/hidden/path" })
check("no custom paths at all -> unaffected by hidden_paths", dest, M.getDefaultPluginsRoot())
check("no custom paths at all -> not all_hidden", all_hidden, false)

os.execute("rm -rf " .. scratch)

if failures > 0 then
    error(string.format("%d of %d assertions failed in storify_plugin_paths_test", failures, total_checks))
end
print(string.format("All %d assertions passed in storify_plugin_paths_test", total_checks))
