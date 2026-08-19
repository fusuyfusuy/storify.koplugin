-- tests/storify_installer_test.lua
-- Unit tests for core/storify_installer.lua

local Installer = require("storify_installer")
local ffiUtil = require("ffiutil")
local lfs = require("lfs")

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

print("--> [storify_installer_test] Starting test suite...")

-- Mock Archive Reader Helper
local function createMockReader(files)
    local reader = {
        files = files,
        extracted_paths = {},
        _iter_index = 0,
    }

    function reader:iterate()
        self._iter_index = 0
        local keys = {}
        for path in pairs(self.files) do
            table.insert(keys, path)
        end
        table.sort(keys)
        local i = 0
        return function()
            i = i + 1
            local path = keys[i]
            if not path then return nil end
            local data = self.files[path]
            return {
                path = path,
                mode = type(data) == "table" and data.mode or "file",
            }
        end
    end

    function reader:extractToMemory(path)
        local f = self.files[path]
        if type(f) == "string" then return f end
        if type(f) == "table" then return f.content end
        return nil
    end

    function reader:extractToPath(entry_path, dest_path)
        local f = self.files[entry_path]
        if not f then return false end
        local content = type(f) == "string" and f or f.content
        if not content then return false end

        -- Create parent dir
        local parent = dest_path:match("^(.*)/[^/]+$")
        if parent and parent ~= "" then
            os.execute(string.format("mkdir -p %q", parent))
        end

        local fh = io.open(dest_path, "wb")
        if not fh then return false end
        fh:write(content)
        fh:close()
        table.insert(self.extracted_paths, dest_path)
        return true
    end

    function reader:rewind()
        self._iter_index = 0
    end

    return reader
end

-- 1. Path canonicalization and Zip Slip checks
do
    assert_eq(Installer.canonicalizePath("/a/b/../c"), "/a/c", "Canonicalize ..")
    assert_eq(Installer.canonicalizePath("/a/b/./c"), "/a/b/c", "Canonicalize .")
    assert_eq(Installer.canonicalizePath("a\\b\\c"), "a/b/c", "Canonicalize backslashes")

    assert_true(Installer.isSubPath("/plugins/myplugin", "/plugins/myplugin/main.lua"), "Child is subpath")
    assert_true(Installer.isSubPath("/plugins/myplugin", "/plugins/myplugin/subdir/file.lua"), "Nested is subpath")
    assert_false(Installer.isSubPath("/plugins/myplugin", "/plugins/myplugin_other/file.lua"), "Sibling is not subpath")
    assert_false(Installer.isSubPath("/plugins/myplugin", "/etc/passwd"), "Root escape is not subpath")
    assert_false(Installer.isSubPath("/plugins/myplugin", "/plugins/myplugin/../../etc/shadow"), "Traversal is not subpath")

    assert_eq(Installer.sanitizePluginDirname("my plugin"), "my_plugin.koplugin", "Sanitize plugin dirname with spaces")
    assert_eq(Installer.sanitizePluginDirname("plugin.koplugin"), "plugin.koplugin", "Already koplugin suffix")
end

-- 2. Archive Metadata Detection
do
    local mock_files = {
        ["myplugin.koplugin/_meta.lua"] = 'return { name = "MyPlugin", version = "1.0.0" }',
        ["myplugin.koplugin/main.lua"] = '-- main logic',
    }
    local reader = createMockReader(mock_files)
    local info, err = Installer.detectPluginFromArchive(reader, { name = "myplugin" })
    assert_true(info ~= nil, "Detected plugin info")
    assert_eq(info.plugin_dirname, "myplugin.koplugin", "Detected plugin dirname")
    assert_eq(info.plugin_name, "MyPlugin", "Detected plugin name")
    assert_eq(info.plugin_version, "1.0.0", "Detected plugin version")
end

