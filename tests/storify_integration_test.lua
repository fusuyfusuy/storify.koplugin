-- tests/storify_integration_test.lua
-- Full Lifecycle Integration & Static Scope Audit Suite

package.path = "./?.lua;./core/?.lua;./data/?.lua;./net/?.lua;./ui/?.lua;./l10n/?.lua;./tests/stubs/?.lua;./tests/?.lua;" .. package.path

local Stubs = require("tests/stubs/koreader_stubs")
local Storify = require("main")
local Cache = require("data/storify_cache")
local Installs = require("data/storify_installs")
local Settings = require("data/storify_settings")
local PluginPaths = require("data/storify_plugin_paths")
local Version = require("core/storify_version")
local Manifest = require("core/storify_manifest")
local Matcher = require("core/storify_matcher")
local Installer = require("core/storify_installer")
local Net = require("net/storify_net")
local GitHub = require("net/storify_net_github")
local Mirror = require("net/storify_mirror")
local RepoContent = require("net/storify_repo_content")
local Crawler = require("net/storify_crawler")

local failures = 0
local function check(label, got, expected)
    local ok = (got == expected)
    if ok then
        print(string.format("  ✓ PASS: %s", label))
    else
        failures = failures + 1
        print(string.format("  ❌ FAIL: %s | Expected: %s, Got: %s", label, tostring(expected), tostring(got)))
    end
end

print("\n--- 1. Testing Plugin Lifecycle & Menu Hooks ---")
local app = Storify:new()
check("app name", app.name, "storify")
check("is_doc_only", app.is_doc_only, false)

