-- net/storify_crawler.lua
-- Exhaustive Discovery & Deep Search Engine for KOReader Storify

local GitHub = (pcall(require, "net/storify_net_github") and require("net/storify_net_github"))
    or (pcall(require, "storify_net_github") and require("storify_net_github")) or {}
local Cache = (pcall(require, "data/storify_cache") and require("data/storify_cache"))
    or (pcall(require, "storify_cache") and require("storify_cache")) or {}
local Installs = (pcall(require, "data/storify_installs") and require("data/storify_installs"))
    or (pcall(require, "storify_installs") and require("storify_installs")) or {}
local Matcher = (pcall(require, "core/storify_matcher") and require("core/storify_matcher"))
    or (pcall(require, "storify_matcher") and require("storify_matcher")) or {}
local PluginPaths = (pcall(require, "data/storify_plugin_paths") and require("data/storify_plugin_paths"))
    or (pcall(require, "storify_plugin_paths") and require("storify_plugin_paths")) or {}
local logger = require("logger")
local _ = (pcall(require, "storify_gettext") and require("storify_gettext"))
    or (pcall(require, "l10n/storify_gettext") and require("l10n/storify_gettext")) or function(s) return s end

local Crawler = {}

function Crawler.buildQueries(kind, include_zero_star_forks)
    kind = kind or "plugin"
    local is_patch = (kind == "patch" or kind == "patches")
    local topic = is_patch and "topic:koreader-user-patch" or "topic:koreader-plugin"
    local name = is_patch and 'in:name "KOReader.patches"' or 'in:name ".koplugin"'
    local fork_qualifier = include_zero_star_forks and "fork:only" or "fork:only stars:>=1"

    return {
        string.format("%s fork:false", topic),
        string.format("%s fork:false", name),
        string.format("%s %s", topic, fork_qualifier),
        string.format("%s %s", name, fork_qualifier),
    }
end

function Crawler.reconcileDiskPlugins(cached_repos)
    cached_repos = cached_repos or Cache.listRepos("plugin")
    local lookup_paths = (PluginPaths.getLookupPaths and PluginPaths.getLookupPaths()) or {}
    if #lookup_paths == 0 then
        lookup_paths = { "plugins" }
    end
    if PluginPaths.getDefaultPluginsRoot then
        local def_root = PluginPaths.getDefaultPluginsRoot()
        local has_def = false
        for _, p in ipairs(lookup_paths) do
            if p == def_root then has_def = true break end
        end
        if not has_def then
            table.insert(lookup_paths, def_root)
        end
    end
    local scanned = Matcher.scanInstalledPlugins(lookup_paths)
    Installs.syncFromDisk(scanned, cached_repos)
    return scanned
end

local function isRateLimitError(err)
    if type(err) == "table" then
        return err.is_rate_limit == true or err.code == 403 or err.code == 429
    elseif type(err) == "string" then
        local s = err:lower()
        return s:find("rate limit", 1, true) ~= nil or s:find("403", 1, true) ~= nil or s:find("429", 1, true) ~= nil
    end
    return false
end

local function formatErrorMessage(err)
    if isRateLimitError(err) then
        local code = (type(err) == "table" and err.code) or 403
        return string.format("GitHub API rate limit exceeded (HTTP %s)", tostring(code))
    end
    if type(err) == "table" then
        return err.body or tostring(err.code or "request failed")
    elseif type(err) == "string" then
        return err
    end
    return "Unknown network error"
end

