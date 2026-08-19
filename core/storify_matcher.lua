-- core/storify_matcher.lua
-- Pure Domain Layer: Local Plugin Directory vs Remote GitHub Repo Matching & Reconciliation

local Version = (pcall(require, "core/storify_version") and require("core/storify_version"))
    or (pcall(require, "storify_version") and require("storify_version")) or {}

local Manifest = (pcall(require, "core/storify_manifest") and require("core/storify_manifest"))
    or (pcall(require, "storify_manifest") and require("storify_manifest")) or {}

local StorifyMatcher = {}

local logger = (pcall(require, "logger") and require("logger")) or {
    warn = function(...) end,
}

-- Normalizes plugin or repository names into a canonical comparison slug
function StorifyMatcher.normalizeIdentifier(str)
    if not str or str == "" then
        return ""
    end

    local norm = tostring(str):lower()
    -- Replace underscores and spaces with dashes
    norm = norm:gsub("[%s_]+", "-")
    -- Strip trailing .koplugin
    norm = norm:gsub("%.koplugin$", "")
    -- Strip standard prefixes
    norm = norm:gsub("^koreader%-plugins%-", "")
    norm = norm:gsub("^koreader%-plugin%-", "")
    norm = norm:gsub("^koreader%-", "")
    norm = norm:gsub("^plugins%-", "")
    norm = norm:gsub("^plugin%-", "")

    return norm
end

-- Finds the best matching remote repository from catalog for a given local plugin
function StorifyMatcher.findMatchingRepo(plugin, repos)
    if not plugin or not repos or #repos == 0 then
        return nil
    end

    -- 1. Exact match on recorded owner/repo or full_name
    if plugin.record and plugin.record.owner and plugin.record.repo then
        local full = string.format("%s/%s", plugin.record.owner, plugin.record.repo):lower()
        for _, r in ipairs(repos) do
            if r.full_name and r.full_name:lower() == full then
                return r
            end
        end
    end
    if plugin.record and plugin.record.repo_full_name then
        local full = plugin.record.repo_full_name:lower()
        for _, r in ipairs(repos) do
            if r.full_name and r.full_name:lower() == full then
                return r
            end
        end
    end

    -- 2. Exact match on directory name
    local dirname = plugin.dirname
    if dirname and dirname ~= "" then
        for _, r in ipairs(repos) do
            if r.name == dirname or (r.name and (r.name .. ".koplugin") == dirname) then
                return r
            end
        end
    end

    -- 3. Match on display name / manifest name
    local plugin_name = plugin.name
    if plugin_name and plugin_name ~= "" then
        local target_name = plugin_name:lower()
        for _, r in ipairs(repos) do
            if r.name and r.name:lower() == target_name then
                return r
            end
        end
    end

    -- 4. Fuzzy slug matching via normalizeIdentifier
    local plugin_slug = StorifyMatcher.normalizeIdentifier(dirname or plugin_name)
    if plugin_slug ~= "" then
        for _, r in ipairs(repos) do
            local repo_slug = StorifyMatcher.normalizeIdentifier(r.name)
            if repo_slug == plugin_slug then
                return r
            end
        end
    end

    return nil
end

-- Matches all installed plugins to remote repository catalog
function StorifyMatcher.matchPlugins(installed_plugins, repos)
    local results = {}
    if not installed_plugins then
        return results
    end

    for _, plugin in ipairs(installed_plugins) do
        local matched = StorifyMatcher.findMatchingRepo(plugin, repos)
        results[plugin.dirname or "unknown"] = {
            plugin = plugin,
            repo = matched,
        }
    end

    return results
end

