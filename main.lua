-- main.lua
-- Plugin Lifecycle Orchestrator for KOReader Storify Plugin.
-- Wires UI events to the core/data/net layers; business logic lives there.

local plugin_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])[^/\\]+$") or ""
for _, sub in ipairs({ "core", "data", "net", "ui", "l10n" }) do
    local p = plugin_dir .. sub .. "/?.lua;"
    if not package.path:find(p, 1, true) then package.path = p .. package.path end
end

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Dispatcher = require("dispatcher")
local DataStorage = require("datastorage")
local logger = require("logger")
local _ = require("storify_gettext")
-- "ffi/util" is KOReader's real module path; headless tests only stub the
-- "ffiutil"/"ffiUtil" aliases (see tests/stubs/koreader_stubs.lua).
local ffiUtil = (pcall(require, "ffi/util") and require("ffi/util"))
    or (pcall(require, "ffiutil") and require("ffiutil")) or {}

-- Domain Layer
local Version = require("core/storify_version")
local Manifest = require("core/storify_manifest")
local Matcher = require("core/storify_matcher")
local Installer = require("core/storify_installer")

-- Data Layer
local Cache = require("data/storify_cache")
local Installs = require("data/storify_installs")
local Settings = require("data/storify_settings")
local PluginPaths = require("data/storify_plugin_paths")

-- Net Layer
local Net = require("net/storify_net")
local GitHub = require("net/storify_net_github")
local Mirror = require("net/storify_mirror")
local RepoContent = require("net/storify_repo_content")
local Crawler = require("net/storify_crawler")

-- UI Layer
local StorifyWidgets = require("ui/storify_widgets")
local StorifyDialogs = require("ui/storify_dialogs")
local StorifyBrowserModule = require("ui/storify_browser_dialog")
local StorifyBrowserDialog = StorifyBrowserModule.StorifyBrowserDialog
local BrowserModel = StorifyBrowserModule.Model
local StorifyUpdatesDialog = require("ui/storify_updates_dialog").StorifyUpdatesDialog
local StorifyProgress = require("ui/storify_progress")

local BROWSER_PAGE_SIZE = 20

local Storify = WidgetContainer:extend{
    name = "storify",
    is_doc_only = false,
    is_refreshing = false,
}

function Storify:init()
    Cache.init()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function Storify:addToMainMenu(menu_items)
    menu_items.storify = {
        sorting_hint = "tools",
        text = _("Storify"),
        sub_item_table = {
            {
                text = _("Browse Plugins"),
                callback = function() self:showBrowser("plugins") end,
            },
            {
                text = _("Browse User Patches"),
                callback = function() self:showBrowser("patches") end,
            },
            {
                text = _("Manage Updates & Installed"),
                callback = function() self:showUpdates("plugins") end,
            },
            {
                text = _("Refresh Catalog"),
                callback = function() self:refreshCatalog() end,
            },
            {
                text = _("Mirror / Proxy Settings"),
                callback = function() self:showMirrorSettings() end,
            },
        },
    }
end

function Storify:onDispatcherRegisterActions()
    Dispatcher:registerAction("storify_browse_plugins", {
        category = "none",
        event = "StorifyBrowsePlugins",
        title = _("Storify: Browse Plugins"),
        general = true,
        callback = function() self:showBrowser("plugins") end,
    })
    Dispatcher:registerAction("storify_browse_patches", {
        category = "none",
        event = "StorifyBrowsePatches",
        title = _("Storify: Browse Patches"),
        general = true,
        callback = function() self:showBrowser("patches") end,
    })
    Dispatcher:registerAction("storify_manage_updates", {
        category = "none",
        event = "StorifyManageUpdates",
        title = _("Storify: Manage Updates"),
        general = true,
        callback = function() self:showUpdates("plugins") end,
    })
    Dispatcher:registerAction("storify_refresh_cache", {
        category = "none",
        event = "StorifyRefreshCache",
        title = _("Storify: Refresh Catalog"),
        general = true,
        callback = function() self:refreshCatalog() end,
    })
end

function Storify:onStorifyBrowsePlugins()
    UIManager:nextTick(function() self:showBrowser("plugins") end)
end

function Storify:onStorifyBrowsePatches()
    UIManager:nextTick(function() self:showBrowser("patches") end)
end

function Storify:onStorifyManageUpdates()
    UIManager:nextTick(function() self:showUpdates("plugins") end)
