-- tests/storify_cache_test.lua
-- Comprehensive unit tests for storify_cache including WAL mode & corruption recovery

local ffi = require("ffi")

-- Robust json mock for test runner
local function json_encode(val)
    if type(val) == "table" then
        local is_array = #val > 0
        local parts = {}
        if is_array then
            for _, v in ipairs(val) do
                table.insert(parts, json_encode(v))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do
                table.insert(parts, string.format("%q:%s", tostring(k), json_encode(v)))
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

local function json_decode(str)
    if not str or str == "" or str == "null" then return nil end
    local s = str:gsub("%[", "{"):gsub("%]", "}")
    s = s:gsub("\"([^\"]-)\"%s*:", "[\"%1\"]="):gsub("null", "nil")
    local f = loadstring("return " .. s)
    if f then
        local ok, res = pcall(f)
        if ok and type(res) == "table" then return res end
    end
    return nil
end

local mock_json = {
    encode = json_encode,
    decode = json_decode,
}
package.preload["json"] = function() return mock_json end
package.loaded["json"] = mock_json

-- Setup FFI SQLite bridge for testing environment if lua-ljsqlite3 is not natively loaded
if not package.preload["lua-ljsqlite3/init"] and not package.preload["lua-ljsqlite3"] then
    local ok_c, C = pcall(ffi.load, "libsqlite3.so.0")
    if not ok_c then
        ok_c, C = pcall(ffi.load, "sqlite3")
    end
    if ok_c then
        ffi.cdef[[
            typedef struct sqlite3 sqlite3;
            typedef struct sqlite3_stmt sqlite3_stmt;
            int sqlite3_open(const char *filename, sqlite3 **ppDb);
            int sqlite3_close(sqlite3 *db);
            int sqlite3_exec(sqlite3 *db, const char *sql, int (*callback)(void*,int,char**,char**), void *arg, char **errmsg);
            int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
            int sqlite3_step(sqlite3_stmt *stmt);
            int sqlite3_reset(sqlite3_stmt *stmt);
            int sqlite3_finalize(sqlite3_stmt *stmt);
            int sqlite3_bind_null(sqlite3_stmt *stmt, int index);
            int sqlite3_bind_int64(sqlite3_stmt *stmt, int index, int64_t val);
            int sqlite3_bind_double(sqlite3_stmt *stmt, int index, double val);
            int sqlite3_bind_text(sqlite3_stmt *stmt, int index, const char *val, int nByte, void(*destructor)(void*));
            int sqlite3_column_count(sqlite3_stmt *stmt);
            const char *sqlite3_column_name(sqlite3_stmt *stmt, int col);
            int sqlite3_column_type(sqlite3_stmt *stmt, int col);
            int64_t sqlite3_column_int64(sqlite3_stmt *stmt, int col);
            double sqlite3_column_double(sqlite3_stmt *stmt, int col);
            const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int col);
            int sqlite3_column_bytes(sqlite3_stmt *stmt, int col);
            const char *sqlite3_errmsg(sqlite3 *db);
        ]]

        local SQLITE_OK = 0
        local SQLITE_ROW = 100
        local SQLITE_DONE = 101

        local Stmt = {}
        Stmt.__index = Stmt

        function Stmt:bind(...)
            local args = {...}
            for i = 1, #args do
                local val = args[i]
                local idx = i
                if val == nil then
                    C.sqlite3_bind_null(self.ptr, idx)
                elseif type(val) == "number" then
                    if math.floor(val) == val then
                        C.sqlite3_bind_int64(self.ptr, idx, val)
                    else
                        C.sqlite3_bind_double(self.ptr, idx, val)
                    end
                elseif type(val) == "string" then
                    C.sqlite3_bind_text(self.ptr, idx, val, #val, ffi.cast("void(*)(void*)", 0))
                elseif type(val) == "boolean" then
                    C.sqlite3_bind_int64(self.ptr, idx, val and 1 or 0)
                else
                    C.sqlite3_bind_text(self.ptr, idx, tostring(val), #tostring(val), ffi.cast("void(*)(void*)", 0))
                end
            end
            return self
        end

        function Stmt:step()
            local rc = C.sqlite3_step(self.ptr)
            if rc == SQLITE_ROW then
                local col_count = C.sqlite3_column_count(self.ptr)
                local row = {}
                for i = 0, col_count - 1 do
                    local col_type = C.sqlite3_column_type(self.ptr, i)
                    if col_type == 1 then
                        row[i + 1] = tonumber(C.sqlite3_column_int64(self.ptr, i))
                    elseif col_type == 2 then
                        row[i + 1] = tonumber(C.sqlite3_column_double(self.ptr, i))
                    elseif col_type == 3 then
                        local txt = C.sqlite3_column_text(self.ptr, i)
                        local bytes = C.sqlite3_column_bytes(self.ptr, i)
                        row[i + 1] = ffi.string(txt, bytes)
                    elseif col_type == 5 then
                        row[i + 1] = nil
                    else
                        local txt = C.sqlite3_column_text(self.ptr, i)
                        row[i + 1] = txt ~= nil and ffi.string(txt) or nil
                    end
                end
                return row
            elseif rc == SQLITE_DONE then
                return nil
            else
                local err = ffi.string(C.sqlite3_errmsg(self.db_ptr))
                error("sqlite step error: " .. err .. " (code " .. rc .. ")")
            end
        end

        function Stmt:reset()
            C.sqlite3_reset(self.ptr)
            return self
        end

        function Stmt:close()
            if self.ptr ~= nil then
                C.sqlite3_finalize(self.ptr)
                self.ptr = nil
            end
        end

        function Stmt:resultset(mode)
            local col_count = C.sqlite3_column_count(self.ptr)
            local headers = {}
            local dataset = { [0] = headers }
            for i = 0, col_count - 1 do
                local col_name = ffi.string(C.sqlite3_column_name(self.ptr, i))
                table.insert(headers, col_name)
                dataset[i + 1] = {}
            end
            local row_index = 1
            while true do
                local row = self:step()
                if not row then break end
                for col_idx = 1, col_count do
                    dataset[col_idx][row_index] = row[col_idx]
                end
                row_index = row_index + 1
            end
            return dataset
        end

        local Conn = {}
        Conn.__index = Conn

        function Conn:exec(sql)
            local errmsg = ffi.new("char*[1]")
            local rc = C.sqlite3_exec(self.ptr, sql, nil, nil, errmsg)
            if rc ~= SQLITE_OK then
                local err = errmsg[0] ~= nil and ffi.string(errmsg[0]) or "unknown error"
                error("sqlite exec error: " .. err .. " in sql: " .. sql)
            end
        end

        function Conn:rowexec(sql)
            local stmt = self:prepare(sql)
            local row = stmt:step()
            stmt:close()
            if row then
                return row[1]
            end
            return nil
        end

        function Conn:prepare(sql)
            local ppStmt = ffi.new("sqlite3_stmt*[1]")
            local rc = C.sqlite3_prepare_v2(self.ptr, sql, #sql, ppStmt, nil)
            if rc ~= SQLITE_OK then
                local err = ffi.string(C.sqlite3_errmsg(self.ptr))
                error("sqlite prepare error: " .. err .. " for sql: " .. sql)
            end
            return setmetatable({ ptr = ppStmt[0], db_ptr = self.ptr }, Stmt)
        end

        function Conn:close()
            if self.ptr ~= nil then
                C.sqlite3_close(self.ptr)
                self.ptr = nil
            end
        end

        local SQ3 = {
            open = function(path)
                local ppDb = ffi.new("sqlite3*[1]")
                local rc = C.sqlite3_open(path, ppDb)
                if rc ~= SQLITE_OK then
                    local err = "cannot open database: " .. path
                    if ppDb[0] ~= nil then
                        err = ffi.string(C.sqlite3_errmsg(ppDb[0]))
                        C.sqlite3_close(ppDb[0])
                    end
                    error(err)
                end
                return setmetatable({ ptr = ppDb[0] }, Conn)
            end
        }

        package.preload["lua-ljsqlite3/init"] = function() return SQ3 end
        package.preload["lua-ljsqlite3"] = function() return SQ3 end
        package.loaded["lua-ljsqlite3/init"] = SQ3
        package.loaded["lua-ljsqlite3"] = SQ3
    end
end

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

local function freshModule()
    package.loaded["storify_cache"] = nil
    package.loaded["data.storify_cache"] = nil
    return require("storify_cache")
end

print("--> [Test Suite] storify_cache")

local Cache = freshModule()

-- 1. Initial State & Basic Setup
Cache.clear()
check("initial countRepos plugin is 0", Cache.countRepos("plugin") == 0)
check("initial countRepos patch is 0", Cache.countRepos("patch") == 0)
check("initial listRepos plugin is empty", #Cache.listRepos("plugin") == 0)

-- 2. Store Repos & List Repos
local sample_repos = {
    {
        id = 101,
        name = "AlphaPlugin",
        full_name = "author/AlphaPlugin",
        description = "An alpha test plugin",
        stargazers_count = 50,
        language = "Lua",
        homepage = "https://example.com/alpha",
        pushed_at = "2026-08-01T00:00:00Z",
        created_at = "2026-01-01T00:00:00Z",
        topics = { "koreader-plugin", "utility" },
        fork = false,
        owner = { login = "author" },
        custom_field = "extra_json_data",
    },
    {
        id = 102,
        name = "BetaPlugin",
        full_name = "author/BetaPlugin",
        description = "A beta test plugin",
        stargazers_count = 100,
        language = "Lua",
        homepage = "https://example.com/beta",
        pushed_at = "2026-08-05T00:00:00Z",
        created_at = "2026-02-01T00:00:00Z",
        topics = { "koreader-plugin", "reader" },
        fork = true,
        owner = { login = "author" },
        custom_field = "extra_beta_data",
    },
}

local stored = Cache.storeRepos("plugin", sample_repos)
check("storeRepos returns true", stored == true)
check("countRepos returns 2", Cache.countRepos("plugin") == 2)
local last_fetched = Cache.getLastFetched("plugin")
check("getLastFetched returns timestamp", type(last_fetched) == "number" and last_fetched > 0)

local repos = Cache.listRepos("plugin")
check("listRepos returns 2 items", #repos == 2)
-- Ordering check: BetaPlugin (100 stars) should come before AlphaPlugin (50 stars)
check("repos sorted by stars DESC (Beta first)", repos[1].name == "BetaPlugin" and repos[2].name == "AlphaPlugin")
check("fork boolean mapped correctly", repos[1].fork == true and repos[2].fork == false)

-- 3. Lazy Data Proxy Verification
local first_repo = repos[1]
check("data proxy lazy load works", first_repo.data ~= nil and first_repo.data.custom_field == "extra_beta_data")
-- Cached lookup check
check("data proxy cached in instance", rawget(first_repo, "data") ~= nil)

-- 4. Protection Against Empty Overwrite
local empty_res = Cache.storeRepos("plugin", {})
check("storeRepos refuses empty repos list", empty_res == false)
check("countRepos unaffected after empty store attempt", Cache.countRepos("plugin") == 2)

-- 5. Rollback on should_stop()
local new_repos = {
    {
        id = 103,
        name = "GammaPlugin",
        full_name = "author/GammaPlugin",
        stargazers_count = 200,
        owner = { login = "author" },
    }
}
local stop_count = 0
local stopped = Cache.storeRepos("plugin", new_repos, nil, function()
    stop_count = stop_count + 1
    return true -- Abort immediately
end)
check("storeRepos with should_stop returns false", stopped == false)
check("previous rows preserved after rollback", Cache.countRepos("plugin") == 2)

-- 6. Patch Files CRUD
local patch_entries = {
    {
        path = "2-test-a.lua",
        filename = "2-test-a.lua",
        branch = "main",
        sha = "sha_a_123",
        size = 2048,
        download_url = "https://raw.githubusercontent.com/user/repo/main/2-test-a.lua",
    },
    {
        path = "2-test-b.lua",
        filename = "2-test-b.lua",
        branch = "main",
        sha = "sha_b_456",
        size = 4096,
        download_url = "https://raw.githubusercontent.com/user/repo/main/2-test-b.lua",
    },
}

Cache.storePatchFiles(101, patch_entries, "2026-08-10T12:00:00Z")
check("countPatchFiles returns 2", Cache.countPatchFiles(101) == 2)
check("getPatchFilePushedAt returns source_pushed_at", Cache.getPatchFilePushedAt(101) == "2026-08-10T12:00:00Z")

local patches = Cache.listPatchFiles(101)
check("listPatchFiles returns 2 patches", #patches == 2)
check("listPatchFiles sorted by filename", patches[1].filename == "2-test-a.lua" and patches[2].filename == "2-test-b.lua")

local summary = Cache.getPatchFileSummaryByRepo()
check("getPatchFileSummaryByRepo contains repo 101", summary[101] ~= nil and summary[101].count == 2)

local grouped = Cache.listPatchFilesByRepo()
check("listPatchFilesByRepo groups by repo_id", grouped[101] ~= nil and #grouped[101] == 2)

-- 7. Orphan Patch Pruning
Cache.storePatchFiles(999, { { path = "orphan.lua", filename = "orphan.lua", size = 100 } }, "2026-08-10T00:00:00Z")
check("orphan patch inserted", Cache.countPatchFiles(999) == 1)
Cache.pruneOrphanPatchFiles({ 101, 102 })
check("orphan patch pruned", Cache.countPatchFiles(999) == 0)
check("valid repo patches retained", Cache.countPatchFiles(101) == 2)

-- 8. withSession Management
local session_ran = false
local session_val = Cache.withSession(function()
    session_ran = true
    local c = Cache.countRepos("plugin")
    local p = Cache.countPatchFiles(101)
    return c + p
end)
check("withSession executed successfully", session_ran and session_val == 4)

-- 9. Corruption Auto-Recovery
local db_dir = DataStorage:getDataDir() .. "/cache/storify"
local db_file = db_dir .. "/storify.sqlite3"

-- Force corruption by writing invalid bytes over the database file
local f = io.open(db_file, "w+b")
if f then
    f:write("CORRUPT HEADER NOT A VALID SQLITE3 DATABASE FILE GARBAGE DATA 1234567890\n")
    f:close()
end

-- Re-import / initialize Cache
local CacheRecovered = freshModule()
-- Next operation should detect corruption, quarantine file, and recreate cleanly without crashing!
local count_after_corrupt = nil
local ok_recover = pcall(function()
    count_after_corrupt = CacheRecovered.countRepos("plugin")
end)

check("auto-recovery survives corrupted database without throwing", ok_recover == true)
check("countRepos returns 0 on newly recovered clean database", count_after_corrupt == 0)

-- Check that quarantined file exists
local p = io.popen("ls " .. db_dir .. "/storify.sqlite3.corrupt.* 2>/dev/null")
local corrupt_file_found = false
if p then
    local out = p:read("*a")
    p:close()
    if out and out:find("corrupt") then
        corrupt_file_found = true
    end
end
check("corrupted database safely quarantined to storify.sqlite3.corrupt.<timestamp>", corrupt_file_found == true)

-- Verify full CRUD works on recovered database
local recover_store = CacheRecovered.storeRepos("plugin", sample_repos)
check("storeRepos works on recovered database", recover_store == true)
check("listRepos works on recovered database", #CacheRecovered.listRepos("plugin") == 2)

-- Clean up
CacheRecovered.clear()
CacheRecovered.clearPatchFiles()

if failures > 0 then
    error(string.format("%d of %d assertions failed in storify_cache_test", failures, total_checks))
end
print(string.format("All %d assertions passed in storify_cache_test", total_checks))
