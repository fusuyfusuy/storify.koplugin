-- core/storify_installer.lua
-- Pure Domain Layer: Package Extraction, Zip Slip Traversal Defense, Staging & Atomic Rollback

local StorifyManifest = (pcall(require, "core/storify_manifest") and require("core/storify_manifest"))
    or (pcall(require, "storify_manifest") and require("storify_manifest")) or {}

local StorifyInstaller = {}

-- Canonicalizes a filesystem path (resolving .., ., backslashes, multiple slashes)
function StorifyInstaller.canonicalizePath(path)
    if not path or path == "" then
        return ""
    end

    local norm = path:gsub("\\", "/")
    local is_absolute = norm:sub(1, 1) == "/"
    local parts = {}

    for part in norm:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                table.remove(parts)
            elseif not is_absolute then
                table.insert(parts, "..")
            end
        elseif part ~= "." and part ~= "" then
            table.insert(parts, part)
        end
    end

    local result = table.concat(parts, "/")
    if is_absolute then
        return "/" .. result
    end
    return result
end

-- Normalizes relative path stripping any leading slashes
function StorifyInstaller.normalizeRelativePath(path)
    if not path or path == "" then
        return ""
    end
    local canonical = StorifyInstaller.canonicalizePath(path)
    return canonical:gsub("^/+", "")
end