local menu = {}
app:addToMainMenu(menu)
check("menu entry present", type(menu.storify), "table")
check("menu sorting_hint is tools", menu.storify.sorting_hint, "tools")
check("menu entry has sub_item_table", type(menu.storify.sub_item_table), "table")
check("menu sub items count", #menu.storify.sub_item_table, 5)

print("\n--- 2. Testing Dispatcher Action Registration ---")
local registered_actions = {}
local mock_dispatcher = require("dispatcher")
mock_dispatcher.registerAction = function(self, action_name, action_def)
    registered_actions[action_name] = action_def
end
app:onDispatcherRegisterActions()
check("browse_plugins action registered", type(registered_actions["storify_browse_plugins"]), "table")
check("browse_patches action registered", type(registered_actions["storify_browse_patches"]), "table")
check("manage_updates action registered", type(registered_actions["storify_manage_updates"]), "table")
check("refresh_cache action registered", type(registered_actions["storify_refresh_cache"]), "table")

print("\n--- 3. Testing UI Dialog Orchestration ---")
local shown_dialogs = {}
local last_dialog = nil
local mock_uimanager = require("ui/uimanager")
mock_uimanager.show = function(self, dialog)
    table.insert(shown_dialogs, dialog)
    last_dialog = dialog
end

app:showBrowser("plugins")
check("browser dialog shown", #shown_dialogs, 1)

app:showUpdates("all")
check("updates dialog shown", #shown_dialogs, 2)

app:showMirrorSettings()
check("mirror settings dialog shown", #shown_dialogs, 3)

print("\n--- 3b. Regression: mirror dialog is wired (presets + custom URL) ---")
-- UI-drive finding: showMirrorSettings passed no presets and no on_custom_url,
-- leaving the mirror dialog a dead stub.
local mirror_dialog = last_dialog
local expected_presets = #Mirror.getPresets()
local button_count = 0
for _, row in ipairs(mirror_dialog.buttons or {}) do
    button_count = button_count + #row
end
check("mirror dialog lists all presets plus custom row", button_count, expected_presets + 1)

local function findButtonIn(dialog, fragment)
    for _, row in ipairs(dialog.buttons or {}) do
        for _, btn in ipairs(row) do
            if type(btn.text) == "string" and btn.text:find(fragment, 1, true) then
                return btn
            end
        end
    end
    return nil
end

-- Select a preset through the dialog -> Mirror settings persist it.
local preset_btn = findButtonIn(mirror_dialog, "Direct")
check("preset button present in dialog", preset_btn ~= nil, true)
if preset_btn then
    preset_btn.callback()
end
check("preset selection persists via Mirror.setPreset", Mirror.getCurrentPresetId() == "direct", true)

-- Custom URL flow: tap the custom row -> InputDialog -> Save -> persisted.
local custom_btn = findButtonIn(mirror_dialog, "Custom mirror URL") or findButtonIn(mirror_dialog, "Custom mirror")
check("custom URL button present", custom_btn ~= nil, true)
if custom_btn then
    custom_btn.callback()
end
local input_dialog = shown_dialogs[#shown_dialogs]
check("custom URL opens InputDialog", type(input_dialog), "table")
local save_btn = findButtonIn(input_dialog, "Save")
check("custom URL dialog has Save", save_btn ~= nil, true)
local test_url = "https://ghproxy.test/"
input_dialog.getInputText = function() return test_url end
input_dialog.input = test_url
if save_btn then save_btn.callback() end
check("custom URL persisted via Mirror.setPreset", Mirror.getCustomUrl(), test_url)
check("preset switched to custom", Mirror.getCurrentPresetId(), "custom")

print("\n--- 3c. Regression: README request fetches then opens (UI-drive finding) ---")
-- handleReadmeRequest used to call openReadme(owner, name) with the wrong
-- signature (local-file path), so the README feature always failed.
local test_item = { owner = "octocat", name = "Hello-World", full_name = "octocat/Hello-World" }
local fetched_path = "/tmp/fake_readme.md"
local opened_path = nil
local orig_fetch = RepoContent.fetchReadme
local orig_open = RepoContent.openReadme
RepoContent.fetchReadme = function(owner, repo)
    check("readme fetch called with owner", owner, test_item.owner)
    check("readme fetch called with repo", repo, test_item.name)
    return true, fetched_path
end
RepoContent.openReadme = function(path)
    opened_path = path
end
app:handleReadmeRequest(test_item)
check("readme opens the fetched path", opened_path, fetched_path)
RepoContent.fetchReadme = orig_fetch
RepoContent.openReadme = orig_open

-- Failure path surfaces an info message instead of a silent no-op.
local shown_before = #shown_dialogs
RepoContent.fetchReadme = function() return false, "boom" end
app:handleReadmeRequest(test_item)
check("readme failure shows an info message", #shown_dialogs, shown_before + 1)
RepoContent.fetchReadme = orig_fetch

print("\n--- 3a. Regression: showBrowser()/showUpdates() close prior dialog instead of stacking ---")
-- Bug: pagination/refresh/scan callbacks re-invoke showBrowser()/showUpdates(),
-- which used to always construct+show a fresh full-screen dialog without ever
-- closing the one already on screen, stacking phantom dialogs. Track close()
-- calls the same way `show` is already tracked above, and assert re-entrant
-- calls close the previously-tracked instance before replacing it.
local closed_dialogs = {}
mock_uimanager.close = function(self, dialog) table.insert(closed_dialogs, dialog) end

local prior_browser_dialog = app._browser_dialog
check("prior browser dialog captured", prior_browser_dialog ~= nil, true)
app:showBrowser("plugins")
check("re-entrant showBrowser closes prior instance", closed_dialogs[1], prior_browser_dialog)
check("browser dialog reference replaced", app._browser_dialog ~= prior_browser_dialog, true)

local prior_updates_dialog = app._updates_dialog
check("prior updates dialog captured", prior_updates_dialog ~= nil, true)
app:showUpdates("all")
check("re-entrant showUpdates closes prior instance", closed_dialogs[2], prior_updates_dialog)
check("updates dialog reference replaced", app._updates_dialog ~= prior_updates_dialog, true)

print("\n--- 3b. Testing showBrowser() Glue: Raw Repo Rows -> Renderable Entries ---")
-- Regression coverage for the "blank browser list" bug: Cache.listRepos() returns
-- raw repo records (name/full_name/description/stars/...) with none of the fields
-- StorifyListItem needs to render a tappable row (text/callback/is_entry). This
-- seeds a real repo into the cache and asserts showBrowser() actually bridges
-- the gap, rather than passing the raw record straight through.
Cache.storeRepos("plugin", {
    {
        id = 901,
        name = "GlueTestPlugin",
        full_name = "author/GlueTestPlugin",
        description = "Exercises the showBrowser entry-shaping glue",
        stargazers_count = 42,
        owner = { login = "author" },
    },
})
app:showBrowser("plugins")
local browser_dialog = last_dialog
local first_entry = browser_dialog and browser_dialog.items and browser_dialog.items[1]
check("glued entry exists", type(first_entry), "table")
check("glued entry has non-empty text", type(first_entry) == "table" and first_entry.text ~= nil and first_entry.text ~= "", true)
check("glued entry text mentions repo name", type(first_entry) == "table" and first_entry.text ~= nil and first_entry.text:find("GlueTestPlugin", 1, true) ~= nil, true)
check("glued entry has a callback", type(first_entry) == "table" and type(first_entry.callback), "function")
check("glued entry marked is_entry", type(first_entry) == "table" and first_entry.is_entry, true)
check("dialog page set from pagination", browser_dialog and browser_dialog.page, 1)
check("dialog total_pages set from pagination", browser_dialog and browser_dialog.total_pages, 1)

print("\n--- 3c. Regression: showUpdates() recognizes an installed+cached repo as linked ---")
-- Bug: Cache.listRepos() returns an array, but prepareUpdateCandidates() looks
-- remote info up by string key (repos_meta[repo_key]) -- passing the array
-- straight through as `{repos = repos}` left array[string] always nil, so
-- every installed plugin showed "Unlinked" forever, even ones with a matching
-- cached repo and a fully-populated repo_full_name. buildRepoMap() in main.lua
-- fixes this by indexing the array by full_name/name before the lookup.
Installs.upsert("gluetestplugin", {
    id = "gluetestplugin",
    name = "GlueTestPlugin",
    dirname = "GlueTestPlugin.koplugin",
    version = "1.0.0",
    repo = "author/GlueTestPlugin",
    repo_owner = "author",
    repo_name = "GlueTestPlugin",
    repo_full_name = "author/GlueTestPlugin",
    installed_at = os.time(),
})
app:showUpdates("all")
local updates_dialog = last_dialog
local linked_cand = nil
for _, cand in ipairs(updates_dialog and updates_dialog.items or {}) do
    if cand.id == "gluetestplugin" then linked_cand = cand end
end
check("installed+cached plugin found in candidates", type(linked_cand), "table")
check("installed+cached plugin is not unlinked", linked_cand and linked_cand.status, "up_to_date")

print("\n--- 3d. Regression: handleInstallRequest() records repo_owner/repo_name/repo_full_name ---")
-- Bug: the success handler only wrote {version, repo, installed_at} -- a bare
-- "owner/repo" string in `repo`. prepareUpdateCandidates() needs repo_full_name
-- (or repo_owner+repo_name), which nothing wrote, so a plugin installed
-- through the normal Browse -> Install flow showed "Unlinked" until a disk
-- rescan happened to backfill it (and syncFromDisk's stale-check treats a bare
-- `repo` string as "already linked", so it never did). Matches the record
-- shape handleManualLink() writes.
local orig_request_to_file = Net.requestToFile
local orig_install_package = Installer.installPackage
Net.requestToFile = function() return true end
Installer.installPackage = function() return true, "/fake/install/path" end

local install_item = {
    id = "freshinstall",
    name = "freshinstall",
    full_name = "acme/freshinstall.koplugin",
    dirname = "freshinstall.koplugin",
    dir_path = Stubs.test_dir .. "/freshinstall.koplugin",
    version = "3.0.0",
    download_url = "https://example.com/freshinstall.zip",
}
app:handleInstallRequest(install_item)
check("install confirm dialog shown", type(last_dialog), "table")
if last_dialog and type(last_dialog.ok_callback) == "function" then
    last_dialog.ok_callback()
end

local fresh_record = Installs.get("freshinstall")
check("fresh install record exists", type(fresh_record), "table")
check("fresh install records repo_owner", fresh_record and fresh_record.repo_owner, "acme")
check("fresh install records repo_name", fresh_record and fresh_record.repo_name, "freshinstall.koplugin")
check("fresh install records repo_full_name", fresh_record and fresh_record.repo_full_name, "acme/freshinstall.koplugin")

Net.requestToFile = orig_request_to_file
Installer.installPackage = orig_install_package

print("\n--- 3e. Regression: \"Show needs update\" filter (on_toggle_filter) ---")
-- The toolbar button was previously unwired: main.lua never set on_toggle_filter,
-- so tapping it did nothing. Mock prepareUpdateCandidates so the filter can be
-- tested without needing a real update_available candidate (Cache.listRepos()
-- rows have no latest_version/latest_tag field in the current schema -- nothing
-- populates one yet -- so that status can't be produced through the real pipeline).
local Updates = require("ui/storify_updates_dialog")
local updates_model_mod = Updates.UpdatesModel or Updates.Model
local orig_prepare_candidates = updates_model_mod.prepareUpdateCandidates
updates_model_mod.prepareUpdateCandidates = function()
    return {
        { id = "needs_update_one", name = "NeedsUpdateOne", kind = "plugin", status = "update_available", has_update = true },
        { id = "up_to_date_one", name = "UpToDateOne", kind = "plugin", status = "up_to_date", has_update = false },
    }
end

app:showUpdates("plugins", false)
check("unfiltered view includes both candidates", #last_dialog.items, 2)
check("unfiltered filter_label reads Show needs update", last_dialog.filter_label, "Show needs update")

app:showUpdates("plugins", true)
check("filtered view keeps only the has_update candidate", #last_dialog.items, 1)
check("filtered view kept the right candidate", last_dialog.items[1] and last_dialog.items[1].id, "needs_update_one")
check("filtered filter_label reads Show all", last_dialog.filter_label, "Show all")

updates_model_mod.prepareUpdateCandidates = orig_prepare_candidates

print("\n--- 3f. Regression: \"Switch to patches\" scope (on_switch_target) ---")
-- Also previously unwired. Seeds a full, real patch-collection repo + one
-- indexed patch file + one installed-patch record through the actual Cache/
-- Installs plumbing (not mocked), proving buildPatchesMap()'s repo_id join
-- and prepareUpdateCandidates()'s patch branch work end-to-end -- ready for
-- whenever patch installs are tracked, even though nothing does yet.
Cache.storeRepos("patch", {
    {
        id = 555,
        name = "patchrepo",
        full_name = "patchauthor/patchrepo",
        description = "A patch collection",
        stargazers_count = 3,
        owner = { login = "patchauthor" },
    },
})
Cache.storePatchFiles(555, {
    {
        path = "10-test-patch.lua",
        filename = "10-test-patch.lua",
        branch = "main",
        sha = "aaaa1111",
        size = 100,
        download_url = "https://example.com/10-test-patch.lua",
    },
})
Installs.upsertPatch("10-test-patch.lua", {
    filename = "10-test-patch.lua",
    owner = "patchauthor",
    repo = "patchrepo",
    path = "10-test-patch.lua",
    sha = "aaaa1111",
})

app:showUpdates("patches", false)
check("switching to patches sets the patch-scoped title", last_dialog.title, "Storify · Patch Updates")
local patch_cand = nil
for _, cand in ipairs(last_dialog.items or {}) do
    if cand.id == "10-test-patch.lua" then patch_cand = cand end
end
check("installed+indexed patch found in candidates", type(patch_cand), "table")
check("installed+indexed patch with matching sha is up_to_date", patch_cand and patch_cand.status, "up_to_date")

app:showUpdates("plugins", false)
check("switching back to plugins restores the plugin-scoped title", last_dialog.title, "Storify · Updates")

print("\n--- 3g. Regression: \"Match with repo\" bulk retry (on_match) ---")
-- Also previously unwired. Seeds an unlinked installed plugin whose dirname
-- matches a cached repo's name (the same matching Matcher.findMatchingRepo
-- already does passively in syncFromDisk), then exercises the explicit
-- on_match retry path via handleMatchWithRepo directly.
Cache.storeRepos("plugin", {
    {
        id = 902,
        name = "MatchTarget",
        full_name = "matchowner/MatchTarget",
        description = "Exercises the Match with repo bulk retry",
        stargazers_count = 7,
        owner = { login = "matchowner" },
    },
})
Installs.upsert("matchtestplugin", {
    id = "matchtestplugin",
    name = "MatchTarget",
    dirname = "MatchTarget.koplugin",
    version = "1.0.0",
    unlinked = true,
    installed_at = os.time(),
})
app:showUpdates("plugins", false)
app:handleMatchWithRepo("plugins", false)
local matched_record = Installs.get("matchtestplugin")
check("Match with repo links a previously-unlinked plugin", matched_record and matched_record.repo_full_name, "matchowner/MatchTarget")
check("Match with repo clears the unlinked flag", matched_record and matched_record.unlinked, nil)

local patches_scope_info_shown = false
for _, dialog in ipairs(shown_dialogs) do
    if dialog and dialog.text and tostring(dialog.text):find("Matching isn't available for patches yet", 1, true) then
        patches_scope_info_shown = true
    end
end
app:handleMatchWithRepo("patches", false)
for _, dialog in ipairs(shown_dialogs) do
    if dialog and dialog.text and tostring(dialog.text):find("Matching isn't available for patches yet", 1, true) then
        patches_scope_info_shown = true
    end
end
check("Match with repo declines to act on the patches scope", patches_scope_info_shown, true)

print("\n--- 3h. Regression: \"Check all updates\" live release check (on_check_updates) ---")
-- Also previously unwired. The awesome.koreader catalog itself rarely carries
-- a version/tag (see .agents/memory.md), so without a live per-repo check
-- prepareUpdateCandidates() has nothing but presence-in-catalog to compare --
-- this mocks GitHub.fetchLatestRelease so the fetched tag flows through
-- self._checked_releases and actually flips a candidate to update_available.
local orig_fetch_latest_release = GitHub.fetchLatestRelease
GitHub.fetchLatestRelease = function(owner, repo)
    if owner == "matchowner" and repo == "MatchTarget" then
        return { tag_name = "v2.0.0" }, nil
    end
    return nil, { code = 404, body = "Not Found" }
end

app:showUpdates("plugins", false)
app:handleCheckAllUpdates("plugins", false)
check("checked release stashed for the linked repo", app._checked_releases
    and app._checked_releases["matchowner/MatchTarget"]
    and app._checked_releases["matchowner/MatchTarget"].latest_tag, "v2.0.0")

local checked_cand = nil
for _, cand in ipairs(last_dialog.items or {}) do
    if cand.id == "matchtestplugin" then checked_cand = cand end
end
check("candidate reflects the fetched release as an available update", checked_cand and checked_cand.status, "update_available")
check("candidate carries the fetched latest_version for display", checked_cand and checked_cand.latest_version, "v2.0.0")

GitHub.fetchLatestRelease = orig_fetch_latest_release

print("\n--- 3i. Regression: \"Check all updates\" stops early on a rate limit ---")
local fetch_calls = 0
GitHub.fetchLatestRelease = function()
    fetch_calls = fetch_calls + 1
    return nil, { code = 403, body = "API rate limit exceeded" }
end
-- Seed a second linked plugin so there's more than one target to check --
-- otherwise stopping "early" after 1 call is indistinguishable from stopping
-- after all of them.
Installs.upsert("secondlinkedplugin", {
    id = "secondlinkedplugin",
    name = "SecondLinked",
    dirname = "SecondLinked.koplugin",
    version = "1.0.0",
    repo_owner = "someowner",
    repo_name = "SecondLinked",
    repo_full_name = "someowner/SecondLinked",
    installed_at = os.time(),
})
app:showUpdates("plugins", false)
app:handleCheckAllUpdates("plugins", false)
check("rate-limited check stops after the first failure instead of grinding through every target", fetch_calls, 1)

GitHub.fetchLatestRelease = orig_fetch_latest_release
Installs.remove("secondlinkedplugin")

print("\n--- 3j. Regression: \"Check all updates\" declines to act on the patches scope ---")
local check_updates_patches_info_shown = false
app:handleCheckAllUpdates("patches", false)
for _, dialog in ipairs(shown_dialogs) do
    if dialog and dialog.text and tostring(dialog.text):find("Checking for updates isn't available for patches yet", 1, true) then
        check_updates_patches_info_shown = true
    end
end
check("Check all updates declines to act on the patches scope", check_updates_patches_info_shown, true)

print("\n--- 4. Testing End-to-End Install, Rollback & Delete Flow ---")
local test_plugins_root = Stubs.test_dir .. "/plugins"
local target_plugin_dir = test_plugins_root .. "/dummy.koplugin"
os.execute("mkdir -p " .. target_plugin_dir)

local sample_item = {
    name = "dummy.koplugin",
    full_name = "author/dummy.koplugin",
    version = "2.0.0",
}

Installs.upsert(sample_item.name, {
    version = sample_item.version,
    repo = sample_item.full_name,
    installed_at = os.time(),
})

check("installed record exists", Installs.get(sample_item.name).version, "2.0.0")

-- Test installer installPackage and rollback
local test_staging = test_plugins_root .. "/test_staging.koplugin"
os.execute("mkdir -p " .. test_staging .. " && echo 'test' > " .. test_staging .. "/main.lua")
local ok_rb, rb_err = Installer.rollback(test_staging, test_staging .. ".bak")
check("rollback fails safely if backup missing", ok_rb, false)

app:handleDelete(sample_item)
if last_dialog and type(last_dialog.ok_callback) == "function" then
    last_dialog.ok_callback()
end
check("deleted record removed from store", Installs.get(sample_item.name), nil)

print("\n--- 4a. Regression: Patch install end-to-end (browse -> file list -> details -> install) ---")
-- Patch installs were never tracked anywhere: handleInstallRequest always
-- zip-extracted into plugins/ regardless of item.kind, Installs.upsertPatch()
-- was never called, and Browse User Patches only ever listed patch-collection
-- repos with no drill-down to individual .lua files (the actual installable
-- unit). Also: StorifyDialogs.showPatchDetails already existed, fully built,
-- but nothing ever called it. This exercises the whole real chain.

Cache.storeRepos("patch", {
    {
        id = 701,
        name = "patchcollection",
        full_name = "patchauthor/patchcollection",
        description = "A patch collection for the install flow test",
        stargazers_count = 5,
        owner = { login = "patchauthor" },
        default_branch = "main",
    },
})
local patch_repos = Cache.listRepos("patch")
local test_repo = nil
for _, r in ipairs(patch_repos) do
    if r.full_name == "patchauthor/patchcollection" then test_repo = r end
end
check("seeded patch-collection repo present in cache", type(test_repo), "table")

-- 4a.1: Browse Patches drill-down triggers a lazy tree fetch (patch_files
-- is never populated eagerly by the awesome.koreader fast path -- see the
-- Crawler.fetchPatchFileTree comment) and shows the resulting file list.
check("no patch files indexed yet (lazy, not eager)", #Cache.listPatchFiles(test_repo.repo_id), 0)

local orig_fetch_repo_tree = GitHub.fetchRepoTree
GitHub.fetchRepoTree = function(owner, repo, branch)
    check("tree fetch uses the repo's owner", owner, "patchauthor")
    check("tree fetch uses the repo's name", repo, "patchcollection")
    return {
        tree = {
            { path = "10-example-patch.lua", sha = "deadbeef", size = 42, type = "blob" },
            { path = "README.md", sha = "notlua0", size = 10, type = "blob" }, -- must be filtered out
        },
    }, nil
end

app:handleDetailsRequest(test_repo)
GitHub.fetchRepoTree = orig_fetch_repo_tree

local indexed_files = Cache.listPatchFiles(test_repo.repo_id)
check("tree fetch indexed exactly the one .lua file", #indexed_files, 1)
check("indexed file has the right filename", indexed_files[1] and indexed_files[1].filename, "10-example-patch.lua")

local file_list_dialog = last_dialog
check("file list dialog shown", type(file_list_dialog), "table")
check("file list dialog title names the repo", file_list_dialog and file_list_dialog.title, "patchauthor/patchcollection")

-- 4a.2: Tapping a file in the list shows the (previously orphaned)
-- showPatchDetails dialog with real install/delete/README actions wired.
local file_button = nil
for _, row in ipairs(file_list_dialog and file_list_dialog.buttons or {}) do
    for _, btn in ipairs(row) do
        if btn.text == "10-example-patch.lua" then file_button = btn end
    end
end
check("file button present in the list", type(file_button), "table")
file_button.callback()

local details_dialog = last_dialog
check("patch details dialog shown", type(details_dialog), "table")

-- 4a.3: Installing from the details dialog downloads straight to
-- DataStorage:getPatchesDir() (never through Installer.installPackage's zip
-- path) and records the install via Installs.upsertPatch().
local orig_request_to_file2 = Net.requestToFile
local downloaded_to = nil
Net.requestToFile = function(opts, dest)
    downloaded_to = dest
    return true
end

local install_row = details_dialog and details_dialog.other_buttons and details_dialog.other_buttons[1]
local install_btn = nil
if install_row then
    for _, btn in ipairs(install_row) do
        if btn.text == "Install patch" then install_btn = btn end
    end
end
check("install patch button present in details dialog", type(install_btn), "table")
install_btn.callback()
-- Only confirm the install prompt itself, not the follow-up "Restart now?"
-- prompt -- same as the plugin install regression in section 3d, since
-- confirming that one calls the real UIManager:restartKOReader(), which the
-- headless stubs don't implement (nor should this test trigger a restart).
if last_dialog and type(last_dialog.ok_callback) == "function" then
    last_dialog.ok_callback()
end

check("patch downloaded to the real patches dir, not a staging/plugin path",
    downloaded_to, Stubs.test_dir .. "/patches/10-example-patch.lua")
local installed_patch_record = Installs.getPatch("10-example-patch.lua")
check("installed patch record exists", type(installed_patch_record), "table")
check("installed patch record has the right owner", installed_patch_record and installed_patch_record.owner, "patchauthor")
check("installed patch record has the right repo", installed_patch_record and installed_patch_record.repo, "patchcollection")
check("installed patch record has the right path", installed_patch_record and installed_patch_record.path, "10-example-patch.lua")

Net.requestToFile = orig_request_to_file2

-- 4a.4: The patches scope of showUpdates() now finds a real installed patch.
app:showUpdates("patches", false)
local patch_cand = nil
for _, cand in ipairs(last_dialog.items or {}) do
    if cand.id == "10-example-patch.lua" then patch_cand = cand end
end
check("installed patch appears in the patches-scope updates view", type(patch_cand), "table")

-- 4a.5: Deleting a patch removes the file and the tracked record (not the
-- plugin Installs store).
app:handleDelete({ kind = "patch", filename = "10-example-patch.lua" })
if last_dialog and type(last_dialog.ok_callback) == "function" then
    last_dialog.ok_callback()
end
check("deleted patch record removed from the patch store", Installs.getPatch("10-example-patch.lua"), nil)

-- 4a.6: Rollback on a patch is a graceful no-op message, not a crash or a
-- plugin-style .bak restore attempt.
local info_shown_before = #shown_dialogs
app:handleRollback({ kind = "patch", name = "10-example-patch.lua" })
check("rollback on a patch shows an info message instead of attempting a restore", #shown_dialogs, info_shown_before + 1)

print("\n--- 5. Static Scope & LuaJIT Local Variable Limit Audit ---")
local p = io.popen("find core data net ui l10n main.lua -name '*.lua' 2>/dev/null")
local max_locals_found = 0
local file_with_max = ""

if p then
    for lua_file in p:lines() do
        local f = io.open(lua_file, "r")
        if f then
            local local_count = 0
            for line in f:lines() do
                -- match top-level local definitions
                if line:match("^local%s+[%w_]+") or line:match("^local%s+function") then
                    local_count = local_count + 1
                end
            end
            f:close()
            if local_count > max_locals_found then
                max_locals_found = local_count
                file_with_max = lua_file
            end
            if local_count > 60 then
                failures = failures + 1
                print(string.format("  ❌ FAIL: %s exceeded safe local variable limit (found %d, limit 60)", lua_file, local_count))
            end
        end
    end
    p:close()
end

check("max top-level locals across all modules < 60", max_locals_found <= 60, true)
print(string.format("  (Highest top-level local count: %d in %s)", max_locals_found, file_with_max))

if failures > 0 then
    error(string.format("%d assertion(s) failed in integration test suite", failures))
end
print("\n✓ [storify_integration_test] All integration tests passed cleanly.")