-- Determines whether an update is available for a single installed plugin
function StorifyMatcher.isUpdateAvailable(local_plugin, remote_info, ignored_tag)
    if not local_plugin or not remote_info then
        return false, "missing_input"
    end

    local release_tag = remote_info.release_tag_name or (remote_info.release and remote_info.release.tag_name)
    local release_ts = remote_info.release_published_at or (remote_info.release and remote_info.release.published_at) or 0
    local local_version = local_plugin.version
    local local_ts = local_plugin.latest_mtime or 0

    if release_tag and release_tag ~= "" then
        if ignored_tag and ignored_tag == release_tag then
            return false, "ignored"
        end

        if local_version and local_version ~= "" then
            if Version and Version.isVersionNewer and Version.isVersionNewer(release_tag, local_version) then
                return true, "version"
            else
                return false, "up_to_date"
            end
        else
            if release_ts > local_ts and local_ts > 0 then
                return true, "timestamp"
            else
                return true, "release_available"
            end
        end
    else
        local remote_version = remote_info.remote_version or remote_info.version
        local remote_repo_ts = remote_info.remote_repo_ts or 0

        if remote_version and local_version and Version and Version.isVersionNewer and Version.isVersionNewer(remote_version, local_version) then
            return true, "remote_version"
        elseif remote_repo_ts > local_ts and remote_repo_ts > 0 and local_ts > 0 then
            return true, "repo_timestamp"
        end
    end

    return false, "no_update"
end

-- Reconciles a full list of installed plugins against remote information and ignore list
function StorifyMatcher.reconcileUpdates(installed_plugins, remote_info_map, ignored_map)
    local items = {}
    local updates_count = 0
    remote_info_map = remote_info_map or {}
    ignored_map = ignored_map or {}

    if not installed_plugins then
        return { items = items, total_count = 0, updates_count = 0 }
    end

    for _, plugin in ipairs(installed_plugins) do
        local remote = remote_info_map[plugin.dirname]
        local ignored_tag = ignored_map[plugin.dirname]
        
        if not ignored_tag and plugin.record and plugin.record.owner and plugin.record.repo then
            local key = string.format("%s/%s", plugin.record.owner, plugin.record.repo)
            ignored_tag = ignored_map[key]
        end

        local has_update, reason = false, "no_remote"
        if remote then
            has_update, reason = StorifyMatcher.isUpdateAvailable(plugin, remote, ignored_tag)
        end

        if has_update then
            updates_count = updates_count + 1
        end

        table.insert(items, {
            plugin = plugin,
            remote = remote,
            has_update = has_update,
            update_reason = reason,
            ignored_tag = ignored_tag,
        })
    end

    return {
        items = items,
        total_count = #installed_plugins,
        updates_count = updates_count,
    }
end

-- Scans lookup directories for *.koplugin folders, deduplicates symlinks, and extracts metadata
function StorifyMatcher.scanInstalledPlugins(lookup_paths)
    if not lookup_paths then
        local ok_pp, PluginPaths = pcall(require, "data/storify_plugin_paths")
        if not ok_pp or not PluginPaths then
            ok_pp, PluginPaths = pcall(require, "storify_plugin_paths")
        end
        if ok_pp and PluginPaths and PluginPaths.getLookupPaths then
            lookup_paths = PluginPaths.getLookupPaths()
        else
            lookup_paths = { "plugins" }
        end
    end

    local scanned = {}
    local seen_real_paths = {}

    local current_lfs
    local ok1, mod1 = pcall(require, "libs/libkoreader-lfs")
    if ok1 and mod1 then current_lfs = mod1 else
        local ok2, mod2 = pcall(require, "lfs")
        if ok2 and mod2 then current_lfs = mod2 end
    end

    local current_ffiutil
    local ok_f1, f_mod1 = pcall(require, "ffi/util")
    if ok_f1 and f_mod1 then current_ffiutil = f_mod1 else
        local ok_f2, f_mod2 = pcall(require, "ffiutil")
        if ok_f2 and f_mod2 then current_ffiutil = f_mod2 else
            pcall(function() current_ffiutil = require("ffiUtil") end)
        end
    end

    local function getRealPath(path)
        if current_ffiutil and current_ffiutil.realpath then
            return current_ffiutil.realpath(path)
        end
        return path
    end

    for _, lookup_dir in ipairs(lookup_paths) do
        if lookup_dir and lookup_dir ~= "" and current_lfs and current_lfs.dir then
            -- ponytail: pcall must wrap the whole iteration (KOReader's
            -- libkoreader-lfs dir iterator needs its state; extracting the
            -- bare generator and calling it outside the original expression
            -- errors on real KOReader: "bad argument #1 to (for generator)").
            local scan_ok = pcall(function()
                for entry in current_lfs.dir(lookup_dir) do
                    -- Ignore hidden directories/files starting with '.'
                    if type(entry) == "string" and not entry:match("^%.") and entry:match("%.koplugin$") then
                        local full_path = lookup_dir .. "/" .. entry
                        local is_dir = false
                        if current_lfs and current_lfs.attributes then
                            local ok_attr, mode = pcall(current_lfs.attributes, full_path, "mode")
                            if ok_attr and (mode == "directory" or mode == "link") then
                                is_dir = true
                            end
                        else
                            local ok_f, f = pcall(io.open, full_path .. "/main.lua", "r")
                            if ok_f and f then f:close() is_dir = true end
                        end

                        if is_dir then
                            local real_p = getRealPath(full_path)
                            if not (real_p and seen_real_paths[real_p]) then
                                if real_p then
                                    seen_real_paths[real_p] = true
                                end
                                local ok_i, info = pcall(function()
                                    return Manifest and Manifest.inspectPluginDirectory and Manifest.inspectPluginDirectory(full_path)
                                end)
                                if ok_i and info and type(info) == "table" then
                                    info.dirname = entry
                                    info.lookup_path = lookup_dir
                                    table.insert(scanned, info)
                                end
                            end
                        end
                    end
                end
            end)
            if not scan_ok then
                logger.warn("storify: failed to scan plugin dir", lookup_dir)
            end
        end
    end

    return scanned
