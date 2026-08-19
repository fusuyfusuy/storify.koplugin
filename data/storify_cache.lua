-- data/storify_cache.lua
local DataStorage = require("datastorage")
local ok_sq, sq_mod = pcall(require, "lua-ljsqlite3/init")
if not ok_sq or not sq_mod then
    ok_sq, sq_mod = pcall(require, "lua-ljsqlite3")
end
local SQ3 = (ok_sq and type(sq_mod) == "table") and sq_mod or nil
local ffiUtil = (pcall(require, "ffi/util") and require("ffi/util"))
    or (pcall(require, "ffiutil") and require("ffiutil"))
    or require("ffiUtil")
local util = (pcall(require, "util") and require("util")) or {}
local json = require("json")
local logger = require("logger")

local Cache = {}

local DB_SCHEMA_VERSION = 20260808
local DB_DIRECTORY = (ffiUtil.joinPath and ffiUtil.joinPath(DataStorage:getDataDir(), "cache/storify"))
    or (DataStorage:getDataDir() .. "/cache/storify")
local DB_PATH = (ffiUtil.joinPath and ffiUtil.joinPath(DB_DIRECTORY, "storify.sqlite3"))
    or (DB_DIRECTORY .. "/storify.sqlite3")

local SCHEMA_STATEMENTS = {
    [[CREATE TABLE IF NOT EXISTS repos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        repo_id INTEGER NOT NULL,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        owner TEXT NOT NULL,
        full_name TEXT NOT NULL,
        description TEXT,
        stars INTEGER NOT NULL DEFAULT 0,
        language TEXT,
        homepage TEXT,
        fetched_at INTEGER NOT NULL,
        -- Ordering and search read these, so they stay out of `data`.
        pushed_at TEXT,
        created_at TEXT,
        -- Space-joined: search terms are split on whitespace, so no term can straddle two topics.
        topics TEXT,
        -- Every rendered row asks whether it's a fork.
        fork INTEGER NOT NULL DEFAULT 0,
        data TEXT NOT NULL,
        UNIQUE(repo_id, kind)
    );]],
    [[CREATE INDEX IF NOT EXISTS idx_repos_kind_stars ON repos(kind, stars DESC);]],
    [[CREATE TABLE IF NOT EXISTS patch_files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        repo_id INTEGER NOT NULL,
        path TEXT NOT NULL,
        filename TEXT NOT NULL,
        branch TEXT,
        sha TEXT,
        size INTEGER,
        download_url TEXT,
        fetched_at INTEGER NOT NULL,
        source_pushed_at TEXT,
        UNIQUE(repo_id, path)
    );]],
    [[CREATE INDEX IF NOT EXISTS idx_patch_files_repo ON patch_files(repo_id);]],
}

local initialized = false

-- Asked on every render to validate other caches, and only ever changes when we write:
-- opening the database to hear the same number again costs more than the number is worth.
local last_fetched_cache = {}

local function ensureDirectory()
    local ok = true
    if ffiUtil and ffiUtil.makePath then
        ok = ffiUtil.makePath(DB_DIRECTORY)
    elseif util and util.makePath then
        ok = util.makePath(DB_DIRECTORY)
    else
        ok = os.execute(string.format("mkdir -p %q", DB_DIRECTORY)) ~= nil
    end
    if not ok then
        logger.warn("storify cache directory creation failed")
    end
end

local function quarantineCorruptedDb(err_msg)
    logger.warn("storify cache: database corrupted, quarantining", tostring(err_msg))
    local timestamp = tostring(os.time())
    local corrupt_suffix = ".corrupt." .. timestamp
    local corrupt_path = DB_PATH .. corrupt_suffix
    pcall(os.rename, DB_PATH, corrupt_path)
    pcall(os.rename, DB_PATH .. "-wal", corrupt_path .. "-wal")
    pcall(os.rename, DB_PATH .. "-shm", corrupt_path .. "-shm")
    pcall(os.remove, DB_PATH)
    pcall(os.remove, DB_PATH .. "-wal")
    pcall(os.remove, DB_PATH .. "-shm")
    initialized = false
    last_fetched_cache = {}
    return corrupt_path