end

function Storify:onStorifyRefreshCache()
    UIManager:nextTick(function() self:refreshCatalog() end)
end

-- Builds the installed-lookup that BrowserModel.filterItems consults to mark
-- catalog rows as installed. Installs.list() keys records by plugin id/name/
-- dirname, so index every alias a catalog row's `.name` might match.
local function buildInstalledSet()
    local installed_set = {}
    for key, rec in pairs(Installs.list() or {}) do
        installed_set[key] = true
        if rec then
            if rec.name then installed_set[rec.name] = true end
            if rec.repo then installed_set[rec.repo] = true end
            if rec.repo_full_name then installed_set[rec.repo_full_name] = true end
        end
    end
    return installed_set
end

-- Formats a raw Cache.listRepos() row into the display string StorifyListItem
-- reads via entry.text, reusing the existing star/badge formatters instead of
-- inventing a parallel one.
local function formatBrowserEntryText(repo, is_installed)
    local title = repo.full_name or repo.name or _("Repository")
    local meta = StorifyWidgets.formatStars(repo.stars)
    if is_installed then
        meta = meta .. " " .. StorifyWidgets.formatStatusBadge("installed")
    end
    local lines = { string.format("%s  %s", title, meta) }
    if repo.description and repo.description ~= "" then
        table.insert(lines, repo.description)
    end
    return table.concat(lines, "\n")
end

function Storify:showBrowser(initial_filter, initial_search, page)
    if self._browser_dialog then
        UIManager:close(self._browser_dialog)
    end
    local filter_mode = initial_filter or "plugins"
    local search_query = initial_search or ""
    -- Cache.listRepos() is a SQL-level filter by kind ("plugin"/"patch"), so the
    -- patches tab must ask for kind="patch" or it always gets the plugin rows.
    local kind = (filter_mode == "patches" or filter_mode == "user_patches" or filter_mode == "installed_patches")
        and "patch" or "plugin"
    local repos = Cache.listRepos(kind)
    local installed_set = buildInstalledSet()

    local filtered = BrowserModel.filterItems(repos, filter_mode, search_query, installed_set)
    local sorted = BrowserModel.sortItems(filtered, "stars_desc")
    local page_items, page_info = BrowserModel.paginateItems(sorted, page or 1, BROWSER_PAGE_SIZE)

    -- Transform pure repo records into the entry shape StorifyListItem expects
    -- (text/callback/is_entry) -- this is the glue that was missing entirely.
    local items = {}
    for _, repo in ipairs(page_items) do
        local is_installed = installed_set[repo.name] == true or installed_set[repo.full_name] == true
        table.insert(items, {
            text = formatBrowserEntryText(repo, is_installed),
            is_entry = true,
            installed = is_installed,
            keep_menu_open = true,
            callback = function() self:handleDetailsRequest(repo) end,
            hold_callback = function() self:handleReadmeRequest(repo) end,
        })
    end

    local dialog = StorifyBrowserDialog:new{
        storify = self,
        items = items,
        page = page_info.current_page,
        total_pages = page_info.total_pages,
        initial_filter = filter_mode,
        initial_search = search_query,
        on_install_request = function(item) self:handleInstallRequest(item) end,
        on_details_request = function(item) self:handleDetailsRequest(item) end,
        on_readme_request = function(item) self:handleReadmeRequest(item) end,
        on_refresh_request = function() self:refreshCatalog(function() self:showBrowser(filter_mode, search_query, page_info.current_page) end) end,
        on_settings_request = function() self:showMirrorSettings() end,
        on_first_page = function() self:showBrowser(filter_mode, search_query, 1) end,
        on_prev_page = function() self:showBrowser(filter_mode, search_query, page_info.current_page - 1) end,
        on_next_page = function() self:showBrowser(filter_mode, search_query, page_info.current_page + 1) end,
        on_last_page = function() self:showBrowser(filter_mode, search_query, page_info.total_pages) end,
        on_goto_page = function(target_page) self:showBrowser(filter_mode, search_query, target_page) end,
    }
    self._browser_dialog = dialog
    -- Explicit refresh type: replacing a full-screen dialog from inside a Button's
    -- own tap callback (footer pagination, toolbar refresh, etc.) races against
    -- Button:onTapSelectButton's own tap-feedback flow, which *always* pre-queues
    -- a small refresh scoped to just the button's own rect (see button.lua's
    -- _undoFeedbackHighlight). UIManager:show()/close() without a refresh type rely
    -- on _repaint()'s "nothing got queued, do a full one" fallback, but that fallback
    -- never fires here because the button's own small-rect refresh already queued
    -- something. Net effect: the new dialog paints correctly into the back buffer,
    -- but only that stale button-sized rect actually gets flashed to the screen, so
    -- the page turn is invisible until some later, unrelated event forces a real
    -- repaint (this is why physical PgFwd/PgBack, which never queues that small-rect
    -- refresh, "just works"). Passing "ui" here guarantees a real full-screen refresh
    -- is queued for every caller of showBrowser (footer buttons, toolbar, keys alike).
    UIManager:show(dialog, "ui")
