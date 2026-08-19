-- core/storify_manifest.lua
-- Pure Domain Layer: Metadata Manifest, Patch Descriptor, and Safe Chunk Parsing

local StorifyManifest = {}

-- Returns the first non-nil, non-empty string or non-nil value from the arguments
function StorifyManifest.firstNonEmpty(...)
    local n = select("#", ...)
    for i = 1, n do
        local value = select(i, ...)
        if value ~= nil then
            if type(value) == "string" then
                if value ~= "" then
                    return value
                end
            else
                return value
            end
        end
    end
    return nil
end

-- Normalizes metadata description, stripping function pointers and trimming
function StorifyManifest.normalizeDescription(value)
    if type(value) ~= "string" then
        return ""
    end
    if value:match("^function:%s*0x%x+$") then
        return ""
    end
    return value
end

-- Normalizes a relative or absolute path pointing to _meta.lua
function StorifyManifest.normalizeMetaPath(path)
    if not path or path == "" then
        return nil
    end
    local normalized = path:gsub("^/+", "")
    if normalized == "_meta.lua" then
        return normalized
    end
    if normalized:match("/_meta%.lua$") then
        return normalized
    end
    if not normalized:match("%.koplugin$") then
        normalized = normalized .. ".koplugin"
    end
    return normalized .. "/_meta.lua"
end

-- Validates and normalizes path with a fallback option
function StorifyManifest.sanitizeMetaPath(path, fallback)
    if path and path ~= "" then
        local normalized = StorifyManifest.normalizeMetaPath(path)
        if normalized then
            return normalized
        end
    end
    if fallback and fallback ~= "" then
        return StorifyManifest.normalizeMetaPath(fallback)
    end
    return nil
end

-- Builds a prioritized list of candidate paths to locate _meta.lua
function StorifyManifest.buildMetaPathCandidates(record)
    if not record then
        return {}
    end
    local seen = {}
    local candidates = {}
    local function add(path)
        if not path or path == "" then
            return
        end
        local normalized = StorifyManifest.normalizeMetaPath(path)
        if not normalized or seen[normalized] then
            return
        end
        seen[normalized] = true
        table.insert(candidates, normalized)
    end

    add(record.meta_path)
    add(record.meta_path_hint)

    if record.meta_path then
        local trimmed = record.meta_path:gsub("%.koplugin/_meta%.lua$", "/_meta.lua")
        add(trimmed)
    end
    if record.meta_path_hint then
        local trimmed = record.meta_path_hint:gsub("%.koplugin/_meta%.lua$", "/_meta.lua")
        add(trimmed)
    end
    if record.dirname then
        add(record.dirname .. "/_meta.lua")
        if record.dirname:match("%.koplugin$") then
            local without_suffix = record.dirname:gsub("%.koplugin$", "")
            add(without_suffix .. "/_meta.lua")
        end
    end

    add("_meta.lua")
    return candidates
end

-- Constructs a standardized repository descriptor table for user patch records
function StorifyManifest.buildPatchRepoDescriptor(record, file)
    if not record or not record.owner or not record.repo then
        return nil
    end

    local owner = record.owner
    return {
        kind = "patch",
        name = record.repo,
        owner = owner,
        full_name = record.repo_full_name or string.format("%s/%s", owner, record.repo),
        id = record.repo_id,
        repo_id = record.repo_id,
        description = record.repo_description,
        file = file or record.file,
        data = {
            owner = { login = owner },
            default_branch = record.branch or "HEAD",
        },
    }
end

-- Resolves the display name for a plugin from metadata or directory name
function StorifyManifest.getPluginDisplayName(meta, dirname)
    if meta then
        if meta.name and meta.name ~= "" then
            return meta.name
        end
        if meta.fullname and meta.fullname ~= "" then
            return meta.fullname
        end
    end
    if dirname and dirname ~= "" then
        return dirname:gsub("%.koplugin$", "")
    end
    return "plugin"
end

