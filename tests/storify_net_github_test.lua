-- tests/storify_net_github_test.lua
-- Unit tests for storify_net, storify_net_github, and storify_repo_content

-- Provide robust JSON decoder/encoder for testing environment
local function parse_json(str)
    if not str or str == "" or str == "null" then return nil end
    local pos = 1
    local len = #str

    local function skip_ws()
        while pos <= len and str:byte(pos) <= 32 do pos = pos + 1 end
    end

    local function parse_val()
        skip_ws()
        if pos > len then return nil end
        local c = str:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local obj = {}
            skip_ws()
            if pos <= len and str:sub(pos, pos) == "}" then
                pos = pos + 1
                return obj
            end
            while pos <= len do
                skip_ws()
                local key = parse_val()
                skip_ws()
                if str:sub(pos, pos) == ":" then pos = pos + 1 else break end
                local val = parse_val()
                if key ~= nil then obj[key] = val end
                skip_ws()
                local delim = str:sub(pos, pos)
                if delim == "," then
                    pos = pos + 1
                elseif delim == "}" then
                    pos = pos + 1
                    break
                else
                    break
                end
            end
            return obj
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            skip_ws()
            if pos <= len and str:sub(pos, pos) == "]" then
                pos = pos + 1
                return arr
            end
            while pos <= len do
                skip_ws()
                local val = parse_val()
                table.insert(arr, val)
                skip_ws()
                local delim = str:sub(pos, pos)
                if delim == "," then
                    pos = pos + 1
                elseif delim == "]" then
                    pos = pos + 1
                    break
                else
                    break
                end
            end
            return arr
        elseif c == "\"" then
            pos = pos + 1
            local s = ""
            while pos <= len do
                local ch = str:sub(pos, pos)
                if ch == "\\" then
                    pos = pos + 1
                    local esc = str:sub(pos, pos)
                    if esc == "n" then s = s .. "\n"
                    elseif esc == "r" then s = s .. "\r"
                    elseif esc == "t" then s = s .. "\t"
                    elseif esc == "\"" then s = s .. "\""
                    elseif esc == "\\" then s = s .. "\\"
                    else s = s .. esc end
                    pos = pos + 1
                elseif ch == "\"" then
                    pos = pos + 1
                    break
                else
                    s = s .. ch
                    pos = pos + 1
                end
            end
            return s
        elseif str:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif str:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif str:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        else
            local num_str = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
            if num_str and num_str ~= "" then
                pos = pos + #num_str
                return tonumber(num_str)
            end
            pos = pos + 1
            return nil
        end
    end

    return parse_val()
end

local function encode_json(val)
    if type(val) == "table" then
        local is_array = #val > 0
        local parts = {}
        if is_array then
            for _, v in ipairs(val) do
                table.insert(parts, encode_json(v))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do
                table.insert(parts, string.format("%q:%s", tostring(k), encode_json(v)))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    elseif type(val) == "string" then
        return string.format("%q", val)
    elseif type(val) == "number" or type(val) == "boolean" then
        return tostring(val)
    elseif val == nil then
        return "null"
    end
    return '"' .. tostring(val) .. '"'
end

local mock_json = {
    decode = parse_json,
    encode = encode_json,
}
package.loaded["json"] = mock_json
package.preload["json"] = function() return mock_json end

local json = mock_json
local socket_url = require("socket.url")

