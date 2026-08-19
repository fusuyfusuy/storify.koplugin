-- tests/stubs/koreader_stubs.lua
-- Comprehensive stubs for running KOReader plugins under standalone LuaJIT.

local ffi = require("ffi")

-- Ensure C declarations for standard libc functions used in stubs
ffi.cdef[[
    char *realpath(const char *path, char *resolved_path);
    int mkdir(const char *pathname, unsigned int mode);
    int access(const char *pathname, int mode);
]]

local Stubs = {}

-- 1. In-memory data store directory
local test_dir = "/tmp/koreader_test_" .. tostring(os.time())
os.execute("mkdir -p " .. test_dir .. "/settings " .. test_dir .. "/cache " .. test_dir .. "/plugins " .. test_dir .. "/patches")
Stubs.test_dir = test_dir

-- 2. logger mock
local mock_logger = {
    warn = function(...) end,
    info = function(...) end,
    dbg = function(...) end,
    err = function(...) end,
}
package.preload["logger"] = function() return mock_logger end

-- 3. gettext mock
local mock_gettext = setmetatable({
    current_lang = "C",
    pgettext = function(ctx, msgid) return msgid end,
}, {
    __call = function(_, msgid) return msgid end,
})
package.preload["gettext"] = function() return mock_gettext end

-- 4. datastorage mock
local mock_datastorage = {
    getDataDir = function() return test_dir end,
    getSettingsDir = function() return test_dir .. "/settings" end,
    getPatchesDir = function() return test_dir .. "/patches" end,
}
package.preload["datastorage"] = function() return mock_datastorage end

-- 5. LuaSettings mock
local _global_settings_store = {}
local LuaSettings = {}
LuaSettings.__index = LuaSettings

function LuaSettings:open(path)
    local o = { path = path, store = _global_settings_store[path] or {} }
    _global_settings_store[path] = o.store
    return setmetatable(o, LuaSettings)
end

function LuaSettings:readSetting(key, default)
    if self.store[key] ~= nil then
        return self.store[key]
    end
    return default
end

function LuaSettings:saveSetting(key, val)
    self.store[key] = val
end

function LuaSettings:delSetting(key)
    self.store[key] = nil
end

function LuaSettings:flush()
    -- in memory mock
end

function LuaSettings:has(key)
    return self.store[key] ~= nil
end

package.preload["luasettings"] = function() return LuaSettings end
package.preload["LuaSettings"] = function() return LuaSettings end

-- 6. json mock
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
    return {}
end

local mock_json = {
    encode = json_encode,
    decode = json_decode,
}
package.preload["json"] = function() return mock_json end

-- 7. socket & socket.url mock
local mock_socket = {
    gettime = function() return os.time() end,
    sleep = function(sec) os.execute("sleep " .. tostring(sec)) end,
    protect = function(f) return f end,
    skip = function(d, ...) return ... end,
}
package.preload["socket"] = function() return mock_socket end
package.preload["socket.core"] = function() return mock_socket end

local mock_url = {
    parse = function(url_str)
        if not url_str then return nil end
        local scheme, rest = url_str:match("^([a-zA-Z0-9+.-]+)://(.*)$")
        if not scheme then return nil end
        local host, path = rest:match("^([^/:]+)(.*)$")
        return {
            scheme = scheme,
            host = host,
            path = path or "/",
        }
    end,
    build = function(parsed)
        if not parsed then return "" end
        local s = (parsed.scheme or "http") .. "://" .. (parsed.host or "")
        if parsed.port then s = s .. ":" .. parsed.port end
        if parsed.path then s = s .. parsed.path end
        if parsed.query then s = s .. "?" .. parsed.query end
        return s
    end,
}
package.preload["socket.url"] = function() return mock_url end

-- 8. socketutil mock
local mock_socketutil = {
    set_timeout = function(b, t) end,
    reset_timeout = function() end,
}
package.preload["socketutil"] = function() return mock_socketutil end

local function is_cmd_ok(res)
    return res == 0 or res == true
end