end

local function openRawConnection()
    ensureDirectory()
    if not SQ3 or not SQ3.open then
        return nil, "SQLite library unavailable"
    end
    local conn = SQ3.open(DB_PATH)
    if conn and conn.exec then
        conn:exec("PRAGMA journal_mode = WAL;")
        conn:exec("PRAGMA synchronous = NORMAL;")
        conn:exec("PRAGMA foreign_keys = ON;")
    end
    return conn
end

local function isCorruptionError(err)
    if not err then return false end
    local s = tostring(err):lower()
    return s:find("corrupt") ~= nil or s:find("notadb") ~= nil or s:find("malformed") ~= nil
        or s:find("file is not a database") ~= nil or s:find("disk i/o error") ~= nil
        or s:find("schema") ~= nil or s:find("integrity") ~= nil
end

local function openConnection()
    if not SQ3 or not SQ3.open then
        return nil, "SQLite library unavailable"
    end
    local ok, conn = pcall(openRawConnection)
    if not ok or not conn then
        quarantineCorruptedDb(conn)
        local ok2, conn2 = pcall(openRawConnection)
        if not ok2 or not conn2 then
            logger.warn("storify cache: secondary open connection failed:", tostring(conn2))
            return nil, conn2
        end
        conn = conn2
    end
    return conn
end

-- Held for the duration of Cache.withSession, so a long run of queries that nobody is
-- waiting through -- a refresh, or building the whole list -- opens the database once.
local session_conn = nil

local function execStatements(conn, statements)
    for _, statement in ipairs(statements) do
        local trimmed = statement:match("^%s*(.-)%s*$") or ""
        if trimmed ~= "" then
            local final_stmt = trimmed
            if not final_stmt:find(";%s*$") then
                final_stmt = final_stmt .. ";"
            end
            local ok, err = pcall(conn.exec, conn, final_stmt)
            if not ok then
                error(string.format("storify cache schema error: %s -- %s", final_stmt, err))
            end
        end
    end
end

function Cache.init()
    if initialized then
        return
    end
    ensureDirectory()
    local ok, err = pcall(function()
        local conn = openConnection()
        local check_ok, integrity = pcall(function()
            return conn:rowexec("PRAGMA integrity_check;")
        end)
        if not check_ok or (integrity and integrity ~= "ok" and not tostring(integrity):match("^ok")) then
            pcall(function() conn:close() end)
            error("Integrity check failed: " .. tostring(integrity))
        end
        local current_version = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
        if current_version < DB_SCHEMA_VERSION then
            conn:exec("DROP TABLE IF EXISTS repos;")
            conn:exec("DROP TABLE IF EXISTS patch_files;")
            conn:exec("VACUUM;")
            conn:exec("PRAGMA user_version = " .. DB_SCHEMA_VERSION .. ";")
        end
        execStatements(conn, SCHEMA_STATEMENTS)
        conn:close()
    end)
    if not ok then
        logger.warn("storify cache init failed, quarantining and recreating:", err)
        local conn = openRawConnection()
        if conn then
            pcall(function()
                conn:exec("DROP TABLE IF EXISTS repos;")
                conn:exec("DROP TABLE IF EXISTS patch_files;")
                conn:exec("VACUUM;")
                conn:exec("PRAGMA user_version = " .. DB_SCHEMA_VERSION .. ";")
                execStatements(conn, SCHEMA_STATEMENTS)
                conn:close()
            end)
        end
    end
    initialized = true
end

