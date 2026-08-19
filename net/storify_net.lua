--[[--
HTTP requests with guaranteed timeout cleanup and error handling.

`socketutil`'s timeouts are global: set, request, reset. Should the request
throw in between, the reset would never run and the rest of KOReader would keep
waiting as long as we asked to. Here the request goes through pcall with a guaranteed
reset cleanup whatever the outcome.

The sink is built here rather than by the caller because socketutil's sinks read the deadline
when they are created, which has to be after `set_timeout`.
]]

local function getHttp()
    local ok_http, http = pcall(require, "socket.http")
    if ok_http and http then return http end
    return {
        request = function() return nil, "socket.http not available" end,
    }
end

local function getSocketUtil()
    local ok_su, socketutil = pcall(require, "socketutil")
    if ok_su and socketutil then return socketutil end
    return nil
end

local ok_log, logger = pcall(require, "logger")
if not ok_log or not logger then
    logger = {
        warn = function(...) end,
        info = function(...) end,
        dbg = function(...) end,
        err = function(...) end,
    }
end

local Net = {}

local DEFAULT_LARGE_BLOCK_TIMEOUT = (socketutil and socketutil.LARGE_BLOCK_TIMEOUT) or 10
local DEFAULT_LARGE_TOTAL_TIMEOUT = (socketutil and socketutil.LARGE_TOTAL_TIMEOUT) or 30
local DEFAULT_FILE_BLOCK_TIMEOUT = (socketutil and socketutil.FILE_BLOCK_TIMEOUT) or 15
local DEFAULT_FILE_TOTAL_TIMEOUT = (socketutil and socketutil.FILE_TOTAL_TIMEOUT) or 300

local function safeResetTimeout()
    local socketutil = getSocketUtil()
    if socketutil and type(socketutil.reset_timeout) == "function" then
        pcall(function()
            socketutil:reset_timeout()
        end)
    end
end

local function safeSetTimeout(block_timeout, total_timeout)
    local socketutil = getSocketUtil()
    if socketutil and type(socketutil.set_timeout) == "function" then
        pcall(function()
            socketutil:set_timeout(
                block_timeout or DEFAULT_LARGE_BLOCK_TIMEOUT,
                total_timeout or DEFAULT_LARGE_TOTAL_TIMEOUT
            )
        end)
    end
end

local function perform(request, make_sink, block_timeout, total_timeout)
    safeSetTimeout(block_timeout, total_timeout)

    local ok, result, code, headers, status = pcall(function()
        if make_sink then
            request.sink = make_sink()
        end
        local http = getHttp()
        return http.request(request)
    end)

    safeResetTimeout()

    if not ok then
        logger.warn("storify: request failed:", request and request.url, result)
        -- The reason goes where a status line would: callers already read it.
        return nil, nil, result
    end
    return code, headers, status
end

--- Collect the response body into `response_parts`, to be concatenated by the caller.
function Net.requestToTable(request, response_parts, block_timeout, total_timeout)
    local socketutil = getSocketUtil()
    return perform(request, function()
        if socketutil and type(socketutil.table_sink) == "function" then
            return socketutil.table_sink(response_parts)
        end
        return function(chunk, err)
            if chunk then
                table.insert(response_parts, chunk)
            end
            return 1
        end
    end, block_timeout or DEFAULT_LARGE_BLOCK_TIMEOUT, total_timeout or DEFAULT_LARGE_TOTAL_TIMEOUT)
end

--- Write the response body to an open file handle or filepath string.
function Net.requestToFile(request, file_or_path, block_timeout, total_timeout)
    local fh = file_or_path
    local opened_here = false

    if type(file_or_path) == "string" then
        local parent = file_or_path:match("^(.*)/[^/]+$")
        if parent and parent ~= "" then
            local ok_f, ffiUtil = pcall(require, "ffi/util")
            if not ok_f or not ffiUtil then
                pcall(function() ffiUtil = require("ffiutil") end)
            end
            if ffiUtil and ffiUtil.makePath then
                pcall(ffiUtil.makePath, parent)
            end
            os.execute(string.format("mkdir -p %q 2>/dev/null", parent))
        end

        local open_err
        fh, open_err = io.open(file_or_path, "wb")
        if not fh then
            return nil, nil, "Failed to open destination file: " .. tostring(open_err)
        end
        opened_here = true
    end

    local socketutil = getSocketUtil()
    local code, headers, status = perform(request, function()
        if socketutil and type(socketutil.file_sink) == "function" then
            return socketutil.file_sink(fh)
        end
        return function(chunk, err)
            if chunk and fh then
                fh:write(chunk)
            end
            return 1
        end
    end, block_timeout or DEFAULT_FILE_BLOCK_TIMEOUT, total_timeout or DEFAULT_FILE_TOTAL_TIMEOUT)

    if opened_here and fh then
        pcall(function() fh:close() end)
    end

    return code, headers, status
end

return Net