end

-- Formats an UpdatesModel.prepareUpdateCandidates() candidate into the display
-- string UpdatesListItem reads via entry.text, reusing the existing badge
-- formatter instead of inventing a parallel one.
-- prepareUpdateCandidates() looks remote repo info up by string key
-- (repos_meta[repo_key]); Cache.listRepos() returns a plain array, so it must
-- be indexed by full_name (and name, its lookup fallback) before use here --
-- passing the array straight through left every candidate perpetually
-- "unlinked" since array[string] is always nil.
local function buildRepoMap(repos)
    local map = {}
    for _, repo in ipairs(repos or {}) do
        if repo.full_name then map[repo.full_name] = repo end
        if repo.name and not map[repo.name] then map[repo.name] = repo end
    end
    return map
end

-- Builds the same kind of string-keyed lookup buildRepoMap() builds for
-- plugins, but for individual patch files: prepareUpdateCandidates() looks
-- an installed patch's remote info up as patches_meta["owner/repo:path"].
-- patch_files rows only carry repo_id, so patch collection repos have to be
-- joined in by id to know the owner/name for that key.
local function buildPatchesMap(patch_repos)
    local repo_by_id = {}
    for _, repo in ipairs(patch_repos or {}) do
        repo_by_id[repo.repo_id] = repo
    end
    local map = {}
    local files_by_repo = Cache.listPatchFilesByRepo and Cache.listPatchFilesByRepo() or {}
    for repo_id, files in pairs(files_by_repo) do
        local repo = repo_by_id[repo_id]
        if repo and repo.owner and repo.name then
            for _, file in ipairs(files) do
                local key = string.format("%s/%s:%s", repo.owner, repo.name, file.path)
                map[key] = { sha = file.sha, download_url = file.download_url }
            end
        end
    end
    return map
end

local function formatUpdateEntryText(cand)
    local title = cand.name or cand.id or _("Plugin")
    local lines = { string.format("%s  %s", title, StorifyWidgets.formatStatusBadge(cand.status)) }
    if cand.kind ~= "patch" then
        local current = cand.current_version or _("unknown")
        if cand.latest_version and cand.latest_version ~= "" then
            table.insert(lines, string.format(_("%s → %s"), current, cand.latest_version))
        else
            table.insert(lines, current)
        end
    end
    return table.concat(lines, "\n")
end

