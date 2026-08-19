-- tests/storify_crawler_test.lua
-- Exhaustive Discovery & Deep Search Engine Test Suite for Storify

package.path = "./?.lua;./core/?.lua;./data/?.lua;./net/?.lua;./ui/?.lua;./l10n/?.lua;./tests/stubs/?.lua;./tests/?.lua;" .. package.path
local Stubs = require("tests/stubs/koreader_stubs")

local Crawler = require("net/storify_crawler")
local GitHub = require("net/storify_net_github")
local Cache = require("data/storify_cache")
local Installs = require("data/storify_installs")
local Matcher = require("core/storify_matcher")
local PluginPaths = require("data/storify_plugin_paths")
local DataStorage = require("datastorage")

local failures = 0
local total_checks = 0

local function check(label, cond, msg)
    total_checks = total_checks + 1
    if cond then
        print("  ✓ PASS: " .. label)
    else
        failures = failures + 1
        print("  ❌ FAIL: " .. label .. (msg and (" (" .. tostring(msg) .. ")") or ""))
    end
end

local function assert_eq(got, expected, label)
    check(label or "equality check", got == expected, string.format("expected %s, got %s", tostring(expected), tostring(got)))
end

print("--> [Test Suite] storify_crawler_test")

-- Store original GitHub methods to restore after tests
local orig_searchRepositories = GitHub.searchRepositories
local orig_fetchRepoTree = GitHub.fetchRepoTree

local function restoreGitHub()
    GitHub.searchRepositories = orig_searchRepositories
    GitHub.fetchRepoTree = orig_fetchRepoTree
end

-- =========================================================================
-- 1. Testing Crawler.buildQueries
-- =========================================================================
print("\n--- 1. Testing Crawler.buildQueries (Dual-branch Adaptive Queries) ---")