-- 3. Zip Slip Traversal Defense in Extraction
do
    local test_dest_root = "/tmp/storify_test_slip_" .. tostring(os.time())
    os.execute("mkdir -p " .. test_dest_root)

    local malicious_files = {
        ["myplugin.koplugin/_meta.lua"] = 'return { name = "Evil", version = "6.6.6" }',
        ["myplugin.koplugin/../../evil_file.txt"] = "malicious payload",
    }
    local reader = createMockReader(malicious_files)
    local info = {
        plugin_root = "myplugin.koplugin",
        plugin_dirname = "myplugin.koplugin",
    }

    local ok, err = Installer.extractPlugin(reader, info, test_dest_root)
    assert_false(ok, "Extraction must fail on Zip Slip attack")
    assert_true(err:find("Security error") ~= nil or err:find("escapes target") ~= nil, "Error mentions security/escape")

    -- Verify evil file was NOT created
    local f = io.open(test_dest_root .. "/evil_file.txt", "r")
    assert_true(f == nil, "Malicious file was not written outside target")

    os.execute("rm -rf " .. test_dest_root)
end

-- 4. Post-Extraction Containment (shell-unzip fallback defense: the fallback
-- writes files via an external process before any Lua-side validation runs,
-- so this checks the tree afterward -- notably for symlink-based Zip Slip,
-- which the shared test `lfs` mock can't simulate since it resolves symlinks
-- via `test -d`/`test -e` like real lfs.attributes does. Use a symlink-aware
-- double here instead of touching the shared stub other suites depend on.
do
    local function symlinkAwareLfs()
        local function execOk(cmd)
            local r = os.execute(cmd)
            return r == 0 or r == true
        end
        return {
            attributes = function(p, req)
                if not p or p == "" then return nil end
                local mode
                if execOk(string.format("test -L %q", p)) then
                    mode = "link"
                elseif execOk(string.format("test -d %q", p)) then
                    mode = "directory"
                elseif execOk(string.format("test -e %q", p)) then
                    mode = "file"
                else
                    return nil
                end
                local attr = { mode = mode }
                if req then return attr[req] end
                return attr
            end,
            dir = lfs.dir,
        }
    end

    local root = "/tmp/storify_test_contain_" .. tostring(os.time())
    os.execute("mkdir -p " .. root .. "/sub")
    os.execute("echo ok > " .. root .. "/sub/file.lua")
    local sym_lfs = symlinkAwareLfs()

    local ok = Installer.containExtractedTree(root, sym_lfs)
    assert_true(ok, "Clean extracted tree passes containment check")

    local outside = root .. "_outside"
    os.execute("mkdir -p " .. outside)
    os.execute(string.format("ln -s %q %q", outside, root .. "/escape_link"))

    local ok2, err2 = Installer.containExtractedTree(root, sym_lfs)
    assert_false(ok2, "Tree containing a symlink is rejected")
    assert_true(err2 ~= nil and err2:find("[Ss]ymlink") ~= nil, "Error mentions symlink: " .. tostring(err2))

    os.execute("rm -rf " .. root .. " " .. outside)
end

-- 4. Clean Plugin Install
do
    local test_dest_root = "/tmp/storify_test_install_" .. tostring(os.time())
    os.execute("mkdir -p " .. test_dest_root)

    local clean_files = {
        ["myplugin.koplugin/_meta.lua"] = 'return { name = "CleanPlugin", version = "1.0.0" }',
        ["myplugin.koplugin/main.lua"] = 'print("hello world")',
        ["myplugin.koplugin/sub/helper.lua"] = 'return {}',
    }
    local reader = createMockReader(clean_files)
    local info = {
        plugin_root = "myplugin.koplugin",
        plugin_dirname = "myplugin.koplugin",
    }

    local ok, installed_dir = Installer.extractPlugin(reader, info, test_dest_root)
    assert_true(ok, "Clean installation succeeds: " .. tostring(installed_dir))
    assert_eq(installed_dir, test_dest_root .. "/myplugin.koplugin", "Target directory matches")

    -- Verify files exist in target
    local f1 = io.open(installed_dir .. "/_meta.lua", "r")
    assert_true(f1 ~= nil, "_meta.lua exists")
    if f1 then f1:close() end

    local f2 = io.open(installed_dir .. "/main.lua", "r")
    assert_true(f2 ~= nil, "main.lua exists")
    if f2 then f2:close() end

    local f3 = io.open(installed_dir .. "/sub/helper.lua", "r")
    assert_true(f3 ~= nil, "helper.lua exists")
    if f3 then f3:close() end

    -- Verify staging and backup directories do not exist
    local f_stage = io.open(installed_dir .. ".new", "r")
    assert_true(f_stage == nil, "Staging directory cleaned up")
    local f_bak = io.open(installed_dir .. ".bak", "r")
    assert_true(f_bak == nil, "Backup directory cleaned up")

    os.execute("rm -rf " .. test_dest_root)
end

-- 5. Upgrade with Atomic Swap & Config Preservation
do
    local test_dest_root = "/tmp/storify_test_upgrade_" .. tostring(os.time())
    local target_dir = test_dest_root .. "/myplugin.koplugin"
    os.execute("mkdir -p " .. target_dir)

    -- Existing version on disk with custom user config
    local f_old_main = io.open(target_dir .. "/main.lua", "w")
    f_old_main:write("old main")
    f_old_main:close()

    local f_old_cfg = io.open(target_dir .. "/user_config.json", "w")
    f_old_cfg:write('{"custom_theme": "dark", "token": 12345}')
    f_old_cfg:close()

    -- New version in archive (has updated main.lua, NO user_config.json)
    local update_files = {
        ["myplugin.koplugin/_meta.lua"] = 'return { name = "CleanPlugin", version = "2.0.0" }',
        ["myplugin.koplugin/main.lua"] = 'new main 2.0.0',
    }
    local reader = createMockReader(update_files)
    local info = {
        plugin_root = "myplugin.koplugin",
        plugin_dirname = "myplugin.koplugin",
    }

    local ok, installed_dir = Installer.extractPlugin(reader, info, test_dest_root, { preserve_config = true })
    assert_true(ok, "Upgrade succeeds: " .. tostring(installed_dir))

    -- Check that main.lua has new content
    local f_main = io.open(installed_dir .. "/main.lua", "r")
    local main_content = f_main:read("*all")
    f_main:close()
    assert_eq(main_content, "new main 2.0.0", "main.lua updated to version 2")

    -- Check that user_config.json was carried over
    local f_cfg = io.open(installed_dir .. "/user_config.json", "r")
    assert_true(f_cfg ~= nil, "user_config.json preserved")
    local cfg_content = f_cfg:read("*all")
    f_cfg:close()
    assert_eq(cfg_content, '{"custom_theme": "dark", "token": 12345}', "User config content preserved exactly")

    os.execute("rm -rf " .. test_dest_root)
end

-- 6. Cancellation mid-extraction
do
    local test_dest_root = "/tmp/storify_test_cancel_" .. tostring(os.time())
    os.execute("mkdir -p " .. test_dest_root)

    local clean_files = {
        ["myplugin.koplugin/_meta.lua"] = 'return { name = "CleanPlugin", version = "1.0.0" }',
        ["myplugin.koplugin/main.lua"] = 'print("hello world")',
    }
    local reader = createMockReader(clean_files)
    local info = {
        plugin_root = "myplugin.koplugin",
        plugin_dirname = "myplugin.koplugin",
    }

    local call_count = 0
    local ok, err = Installer.extractPlugin(reader, info, test_dest_root, {
        should_cancel = function()
            call_count = call_count + 1
            return true -- Cancel immediately
        end
    })

    assert_false(ok, "Extraction cancelled returns false")
    assert_true(err:find("cancelled") ~= nil or err:find("Cancelled") ~= nil, "Error indicates cancellation")

    -- Target dir must not exist
    local f_target = io.open(test_dest_root .. "/myplugin.koplugin", "r")
    assert_true(f_target == nil, "Target dir does not exist on cancellation")

    os.execute("rm -rf " .. test_dest_root)
end

print("✓ [storify_installer_test] All installer tests passed successfully.")
return true