-- Augment socket_url if needed for testing environment
if not socket_url.escape then
    socket_url.escape = function(s)
        return tostring(s):gsub("([^%w _%%%-%.~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end):gsub(" ", "+")
    end
end
if not socket_url.absolute then
    socket_url.absolute = function(base, rel)
        if not rel or rel == "" then return base end
        if rel:find("^https?://") then return rel end
        local scheme, host = base:match("^(https?://[^/]+)")
        if rel:sub(1, 1) == "/" then
            return (scheme or "") .. rel
        end
        local base_path = base:match("^(https?://[^/]+/.-)[^/]*$") or base
        if base_path:sub(-1) ~= "/" then base_path = base_path .. "/" end
        return base_path .. rel
    end
end

-- Mock socketutil tracking
local socketutil_calls = {
    set_timeout = 0,
    reset_timeout = 0,
    last_block = nil,
    last_total = nil,
}
local mock_socketutil = {
    LARGE_BLOCK_TIMEOUT = 10,
    LARGE_TOTAL_TIMEOUT = 30,
    FILE_BLOCK_TIMEOUT = 15,
    FILE_TOTAL_TIMEOUT = 300,
    set_timeout = function(self, block, total)
        socketutil_calls.set_timeout = socketutil_calls.set_timeout + 1
        socketutil_calls.last_block = block
        socketutil_calls.last_total = total
    end,
    reset_timeout = function(self)
        socketutil_calls.reset_timeout = socketutil_calls.reset_timeout + 1
    end,
    table_sink = function(tbl)
        return function(chunk, err)
            if chunk then table.insert(tbl, chunk) end
            return 1
        end
    end,
    file_sink = function(file)
        return function(chunk, err)
            if chunk then file:write(chunk) end
            return 1
        end
    end,
}
package.loaded["socketutil"] = mock_socketutil
package.preload["socketutil"] = function() return mock_socketutil end

-- Mock socket.http for testing Net requests
local http_mock_handler = nil
local mock_http = {
    request = function(req)
        if http_mock_handler then
            return http_mock_handler(req)
        end
        return nil, "no mock handler defined"
    end,
}
package.loaded["socket.http"] = mock_http
package.preload["socket.http"] = function() return mock_http end

-- Config mock
local test_config = {
    auth = {
        github = {
            token = "ghp_secret_test_token_12345",
            scheme = "Bearer",
        },
    },
}
package.loaded["storify_configuration"] = test_config
package.preload["storify_configuration"] = function() return test_config end

local Net = require("storify_net")
local GitHubClient = require("storify_net_github")
local RepoContent = require("storify_repo_content")
local Mirror = require("storify_mirror")

local failures = 0
local function check(label, got, expected)
    if got == expected then
        print(string.format("  ✓ PASS: %s", label))
    else
        failures = failures + 1
        print(string.format("  ❌ FAIL: %s | expected: %s, got: %s", label, tostring(expected), tostring(got)))
    end
end

-- =============================================================================
-- 1. Tests for storify_net.lua (Transport & Timeout Safety)
-- =============================================================================
print("\n--- 1. Testing storify_net (Socket Transport & Timeout Safety) ---")

-- Test: Successful requestToTable
http_mock_handler = function(req)
    if req.sink then
        req.sink("hello ")
        req.sink("world")
    end
    return 1, 200, { ["content-type"] = "text/plain" }, "HTTP/1.1 200 OK"
end

socketutil_calls.set_timeout = 0
socketutil_calls.reset_timeout = 0
local body_parts = {}
local code, headers, status = Net.requestToTable({ url = "https://api.github.com/zen" }, body_parts, 5, 20)

check("requestToTable status code", code, 200)
check("requestToTable status string", status, "HTTP/1.1 200 OK")
check("requestToTable body", table.concat(body_parts), "hello world")
check("requestToTable set_timeout called", socketutil_calls.set_timeout, 1)
check("requestToTable reset_timeout called", socketutil_calls.reset_timeout, 1)
check("requestToTable custom block timeout", socketutil_calls.last_block, 5)
check("requestToTable custom total timeout", socketutil_calls.last_total, 20)

-- Test: Thrown error in http.request cleans up timeout properly
http_mock_handler = function(req)
    error("socket connection closed abruptly")
end

socketutil_calls.reset_timeout = 0
local err_code, err_headers, err_status = Net.requestToTable({ url = "https://api.github.com/crash" }, {})

check("requestToTable returns nil code on thrown error", err_code, nil)
check("requestToTable returns nil headers on thrown error", err_headers, nil)
check("requestToTable returns error message in status", tostring(err_status):find("socket connection closed abruptly") ~= nil, true)
check("requestToTable resets timeout even on error", socketutil_calls.reset_timeout, 1)

-- Test: requestToFile
local tmp_filepath = "/tmp/storify_test_file_" .. tostring(os.time()) .. ".txt"
local tmp_file = io.open(tmp_filepath, "w+")
http_mock_handler = function(req)
    if req.sink then
        req.sink("payload from file request")
    end
    return 1, 200, {}, "HTTP/1.1 200 OK"
end

socketutil_calls.reset_timeout = 0
local f_code, f_headers, f_status = Net.requestToFile({ url = "https://api.github.com/file" }, tmp_file, 8, 40)
tmp_file:seek("set", 0)
local file_content = tmp_file:read("*a")
tmp_file:close()
os.remove(tmp_filepath)

check("requestToFile status code", f_code, 200)
check("requestToFile content written", file_content, "payload from file request")
check("requestToFile reset_timeout called", socketutil_calls.reset_timeout, 1)


-- =============================================================================
-- 2. Tests for storify_net_github.lua (Query Builders & Auth)
-- =============================================================================
print("\n--- 2. Testing storify_net_github (Auth & Query Builders) ---")

check("hasAuthToken returns true when configured", GitHubClient.hasAuthToken(), true)

test_config.auth.github.token = ""
check("hasAuthToken returns false when empty", GitHubClient.hasAuthToken(), false)

test_config.auth.github.token = "your_github_token"
check("hasAuthToken returns false when placeholder", GitHubClient.hasAuthToken(), false)

test_config.auth.github.token = "ghp_secret_test_token_12345"


-- =============================================================================
-- 3. Tests for SSRF & Guarded Redirects (Header Stripping & Allowlist)
-- =============================================================================
print("\n--- 3. Testing SSRF & Token Leakage Defense in Redirect Loops ---")

-- Test: Authorization header stripped on redirect away from api.github.com to objects.githubusercontent.com
local request_history = {}
http_mock_handler = function(req)
    table.insert(request_history, {
        url = req.url,
        auth_header = req.headers and (req.headers["Authorization"] or req.headers["authorization"]),
    })
    if req.url == "https://api.github.com/repos/koreader/koreader/releases/assets/1234" then
        return 1, 302, { location = "https://objects.githubusercontent.com/github-production-release-asset/abc" }, "HTTP/1.1 302 Found"
    elseif req.url == "https://objects.githubusercontent.com/github-production-release-asset/abc" then
        if req.sink then req.sink('{"status":"downloaded"}') end
        return 1, 200, {}, "HTTP/1.1 200 OK"
    end
    return 1, 404, {}, "HTTP/1.1 404 Not Found"
end

request_history = {}
local rel_code, rel_data = GitHubClient.fetchLatestRelease("koreader", "koreader")

-- Perform direct redirect inspection via search or release querying
http_mock_handler = function(req)
    table.insert(request_history, {
        url = req.url,
        auth_header = req.headers and (req.headers["Authorization"] or req.headers["authorization"]),
    })
    if req.url:find("api%.github%.com") then
        return 1, 302, { location = "https://objects.githubusercontent.com/download/asset.zip" }, "HTTP/1.1 302 Found"
    elseif req.url:find("objects%.githubusercontent%.com") then
        if req.sink then req.sink('{"asset":"ok"}') end
        return 1, 200, {}, "HTTP/1.1 200 OK"
    end
    return 1, 404, {}, "HTTP/1.1 404 Not Found"
end

request_history = {}
local meta_res, meta_err = GitHubClient.fetchRepoMetadata("koreader", "koreader")

check("Guarded redirect hopped to second URL", #request_history, 2)
check("First request had Authorization header", request_history[1].auth_header, "Bearer ghp_secret_test_token_12345")
check("Redirect to objects.githubusercontent.com stripped Authorization", request_history[2].auth_header, nil)

-- Test: Redirect to untrusted host is blocked
http_mock_handler = function(req)
    return 1, 302, { location = "https://malicious-site.com/steal-token" }, "HTTP/1.1 302 Found"
end

local untrusted_res, untrusted_err = GitHubClient.fetchRepoMetadata("koreader", "koreader")
check("Untrusted host redirect is blocked", untrusted_res, nil)
check("Untrusted host error details", type(untrusted_err) == "table" and untrusted_err.code, 0)
check("Untrusted host error message", type(untrusted_err) == "table" and tostring(untrusted_err.body):find("refusing unexpected host") ~= nil, true)

-- Test: Redirect to non-https is blocked
http_mock_handler = function(req)
    return 1, 302, { location = "http://api.github.com/insecure" }, "HTTP/1.1 302 Found"
end

local http_res, http_err = GitHubClient.fetchRepoMetadata("koreader", "koreader")
check("Non-HTTPS redirect is blocked", http_res, nil)
check("Non-HTTPS error message", type(http_err) == "table" and tostring(http_err.body):find("refusing non%-https URL") ~= nil, true)

-- Test: Infinite redirect loop is capped at MAX_REDIRECTS (5)
local redirect_count = 0
http_mock_handler = function(req)
    redirect_count = redirect_count + 1
    return 1, 302, { location = "https://api.github.com/loop_" .. tostring(redirect_count) }, "HTTP/1.1 302 Found"
end

local loop_res, loop_err = GitHubClient.fetchRepoMetadata("koreader", "koreader")
check("Redirect loop is capped", loop_res, nil)
check("Redirect loop error message", type(loop_err) == "table" and tostring(loop_err.body):find("too many redirects") ~= nil, true)


-- =============================================================================
-- 4. Tests for GitHub REST API Endpoints with Mocks
-- =============================================================================
print("\n--- 4. Testing GitHub REST API Client Endpoints ---")

-- Test: searchRepositories
http_mock_handler = function(req)
    check("searchRepositories URL query has parameters", req.url:find("q=topic%%3Akoreader%-plugin") ~= nil, true)
    if req.sink then
        req.sink(json.encode({
            total_count = 1,
            items = {
                { name = "sample-plugin", full_name = "dev/sample-plugin", stargazers_count = 42 }
            }
        }))
    end
    return 1, 200, {}, "HTTP/1.1 200 OK"
end

local search_res, search_err = GitHubClient.searchByTopics({ "koreader-plugin" })
check("searchByTopics returns decoded json", search_res and search_res.total_count, 1)
check("searchByTopics item name", search_res and search_res.items[1].name, "sample-plugin")

-- Test: searchRepositories rate limit handling (403 and 429)
http_mock_handler = function(req)
    if req.sink then req.sink('{"message":"API rate limit exceeded"}') end
    return 1, 403, {}, "HTTP/1.1 403 Forbidden"
end

local rl_res, rl_err = GitHubClient.searchRepositories({ q = "test" })
check("Rate limit 403 returns nil data", rl_res, nil)
check("Rate limit 403 is_rate_limit flag", rl_err and rl_err.is_rate_limit, true)
check("Rate limit 403 is_fine_grained flag", rl_err and rl_err.is_fine_grained_unsupported, false)

-- Test: searchRepositories fine-grained PAT 403 rejection
http_mock_handler = function(req)
    if req.sink then req.sink('{"message":"Resource not accessible by integration (fine-grained token not supported)"}') end
    return 1, 403, {}, "HTTP/1.1 403 Forbidden"
end

local fg_res, fg_err = GitHubClient.searchRepositories({ q = "test" })
check("Fine-grained 403 is_fine_grained_unsupported flag", fg_err and fg_err.is_fine_grained_unsupported, true)
check("Fine-grained 403 is_rate_limit flag is false", fg_err and fg_err.is_rate_limit, false)

-- Test: fetchRepoTree
http_mock_handler = function(req)
    check("fetchRepoTree queries recursive tree", req.url:find("/git/trees/main%?recursive=1") ~= nil, true)
    if req.sink then
        req.sink(json.encode({
            sha = "tree123",
            tree = { { path = "main.lua", mode = "100644", type = "blob" } }
        }))
    end
    return 1, 200, {}, "HTTP/1.1 200 OK"
end

local tree_res = GitHubClient.fetchRepoTree("owner", "repo", "main")
check("fetchRepoTree parsed sha", tree_res and tree_res.sha, "tree123")
check("fetchRepoTree file item", tree_res and tree_res.tree[1].path, "main.lua")

-- Test: fetchReleases with transparent pagination
local requested_pages = {}
http_mock_handler = function(req)
    local page_num = req.url:match("[?&]page=(%d+)")
    table.insert(requested_pages, tonumber(page_num))
    if page_num == "1" then
        if req.sink then
            req.sink(json.encode({
                { tag_name = "v2.0.0", name = "Release 2.0.0" },
                { tag_name = "v1.9.0", name = "Release 1.9.0" },
            }))
        end
        return 1, 200, {}, "HTTP/1.1 200 OK"
    elseif page_num == "2" then
        if req.sink then
            req.sink(json.encode({
                { tag_name = "v1.0.0", name = "Release 1.0.0" },
            }))
        end
        return 1, 200, {}, "HTTP/1.1 200 OK"
    else
        if req.sink then req.sink("[]") end
        return 1, 200, {}, "HTTP/1.1 200 OK"
    end
end

local rels_res = GitHubClient.fetchReleases("owner", "repo", { per_page = 2, max_pages = 3 })
check("fetchReleases paginated across pages", #rels_res, 3)
check("fetchReleases first release tag", rels_res[1].tag_name, "v2.0.0")
check("fetchReleases last release tag", rels_res[3].tag_name, "v1.0.0")

-- Test: fetchCompareCommits
http_mock_handler = function(req)
    check("fetchCompareCommits URL", req.url:find("/compare/v1%.0%.0%.%.%.v2%.0%.0") ~= nil, true)
    if req.sink then
        req.sink(json.encode({
            total_commits = 5,
            commits = { { sha = "c1" }, { sha = "c2" } }
        }))
    end
    return 1, 200, {}, "HTTP/1.1 200 OK"
end

local cmp_res = GitHubClient.fetchCompareCommits("owner", "repo", "v1.0.0", "v2.0.0")
check("fetchCompareCommits total_commits", cmp_res and cmp_res.total_commits, 5)


-- =============================================================================
-- 5. Tests for storify_repo_content.lua (README Download & HTML img Stripping)
-- =============================================================================
print("\n--- 5. Testing storify_repo_content (README & Formatting) ---")

-- Test: supportsReadmePopup
check("supportsReadmePopup returns boolean", type(RepoContent.supportsReadmePopup()), "boolean")

-- Test: fetchReadmeContent strips inline <img> HTML tags while keeping text
http_mock_handler = function(req)
    if req.sink then
        req.sink("# My Plugin\n\n<p align=\"center\"><img src=\"https://example.com/banner.png\" alt=\"Banner\"/></p>\n\nDetailed descriptions here.\n<img src='badge.svg'>")
    end
    return 1, 200, {}, "HTTP/1.1 200 OK"
end

local readme_text, r_err = RepoContent.fetchReadmeContent("testowner", "testrepo")
check("fetchReadmeContent stripped first <img> tag", readme_text and readme_text:find("<img.-banner%.png"), nil)
check("fetchReadmeContent stripped second <img> tag", readme_text and readme_text:find("<img.-badge%.svg"), nil)
check("fetchReadmeContent kept heading", readme_text and (readme_text:find("# My Plugin", 1, true) ~= nil), true)
check("fetchReadmeContent kept text", readme_text and (readme_text:find("Detailed descriptions here.", 1, true) ~= nil), true)

-- Test: fetchReadme caches to disk
local cached_ok, cached_path = RepoContent.fetchReadme("testowner", "testrepo")
check("fetchReadme returns success true", cached_ok, true)
check("fetchReadme cached file exists", type(cached_path) == "string" and cached_path:find("testowner_testrepo_README.md") ~= nil, true)

local f = io.open(cached_path, "r")
check("Cached file can be opened", f ~= nil, true)
if f then
    local content = f:read("*a")
    f:close()
    check("Cached file content matches stripped text", content, readme_text)
end

-- Test: clearReadmeCache cleans up files
local clear_res = RepoContent.clearReadmeCache()
check("clearReadmeCache removed at least 1 file", clear_res and clear_res.removed >= 1, true)
check("clearReadmeCache errors empty", clear_res and #clear_res.errors, 0)

-- Check file was removed
local f_check = io.open(cached_path, "r")
check("Cached file was deleted", f_check, nil)
if f_check then f_check:close() end

if failures > 0 then
    error(string.format("%d test(s) failed in storify_net_github_test.lua", failures))
end