-- scope switches which installed set this dialog tracks ("plugins" or
-- "patches" -- see the "Switch to patches" wiring below); needs_update_only
-- mirrors the "Show needs update" toggle.
function Storify:showUpdates(scope, needs_update_only)
    scope = scope or "plugins"
    if self._updates_dialog then
        UIManager:close(self._updates_dialog)
    end

    local updates_mod = require("ui/storify_updates_dialog")
    local updates_model = updates_mod.UpdatesModel or updates_mod.Model or updates_mod
    local candidates

    if scope == "patches" then
        local patch_repos = Cache.listRepos("patch")
        local installed_patches = Installs.listPatches()
        candidates = updates_model.prepareUpdateCandidates
            and updates_model.prepareUpdateCandidates(nil, installed_patches, { patches = buildPatchesMap(patch_repos) })
            or {}
    else
        local lookup_paths = PluginPaths.getLookupPaths and PluginPaths.getLookupPaths() or { "plugins" }
        local scanned = Matcher.scanInstalledPlugins(lookup_paths)
        local repos = Cache.listRepos()
        Installs.syncFromDisk(scanned, repos)
        local installed = Installs.list()
        -- "Check all updates" (handleCheckAllUpdates) fetches live GitHub
        -- release tags on demand and stashes them here for the running
        -- session -- the catalog itself rarely carries a version/tag (see the
        -- awesome.koreader gotcha in .agents/memory.md), so without this
        -- prepareUpdateCandidates() has no latest_version to compare against.
        local repos_meta = buildRepoMap(repos)
        for full_name, release_info in pairs(self._checked_releases or {}) do
            local target = repos_meta[full_name]
            if target then
                target.latest_version = release_info.latest_version
                target.latest_tag = release_info.latest_tag
            else
                repos_meta[full_name] = release_info
            end
        end
        candidates = updates_model.prepareUpdateCandidates
            and updates_model.prepareUpdateCandidates(installed, nil, { repos = repos_meta })
            or {}
    end

    if needs_update_only then
        local filtered = {}
        for _, cand in ipairs(candidates) do
            if cand.has_update then
                table.insert(filtered, cand)
            end
        end
        candidates = filtered
    end

    -- Glue: prepareUpdateCandidates() returns bare data records, not the
    -- {text=, callback=, is_entry=} shape UpdatesListItem renders. Without this,
    -- rows are blank and non-tappable (the same bug class as the browser dialog).
    local items = {}
    for _, cand in ipairs(candidates) do
        cand.text = formatUpdateEntryText(cand)
        cand.is_entry = true
        if cand.can_update then
            -- handleInstallRequest resolves its archive URL from item.full_name;
            -- candidates only carry repo_full_name, so alias it here.
            cand.full_name = cand.repo_full_name
            cand.version = cand.latest_version or cand.current_version
            cand.callback = function() self:handleInstallRequest(cand) end
        elseif cand.status ~= "unlinked" and not cand.unlinked then
            -- Unlinked rows get their callback auto-wired to on_link_item by
            -- StorifyUpdatesDialog:setItems(); everything else that can't be
            -- acted on directly is shown but not tappable.
            cand.select_enabled = false
        end
        table.insert(items, cand)
    end
    self._updates_items = items
    self._updates_scope = scope
    self._updates_needs_update_only = needs_update_only

    local dialog = StorifyUpdatesDialog:new{
        storify = self,
        items = items,
        title = scope == "patches" and _("Storify · Patch Updates") or _("Storify · Updates"),
        filter_label = needs_update_only and _("Show all") or _("Show needs update"),
        on_update_item = function(item) self:handleInstallRequest(item) end,
        on_batch_update = function(selected_items) self:handleBatchUpdate(selected_items) end,
        on_rollback_item = function(item) self:handleRollback(item) end,
        on_delete_item = function(item) self:handleDelete(item) end,
        on_scan_request = function() self:scanDiskPlugins(function() self:showUpdates(scope, needs_update_only) end) end,
        on_link_item = function(item) self:handleManualLink(item) end,
        on_refresh_request = function() self:refreshCatalog(function() self:showUpdates(scope, needs_update_only) end) end,
        on_toggle_filter = function() self:showUpdates(scope, not needs_update_only) end,
        on_switch_target = function() self:showUpdates(scope == "patches" and "plugins" or "patches", needs_update_only) end,
        on_match = function() self:handleMatchWithRepo(scope, needs_update_only) end,
        on_check_updates = function() self:handleCheckAllUpdates(scope, needs_update_only) end,
    }
    self._updates_dialog = dialog
    -- See the matching comment in showBrowser(): without an explicit refresh type,
    -- replacing this full-screen dialog from a Button callback (scan/refresh
    -- buttons) only flashes the stale button's own small rect, not the new dialog.
    UIManager:show(dialog, "ui")
end

-- Bulk retry of automatic matching for every currently-unlinked plugin row,
-- reusing the same Matcher.findMatchingRepo() the passive disk-scan
-- reconciliation (syncFromDisk) already runs on every dialog open -- this is
-- for the case where that already ran and still came up empty (e.g. right
-- after a catalog refresh added a match), so the user has an explicit retry
-- instead of only ever getting one automatic pass. Patches have no matcher
-- yet (nothing installs a patch outside a fully-linked catalog entry today).
function Storify:handleMatchWithRepo(scope, needs_update_only)
    if scope == "patches" then
        StorifyDialogs.showInfoMessage(_("Matching isn't available for patches yet."))
        return
    end
    local repos = Cache.listRepos()
    local matched_count = 0
    for _, cand in ipairs(self._updates_items or {}) do
        if cand.kind ~= "patch" and (cand.status == "unlinked" or cand.unlinked) then
            local matched = Matcher.findMatchingRepo(cand, repos)
            if matched then
                local key = cand.id
                local existing = Installs.get(key) or {}
                existing.id = key
                existing.name = existing.name or cand.name
                existing.dirname = existing.dirname or cand.dirname
                existing.repo = matched.full_name or (matched.owner and matched.name and (matched.owner .. "/" .. matched.name))
                existing.repo_owner = matched.owner
                existing.repo_name = matched.name
                existing.repo_full_name = matched.full_name or existing.repo
                existing.unlinked = nil
                Installs.upsert(key, existing)
                matched_count = matched_count + 1
            end
        end
    end
    StorifyDialogs.showInfoMessage(matched_count > 0
        and string.format(_("Matched %d plugin(s) to a repo."), matched_count)
        or _("No new matches found."))
    self:showUpdates(scope, needs_update_only)