local function withConnection(fn)
    Cache.init()
    if session_conn then
        return fn(session_conn)
    end
    local conn = openConnection()
    if not conn then
        return nil, "Database connection unavailable"
    end
    local ok, result = pcall(fn, conn)
    pcall(function() conn:close() end)
    if not ok then
        if isCorruptionError(result) then
            logger.warn("storify cache query failed due to corruption, recovering:", result)
            quarantineCorruptedDb(result)
            Cache.init()
            local conn2 = openConnection()
            if not conn2 then
                return nil, "Database connection unavailable after recovery"
            end
            local ok2, result2 = pcall(fn, conn2)
            pcall(function() conn2:close() end)
            if not ok2 then
                logger.warn("storify cache query failed after recovery:", result2)
                return nil, result2
            end
            return result2
        else
            logger.warn("storify cache query failed:", result)
            return nil, result
        end
    end
    return result
end

-- Wraps an operation with no human in the middle of it. Between such operations -- while
-- the reader is looking at a page -- the database stays closed.
function Cache.withSession(fn)
    if session_conn then
        return fn()
    end
    Cache.init()
    session_conn = openConnection()
    local results = table.pack(pcall(fn))
    local conn = session_conn
    session_conn = nil
    pcall(function() conn:close() end)
    if not results[1] then
        if isCorruptionError(results[2]) then
            logger.warn("storify cache session failed due to corruption, recovering:", results[2])
            quarantineCorruptedDb(results[2])
            Cache.init()
        end
        error(results[2])
    end
    return table.unpack(results, 2, results.n)
end

local function normalizeString(value)
    if value == nil or value == json.null then
        return ""
    end
    return tostring(value)
end

local function joinTopics(value)
    if type(value) ~= "table" then
        return ""
    end
    local parts = {}
    for _, topic in ipairs(value) do
        local text = normalizeString(topic)
        if text ~= "" then
            parts[#parts + 1] = text
        end
    end
    return table.concat(parts, " ")
end

local function normalizeNumber(value)
    if value == nil or value == json.null then
        return 0
    end
    return tonumber(value) or 0
end

function Cache.storePatchFiles(repo_id, entries, source_pushed_at)
    repo_id = tonumber(repo_id)
    if not repo_id then
        return
    end
    local fetched_at = os.time()
    local pushed_at_value = normalizeString(source_pushed_at)
    withConnection(function(conn)
        conn:exec("BEGIN;")
        local delete_stmt = conn:prepare([[DELETE FROM patch_files WHERE repo_id = ?;]])
        delete_stmt:bind(repo_id)
        delete_stmt:step()
        delete_stmt:close()
        if entries and #entries > 0 then
            local insert_sql = [[INSERT INTO patch_files (repo_id, path, filename, branch, sha, size, download_url, fetched_at, source_pushed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);]]
            local stmt = conn:prepare(insert_sql)
            for _, entry in ipairs(entries) do
                stmt:bind(
                    repo_id,
                    normalizeString(entry.path),
                    normalizeString(entry.filename),
                    normalizeString(entry.branch),
                    normalizeString(entry.sha),
                    normalizeNumber(entry.size),
                    normalizeString(entry.download_url),
                    fetched_at,
                    pushed_at_value
                )
                stmt:step()
                stmt:reset()
            end
            stmt:close()
        end
        conn:exec("COMMIT;")
    end)
end

-- Returns the source_pushed_at timestamp (string) stored when the patch tree
-- for this repo was last successfully fetched, or nil when there is no
-- recorded value. The column is populated by storePatchFiles.
function Cache.getPatchFilePushedAt(repo_id)
    repo_id = tonumber(repo_id)
    if not repo_id then
        return nil
    end
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT source_pushed_at FROM patch_files
            WHERE repo_id = ? AND source_pushed_at IS NOT NULL AND source_pushed_at <> ''
            LIMIT 1;]])
        stmt:bind(repo_id)
        local row = stmt:step()
        local value = row and row[1] or nil
        stmt:close()
        if value == nil or value == "" then
            return nil
        end
        return tostring(value)
    end)
end