do
    -- Plugins (non-fork + fork with stars >= 1)
    local plugin_queries = Crawler.buildQueries("plugin", false)
    check("plugin_queries is array", type(plugin_queries) == "table" and #plugin_queries == 4)
    check("has plugin topic non-fork", plugin_queries[1] == "topic:koreader-plugin fork:false")
    check("has plugin name non-fork", plugin_queries[2] == "in:name \".koplugin\" fork:false")
    check("has plugin topic fork stars>=1", plugin_queries[3] == "topic:koreader-plugin fork:only stars:>=1")
    check("has plugin name fork stars>=1", plugin_queries[4] == "in:name \".koplugin\" fork:only stars:>=1")

    -- Plugins with include_zero_star_forks = true
    local plugin_queries_zero = Crawler.buildQueries("plugin", true)
    check("plugin_queries_zero is array", type(plugin_queries_zero) == "table" and #plugin_queries_zero == 4)
    check("has plugin topic fork all", plugin_queries_zero[3] == "topic:koreader-plugin fork:only")
    check("has plugin name fork all", plugin_queries_zero[4] == "in:name \".koplugin\" fork:only")

    -- Patches (non-fork + fork with stars >= 1)
    local patch_queries = Crawler.buildQueries("patch", false)
    check("patch_queries is array", type(patch_queries) == "table" and #patch_queries == 4)
    check("has patch topic non-fork", patch_queries[1] == "topic:koreader-user-patch fork:false")
    check("has patch name non-fork", patch_queries[2] == "in:name \"KOReader.patches\" fork:false")
    check("has patch topic fork stars>=1", patch_queries[3] == "topic:koreader-user-patch fork:only stars:>=1")
    check("has patch name fork stars>=1", patch_queries[4] == "in:name \"KOReader.patches\" fork:only stars:>=1")

    -- Patches with include_zero_star_forks = true
    local patch_queries_zero = Crawler.buildQueries("patch", true)
    check("patch_queries_zero is array", type(patch_queries_zero) == "table" and #patch_queries_zero == 4)
    check("has patch topic fork all", patch_queries_zero[3] == "topic:koreader-user-patch fork:only")
    check("has patch name fork all", patch_queries_zero[4] == "in:name \"KOReader.patches\" fork:only")

    -- Default fallback
    local default_queries = Crawler.buildQueries()
    check("default queries match plugin queries", type(default_queries) == "table" and #default_queries == 4)
    check("default query 1 is plugin topic", default_queries[1] == "topic:koreader-plugin fork:false")
end

-- =========================================================================
-- 2. Testing Exhaustive Crawling, Pagination & Deduplication
-- =========================================================================
print("\n--- 2. Testing Exhaustive Crawling of Plugin Repositories ---")

do
    Cache.clear()
    local search_calls = {}

    -- Mock GitHub search with pagination and deduplication scenarios
    GitHub.searchRepositories = function(opts)
        table.insert(search_calls, opts)
        if opts.q:find("topic:koreader-plugin fork:false", 1, true) then
            if opts.page == 1 then
                local items = {}
                for i = 1, 100 do
                    table.insert(items, {
                        id = 1000 + i,
                        name = "plugin-" .. i .. ".koplugin",
                        full_name = "author" .. i .. "/plugin-" .. i .. ".koplugin",
                        owner = { login = "author" .. i },
                        stargazers_count = 100 - i,
                        topics = { "koreader-plugin" },
                        fork = false,
                    })
                end
                return { total_count = 120, items = items }, nil
            elseif opts.page == 2 then
                local items = {}
                for i = 101, 120 do
                    table.insert(items, {
                        id = 1000 + i,
                        name = "plugin-" .. i .. ".koplugin",
                        full_name = "author" .. i .. "/plugin-" .. i .. ".koplugin",
                        owner = { login = "author" .. i },
                        stargazers_count = 20,
                        topics = { "koreader-plugin" },
                        fork = false,
                    })
                end
                return { total_count = 120, items = items }, nil
            end
        elseif opts.q:find("in:name \".koplugin\" fork:false", 1, true) then
            -- Returns 1 overlapping item (id 1001) and 1 new item (id 2001)
            return {
                total_count = 2,
                items = {
                    {
                        id = 1001,
                        name = "plugin-1.koplugin",
                        full_name = "author1/plugin-1.koplugin",
                        owner = { login = "author1" },
                        stargazers_count = 99,
                        fork = false,
                    },
                    {
                        id = 2001,
                        name = "special.koplugin",
                        full_name = "developer/special.koplugin",
                        owner = { login = "developer" },
                        stargazers_count = 15,
                        fork = false,
                    }
                }
            }, nil
        else
            -- Other queries return 0 items
            return { total_count = 0, items = {} }, nil
        end
    end

    local progress_updates = {}
    local completed_ok = false
    local completed_err = nil

    local ok, err = Crawler.refreshCatalog{
        kind = "plugin",
        reconcile_disk = false,
        force_crawler = true,
        on_progress = function(fraction, status)
            table.insert(progress_updates, { fraction = fraction, status = status })
        end,
        on_complete = function(success, error_msg)
            completed_ok = success
            completed_err = error_msg
        end
    }

    check("refreshCatalog returns success", ok == true and completed_ok == true)
    check("multiple search queries executed", #search_calls >= 4)
    check("pagination triggered for query 1 (page 1 and page 2)", search_calls[1].page == 1 and search_calls[2].page == 2)
    -- Total unique plugins = 120 from topic query + 1 unique from name query (1 duplicate ignored) = 121
    local count = Cache.countRepos("plugin")
    check("exact deduplicated count stored in cache (121 repos)", count == 121, "got " .. tostring(count))
    check("progress updates emitted", #progress_updates > 0)
    check("final progress reached 1.0", progress_updates[#progress_updates].fraction == 1.0)

    restoreGitHub()
end

-- =========================================================================
-- 3. Testing Deep Crawling of Patch Repositories & Git File Trees
-- =========================================================================
print("\n--- 3. Testing Deep Crawling of Patch Repositories & Git Trees ---")

do
    Cache.clear()
    Cache.clearPatchFiles()

    local tree_fetch_calls = {}

    GitHub.searchRepositories = function(opts)
        if opts.q:find("topic:koreader-user-patch fork:false", 1, true) then
            return {
                total_count = 2,
                items = {
                    {
                        id = 5001,
                        name = "KOReader.patches",
                        full_name = "patcher/KOReader.patches",
                        owner = { login = "patcher" },
                        default_branch = "master",
                        pushed_at = "2026-08-15T10:00:00Z",
                        stargazers_count = 35,
                        fork = false,
                    },
                    {
                        id = 5002,
                        name = "extra-patches",
                        full_name = "user2/extra-patches",
                        owner = { login = "user2" },
                        default_branch = "main",
                        pushed_at = "2026-08-16T12:00:00Z",
                        stargazers_count = 10,
                        fork = false,
                    }
                }
            }, nil
        end
        return { total_count = 0, items = {} }, nil
    end

    GitHub.fetchRepoTree = function(owner, repo, branch)
        table.insert(tree_fetch_calls, { owner = owner, repo = repo, branch = branch })
        if owner == "patcher" and repo == "KOReader.patches" then
            return {
                sha = "root_tree_sha_1",
                tree = {
                    {
                        path = "2-custom-font.lua",
                        mode = "100644",
                        type = "blob",
                        sha = "blob_sha_font_123",
                        size = 1500,
                    },
                    {
                        path = "nested/3-nightmode.lua",
                        mode = "100644",
                        type = "blob",
                        sha = "blob_sha_night_456",
                        size = 2800,
                    },
                    {
                        path = "README.md",
                        mode = "100644",
                        type = "blob",
                        sha = "blob_sha_readme",
                        size = 500,
                    },
                    {
                        path = "nested",
                        mode = "040000",
                        type = "tree",
                        sha = "sub_tree_sha",
                    }
                }
            }, nil
        elseif owner == "user2" and repo == "extra-patches" then
            return {
                sha = "root_tree_sha_2",
                tree = {
                    {
                        path = "99-test-patch.lua",
                        mode = "100644",
                        type = "blob",
                        sha = "blob_sha_test_789",
                        size = 850,
                    }
                }
            }, nil
        end
        return nil, "repo not found"
    end

    -- Pre-insert an orphan patch file for a non-existent repo 9999
    Cache.storePatchFiles(9999, { { path = "orphan.lua", filename = "orphan.lua", size = 100 } }, "2026-01-01T00:00:00Z")
    check("orphan patch present initially", Cache.countPatchFiles(9999) == 1)

    local ok, err = Crawler.refreshCatalog{
        kind = "patch",
        reconcile_disk = false,
    }

    check("refreshCatalog for patches succeeded", ok == true)
    check("both patch repos fetched trees", #tree_fetch_calls == 2)
    check("first tree fetched master branch", tree_fetch_calls[1].branch == "master")
    check("second tree fetched main branch", tree_fetch_calls[2].branch == "main")

    -- Check patch files in cache for repo 5001
    local p_count_5001 = Cache.countPatchFiles(5001)
    check("repo 5001 has 2 extracted .lua patch files", p_count_5001 == 2, "got " .. tostring(p_count_5001))

    local patch_list = Cache.listPatchFiles(5001)
    check("patch 1 filename extracted", patch_list[1].filename == "2-custom-font.lua")
    check("patch 1 sha stored", patch_list[1].sha == "blob_sha_font_123")
    check("patch 1 download url formatted", patch_list[1].download_url == "https://raw.githubusercontent.com/patcher/KOReader.patches/master/2-custom-font.lua")
    check("patch 2 nested filename extracted", patch_list[2].filename == "3-nightmode.lua")
    check("patch 2 path preserved", patch_list[2].path == "nested/3-nightmode.lua")
    check("repo 5001 pushed_at saved", Cache.getPatchFilePushedAt(5001) == "2026-08-15T10:00:00Z")

    -- Check patch files in cache for repo 5002
    check("repo 5002 has 1 patch file", Cache.countPatchFiles(5002) == 1)

    -- Check orphan patch files were pruned
    check("orphan patch for repo 9999 pruned", Cache.countPatchFiles(9999) == 0)

    restoreGitHub()
end

-- =========================================================================
-- 4. Testing Rate Limit (403/429) Detection & Cache Protection
-- =========================================================================
print("\n--- 4. Testing Rate Limit (403/429) Handling & Cache Protection ---")

do
    Cache.clear()
    -- Seed cache with valid existing plugin
    Cache.storeRepos("plugin", {
        {
            id = 9001,
            name = "existing.koplugin",
            full_name = "author/existing.koplugin",
            stargazers_count = 50,
            fork = false,
        }
    })
    check("pre-existing cache has 1 plugin", Cache.countRepos("plugin") == 1)

    -- Mock GitHub returning 403 rate limit error
    GitHub.searchRepositories = function(opts)
        return nil, {
            code = 403,
            body = "API rate limit exceeded for IP",
            is_rate_limit = true,
        }
    end

    local rate_limit_hit = false
    local refresh_ok, refresh_err = Crawler.refreshCatalog{
        kind = "plugin",
        reconcile_disk = false,
        force_crawler = true,
        on_complete = function(success, err_info)
            rate_limit_hit = not success
        end
    }

    check("crawl failed gracefully on rate limit", refresh_ok == false and rate_limit_hit == true)
    check("error details indicate rate limit", type(refresh_err) == "string" and refresh_err:find("rate limit", 1, true) ~= nil)
    check("valid pre-existing cache was NOT wiped", Cache.countRepos("plugin") == 1)
    local preserved = Cache.listRepos("plugin")
    check("preserved repo name intact", preserved[1] and preserved[1].name == "existing.koplugin")

    restoreGitHub()
end

-- =========================================================================
-- 5. Testing Cooperative Cancellation via should_cancel()
-- =========================================================================
print("\n--- 5. Testing Cooperative Cancellation ---")

do
    Cache.clear()
    Cache.storeRepos("plugin", {
        {
            id = 9002,
            name = "safe.koplugin",
            full_name = "author/safe.koplugin",
            stargazers_count = 40,
            fork = false,
        }
    })

    local calls_made = 0
    GitHub.searchRepositories = function(opts)
        calls_made = calls_made + 1
        return {
            total_count = 50,
            items = {
                {
                    id = 8000 + calls_made,
                    name = "new-" .. calls_made .. ".koplugin",
                    full_name = "author/new-" .. calls_made .. ".koplugin",
                    stargazers_count = 10,
                    fork = false,
                }
            }
        }, nil
    end

    local cancel_ok, cancel_err = Crawler.refreshCatalog{
        kind = "plugin",
        reconcile_disk = false,
        force_crawler = true,
        should_cancel = function()
            -- Cancel after the very first search call
            return calls_made >= 1
        end,
    }

    check("crawler stopped on cancellation", cancel_ok == false)
    check("crawler reported cancelled status", cancel_err == "cancelled")
    check("further queries aborted after cancellation", calls_made == 1)
    check("pre-existing cache untouched after cancellation", Cache.countRepos("plugin") == 1)

    restoreGitHub()
end

-- =========================================================================
-- 6. Testing Disk Scan & Reconciliation Hook After Crawl
-- =========================================================================
print("\n--- 6. Testing Disk Scan & Reconciliation Hook ---")

do
    Cache.clear()
    local test_plugins_root = DataStorage.getDataDir() .. "/plugins"
    local sample_plugin_dir = test_plugins_root .. "/crawled_sample.koplugin"
    os.execute(string.format("mkdir -p %q", sample_plugin_dir))
    local mf = io.open(sample_plugin_dir .. "/_meta.lua", "w")
    mf:write([[
        return {
            name = "crawled_sample",
            fullname = "Crawled Sample Plugin",
            version = "1.0.0",
        }
    ]])
    mf:close()

    Installs.clear()

    -- Mock GitHub returning repo corresponding to the disk plugin
    GitHub.searchRepositories = function(opts)
        if opts.q:find("topic:koreader-plugin fork:false", 1, true) then
            return {
                total_count = 1,
                items = {
                    {
                        id = 7701,
                        name = "crawled_sample.koplugin",
                        full_name = "community/crawled_sample.koplugin",
                        owner = { login = "community" },
                        stargazers_count = 80,
                        fork = false,
                    }
                }
            }, nil
        end
        return { total_count = 0, items = {} }, nil
    end

    local ok, err = Crawler.refreshCatalog{
        kind = "plugin",
        reconcile_disk = true,
        force_crawler = true,
    }

    check("refreshCatalog with disk reconciliation succeeded", ok == true)
    local inst_rec = Installs.get("crawled_sample") or Installs.get("crawled_sample.koplugin")
    check("sideloaded disk plugin auto-linked after crawl", inst_rec ~= nil and inst_rec.repo == "community/crawled_sample.koplugin")
    check("inst_rec is not unlinked", inst_rec and inst_rec.unlinked == nil)

    -- Cleanup test folder
    os.execute(string.format("rm -rf %q", sample_plugin_dir))
    restoreGitHub()
end

-- =========================================================================
-- 7. Audit Local Variable Counts
-- =========================================================================
print("\n--- 7. Scope & Local Limit Check ---")

do
    local f = io.open("net/storify_crawler.lua", "r")
    if f then
        local local_count = 0
        for line in f:lines() do
            if line:match("^local%s+[%w_]+") or line:match("^local%s+function") then
                local_count = local_count + 1
            end
        end
        f:close()
        check("net/storify_crawler.lua has <= 40 top-level locals", local_count <= 40, "found " .. tostring(local_count))
    end
end

-- =========================================================================
-- 8. Testing fusuyfusuy/awesome.koreader Catalog Ingestion
-- =========================================================================
print("\n--- 8. Testing awesome.koreader Weekly Catalog Sync ---")

do
    Cache.clear()
    local Net = require("net/storify_net")
    local orig_requestToTable = Net.requestToTable

    -- Mock Net returning valid awesome.koreader JSON payload
    Net.requestToTable = function(req, parts)
        local sample_catalog = {
            metadata = {
                title = "Master KOReader Plugin Database",
                last_updated = "2026-08-18T18:56:55Z",
            },
            plugins = {
                {
                    id = "readest.koplugin",
                    name = "readest",
                    full_name = "readest/readest",
                    owner = "readest",
                    stars = 23529,
                    description = "Readest ebook reader",
                    category = "Sync, Cloud & File Transfer",
                    topics = { "koreader", "koreader-plugin" },
                    default_branch = "main",
                    url = "https://github.com/readest/readest",
                },
                {
                    id = "custom.koplugin",
                    name = "custom",
                    full_name = "dev/custom",
                    owner = "dev",
                    stars = 120,
                    description = "Custom tool",
                },
                {
                    -- Ships bundled with every KOReader install; its full_name/url
                    -- point at a sub-path inside koreader/koreader rather than its
                    -- own repo, which breaks the flat "owner/repo" README/download
                    -- URL builders. Must be filtered out, not stored.
                    id = "keepalive.koplugin",
                    name = "keepalive",
                    full_name = "koreader/koreader/plugins/keepalive.koplugin",
                    owner = "koreader",
                    stars = 18000,
                    description = "Prevents device suspension",
                    default_branch = "master",
                    url = "https://github.com/koreader/koreader/tree/master/plugins/keepalive.koplugin",
                    type = "builtin_plugin",
                }
            },
            patches = {
                {
                    id = "patches.koplugin",
                    name = "patches",
                    full_name = "author/patches",
                    owner = "author",
                    stars = 15,
                    description = "User patches collection",
                }
            }
        }
        local json_mod = require("json")
        local raw = json_mod.encode(sample_catalog)
        table.insert(parts, raw)
        return 200, {}, "HTTP/1.1 200 OK"
    end

    local progress_steps = {}
    local ok, err, stats = Crawler.refreshCatalog{
        kind = "all",
        reconcile_disk = false,
        on_progress = function(frac, msg)
            table.insert(progress_steps, { frac = frac, msg = msg })
        end,
    }

    check("awesome.koreader refresh succeeded", ok == true)
    check("stats plugins_discovered", stats and stats.plugins_discovered, 2)
    check("stats patches_discovered", stats and stats.patches_discovered, 1)
    check("cache has 2 plugins", Cache.countRepos("plugin") == 2)
    check("cache has 1 patch", Cache.countRepos("patch") == 1)

    local stored_plugins = Cache.listRepos("plugin")
    check("readest plugin stored with stars", stored_plugins[1] and stored_plugins[1].stars == 23529)
    check("readest plugin owner is readest", stored_plugins[1] and stored_plugins[1].owner == "readest")
    check("readest download_url generated", stored_plugins[1] and stored_plugins[1].data and (stored_plugins[1].data.download_url:find("readest/archive/refs/heads/main.zip", 1, true) ~= nil))

    local found_builtin = false
    for _, sp in ipairs(stored_plugins) do
        if sp.name == "keepalive" then found_builtin = true end
    end
    check("builtin_plugin entry (keepalive, already bundled) is filtered out of the catalog", not found_builtin)

    Net.requestToTable = orig_requestToTable
end

if failures > 0 then
    error(string.format("%d assertion(s) failed in storify_crawler_test", failures))
end
print(string.format("\nAll %d assertions passed in storify_crawler_test!", total_checks))