end

-- Reconciles scanned plugins against remote catalog and existing install records
function StorifyMatcher.linkScannedPlugins(scanned_plugins, cached_repos, existing_installs)
    scanned_plugins = scanned_plugins or {}
    cached_repos = cached_repos or {}
    existing_installs = existing_installs or {}

    local linked = {}
    local unlinked = {}

    for _, plugin in ipairs(scanned_plugins) do
        local id = plugin.id or plugin.dirname or plugin.name
        local existing = existing_installs[id] or existing_installs[plugin.dirname] or existing_installs[plugin.name]

        if existing and (existing.repo_full_name or existing.repo or (existing.repo_owner and existing.repo_name)) and not existing.unlinked then
            local repo = StorifyMatcher.findMatchingRepo({
                id = id,
                name = plugin.name,
                dirname = plugin.dirname,
                record = {
                    owner = existing.repo_owner,
                    repo = existing.repo_name,
                    repo_full_name = existing.repo_full_name or existing.repo,
                },
            }, cached_repos)

            if not repo then
                repo = {
                    name = existing.repo_name or plugin.name,
                    owner = existing.repo_owner,
                    full_name = existing.repo_full_name or existing.repo or string.format("%s/%s", existing.repo_owner or "", existing.repo_name or ""),
                }
            end

            local item = {
                plugin = plugin,
                repo = repo,
                record = existing,
                is_linked = true,
            }
            linked[id] = item
            if plugin.dirname and plugin.dirname ~= id then
                linked[plugin.dirname] = item
            end
            table.insert(linked, item)
        else
            local matched_repo = StorifyMatcher.findMatchingRepo(plugin, cached_repos)
            if matched_repo then
                local item = {
                    plugin = plugin,
                    repo = matched_repo,
                    record = {
                        repo_owner = matched_repo.owner,
                        repo_name = matched_repo.name,
                        repo_full_name = matched_repo.full_name or (matched_repo.owner and matched_repo.name and (matched_repo.owner .. "/" .. matched_repo.name)),
                        version = plugin.version,
                    },
                    is_linked = true,
                    auto_linked = true,
                }
                linked[id] = item
                if plugin.dirname and plugin.dirname ~= id then
                    linked[plugin.dirname] = item
                end
                table.insert(linked, item)
            else
                local item = {
                    plugin = plugin,
                    repo = nil,
                    is_linked = false,
                    unlinked = true,
                }
                unlinked[id] = item
                if plugin.dirname and plugin.dirname ~= id then
                    unlinked[plugin.dirname] = item
                end
                table.insert(unlinked, item)
            end
        end
    end

    return linked, unlinked
end

return StorifyMatcher