-- Row count and stored tree stamp for every repository at once, keyed by repo_id.
function Cache.getPatchFileSummaryByRepo()
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT repo_id, COUNT(1) AS count,
            MAX(CASE WHEN source_pushed_at IS NULL OR source_pushed_at = ''
                THEN NULL ELSE source_pushed_at END) AS pushed_at
            FROM patch_files GROUP BY repo_id;]])
        local dataset = stmt:resultset("hi")
        stmt:close()
        local summary = {}
        local headers = dataset and dataset[0]
        local first_column = headers and dataset[1]
        if type(first_column) ~= "table" then
            return summary
        end
        for row_index = 1, #first_column do
            local row = {}
            for col_index, header in ipairs(headers) do
                row[header] = dataset[col_index][row_index]
            end
            local repo_id = tonumber(row.repo_id)
            if repo_id then
                local pushed_at = row.pushed_at
                if pushed_at == nil or pushed_at == "" then
                    pushed_at = nil
                end
                summary[repo_id] = {
                    count = tonumber(row.count) or 0,
                    pushed_at = pushed_at and tostring(pushed_at) or nil,
                }
            end
        end
        return summary
    end)
end

-- Count of rows stored for the given repo.
function Cache.countPatchFiles(repo_id)
    repo_id = tonumber(repo_id)
    if not repo_id then
        return 0
    end
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT COUNT(1) FROM patch_files WHERE repo_id = ?;]])
        stmt:bind(repo_id)
        local row = stmt:step()
        local value = row and row[1] or 0
        stmt:close()
        return tonumber(value) or 0
    end)
end

function Cache.listPatchFiles(repo_id)
    repo_id = tonumber(repo_id)
    if not repo_id then
        return {}
    end
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT path, filename, branch, sha, size, download_url
            FROM patch_files WHERE repo_id = ?
            ORDER BY filename COLLATE NOCASE, filename;]])
        stmt:bind(repo_id)
        local dataset = stmt:resultset("hi")
        stmt:close()
        local result = {}
        if not dataset then
            return result
        end
        local headers = dataset[0]
        if not headers then
            return result
        end
        local first_column = dataset[1]
        if type(first_column) ~= "table" then
            return result
        end
        local row_count = #first_column
        for row_index = 1, row_count do
            local row = {}
            for col_index, header in ipairs(headers) do
                row[header] = dataset[col_index][row_index]
            end
            table.insert(result, row)
        end
        return result
    end)
end

-- Every patch file of every repository, grouped by repo_id.
function Cache.listPatchFilesByRepo()
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT repo_id, path, filename, branch, sha, size, download_url
            FROM patch_files ORDER BY repo_id, filename COLLATE NOCASE, filename;]])
        local dataset = stmt:resultset("hi")
        stmt:close()
        local grouped = {}
        local headers = dataset and dataset[0]
        local first_column = headers and dataset[1]
        if type(first_column) ~= "table" then
            return grouped
        end
        for row_index = 1, #first_column do
            local row = {}
            for col_index, header in ipairs(headers) do
                row[header] = dataset[col_index][row_index]
            end
            local repo_id = tonumber(row.repo_id)
            if repo_id then
                local bucket = grouped[repo_id]
                if not bucket then
                    bucket = {}
                    grouped[repo_id] = bucket
                end
                bucket[#bucket + 1] = row
            end
        end
        return grouped
    end)
end