end

-- Live per-repo version check: the awesome.koreader catalog itself rarely
-- carries a version/tag (see .agents/memory.md), so prepareUpdateCandidates()
-- otherwise has nothing but presence-in-catalog to call "up to date". Fetches
-- GitHub's latest-release tag for every linked plugin and stashes the result
-- on self._checked_releases, which showUpdates() merges into the repo lookup
-- for the rest of this session. Blocking/synchronous like refreshCatalog()
-- (see the P1 async-work item in .agents/memory.md) -- one HTTP round trip
-- per linked plugin, so this can take a while with many plugins linked.
function Storify:handleCheckAllUpdates(scope, needs_update_only)
    if scope == "patches" then
        StorifyDialogs.showInfoMessage(_("Checking for updates isn't available for patches yet."))
        return
    end
    if self.is_checking_updates then
        return
    end

    local targets = {}
    for _, cand in ipairs(self._updates_items or {}) do
        if cand.kind ~= "patch" and cand.repo_owner and cand.repo_name then
            table.insert(targets, cand)
        end
    end
    if #targets == 0 then
        StorifyDialogs.showInfoMessage(_("No linked plugins to check."))
        return
    end

    self.is_checking_updates = true
    local progress = StorifyProgress:new{ title = _("Checking for updates…") }
    progress:show()

    self._checked_releases = self._checked_releases or {}
    local checked, no_release, rate_limited = 0, 0, false

    for i, cand in ipairs(targets) do
        if progress:cancelled() or rate_limited then
            break
        end
        progress:setTitle(string.format(_("Checking %s… (%d/%d)"), cand.name or cand.repo_full_name, i, #targets))
        progress:setFraction(i / #targets)

        local release, err = GitHub.fetchLatestRelease(cand.repo_owner, cand.repo_name)
        if release and type(release) == "table" and release.tag_name and release.tag_name ~= "" then
            self._checked_releases[cand.repo_full_name] = {
                latest_tag = release.tag_name,
                latest_version = release.tag_name,
            }
            checked = checked + 1
        else
            no_release = no_release + 1
            -- GitHub returns 403 for both "no auth" rate limiting and a
            -- handful of other refusals; either way, further requests this
            -- run are very likely to fail the same way, so stop spending
            -- them rather than grinding through the rest of the list.
            if type(err) == "table" and err.code == 403 then
                rate_limited = true
            end
        end
    end

    UIManager:close(progress)
    self.is_checking_updates = false

    local msg
    if rate_limited then
        msg = string.format(_("GitHub rate limit reached after checking %d of %d repo(s). Try again later."), checked + no_release, #targets)
    else
        msg = string.format(_("Checked %d repo(s): %d have a GitHub release, %d don't."), #targets, checked, no_release)
    end
    StorifyDialogs.showInfoMessage(msg)
    self:showUpdates(scope, needs_update_only)
end

function Storify:showMirrorSettings()
    StorifyDialogs.showMirrorDialog{
        presets = Mirror.getPresets(),
        current_preset = Mirror.getCurrentPresetId(),
        on_select_preset = function(preset_id)
            local ok, err = Mirror.setPreset(preset_id)
            if ok then
                logger.info("storify: mirror preset changed to " .. tostring(Mirror.getCurrentPresetId()))
            else
                logger.err("storify: failed to set mirror preset", err)
            end
        end,
        on_custom_url = function()
            StorifyDialogs.showCustomUrlDialog{
                current_url = Mirror.getCustomUrl(),
                on_save = function(value)
                    local ok, err = Mirror.setPreset("custom", value)
                    if ok then
                        logger.info("storify: custom mirror URL set to " .. tostring(Mirror.getCurrentPrefix()))
                    else
                        logger.err("storify: failed to set custom mirror URL", err)
                    end
                end,
            }
        end,
    }
end

function Storify:refreshCatalog(on_complete)
    if self.is_refreshing then return end
    self.is_refreshing = true

    local progress = StorifyProgress:new{ title = _("Refreshing catalog…") }
    progress:show()

    local function done(ok, msg)
        self.is_refreshing = false
        UIManager:close(progress)
        if on_complete then on_complete(ok, msg) end
    end

    Crawler.refreshCatalog{
        kind = "all",
        on_progress = function(fraction, status_text)
            if status_text then
                progress:setTitle(status_text)
            end
            progress:setFraction(fraction)
        end,
        should_cancel = function()
            return progress:cancelled()
        end,
        on_complete = function(ok, err)
            done(ok, err)
        end,
    }
end

local function resolvePluginDir(item)
    if not item then return nil end
    if item.dir_path and item.dir_path ~= "" then
        return item.dir_path
    end
    local root = (PluginPaths.resolveInstallDestination and PluginPaths.resolveInstallDestination())
        or (PluginPaths.getDefaultPluginsRoot and PluginPaths.getDefaultPluginsRoot())
        or "plugins"
    local raw_name = item.dirname or item.name or item.id or "plugin"
    local dirname = raw_name:match("%.koplugin$") and raw_name or (raw_name .. ".koplugin")
    return root .. "/" .. dirname
end

function Storify:handleInstallRequest(item)
    if not item then return end
    if item.is_patch or item.kind == "patch" then
        -- A patch is one .lua file dropped into DataStorage:getPatchesDir(),
        -- not a zip archive to extract into plugins/ -- handleInstallPatchFile
        -- also covers the "update available" reinstall path from the patches
        -- scope of showUpdates(), since that candidate carries the same
        -- filename/owner/repo/path/download_url shape.
        return self:handleInstallPatchFile(item)
    end
    local msg = string.format(_("Do you want to install %s?"), item.name or item.full_name or "package")

    StorifyDialogs.showRestartDialog(msg, {
        confirm_text = _("Install"),
        on_confirm = function()
            local dest_dir = resolvePluginDir(item)
            if not dest_dir or dest_dir == "" then
                logger.err("storify: invalid install destination for", item.name)
                return
            end
            local archive_url = item.download_url
                or (item.release and (item.release.zipball_url or item.release.tarball_url))
                or (item.full_name and string.format("https://api.github.com/repos/%s/zipball", item.full_name))
            if not archive_url then
                logger.err("storify: no download URL found for", item.name)
                return
            end
            local rewritten_url = Mirror.apply(archive_url)

            local tmp_archive = DataStorage:getDataDir() .. "/cache/storify/download.tmp"
            local dl_ok, dl_err = Net.requestToFile({ url = rewritten_url }, tmp_archive)
            if not dl_ok then
                logger.err("storify install download failed", dl_err)
                return
            end

            local ok, err = Installer.installPackage({
                archive_path = tmp_archive,
                target_dir = dest_dir,
                config_patterns = { "settings/.*", ".*%.json", ".*%.lua" },
            })
            os.remove(tmp_archive)

            if ok then
                local key = item.id or item.name or item.dirname
                -- repo_owner/repo_name/repo_full_name (not just the bare `repo`
                -- string) are what prepareUpdateCandidates() looks up by --
                -- matches the record shape handleManualLink() writes, so a
                -- fresh install is immediately recognized as linked instead of
                -- showing "Unlinked" until a disk-scan reconciliation backfills it.
                local owner, repo_name
                if item.full_name then
                    owner, repo_name = item.full_name:match("^([^/]+)/(.*)$")
                end
                Installs.upsert(key, {
                    version = item.version or (item.release and item.release.tag_name) or "unknown",
                    repo = item.full_name,
                    repo_owner = owner,
                    repo_name = repo_name,
                    repo_full_name = item.full_name,
                    installed_at = os.time(),
                })
                StorifyDialogs.showRestartDialog(_("Installation successful! Restart KOReader now?"), {
                    on_confirm = function() UIManager:restartKOReader() end,
                })
            else
                logger.err("storify installation failed", err)
            end
        end,
    })
end

-- Installs a single patch .lua file to DataStorage:getPatchesDir() (KOReader
-- runs everything there flat, sorted by filename -- see userpatch.lua -- so
-- this must NOT go through Installer.installPackage's zip-extraction path).
-- Called both for a fresh install from showPatchFileBrowser() and for the
-- "update available" reinstall from the patches scope of showUpdates(); both
-- item shapes carry filename/owner/repo/path/download_url.
function Storify:handleInstallPatchFile(item)
    if not item then return end
    local filename = item.filename or item.name
    local download_url = item.download_url
    if not filename or not download_url then
        logger.err("storify: invalid patch install item", filename)
        return
    end

    local msg = string.format(_("Do you want to install the patch %s?"), filename)
    StorifyDialogs.showRestartDialog(msg, {
        confirm_text = _("Install"),
        on_confirm = function()
            local patches_dir = DataStorage:getPatchesDir()
            if ffiUtil.makePath then
                ffiUtil.makePath(patches_dir)
            end
            local dest_path = patches_dir .. "/" .. filename
            local rewritten_url = Mirror.apply(download_url)

            local dl_ok, dl_err = Net.requestToFile({ url = rewritten_url }, dest_path)
            if not dl_ok then
                logger.err("storify patch install download failed", dl_err)
                return
            end

            Installs.upsertPatch(filename, {
                filename = filename,
                owner = item.owner,
                repo = item.repo,
                path = item.path,
                sha = item.sha or item.latest_sha,
                installed_at = os.time(),
            })
            StorifyDialogs.showRestartDialog(_("Patch installed! Restart KOReader now?"), {
                on_confirm = function() UIManager:restartKOReader() end,
            })
        end,
    })
end

-- Browse User Patches lists patch-*collection* repos, not individual files --
-- tapping one drills into its indexed .lua files (fetched lazily on first
-- visit; see Crawler.fetchPatchFileTree for why this isn't done eagerly for
-- every repo up front) and lets the user install exactly one.
function Storify:showPatchFileBrowser(repo)
    if not repo then return end
    local files = Cache.listPatchFiles(repo.repo_id)
    if #files == 0 then
        local ok, err = Crawler.fetchPatchFileTree(repo)
        if not ok then
            logger.err("storify: patch tree fetch failed for", repo.full_name or repo.name, err)
            StorifyDialogs.showInfoMessage(string.format(_("Could not load patch files for %s."), repo.full_name or repo.name or ""))
            return
        end
        files = Cache.listPatchFiles(repo.repo_id)
    end
    if #files == 0 then
        StorifyDialogs.showInfoMessage(_("No .lua patch files found in this repository."))
        return
    end

    StorifyDialogs.showPatchFileList(repo.full_name or repo.name, files, {
        on_select = function(file)
            self:handlePatchFileDetails(repo, file)
        end,
    })
end

-- The per-file detail dialog (StorifyDialogs.showPatchDetails) already
-- existed, fully built, but nothing ever called it -- this is that call site.
function Storify:handlePatchFileDetails(repo, file)
    if not repo or not file then return end
    local is_installed = Installs.getPatch(file.filename) ~= nil
    StorifyDialogs.showPatchDetails(repo, file, {
        is_installed = is_installed,
        on_install = function(details_repo, patch)
            self:handleInstallPatchFile({
                filename = patch.filename,
                path = patch.path,
                sha = patch.sha,
                download_url = patch.download_url,
                owner = details_repo.owner,
                repo = details_repo.name,
            })
        end,
        on_uninstall = function(_details_repo, patch)
            self:handleDelete({ kind = "patch", filename = patch.filename })
        end,
        -- A single patch file has no README of its own; showPatchDetails
        -- passes the parent repo through, so this reuses the same
        -- repo-README fetch handleDetailsRequest already uses for plugins.
        on_readme = function(details_repo)
            self:handleReadmeRequest(details_repo)
        end,
    })
end

function Storify:handleDetailsRequest(item)
    if not item then return end
    if item.kind == "patch" then
        return self:showPatchFileBrowser(item)
    end
    StorifyDialogs.showPluginDetails(item, {
        on_install = function() self:handleInstallRequest(item) end,
        on_readme = function() self:handleReadmeRequest(item) end,
    })
end

function Storify:handleReadmeRequest(item)
    if not item then return end
    -- ponytail: fetchReadme does one blocking HTTP request on the UI thread
    -- (same class as refresh/install). READMEs are small; off-threading the
    -- whole pipeline (subprocess) is the upgrade path, tracked with the P1
    -- async work.
    local ok, path_or_err = RepoContent.fetchReadme(item.owner, item.name)
    if ok and path_or_err then
        RepoContent.openReadme(path_or_err)
    else
        logger.err("storify: README fetch failed for", item.full_name or item.name, path_or_err)
        StorifyDialogs.showInfoMessage(string.format(
            _("Could not load README for %s."), item.full_name or (item.owner and item.name and (item.owner .. "/" .. item.name)) or (item.name or "")
        ))
    end
end

function Storify:handleRollback(item)
    if not item or not item.name then return end
    if item.kind == "patch" then
        -- Patch installs overwrite the single .lua file directly (no staging
        -- dir, no atomic swap -- see handleInstallPatchFile), so there is no
        -- .bak to roll back to yet.
        StorifyDialogs.showInfoMessage(_("Patches can't be rolled back yet."))
        return
    end
    local dest_dir = resolvePluginDir(item)
    local bak_dir = dest_dir .. ".bak"
    local ok, err = Installer.rollback(dest_dir, bak_dir)
    if ok then
        StorifyDialogs.showRestartDialog(_("Rollback completed. Restart KOReader now?"), {
            on_confirm = function() UIManager:restartKOReader() end,
        })
    else
        logger.err("storify rollback failed", err)
    end
end

function Storify:handleDelete(item)
    if not item or not (item.name or item.id or item.dirname or item.filename) then return end
    if item.kind == "patch" then
        local filename = item.filename or item.name or item.id
        StorifyDialogs.showDeleteConfirm(
            _("Confirm Deletion"),
            string.format(_("Are you sure you want to remove %s?"), filename),
            function()
                local dest_path = DataStorage:getPatchesDir() .. "/" .. filename
                os.remove(dest_path)
                Installs.removePatch(filename)
                StorifyDialogs.showRestartDialog(_("Patch removed. Restart KOReader now?"), {
                    on_confirm = function() UIManager:restartKOReader() end,
                })
            end
        )
        return
    end
    local key = item.id or item.name or item.dirname
    StorifyDialogs.showDeleteConfirm(
        _("Confirm Deletion"),
        string.format(_("Are you sure you want to remove %s?"), key),
        function()
            local dest_dir = resolvePluginDir(item)
            if dest_dir and dest_dir ~= "" and dest_dir ~= "/" and dest_dir:match("%.koplugin$") then
                os.execute("rm -rf " .. string.format("%q", dest_dir))
            end
            Installs.remove(key)
            StorifyDialogs.showRestartDialog(_("Plugin removed. Restart KOReader now?"), {
                on_confirm = function() UIManager:restartKOReader() end,
            })
        end
    )
end

function Storify:handleBatchUpdate(selected_items)
    if not selected_items or #selected_items == 0 then return end
    for _, item in ipairs(selected_items) do
        self:handleInstallRequest(item)
    end
end

function Storify:scanDiskPlugins(on_complete)
    local lookup_paths = PluginPaths.getLookupPaths and PluginPaths.getLookupPaths() or { "plugins" }
    local scanned = Matcher.scanInstalledPlugins(lookup_paths)
    local repos = Cache.listRepos()
    Installs.syncFromDisk(scanned, repos)
    if on_complete then
        on_complete(scanned)
    end
end

function Storify:handleManualLink(item)
    if not item then return end
    local repos = Cache.listRepos()
    StorifyDialogs.showManualLinkDialog(item, repos, {
        on_link = function(full_name, repo)
            local owner, repo_name = full_name:match("^([^/]+)/(.*)$")
            if not owner then
                owner = repo and repo.owner or "custom"
                repo_name = full_name
            end
            local key = item.id or item.name or item.dirname
            local existing = Installs.get(key) or {}
            existing.id = key
            existing.name = item.name or key
            existing.dirname = item.dirname or (item.name and item.name .. ".koplugin") or key
            existing.repo = full_name
            existing.repo_owner = owner
            existing.repo_name = repo_name
            existing.repo_full_name = full_name
            existing.unlinked = nil
            existing.version = item.version or item.current_version or existing.version
            Installs.upsert(key, existing)
            self:showUpdates()
        end,
        on_delete = function(plugin_item)
            self:handleDelete(plugin_item)
        end,
    })
end

return Storify