local function crawlSingleKind(kind, include_zero_star_forks, should_cancel, on_progress_step)
    local queries = Crawler.buildQueries(kind, include_zero_star_forks)
    local discovered = {}
    local seen_ids = {}
    local total_queries = #queries

    for query_index, query in ipairs(queries) do
        if should_cancel and should_cancel() then
            return nil, "cancelled"
        end

        local page = 1
        while page <= 10 do
            if should_cancel and should_cancel() then
                return nil, "cancelled"
            end

            local res, err = GitHub.searchRepositories({
                q = query,
                page = page,
                per_page = 100,
                sort = "stars",
                order = "desc",
            })

            if not res or not res.items then
                logger.warn("Crawler: search failed for query", query, "page", page, err)
                return nil, formatErrorMessage(err)
            end

            for _, item in ipairs(res.items) do
                local id = item.id
                if id and not seen_ids[id] then
                    seen_ids[id] = true
                    table.insert(discovered, item)
                end
            end

            if on_progress_step then
                on_progress_step(query_index, total_queries, page, #discovered)
            end

            if #res.items < 100 or (page * 100 >= (res.total_count or 0)) then
                break
            end
            page = page + 1
        end
    end

    return discovered, nil
end

-- Fetches and stores the .lua patch files for a single patch-collection repo.
-- Shared by the bulk fallback crawl below and by main.lua's on-demand Browse
-- Patches drill-down: the awesome.koreader fast path (the normal case,
-- fetchAwesomeCatalog above) never runs a tree fetch for any repo eagerly --
-- doing that for every one of the catalog's ~100+ patch-collection repos on
-- every "Refresh Catalog" would be exactly the crawling cost/lag that catalog
-- replaced -- so the tree is only ever fetched lazily, the first time a user
-- actually opens a given repo. `repo` accepts either shape: a raw GitHub API
-- object (search results, `.id`/`.owner` as a table) or a Cache.listRepos()
-- row (`.repo_id`/`.owner` as a plain string, `.default_branch` only reachable
-- via the lazily-loaded `.data` blob).
function Crawler.fetchPatchFileTree(repo)
    if not repo then
        return false, "missing repo"
    end
    local repo_id = repo.repo_id or repo.id
    local owner = (type(repo.owner) == "table" and repo.owner.login) or repo.owner
    local repo_name = repo.name
    local branch = repo.default_branch or (repo.data and repo.data.default_branch) or "main"
    if not repo_id or not owner or not repo_name then
        return false, "missing repo id/owner/name"
    end

    local tree_data, tree_err = GitHub.fetchRepoTree(owner, repo_name, branch)
    if not tree_data or type(tree_data) ~= "table" or type(tree_data.tree) ~= "table" then
        return false, tree_err
    end

    local patch_entries = {}
    for _, item in ipairs(tree_data.tree) do
        if item.path and item.path:match("%.lua$") and (not item.type or item.type == "blob") then
            local filename = item.path:match("([^/]+)$") or item.path
            local full_repo_slug = repo.full_name or string.format("%s/%s", owner, repo_name)
            local download_url = string.format(
                "https://raw.githubusercontent.com/%s/%s/%s",
                full_repo_slug,
                branch,
                item.path
            )
            table.insert(patch_entries, {
                path = item.path,
                filename = filename,
                branch = branch,
                sha = item.sha or "",
                size = tonumber(item.size) or 0,
                download_url = download_url,
            })
        end
    end
    Cache.storePatchFiles(repo_id, patch_entries, repo.pushed_at)
    return true, nil
end

local function deepCrawlPatchTrees(patch_repos, should_cancel, on_tree_progress)
    local total_repos = #patch_repos
    local valid_ids = {}

    for index, repo in ipairs(patch_repos) do
        if should_cancel and should_cancel() then
            return nil, "cancelled"
        end

        local repo_id = repo.repo_id or repo.id
        if repo_id then
            table.insert(valid_ids, repo_id)
        end

        local ok, err = Crawler.fetchPatchFileTree(repo)
        if not ok then
            if isRateLimitError(err) then
                return nil, formatErrorMessage(err)
            end
            logger.warn("Crawler: failed to fetch tree for patch repo", repo.full_name or repo.name, err)
        end

        if on_tree_progress then
            on_tree_progress(index, total_repos)
        end
    end

    Cache.pruneOrphanPatchFiles(valid_ids)
    return true, nil
end

local AWESOME_CATALOG_URL = "https://raw.githubusercontent.com/fusuyfusuy/awesome.koreader/main/plugins.json"

local function fetchAwesomeCatalog(should_cancel, on_progress)
    if should_cancel and should_cancel() then
        return nil, "cancelled"
    end

    if on_progress then
        on_progress(0.1, _("Downloading weekly catalog index…"))
    end

    local Mirror = (pcall(require, "net/storify_mirror") and require("net/storify_mirror"))
        or (pcall(require, "storify_mirror") and require("storify_mirror")) or {}
    local Net = (pcall(require, "net/storify_net") and require("net/storify_net"))
        or (pcall(require, "storify_net") and require("storify_net")) or {}
    local json = (pcall(require, "json") and require("json")) or {}

    local target_url = (Mirror.apply and Mirror.apply(AWESOME_CATALOG_URL)) or AWESOME_CATALOG_URL

    local response_parts = {}
    local code, headers, status = Net.requestToTable({ url = target_url }, response_parts, 15, 60)

    if should_cancel and should_cancel() then
        return nil, "cancelled"
    end

    if not code or code ~= 200 or #response_parts == 0 then
        return nil, string.format("Catalog fetch failed (HTTP %s: %s)", tostring(code), tostring(status or "no data"))
    end

    if on_progress then
        on_progress(0.4, _("Parsing catalog metadata…"))
    end

    local raw_json = table.concat(response_parts)
    local ok_decode, catalog_data = pcall(function()
        if json.decode then
            return json.decode(raw_json)
        end
        return nil
    end)

    if not ok_decode or type(catalog_data) ~= "table" then
        return nil, "Invalid JSON received from catalog index"
    end

    local raw_plugins = catalog_data.plugins or {}
    local patches = catalog_data.patches or {}

    -- Normalize plugins. "builtin_plugin" entries (e.g. koreader/koreader's
    -- own plugins/keepalive.koplugin) already ship with every KOReader
    -- install and live at a sub-path inside the koreader/koreader monorepo,
    -- not their own repo -- their full_name/url don't fit the flat
    -- "owner/repo" shape every other catalog entry has, which breaks both
    -- README fetch (raw.githubusercontent.com/<owner>/<repo>/HEAD/README.md
    -- 404s) and download_url (<url>/archive/refs/heads/<branch>.zip yields a
    -- garbage path). Rather than special-case that shape throughout the
    -- install/README pipeline for something users can't actually install
    -- (it's already on their device), drop them from the catalog here.
    local plugins = {}
    for _, p in ipairs(raw_plugins) do
        if p.type ~= "builtin_plugin" then
            p.kind = "plugin"
            p.stars = tonumber(p.stars) or tonumber(p.stargazers_count) or 0
            p.stargazers_count = p.stars
            p.owner = p.owner or (p.full_name and p.full_name:match("^([^/]+)")) or ""
            if not p.download_url and p.url then
                p.download_url = p.url .. "/archive/refs/heads/" .. (p.default_branch or "main") .. ".zip"
            end
            table.insert(plugins, p)
        end
    end

    -- Normalize patches
    for _, pt in ipairs(patches) do
        pt.kind = "patch"
        pt.stars = tonumber(pt.stars) or tonumber(pt.stargazers_count) or 0
        pt.stargazers_count = pt.stars
        pt.owner = pt.owner or (pt.full_name and pt.full_name:match("^([^/]+)")) or ""
        if not pt.download_url and pt.url then
            pt.download_url = pt.url .. "/archive/refs/heads/" .. (pt.default_branch or "main") .. ".zip"
        end
    end

    return {
        plugins = plugins,
        patches = patches,
    }, nil
end

function Crawler.refreshCatalog(opts)
    opts = opts or {}
    local kind = opts.kind or "all"
    local include_zero_star_forks = opts.include_zero_star_forks == true
    local should_cancel = opts.should_cancel or function() return false end
    local on_progress = opts.on_progress or function() end
    local on_complete = opts.on_complete or function() end
    local reconcile_disk = opts.reconcile_disk ~= false
    local force_crawler = opts.force_crawler == true

    local function finish(success, err_msg, stats)
        on_complete(success, err_msg, stats)
        return success, err_msg, stats
    end

    if should_cancel() then
        return finish(false, "cancelled")
    end

    -- 1. Primary: Lightning-fast catalog sync from fusuyfusuy/awesome.koreader
    if not force_crawler then
        local catalog, cat_err = fetchAwesomeCatalog(should_cancel, on_progress)
        if catalog and (catalog.plugins or catalog.patches) then
            local stats = {
                plugins_discovered = #(catalog.plugins or {}),
                patches_discovered = #(catalog.patches or {}),
            }

            if kind == "all" or kind == "plugin" then
                if #(catalog.plugins or {}) > 0 then
                    on_progress(0.6, _("Saving plugins to cache…"))
                    Cache.storeRepos("plugin", catalog.plugins, function(idx, total)
                        on_progress(0.6 + 0.15 * (idx / (total > 0 and total or 1)), _("Saving plugins to cache…"))
                    end, should_cancel)
                end
            end

            if kind == "all" or kind == "patch" or kind == "patches" then
                if #(catalog.patches or {}) > 0 then
                    on_progress(0.8, _("Saving user patches to cache…"))
                    Cache.storeRepos("patch", catalog.patches, function(idx, total)
                        on_progress(0.8 + 0.1 * (idx / (total > 0 and total or 1)), _("Saving user patches to cache…"))
                    end, should_cancel)
                end
            end

            if reconcile_disk and catalog.plugins then
                on_progress(0.95, _("Scanning installed plugins…"))
                Crawler.reconcileDiskPlugins(catalog.plugins)
            end

            on_progress(1.0, _("Catalog updated!"))
            return finish(true, nil, stats)
        else
            logger.warn("Crawler: awesome.koreader catalog fetch failed, falling back to direct crawler:", cat_err)
        end
    end

    -- 2. Fallback: Dual-branch GitHub API crawler
    local kinds_to_crawl = {}
    if kind == "all" then
        kinds_to_crawl = { "plugin", "patch" }
    elseif kind == "patch" or kind == "patches" then
        kinds_to_crawl = { "patch" }
    else
        kinds_to_crawl = { "plugin" }
    end

    local stats = {
        plugins_discovered = 0,
        patches_discovered = 0,
    }

    local total_kinds = #kinds_to_crawl

    for kind_index, current_kind in ipairs(kinds_to_crawl) do
        if should_cancel() then
            return finish(false, "cancelled")
        end

        local base_fraction = (kind_index - 1) / total_kinds
        local kind_weight = 1.0 / total_kinds

        local status_label = current_kind == "patch" and _("Discovering user patches…") or _("Discovering plugins…")
        on_progress(base_fraction, status_label)

        local repos, crawl_err = crawlSingleKind(
            current_kind,
            include_zero_star_forks,
            should_cancel,
            function(q_idx, total_q, page, discovered_count)
                local sub_fraction = (q_idx - 1) / total_q + (1 / total_q) * 0.5
                on_progress(base_fraction + (sub_fraction * kind_weight * 0.7), status_label)
            end
        )

        if not repos then
            return finish(false, crawl_err)
        end

        if current_kind == "plugin" then
            stats.plugins_discovered = #repos
            if #repos > 0 then
                Cache.storeRepos("plugin", repos, function(idx, total)
                    local write_fraction = (idx / (total > 0 and total or 1))
                    on_progress(base_fraction + (0.7 + 0.3 * write_fraction) * kind_weight, _("Saving plugins to cache…"))
                end, should_cancel)
            end
            if reconcile_disk then
                Crawler.reconcileDiskPlugins(repos)
            end
        elseif current_kind == "patch" then
            stats.patches_discovered = #repos
            if #repos > 0 then
                Cache.storeRepos("patch", repos, function(idx, total)
                    local write_fraction = (idx / (total > 0 and total or 1))
                    on_progress(base_fraction + (0.35 + 0.15 * write_fraction) * kind_weight, _("Saving patches to cache…"))
                end, should_cancel)

                local tree_ok, tree_err = deepCrawlPatchTrees(repos, should_cancel, function(t_idx, total_t)
                    local tree_fraction = (t_idx / (total_t > 0 and total_t or 1))
                    on_progress(base_fraction + (0.5 + 0.5 * tree_fraction) * kind_weight, _("Scanning patch file trees…"))
                end)

                if not tree_ok then
                    return finish(false, tree_err)
                end
            end
        end
    end

    on_progress(1.0, _("Catalog updated!"))
    return finish(true, nil, stats)
end

return Crawler