-- Delete patch_files rows for any repo_id not present in `valid_repo_ids`.
function Cache.pruneOrphanPatchFiles(valid_repo_ids)
    valid_repo_ids = valid_repo_ids or {}
    local lookup = {}
    for _, repo_id in ipairs(valid_repo_ids) do
        local numeric = tonumber(repo_id)
        if numeric then
            lookup[numeric] = true
        end
    end
    withConnection(function(conn)
        local existing_stmt = conn:prepare([[SELECT DISTINCT repo_id FROM patch_files;]])
        local dataset = existing_stmt:resultset("hi")
        existing_stmt:close()
        local orphans = {}
        if dataset and type(dataset[1]) == "table" then
            for row_index = 1, #dataset[1] do
                local repo_id = tonumber(dataset[1][row_index])
                if repo_id and not lookup[repo_id] then
                    table.insert(orphans, repo_id)
                end
            end
        end
        if #orphans == 0 then
            return
        end
        conn:exec("BEGIN;")
        local delete_stmt = conn:prepare([[DELETE FROM patch_files WHERE repo_id = ?;]])
        for _, repo_id in ipairs(orphans) do
            delete_stmt:bind(repo_id)
            delete_stmt:step()
            delete_stmt:reset()
        end
        delete_stmt:close()
        conn:exec("COMMIT;")
    end)
end

function Cache.clearPatchFiles(kind)
    withConnection(function(conn)
        if kind == "plugin" then
            return -- no-op
        end
        if kind == "patch" or not kind then
            conn:exec("DELETE FROM patch_files;")
        end
    end)
end

local function getOwnerLogin(owner)
    if type(owner) == "string" then
        return owner
    elseif type(owner) == "table" and owner.login then
        return tostring(owner.login)
    end
    return ""
end

local function getNumericId(repo, index)
    if repo.repo_id and tonumber(repo.repo_id) then
        return tonumber(repo.repo_id)
    end
    if repo.id and tonumber(repo.id) then
        return tonumber(repo.id)
    end
    local name = repo.full_name or repo.name or tostring(index)
    local hash = 0
    for i = 1, #name do
        hash = (hash * 31 + string.byte(name, i)) % 2147483647
    end
    return (hash > 0) and hash or (index or 1)
end

function Cache.storeRepos(kind, repos, on_progress, should_stop)
    if not kind or type(repos) ~= "table" then
        return false
    end
    if #repos == 0 then
        logger.warn("storify cache: refusing to replace", kind, "rows with an empty result")
        return false
    end
    local total = #repos
    local fetched_at = os.time()
    local abandoned = false
    withConnection(function(conn)
        conn:exec("BEGIN;")
        local delete_stmt = conn:prepare([[DELETE FROM repos WHERE kind = ?;]])
        delete_stmt:bind(kind)
        delete_stmt:step()
        delete_stmt:close()

        local insert_sql = [[INSERT INTO repos (repo_id, kind, name, owner, full_name, description, stars, language, homepage, fetched_at, pushed_at, created_at, topics, fork, data)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);]]
        local stmt = conn:prepare(insert_sql)
        for index, repo in ipairs(repos) do
            if on_progress then
                on_progress(index, total)
            end
            if should_stop and should_stop() then
                stmt:close()
                conn:exec("ROLLBACK;")
                abandoned = true
                logger.dbg("storify cache: write abandoned after", index - 1, "of", total)
                return
            end
            local owner_login = getOwnerLogin(repo.owner)
            if owner_login == "" and repo.full_name and repo.full_name:find("/") then
                owner_login = repo.full_name:match("^([^/]+)") or ""
            end
            local ok, serialized = pcall(json.encode, repo)
            local encoded = ""
            if ok and type(serialized) == "string" then
                encoded = serialized
            else
                logger.warn("storify cache encode error", serialized)
            end
            local stars_count = normalizeNumber(repo.stars or repo.stargazers_count)
            local home_page = normalizeString(repo.homepage or repo.url)
            stmt:bind(
                getNumericId(repo, index),
                kind,
                normalizeString(repo.name),
                owner_login,
                normalizeString(repo.full_name),
                normalizeString(repo.description),
                stars_count,
                normalizeString(repo.language),
                home_page,
                fetched_at,
                normalizeString(repo.pushed_at),
                normalizeString(repo.created_at),
                joinTopics(repo.topics),
                repo.fork == true and 1 or 0,
                encoded
            )
            stmt:step()
            stmt:reset()
        end
        stmt:close()
        conn:exec("COMMIT;")
    end)
    if abandoned then
        return false
    end
    last_fetched_cache[kind] = #repos > 0 and fetched_at or false
    return true
