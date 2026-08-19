local DataStorage = require("datastorage")
local logger = require("logger")
local Net = (pcall(require, "net/storify_net") and require("net/storify_net"))
    or (pcall(require, "storify_net") and require("storify_net")) or {}
local Mirror = (pcall(require, "net/storify_mirror") and require("net/storify_mirror"))
    or (pcall(require, "storify_mirror") and require("storify_mirror")) or {}

local ok_uim, UIManager = pcall(require, "ui/uimanager")
local ok_info, InfoMessage = pcall(require, "ui/widget/infomessage")
local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")

local ok_gt, _ = pcall(require, "storify_gettext")
if not ok_gt then
    ok_gt, _ = pcall(require, "l10n/storify_gettext")
    if not ok_gt then
        _ = function(msg) return msg end
    end
end

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end

local ok_ver, Version = pcall(require, "version")
if not ok_ver or not Version then
    Version = {
        getNormalizedVersion = function(self, v) return 202607 end,
        getNormalizedCurrentVersion = function(self) return 202608 end,
    }
end

local function runSysCommand(cmd)
    local res = os.execute(cmd)
    return res == true or res == 0
end

local ok_util, util = pcall(require, "util")
if not ok_util or not util then
    util = {
        makePath = function(dir)
            local ok_f, ffiUtil = pcall(require, "ffiutil")
            if ok_f and ffiUtil and ffiUtil.makePath then
                return ffiUtil.makePath(dir)
            end
            if lfs and lfs.mkdir then
                return lfs.mkdir(dir)
            end
            return runSysCommand(string.format("mkdir -p %q", dir))
        end,
        writeToFile = function(content, path)
            local f = io.open(path, "w")
            if not f then return false, "cannot open file for writing: " .. tostring(path) end
            f:write(content)
            f:close()
            return true
        end,
        readFromFile = function(path)
            local f = io.open(path, "r")
            if not f then return nil, "cannot open file for reading: " .. tostring(path) end
            local content = f:read("*a")
            f:close()
            return content
        end,
    }
end

local RepoContent = {}

-- TextViewer only gained Markdown rendering (text_format = "md") in KOReader
-- v2026.07. Older versions keep the cache-to-file-then-open flow below.
local README_POPUP_MIN_VERSION = Version.getNormalizedVersion and Version:getNormalizedVersion("v2026.07") or 202607

function RepoContent.supportsReadmePopup()
    local cur = Version.getNormalizedCurrentVersion and Version:getNormalizedCurrentVersion() or 0
    return cur >= README_POPUP_MIN_VERSION
end

local function isDirectory(dir)
    if lfs and type(lfs.attributes) == "function" then
        local m = lfs.attributes(dir, "mode")
        if m == "directory" then return true end
    end
    return runSysCommand(string.format("test -d %q", dir))
end

local function getCacheDir()
    local base_dir = DataStorage.getDataDir and DataStorage:getDataDir() or "/tmp"
    local dir = base_dir .. "/cache/storify/readme"
    local ok, err = util.makePath(dir)
    if not ok then
        logger.warn("Storify README cache dir failure", err)
    end
    return dir
end

local function buildRawUrl(owner, repo)
    return string.format("https://raw.githubusercontent.com/%s/%s/HEAD/README.md", owner, repo)
end

local function download(url)
    local response = {}
    local code, _, status = Net.requestToTable({
        url = url,
        headers = {
            ["Accept"] = "text/plain",
            ["User-Agent"] = "KOReader-Storify",
        },
    }, response)
    return code, status, table.concat(response)
end

-- Download and clean the raw README body, shared by the cached and
-- direct-to-viewer fetch paths below.
local function downloadReadmeBody(owner, repo)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    local url = Mirror.apply(buildRawUrl(owner, repo))
    local code, status, body = download(url)
    if tonumber(code) ~= 200 then
        if code then
            return nil, string.format("HTTP %s", tostring(code))
        end
        return nil, tostring(status or "network error")
    end
    if not body or body == "" then
        return nil, "empty body"
    end
    -- Strip inline HTML <img> tags to avoid rendering issues in the text viewer.
    -- This keeps the textual README content while dropping embedded images.
    body = body:gsub("<img[^>]->", "")
    return body
end

-- Legacy path (KOReader older than TextViewer markdown support): download the
-- README and cache it to disk, returning the file path.
function RepoContent.fetchReadme(owner, repo)
    local body, err = downloadReadmeBody(owner, repo)
    if not body then
        return false, err
    end
    local dir = getCacheDir()
    local safe_owner = owner:gsub("[^%w_-]", "_")
    local safe_repo = repo:gsub("[^%w_-]", "_")
    local path = string.format("%s/%s_%s_README.md", dir, safe_owner, safe_repo)
    local ok, werr = util.writeToFile(body, path)
    if not ok then
        return false, werr or "write error"
    end
    return true, path
end

-- Direct-to-viewer path: download the README and return its content, with no
-- on-disk caching.
function RepoContent.fetchReadmeContent(owner, repo)
    return downloadReadmeBody(owner, repo)
end

-- Remove every cached README markdown file generated by RepoContent.fetchReadme.
-- Returns a table with `removed` count and `errors` list (failed file paths).
function RepoContent.clearReadmeCache()
    local base_dir = DataStorage.getDataDir and DataStorage:getDataDir() or "/tmp"
    local dir = base_dir .. "/cache/storify/readme"
    local removed = 0
    local errors = {}

    if not isDirectory(dir) then
        return { removed = 0, errors = errors }
    end

    if lfs and type(lfs.dir) == "function" then
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." then
                local full_path = dir .. "/" .. entry
                local is_dir = runSysCommand(string.format("test -d %q", full_path))
                if not is_dir then
                    local ok = os.remove(full_path)
                    if ok then
                        removed = removed + 1
                    else
                        table.insert(errors, full_path)
                    end
                end
            end
        end
    end
    return { removed = removed, errors = errors }
end

function RepoContent.openReadme(path)
    if not path then
        if ok_uim and ok_info and UIManager and InfoMessage then
            UIManager:show(InfoMessage:new{ text = _("Missing README path"), timeout = 4 })
        end
        return
    end
    local text, err = util.readFromFile(path)
    if not text or text == "" then
        if ok_uim and ok_info and UIManager and InfoMessage then
            UIManager:show(InfoMessage:new{ text = _("Unable to read README file"), timeout = 4 })
        end
        return
    end
    if ok_fm and FileManager and FileManager.openFile then
        FileManager:openFile(path)
    end
end

return RepoContent