-- Strictly tests whether child path is fully contained inside parent directory
function StorifyInstaller.isSubPath(parent, child)
    if not parent or not child then
        return false
    end

    local norm_parent = StorifyInstaller.canonicalizePath(parent)
    local norm_child = StorifyInstaller.canonicalizePath(child)

    if norm_parent == norm_child then
        return true
    end

    if not norm_parent:match("/$") then
        norm_parent = norm_parent .. "/"
    end

    return norm_child:sub(1, #norm_parent) == norm_parent
end

-- Post-extraction Zip Slip / symlink containment check for the shell unzip/tar
-- fallback (installPackage), which writes files to disk via an external
-- process before any Lua-side path validation can run -- unlike extractPlugin's
-- Archiver path, which validates every entry against isSubPath() before ever
-- touching disk. Walks the extracted tree and refuses it if any entry lands
-- outside root once canonicalized, or is itself a symlink (the classic
-- zip-slip-via-symlink vector: a symlink planted inside the archive, then a
-- later "file" entry written through it to escape the staging directory).
-- ponytail: canonicalizePath is lexical only (no realpath), so a symlink's
-- target is never resolved and compared -- any symlink is rejected outright
-- rather than validated. Upgrade path: real realpath-based resolution if a
-- legitimate use for symlinks inside installed packages ever emerges.
function StorifyInstaller.containExtractedTree(root, lfs)
    if not root or root == "" then
        return false, "Missing extraction root"
    end
    if not lfs or not lfs.dir or not lfs.attributes then
        return true
    end

    local canonical_root = StorifyInstaller.canonicalizePath(root)

    local function walk(dir_path)
        local blocked_err = nil
        local scan_ok = pcall(function()
            for entry in lfs.dir(dir_path) do
                if blocked_err then break end
                if type(entry) == "string" and entry ~= "." and entry ~= ".." then
                    local full_path = dir_path .. "/" .. entry
                    local canonical_full = StorifyInstaller.canonicalizePath(full_path)

                    if not StorifyInstaller.isSubPath(canonical_root, canonical_full) then
                        blocked_err = "Security error: extracted entry escapes staging directory: " .. entry
                    else
                        local ok_attr, mode = pcall(lfs.attributes, full_path, "mode")
                        if ok_attr and mode == "link" then
                            blocked_err = "Security error: extracted archive contains a symlink: " .. entry
                        elseif ok_attr and mode == "directory" then
                            local sub_ok, sub_err = walk(full_path)
                            if not sub_ok then
                                blocked_err = sub_err
                            end
                        end
                    end
                end
            end
        end)
        if blocked_err then
            return false, blocked_err
        end
        if not scan_ok then
            return false, "Failed to scan extracted directory: " .. tostring(dir_path)
        end
        return true
    end

    return walk(root)
end

-- Sanitizes directory names to avoid invalid characters or path escaping
function StorifyInstaller.sanitizePluginDirname(name)
    if not name or name == "" then
        return "plugin.koplugin"
    end
    local sanitized = tostring(name):gsub("[^%w_%-%.]", "_")
    if not sanitized:match("%.koplugin$") then
        sanitized = sanitized .. ".koplugin"
    end
    return sanitized
end

-- Robust directory check across standard LFS and shell/libc stubs
local function isDir(path, lfs)
    if not path or path == "" then return false end
    if lfs and lfs.attributes then
        local ok, m = pcall(lfs.attributes, path, "mode")
        if ok and m == "directory" then return true end
    end
    local ok = os.execute(string.format("test -d %q 2>/dev/null", path))
    return ok == 0 or ok == true
end

-- Robust file check across standard LFS and shell/libc stubs
local function isFile(path, lfs)
    if not path or path == "" then return false end
    if lfs and lfs.attributes then
        local ok, m = pcall(lfs.attributes, path, "mode")
        if ok and m == "file" then return true end
    end
    local ok = os.execute(string.format("test -f %q 2>/dev/null", path))
    return ok == 0 or ok == true
end

-- Gets file size with fallback to seek
local function getFileSize(path, lfs)
    if lfs and lfs.attributes then
        local ok, sz = pcall(lfs.attributes, path, "size")
        if ok and sz and sz ~= 1024 then return sz end
    end
    local fh = io.open(path, "rb")
    if fh then
        local sz = fh:seek("end")
        fh:close()
        return sz
    end
    return 0
end

-- Helper to recursively purge directories
local function purgeDir(path, ffiUtil, lfs)
    if not path or path == "" then return true end
    if not lfs then
        local ok1, m1 = pcall(require, "libs/libkoreader-lfs")
        if ok1 and m1 then lfs = m1 else
            local ok2, m2 = pcall(require, "lfs")
            if ok2 and m2 then lfs = m2 end
        end
    end
    ffiUtil = ffiUtil or (package.loaded["ffiutil"] or package.loaded["ffi/util"] or package.loaded["ffiUtil"])
    
    if isDir(path, lfs) then
        if ffiUtil and ffiUtil.purgeDir then
            pcall(ffiUtil.purgeDir, path)
        end
        os.execute(string.format("rm -rf %q 2>/dev/null", path))
    elseif isFile(path, lfs) then
        os.remove(path)
    end
    return not isDir(path, lfs) and not isFile(path, lfs)
end

-- Helper to copy file
local function copyFile(src, dst, ffiUtil)
    ffiUtil = ffiUtil or (package.loaded["ffiutil"] or package.loaded["ffi/util"] or package.loaded["ffiUtil"])
    if ffiUtil and ffiUtil.copyFile then
        local ok, res = pcall(ffiUtil.copyFile, src, dst)
        if ok and (res == 0 or res == true or res == nil) then
            return true
        end
    end

    local src_f = io.open(src, "rb")
    if not src_f then return false, "cannot open src" end
    local content = src_f:read("*all")
    src_f:close()

    local dst_f = io.open(dst, "wb")
    if not dst_f then return false, "cannot open dst" end
    dst_f:write(content)
    dst_f:close()
    return true
end

-- Helper to make path
local function makePath(dir, ffiUtil)
    ffiUtil = ffiUtil or (package.loaded["ffiutil"] or package.loaded["ffi/util"] or package.loaded["ffiUtil"])
    if ffiUtil and ffiUtil.makePath then
        pcall(ffiUtil.makePath, dir)
    end
    os.execute(string.format("mkdir -p %q 2>/dev/null", dir))
end

-- Inspects archive entries to discover plugin root directory and metadata
function StorifyInstaller.detectPluginFromArchive(reader, repo)
    if not reader then
        return nil, "Invalid archive reader"
    end

    local plugin_root
    local plugin_dirname
    local meta_entry_path

    for entry in reader:iterate() do
        if entry.mode == "file" then
            if entry.path:match("^_meta%.lua$") then
                meta_entry_path = entry.path
                plugin_root = ""
            elseif entry.path:match("%.koplugin/_meta%.lua$") then
                meta_entry_path = entry.path
                plugin_root = entry.path:match("(.+%.koplugin)/_meta%.lua$")
                if plugin_root then
                    plugin_dirname = plugin_root:match("([^/]+%.koplugin)$")
                end
                break
            elseif not meta_entry_path and entry.path:match("/_meta%.lua$") then
                meta_entry_path = entry.path
                plugin_root = entry.path:match("(.+)/_meta%.lua$")
            end
        end
    end

    if not plugin_root or not meta_entry_path then
        return nil, "Could not locate plugin folder (_meta.lua) in archive."
    end

    local meta_source = reader:extractToMemory(meta_entry_path)
    local meta = meta_source and StorifyManifest.parseMetaChunk(meta_source)
    local plugin_name = meta and (meta.name or meta.fullname)
    local plugin_version = meta and meta.version

    if not plugin_name and meta_source and type(meta_source) == "string" then
        plugin_name = meta_source:match('name%s*=%s*["\']([^"\']+)["\']') or meta_source:match('fullname%s*=%s*["\']([^"\']+)["\']')
        plugin_version = meta_source:match('version%s*=%s*["\']([^"\']+)["\']')
    end

    if not plugin_dirname then
        local repo_name = repo and repo.name
        local repo_is_plugin_dir = repo_name and repo_name:match("^[%w_%-%.]+%.koplugin$") ~= nil
        if repo_is_plugin_dir then
            plugin_dirname = repo_name
        elseif plugin_root and plugin_root ~= "" then
            local root_basename = plugin_root:match("([^/]+)$")
            if root_basename and root_basename:match("%.koplugin") then
                local extracted = root_basename:match("([%w_%-%.]+%.koplugin)")
                if extracted then
                    plugin_dirname = extracted
                end
            end
        end

        if not plugin_dirname then
            if plugin_name and plugin_name ~= "" then
                plugin_dirname = StorifyInstaller.sanitizePluginDirname(plugin_name)
            elseif repo_name then
                plugin_dirname = StorifyInstaller.sanitizePluginDirname(repo_name)
            else
                plugin_dirname = "plugin.koplugin"
            end
        end
    elseif not plugin_name or plugin_name == "" then
        plugin_name = plugin_dirname:gsub("%.koplugin$", "")
    end

    return {
        plugin_root = plugin_root,
        plugin_dirname = plugin_dirname,
        plugin_name = plugin_name,
        plugin_version = plugin_version,
    }
end

-- Fallback release name resolver
function StorifyInstaller.extractReleaseNameFallback(repo, release, asset, meta_source)
    local repo_name = repo and repo.name
    local asset_name = asset and asset.name
    local plugin_name

    if meta_source and type(meta_source) == "string" then
        plugin_name = meta_source:match('name%s*=%s*["\']([^"\']+)["\']')
    end

    local asset_plugin_dir = asset_name and asset_name:match("([%w_%-%.]+%.koplugin)%.zip$")
    if asset_plugin_dir then
        return asset_plugin_dir
    end

    local is_source_code = asset_name and asset_name:match("^Source code") ~= nil
    if is_source_code and repo_name then
        local repo_is_plugin_dir = repo_name and repo_name:match("^[%w_%-%.]+%.koplugin$") ~= nil
        if repo_is_plugin_dir then
            return repo_name
        end
    end

    if repo_name and repo_name:match("^[%w_%-%.]+%.koplugin$") then
        return repo_name
    end

    if repo_name and repo_name:match("^[%w_%-%.]+$") then
        return repo_name .. ".koplugin"
    end

    if plugin_name and plugin_name ~= "" then
        return StorifyInstaller.sanitizePluginDirname(plugin_name)
    end

    return "plugin.koplugin"
end

-- Detects plugin from archive with shallow and multi-level fallbacks
function StorifyInstaller.detectPluginFromArchiveWithFallback(reader, repo, release, asset)
    local info, detect_err = StorifyInstaller.detectPluginFromArchive(reader, repo)
    if info and info.plugin_root and info.plugin_dirname then
        return info, nil
    end

    if reader and reader.rewind then
        reader:rewind()
    end

    local meta_entry_path
    local root_candidate
    local shallow_meta_entry

    for entry in reader:iterate() do
        if entry.mode == "file" then
            if entry.path:match("^_meta%.lua$") then
                meta_entry_path = entry.path
                root_candidate = ""
                shallow_meta_entry = shallow_meta_entry or entry.path
            elseif entry.path:match("/_meta%.lua$") then
                if not shallow_meta_entry or #entry.path < #shallow_meta_entry then
                    shallow_meta_entry = entry.path
                    meta_entry_path = entry.path
                    root_candidate = entry.path:match("(.+)/_meta%.lua$")
                end
            end
        end
    end

    if not meta_entry_path or not root_candidate then
        return nil, detect_err or "Could not locate plugin folder (_meta.lua) in archive."
    end

    local meta_source = reader:extractToMemory(meta_entry_path)
    local plugin_dirname = StorifyInstaller.extractReleaseNameFallback(repo, release, asset, meta_source)
    local meta = meta_source and StorifyManifest.parseMetaChunk(meta_source)
    local plugin_name = meta and (meta.name or meta.fullname)
    local plugin_version = meta and meta.version

    if not plugin_name and meta_source and type(meta_source) == "string" then
        plugin_name = meta_source:match('name%s*=%s*["\']([^"\']+)["\']')
        plugin_version = meta_source:match('version%s*=%s*["\']([^"\']+)["\']')
    end
    if (not plugin_name or plugin_name == "") and plugin_dirname then
        plugin_name = plugin_dirname:gsub("%.koplugin$", "")
    end

    return {
        plugin_root = root_candidate,
        plugin_dirname = plugin_dirname,
        plugin_name = plugin_name,
        plugin_version = plugin_version,
    }, nil
end

-- Extracts an archive safely into dest_root with Zip Slip defenses, staging, and atomic swap
function StorifyInstaller.extractPlugin(reader, info, dest_root, options)
    options = options or {}
    local on_progress = options.on_progress or function() end
    local should_cancel = options.should_cancel or function() return false end
    local preserve_config = (options.preserve_config ~= false)
    local ffiUtil = options.ffiUtil
    if not ffiUtil then
        local ok_f, mod_f = pcall(require, "ffi/util")
        if ok_f and mod_f then ffiUtil = mod_f else
            local ok_f2, mod_f2 = pcall(require, "ffiutil")
            if ok_f2 and mod_f2 then ffiUtil = mod_f2 else
                local ok_f3, mod_f3 = pcall(require, "ffiUtil")
                if ok_f3 and mod_f3 then ffiUtil = mod_f3 end
            end
        end
    end

    local lfs = options.lfs
    if not lfs then
        local ok_l, mod_l = pcall(require, "libs/libkoreader-lfs")
        if ok_l and mod_l then lfs = mod_l else
            local ok_l2, mod_l2 = pcall(require, "lfs")
            if ok_l2 and mod_l2 then lfs = mod_l2 end
        end
    end

    if should_cancel() then
        return false, "Operation cancelled"
    end

    dest_root = dest_root or "/tmp"
    makePath(dest_root, ffiUtil)

    local target_dir = dest_root .. "/" .. info.plugin_dirname
    local canonical_target = StorifyInstaller.canonicalizePath(target_dir)

    -- 1. Scan and plan extraction entries while validating Zip Slip protection
    local planned = {}
    local archive_relatives = {}

    for entry in reader:iterate() do
        if entry.mode == "file" then
            local relative
            if info.plugin_root == "" or not info.plugin_root then
                relative = entry.path
            elseif entry.path:sub(1, #info.plugin_root + 1) == info.plugin_root .. "/" then
                relative = entry.path:sub(#info.plugin_root + 2)
            end

            if relative then
                local norm_rel = StorifyInstaller.normalizeRelativePath(relative)
                local dest_target = target_dir .. "/" .. norm_rel

                -- Strict Zip Slip check
                if not StorifyInstaller.isSubPath(canonical_target, dest_target) then
                    return false, "Security error: Archive entry escapes target directory: " .. entry.path
                end

                table.insert(planned, { path = entry.path, relative = norm_rel })
                archive_relatives[norm_rel] = true
            end
        end
    end

    if #planned == 0 then
        return false, "Archive contains no installable files."
    end

    -- 2. Prepare staging directory
    local staging_dir = target_dir .. ".new"
    local backup_dir = target_dir .. ".bak"

    purgeDir(staging_dir, ffiUtil, lfs)
    makePath(staging_dir, ffiUtil)

    -- 3. Extract planned items into staging directory
    local total_files = #planned
    for i, item in ipairs(planned) do
        if should_cancel() then
            purgeDir(staging_dir, ffiUtil, lfs)
            return false, "Operation cancelled"
        end

        local dest_path = staging_dir .. "/" .. item.relative
        local parent = dest_path:match("^(.*)/[^/]+$")
        if parent and parent ~= "" then
            makePath(parent, ffiUtil)
        end

        if not reader:extractToPath(item.path, dest_path) then
            purgeDir(staging_dir, ffiUtil, lfs)
            return false, "Failed to extract file: " .. item.path
        end

        on_progress(i / total_files * 0.7, "Extracting " .. item.relative)
    end

    -- 4. Preserve existing local user configuration files
    if preserve_config and isDir(target_dir, lfs) then
        on_progress(0.75, "Preserving configuration files")
        local carry_err = nil

        local function carryDirectory(src_dir, dst_dir)
            if not isDir(src_dir, lfs) then return end
            if lfs and lfs.dir then
                for file in lfs.dir(src_dir) do
                    if file ~= "." and file ~= ".." then
                        local src_entry = src_dir .. "/" .. file
                        local dst_entry = dst_dir .. "/" .. file

                        if isDir(src_entry, lfs) then
                            makePath(dst_entry, ffiUtil)
                            carryDirectory(src_entry, dst_entry)
                        elseif isFile(src_entry, lfs) then
                            local is_config = file:match("%.json$") or file:match("%.lua$") or file:match("^settings")
                            if is_config and not archive_relatives[StorifyInstaller.normalizeRelativePath(src_entry:sub(#target_dir + 2))] then
                                if not copyFile(src_entry, dst_entry, ffiUtil) then
                                    carry_err = "Failed to preserve config file: " .. src_entry
                                end
                            end
                        end
                    end
                end
            end
        end

        carryDirectory(target_dir, staging_dir)
        if carry_err then
            purgeDir(staging_dir, ffiUtil, lfs)
            return false, carry_err
        end
    end

    if should_cancel() then
        purgeDir(staging_dir, ffiUtil, lfs)
        return false, "Operation cancelled"
    end

    -- 5. Atomic swap with rollback
    on_progress(0.9, "Applying update atomically")
    local had_existing = isDir(target_dir, lfs)
    if had_existing then
        purgeDir(backup_dir, ffiUtil, lfs)
        local ok_bak, bak_err = os.rename(target_dir, backup_dir)
        if not ok_bak then
            purgeDir(staging_dir, ffiUtil, lfs)
            return false, "Failed to backup existing installation: " .. tostring(bak_err)
        end
    end

    local ok_swap, swap_err = os.rename(staging_dir, target_dir)
    if not ok_swap then
        if had_existing then
            os.rename(backup_dir, target_dir)
        end
        purgeDir(staging_dir, ffiUtil, lfs)
        return false, "Failed to swap new installation: " .. tostring(swap_err)
    end

    -- Success: clean up backup
    purgeDir(backup_dir, ffiUtil, lfs)
    on_progress(1.0, "Installation complete")

    return true, target_dir
end

-- High-level package installer from archive file path or reader
function StorifyInstaller.installPackage(options)
    options = options or {}
    local archive_path = options.archive_path
    local target_dir = options.target_dir
    local on_progress = options.on_progress or function() end
    local should_cancel = options.should_cancel or function() return false end
    local preserve_config = (options.preserve_config ~= false)

    if not target_dir or target_dir == "" then
        return false, "Missing target directory"
    end

    if not archive_path or archive_path == "" then
        return false, "Missing archive path"
    end

    local ffiUtil = options.ffiUtil
    if not ffiUtil then
        local ok_f, mod_f = pcall(require, "ffi/util")
        if ok_f and mod_f then ffiUtil = mod_f else
            local ok_f2, mod_f2 = pcall(require, "ffiutil")
            if ok_f2 and mod_f2 then ffiUtil = mod_f2 else
                local ok_f3, mod_f3 = pcall(require, "ffiUtil")
                if ok_f3 and mod_f3 then ffiUtil = mod_f3 end
            end
        end
    end

    local lfs = options.lfs
    if not lfs then
        local ok_l, mod_l = pcall(require, "libs/libkoreader-lfs")
        if ok_l and mod_l then lfs = mod_l else
            local ok_l2, mod_l2 = pcall(require, "lfs")
            if ok_l2 and mod_l2 then lfs = mod_l2 end
        end
    end

    -- Attempt to open with KOReader Archiver if available
    local ok_arch, Archiver = pcall(require, "archiver")
    if ok_arch and Archiver and Archiver.open then
        local ok_open, reader = pcall(Archiver.open, Archiver, archive_path)
        if ok_open and reader then
            local info, _ = StorifyInstaller.detectPluginFromArchive(reader)
            if not info then
                info = {
                    plugin_root = "",
                    plugin_dirname = target_dir:match("([^/\\]+)$") or "plugin.koplugin",
                }
            end
            local dest_root = target_dir:match("^(.*)/[^/]+$") or "/tmp"
            if reader.rewind then pcall(reader.rewind, reader) end
            local res_ok, res_path = StorifyInstaller.extractPlugin(reader, info, dest_root, {
                on_progress = on_progress,
                should_cancel = should_cancel,
                preserve_config = preserve_config,
                ffiUtil = ffiUtil,
                lfs = lfs,
            })
            if reader.close then pcall(reader.close, reader) end
            return res_ok, res_path
        end
    end

    -- Shell unzip/tar fallback
    local staging_dir = target_dir .. ".new"
    local backup_dir = target_dir .. ".bak"
    purgeDir(staging_dir, ffiUtil, lfs)
    makePath(staging_dir, ffiUtil)

    on_progress(0.3, "Extracting package")
    local unzip_cmd = string.format("unzip -q -o %q -d %q 2>/dev/null", archive_path, staging_dir)
    local cmd_res = os.execute(unzip_cmd)
    if cmd_res ~= 0 and cmd_res ~= true then
        local tar_cmd = string.format("tar -xzf %q -C %q 2>/dev/null", archive_path, staging_dir)
        cmd_res = os.execute(tar_cmd)
    end

    if cmd_res ~= 0 and cmd_res ~= true then
        purgeDir(staging_dir, ffiUtil, lfs)
        return false, "Extraction command failed"
    end

    -- The Archiver path validates every entry before it touches disk; the
    -- shell unzip/tar fallback can't be pre-validated, so verify the result
    -- afterward and refuse the install if anything escaped the staging dir.
    local contained_ok, contain_err = StorifyInstaller.containExtractedTree(staging_dir, lfs)
    if not contained_ok then
        purgeDir(staging_dir, ffiUtil, lfs)
        return false, contain_err
    end

    local extracted_items = {}
    if lfs and lfs.dir then
        -- ponytail: iterate inside pcall (bare generator from pcall(lfs.dir, d)
        -- crashes on real KOReader: "bad argument #1 to (for generator)")
        pcall(function()
            for e in lfs.dir(staging_dir) do
                if e and not e:match("^%.") then
                    table.insert(extracted_items, e)
                end
            end
        end)
    end

    local actual_source = staging_dir
    if #extracted_items == 1 then
        local sub = staging_dir .. "/" .. extracted_items[1]
        if isDir(sub, lfs) then
            actual_source = sub
        end
    end

    if should_cancel() then
        purgeDir(staging_dir, ffiUtil, lfs)
        return false, "Operation cancelled"
    end

    if preserve_config and isDir(target_dir, lfs) then
        on_progress(0.75, "Preserving configuration files")
        if lfs and lfs.dir then
            local function carry(src_p, dst_p)
                for f in lfs.dir(src_p) do
                    if f and not f:match("^%.") then
                        local src_f = src_p .. "/" .. f
                        local dst_f = dst_p .. "/" .. f
                        if isDir(src_f, lfs) then
                            makePath(dst_f, ffiUtil)
                            carry(src_f, dst_f)
                        elseif isFile(src_f, lfs) then
                            local is_cfg = f:match("%.json$") or f:match("%.lua$") or f:match("^settings")
                            if is_cfg and not isFile(dst_f, lfs) then
                                copyFile(src_f, dst_f, ffiUtil)
                            end
                        end
                    end
                end
            end
            carry(target_dir, actual_source)
        end
    end

    local had_existing = isDir(target_dir, lfs)
    if had_existing then
        purgeDir(backup_dir, ffiUtil, lfs)
        local ok_bak, bak_err = os.rename(target_dir, backup_dir)
        if not ok_bak then
            purgeDir(staging_dir, ffiUtil, lfs)
            return false, "Failed to backup existing directory: " .. tostring(bak_err)
        end
    end

    local ok_swap, swap_err = os.rename(actual_source, target_dir)
    if not ok_swap then
        if had_existing then
            os.rename(backup_dir, target_dir)
        end
        purgeDir(staging_dir, ffiUtil, lfs)
        return false, "Failed to activate installation: " .. tostring(swap_err)
    end

    purgeDir(staging_dir, ffiUtil, lfs)
    purgeDir(backup_dir, ffiUtil, lfs)
    on_progress(1.0, "Installation complete")
    return true, target_dir
end

-- Rolls back a target directory to its .bak counterpart
function StorifyInstaller.rollback(target_dir, backup_dir)
    if not target_dir or target_dir == "" then
        return false, "Invalid target directory"
    end
    backup_dir = backup_dir or (target_dir .. ".bak")

    local ffiUtil
    local ok_f, mod_f = pcall(require, "ffi/util")
    if ok_f and mod_f then ffiUtil = mod_f else
        local ok_f2, mod_f2 = pcall(require, "ffiutil")
        if ok_f2 and mod_f2 then ffiUtil = mod_f2 else
            local ok_f3, mod_f3 = pcall(require, "ffiUtil")
            if ok_f3 and mod_f3 then ffiUtil = mod_f3 end
        end
    end

    local lfs
    local ok_l, mod_l = pcall(require, "libs/libkoreader-lfs")
    if ok_l and mod_l then lfs = mod_l else
        local ok_l2, mod_l2 = pcall(require, "lfs")
        if ok_l2 and mod_l2 then lfs = mod_l2 end
    end

    if not isDir(backup_dir, lfs) then
        return false, "Backup directory not found: " .. tostring(backup_dir)
    end

    purgeDir(target_dir, ffiUtil, lfs)
    local ok_ren, ren_err = os.rename(backup_dir, target_dir)
    if not ok_ren then
        return false, "Failed to restore backup: " .. tostring(ren_err)
    end

    return true, target_dir
end

return StorifyInstaller
