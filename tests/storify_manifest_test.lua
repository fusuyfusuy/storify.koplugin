-- tests/storify_manifest_test.lua
-- Unit tests for core/storify_manifest.lua

local Manifest = require("storify_manifest")

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

print("--> [storify_manifest_test] Starting test suite...")

-- 1. firstNonEmpty helper
do
    assert_eq(Manifest.firstNonEmpty(nil, "", "hello", "world"), "hello", "Picks first non-empty string")
    assert_eq(Manifest.firstNonEmpty("", nil, ""), nil, "Returns nil when all empty")
    assert_eq(Manifest.firstNonEmpty(nil, 42, "foo"), 42, "Non-string non-nil returned")
    assert_eq(Manifest.firstNonEmpty("first"), "first", "Single argument non-empty")
end

-- 2. normalizeDescription
do
    assert_eq(Manifest.normalizeDescription("A nice plugin"), "A nice plugin", "Preserves normal string")
    assert_eq(Manifest.normalizeDescription("function: 0x55d1a8b4"), "", "Strips function pointers")
    assert_eq(Manifest.normalizeDescription(nil), "", "Nil becomes empty string")
    assert_eq(Manifest.normalizeDescription(123), "", "Non-string becomes empty string")
end

-- 3. normalizeMetaPath and sanitizeMetaPath
do
    assert_eq(Manifest.normalizeMetaPath("_meta.lua"), "_meta.lua", "Root _meta.lua")
    assert_eq(Manifest.normalizeMetaPath("myplugin.koplugin/_meta.lua"), "myplugin.koplugin/_meta.lua", "Exact meta path")
    assert_eq(Manifest.normalizeMetaPath("myplugin.koplugin"), "myplugin.koplugin/_meta.lua", "Append _meta.lua to koplugin")
    assert_eq(Manifest.normalizeMetaPath("myplugin"), "myplugin.koplugin/_meta.lua", "Append koplugin and _meta.lua")
    assert_eq(Manifest.normalizeMetaPath("/nested/dir/myplugin.koplugin/_meta.lua"), "nested/dir/myplugin.koplugin/_meta.lua", "Strip leading slash")
    assert_eq(Manifest.normalizeMetaPath(nil), nil, "Nil path returns nil")

    assert_eq(Manifest.sanitizeMetaPath("valid.koplugin", "fallback"), "valid.koplugin/_meta.lua", "Sanitize valid path")
    assert_eq(Manifest.sanitizeMetaPath(nil, "fallback.koplugin"), "fallback.koplugin/_meta.lua", "Sanitize with fallback")
    assert_eq(Manifest.sanitizeMetaPath("", "fallback"), "fallback.koplugin/_meta.lua", "Sanitize empty with fallback")
end

-- 4. buildMetaPathCandidates
do
    local record = {
        dirname = "myplugin.koplugin",
        meta_path = "nested/myplugin.koplugin/_meta.lua",
        meta_path_hint = "hint.koplugin/_meta.lua",
    }
    local candidates = Manifest.buildMetaPathCandidates(record)
    assert_true(#candidates > 0, "Candidates returned")
    local seen = {}
    for _, c in ipairs(candidates) do
        seen[c] = true
    end
    assert_true(seen["nested/myplugin.koplugin/_meta.lua"], "Contains meta_path")
    assert_true(seen["hint.koplugin/_meta.lua"], "Contains meta_path_hint")
    assert_true(seen["myplugin.koplugin/_meta.lua"], "Contains dirname candidate")
    assert_true(seen["_meta.lua"], "Contains root fallback candidate")
end

-- 5. Safe Sandboxed parseMetaChunk
do
    local valid_chunk = [[
        return {
            name = "Test Plugin",
            fullname = _("Test Plugin Full Name"),
            version = "1.0.4",
            description = "A test plugin for KOReader.",
        }
    ]]
    local meta, err = Manifest.parseMetaChunk(valid_chunk)
    assert_true(meta ~= nil, "Parsed valid meta chunk")
    assert_eq(meta.name, "Test Plugin", "Meta name parsed")
    assert_eq(meta.fullname, "Test Plugin Full Name", "Meta fullname translated via sandbox _")
    assert_eq(meta.version, "1.0.4", "Meta version parsed")
    assert_eq(meta.description, "A test plugin for KOReader.", "Meta description parsed")

    -- Dangerous chunk attempting to access os/io/ffi/global env
    local malicious_chunk = [[
        local res = tostring(os) .. tostring(io) .. tostring(package)
        if os and os.execute then
            os.execute("rm -rf /")
        end
        return {
            name = "Malicious",
            os_val = tostring(os),
        }
    ]]
    local safe_meta, safe_err = Manifest.parseMetaChunk(malicious_chunk)
    assert_true(safe_meta ~= nil, "Safe meta returns table")
    assert_eq(safe_meta.os_val, "nil", "Sandbox prevents access to os global")

    -- Syntax error chunk
    local syntax_err_chunk = "return { name = "
    local err_meta, syntax_err = Manifest.parseMetaChunk(syntax_err_chunk)
    assert_eq(err_meta, nil, "Syntax error returns nil")
    assert_true(syntax_err ~= nil, "Syntax error returns error message")
end

-- 6. buildPatchRepoDescriptor
do
    local record = {
        owner = "koreader",
        repo = "userpatches",
        repo_full_name = "koreader/userpatches",
        repo_id = 12345,
        repo_description = "Community user patches",
        branch = "main",
    }
    local descriptor = Manifest.buildPatchRepoDescriptor(record, "20-invert-screen.lua")
    assert_eq(descriptor.kind, "patch", "Descriptor kind is patch")
    assert_eq(descriptor.name, "userpatches", "Descriptor repo name")
    assert_eq(descriptor.owner, "koreader", "Descriptor owner")
    assert_eq(descriptor.full_name, "koreader/userpatches", "Descriptor full name")
    assert_eq(descriptor.id, 12345, "Descriptor id")
    assert_eq(descriptor.description, "Community user patches", "Descriptor description")
    assert_eq(descriptor.file, "20-invert-screen.lua", "Descriptor patch file")
    assert_eq(descriptor.data.default_branch, "main", "Descriptor default branch")

    -- Nil handling
    assert_eq(Manifest.buildPatchRepoDescriptor(nil), nil, "Nil record returns nil")
    assert_eq(Manifest.buildPatchRepoDescriptor({ owner = "koreader" }), nil, "Missing repo returns nil")
end

-- 7. getPluginDisplayName
do
    assert_eq(Manifest.getPluginDisplayName({ name = "CoverImage" }, "coverimage.koplugin"), "CoverImage", "Uses meta.name")
    assert_eq(Manifest.getPluginDisplayName({ fullname = "Auto Suspend" }, "autosuspend.koplugin"), "Auto Suspend", "Uses meta.fullname")
    assert_eq(Manifest.getPluginDisplayName(nil, "wallpapers.koplugin"), "wallpapers", "Falls back to dirname")
    assert_eq(Manifest.getPluginDisplayName(nil, nil), "plugin", "Default fallback to plugin")
end

print("✓ [storify_manifest_test] All manifest tests passed successfully.")
return true