end

local function decodeData(raw, context)
    if not raw or raw == "" then
        return nil
    end
    local ok, parsed = pcall(json.decode, raw)
    if ok then
        return parsed
    end
    logger.warn("storify cache decode error", context, parsed)
    return nil
end

local function loadDataFor(repo_id, kind)
    if not repo_id then
        return nil
    end
    local raw = withConnection(function(conn)
        local stmt = conn:prepare([[SELECT data FROM repos WHERE repo_id = ? AND kind = ?;]])
        stmt:bind(repo_id, kind)
        local row = stmt:step()
        local value = row and row[1] or nil
        stmt:close()
        return value
    end)
    return decodeData(raw, repo_id)
end

local lazy_data_mt = {
    __index = function(entry, key)
        if key ~= "data" then
            return nil
        end
        if rawget(entry, "_no_data") then
            return nil
        end
        local loaded = loadDataFor(rawget(entry, "repo_id"), rawget(entry, "kind"))
        if loaded == nil then
            rawset(entry, "_no_data", true)
            return nil
        end
        rawset(entry, "data", loaded)
        return loaded
    end,
}

local function makeRow(row)
    return setmetatable({
        repo_id = tonumber(row.repo_id),
        kind = row.kind,
        name = row.name,
        owner = row.owner,
        full_name = row.full_name,
        description = row.description,
        stars = tonumber(row.stars) or 0,
        language = row.language,
        homepage = row.homepage,
        fetched_at = tonumber(row.fetched_at) or 0,
        pushed_at = row.pushed_at,
        created_at = row.created_at,
        topics = row.topics,
        fork = tonumber(row.fork) == 1,
    }, lazy_data_mt)
end

local function fetchRows(kind)
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT repo_id, kind, name, owner, full_name, description, stars, language, homepage, fetched_at, pushed_at, created_at, topics, fork
            FROM repos WHERE kind = ? ORDER BY stars DESC, name COLLATE NOCASE, name;]])
        stmt:bind(kind)
        local dataset = stmt:resultset("hi")
        stmt:close()
        return dataset
    end)
end

function Cache.listRepos(kind)
    kind = kind or "plugin"
    local dataset = fetchRows(kind)
    local result = {}
    if not dataset then
        return result
    end
    local headers = dataset[0]
    if not headers then
        return result
    end
    local first_column = dataset[1]
    if type(first_column) ~= "table" then
        return result
    end
    local row_count = #first_column
    if row_count == 0 then
        return result
    end
    for row_index = 1, row_count do
        local row = {}
        for col_index, header in ipairs(headers) do
            row[header] = dataset[col_index][row_index]
        end
        table.insert(result, makeRow(row))
    end
    return result
end

function Cache.countRepos(kind)
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT COUNT(1) FROM repos WHERE kind = ?;]])
        stmt:bind(kind)
        local row = stmt:step()
        local value = row and row[1] or 0
        stmt:close()
        return tonumber(value) or 0
    end)
end

function Cache.getLastFetched(kind)
    kind = kind or "plugin"
    local cached = last_fetched_cache[kind]
    if cached ~= nil then
        return cached or nil
    end
    local value = withConnection(function(conn)
        local stmt = conn:prepare([[SELECT fetched_at FROM repos WHERE kind = ? LIMIT 1;]])
        stmt:bind(kind)
        local row = stmt:step()
        local result = row and row[1] or nil
        stmt:close()
        return tonumber(result)
    end)
    last_fetched_cache[kind] = value or false
    return value
end

function Cache.clear()
    last_fetched_cache = {}
    withConnection(function(conn)
        conn:exec("DELETE FROM repos;")
    end)
end

return Cache