-- 9. ffiUtil mock
local mock_ffiutil = {
    realpath = function(p)
        if not p then return nil end
        local buf = ffi.new("char[4096]")
        local res = ffi.C.realpath(p, buf)
        if res ~= nil then
            return ffi.string(res)
        end
        return p
    end,
    isSubPath = function(sub, parent)
        if not sub or not parent then return false end
        local norm_p = parent:gsub("/+$", "") .. "/"
        local norm_s = sub:gsub("/+$", "") .. "/"
        return norm_s:sub(1, #norm_p) == norm_p
    end,
    makePath = function(p)
        os.execute("mkdir -p " .. string.format("%q", p))
        return true
    end,
    copyFile = function(src, dst)
        return is_cmd_ok(os.execute(string.format("cp %q %q", src, dst)))
    end,
}
package.preload["ffiutil"] = function() return mock_ffiutil end
package.preload["ffiUtil"] = function() return mock_ffiutil end

-- 10. lfs mock
local mock_lfs = {
    attributes = function(filepath, req)
        if not filepath or filepath == "" then return nil end
        local is_dir = is_cmd_ok(os.execute(string.format("test -d %q", filepath)))
        local is_file = not is_dir and is_cmd_ok(os.execute(string.format("test -e %q", filepath)))
        if not is_dir and not is_file then
            return nil
        end
        local attr = {
            mode = is_dir and "directory" or "file",
            size = 1024,
            modification = os.time(),
        }
        if req then return attr[req] end
        return attr
    end,
    dir = function(dirpath)
        local p = io.popen(string.format("ls -a %q 2>/dev/null", dirpath))
        if not p then return function() return nil end end
        local lines = {}
        for l in p:lines() do
            table.insert(lines, l)
        end
        p:close()
        local i = 0
        return function()
            i = i + 1
            return lines[i]
        end
    end,
    mkdir = function(dirpath)
        return is_cmd_ok(os.execute(string.format("mkdir -p %q", dirpath)))
    end,
    rmdir = function(dirpath)
        return is_cmd_ok(os.execute(string.format("rmdir %q 2>/dev/null", dirpath)))
    end,
}
package.preload["lfs"] = function() return mock_lfs end
package.preload["libs/libkoreader-lfs"] = function() return mock_lfs end

-- 11. UI and Widget Stubs
local mock_widget_container = {
    extend = function(self, tbl)
        tbl = tbl or {}
        tbl.__index = tbl
        function tbl:new(o)
            o = o or {}
            setmetatable(o, tbl)
            if o.init then o:init() end
            return o
        end
        return tbl
    end,
    new = function(self, o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        if o.init then o:init() end
        return o
    end,
    getSize = function(self)
        return { w = self.width or 800, h = self.height or 50 }
    end,
    getHeight = function(self)
        return self.height or 50
    end,
}
package.preload["ui/widget/container/widgetcontainer"] = function() return mock_widget_container end
package.preload["ui/widget/container/inputcontainer"] = function() return mock_widget_container end
package.preload["ui/widget/focusmanager"] = function() return mock_widget_container end
package.preload["ui/widget/container/scrollablecontainer"] = function() return mock_widget_container end
package.preload["ui/widget/container/framecontainer"] = function() return mock_widget_container end
package.preload["ui/widget/container/centercontainer"] = function() return mock_widget_container end
package.preload["ui/widget/container/rightcontainer"] = function() return mock_widget_container end
package.preload["ui/widget/overlapgroup"] = function() return mock_widget_container end
package.preload["ui/widget/horizontalgroup"] = function() return mock_widget_container end
package.preload["ui/widget/verticalgroup"] = function() return mock_widget_container end
package.preload["ui/widget/titlebar"] = function() return mock_widget_container end
package.preload["ui/widget/button"] = function() return mock_widget_container end
package.preload["ui/widget/horizontalspan"] = function() return mock_widget_container end
package.preload["ui/widget/verticalspan"] = function() return mock_widget_container end
package.preload["ui/widget/linewidget"] = function() return mock_widget_container end
package.preload["ui/widget/confirmbox"] = function() return mock_widget_container end
package.preload["ui/widget/infomessage"] = function() return mock_widget_container end
package.preload["ui/widget/textviewer"] = function() return mock_widget_container end
package.preload["ui/widget/textwidget"] = function() return mock_widget_container end
package.preload["ui/widget/textboxwidget"] = function() return mock_widget_container end
package.preload["ui/widget/multiinputdialog"] = function() return mock_widget_container end
package.preload["ui/widget/inputdialog"] = function() return mock_widget_container end
package.preload["ui/widget/checkbutton"] = function() return mock_widget_container end
package.preload["ui/widget/buttondialog"] = function() return mock_widget_container end
package.preload["ui/widget/spinwidget"] = function() return mock_widget_container end

local mock_uimanager = {
    show = function(...) end,
    close = function(...) end,
    nextTick = function(fn) if fn then fn() end end,
    scheduleIn = function(sec, fn) if fn then fn() end end,
}
package.preload["ui/uimanager"] = function() return mock_uimanager end

local mock_device = {
    screen = {
        getWidth = function() return 1072 end,
        getHeight = function() return 1448 end,
    },
    input = {
        group = {},
    },
}
package.preload["device"] = function() return mock_device end

local mock_dispatcher = {
    registerAction = function(...) end,
}
package.preload["dispatcher"] = function() return mock_dispatcher end

local mock_size = {
    margin = { small = 4, default = 8, large = 16 },
    border = { thin = 1, default = 2 },
    padding = { small = 4, default = 8 },
}
package.preload["ui/size"] = function() return mock_size end

local mock_font = {
    fontface = {
        t = { font = "sans", size = 16 },
    },
    getFace = function() return {} end,
    getSize = function() return 16 end,
}
package.preload["ui/font"] = function() return mock_font end

local mock_geom = {
    new = function(x, y, w, h) return { x = x or 0, y = y or 0, w = w or 0, h = h or 0 } end,
}
package.preload["ui/geometry"] = function() return mock_geom end

local mock_sha2 = {
    sha256 = function(str) return "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" end,
}
package.preload["ffi/sha2"] = function() return mock_sha2 end

local mock_archiver = {
    extract = function(src, dst)
        return os.execute(string.format("unzip -q -o %q -d %q 2>/dev/null || tar -xzf %q -C %q 2>/dev/null", src, dst, src, dst)) == 0
    end,
}
package.preload["ffi/archiver"] = function() return mock_archiver end

-- 12. SQLite FFI Bridge
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

return Stubs