-- Safely parses a Lua chunk string inside a sandboxed environment
function StorifyManifest.parseMetaChunk(chunk_str, custom_env)
    if not chunk_str or chunk_str == "" then
        return nil, "empty chunk"
    end

    local chunk, err = loadstring(chunk_str)
    if not chunk then
        return nil, err
    end

    local sandbox_env = custom_env or {
        _ = function(msgid) return msgid end,
        pgettext = function(_ctx, msgid) return msgid end,
        require = function(mod)
            return function(s) return s end
        end,
        tostring = tostring,
        tonumber = tonumber,
        type = type,
        select = select,
        pairs = pairs or function(t) return next, t, nil end,
        ipairs = ipairs or function(t) return next, t, nil end,
        next = next,
        string = {
            format = string.format,
            gsub = string.gsub,
            sub = string.sub,
            match = string.match,
            gmatch = string.gmatch,
            find = string.find,
            lower = string.lower,
            upper = string.upper,
            len = string.len,
        },
        table = {
            concat = table.concat,
            insert = table.insert,
            remove = table.remove,
            sort = table.sort,
        },
        math = {
            max = math.max,
            min = math.min,
            floor = math.floor,
            ceil = math.ceil,
        },
    }

    if setfenv then
        pcall(setfenv, chunk, sandbox_env)
    end

    local ok, res = pcall(chunk)
    if not ok then
        return nil, res
    end
    if type(res) ~= "table" then
        return nil, "chunk did not return a table"
    end

    return res, nil
end

-- Loads and parses a _meta.lua file from disk in a sandbox
function StorifyManifest.loadMetaFile(filepath, custom_env)
    if not filepath or filepath == "" then
        return nil, "invalid filepath"
    end

    local ok_open, f = pcall(io.open, filepath, "r")
    if not ok_open or not f then
        return nil, "cannot open file"
    end
    local ok_read, content = pcall(function() return f:read(65536) end)
    pcall(function() f:close() end)
    if not ok_read or not content or content == "" then
        return nil, "empty or unreadable"
    end

    return StorifyManifest.parseMetaChunk(content, custom_env)
end

-- Extracts a version string from main.lua via regex
function StorifyManifest.extractVersionFromMain(main_path)
    if not main_path or main_path == "" then
        return nil
    end
    local ok_open, f = pcall(io.open, main_path, "r")
    if not ok_open or not f then
        return nil
    end
    local ok_read, content = pcall(function() return f:read(32768) end)
    pcall(function() f:close() end)
    if not ok_read or not content or content == "" then
        return nil
    end

    local ver = content:match("[vV][eE][rR][sS][iI][oO][nN]%s*=%s*[\"']([^\"']+)[\"']")
    if not ver then
        ver = content:match("_VERSION%s*=%s*[\"']([^\"']+)[\"']")
    end
    return ver
end

-- Inspects a plugin directory on disk to extract metadata and version
function StorifyManifest.inspectPluginDirectory(dir_path)
    if not dir_path or dir_path == "" then
        return nil, "invalid dir_path"
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        ok_lfs, lfs = pcall(require, "lfs")
    end

    local is_dir = false
    if ok_lfs and lfs and lfs.attributes then
        local mode = lfs.attributes(dir_path, "mode")
        is_dir = (mode == "directory")
    else
        local f = io.open(dir_path .. "/main.lua", "r") or io.open(dir_path .. "/_meta.lua", "r")
        if f then
            f:close()
            is_dir = true
        end
    end

    if not is_dir then
        return nil, "directory not found"
    end

    local dirname = dir_path:match("([^/\\]+)/?$") or dir_path
    local base_name = dirname:gsub("%.koplugin$", "")

    local meta_path = dir_path .. "/_meta.lua"
    local meta, _ = StorifyManifest.loadMetaFile(meta_path)

    local main_path = dir_path .. "/main.lua"
    local main_ver = StorifyManifest.extractVersionFromMain(main_path)

    local id = base_name
    local name = base_name
    local fullname = base_name
    local version = main_ver
    local description = ""

    if meta and type(meta) == "table" then
        id = meta.id or meta.name or base_name
        name = meta.name or meta.fullname or base_name
        fullname = meta.fullname or meta.name or base_name
        version = meta.version or main_ver
        description = StorifyManifest.normalizeDescription(meta.description)
    end

    return {
        id = id,
        name = name,
        fullname = fullname,
        version = version,
        description = description,
        dir_path = dir_path,
        dirname = dirname,
    }
end

return StorifyManifest
