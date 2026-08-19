-- core/storify_version.lua
-- Pure Domain Layer: Semantic Versioning, Date Versioning, and Tag Parsing Engine

local StorifyVersion = {}

-- Strips common git tag / release prefixes (e.g., "v1.0", "release-v2.0", "plugin-1.4")
function StorifyVersion.stripVersionPrefix(str)
    if not str or str == "" then
        return str
    end
    local cleaned = tostring(str):match("^%s*(.-)%s*$")
    -- Strip release-, release/, release_, version-, version/, version_, plugin-, plugin/, plugin_
    cleaned = cleaned:gsub("^[rR][eE][lL][eE][aA][sS][eE][%-_/]", "")
    cleaned = cleaned:gsub("^[vV][eE][rR][sS][iI][oO][nN][%-_/]", "")
    cleaned = cleaned:gsub("^[pP][lL][uU][gG][iI][nN][%-_/]", "")
    -- Strip leading v / V
    cleaned = cleaned:gsub("^[vV]", "")
    return cleaned
end

-- Trims whitespace and strips prefixes
function StorifyVersion.cleanTagName(tag)
    return StorifyVersion.stripVersionPrefix(tag)
end

-- Validates whether components form a realistic calendar date (2000-2100)
local function isValidDate(year, month, day)
    local y = tonumber(year)
    local m = tonumber(month)
    local d = tonumber(day)
    if y and m and d then
        if y >= 2000 and y <= 2100 and m >= 1 and m <= 12 and d >= 1 and d <= 31 then
            return true
        end
    end
    return false
end

-- Checks if a version string is date-based (e.g. 2026.08.18, 2024-05-01, 20250130)
function StorifyVersion.isDateBasedVersion(str)
    if not str or str == "" then
        return false
    end
    local s = StorifyVersion.stripVersionPrefix(str)
    
    -- Format: YYYY.MM.DD or YYYY-MM-DD or YYYY_MM_DD
    local y, m, d = s:match("^(%d%d%d%d)[%.%-_](%d%d?)[%.%-_](%d%d?)")
    if y and m and d and isValidDate(y, m, d) then
        return true, tonumber(y), tonumber(m), tonumber(d)
    end

    -- Format: YYYYMMDD
    y, m, d = s:match("^(%d%d%d%d)(%d%d)(%d%d)$")
    if y and m and d and isValidDate(y, m, d) then
        return true, tonumber(y), tonumber(m), tonumber(d)
    end

    return false
end

-- Parses a version string into a structured representation
function StorifyVersion.parseVersion(str)
    if not str or str == "" then
        return nil
    end

    local clean = StorifyVersion.stripVersionPrefix(str)
    local is_date, dy, dm, dd = StorifyVersion.isDateBasedVersion(clean)
    if is_date then
        -- Date based version
        local extra_part = clean:match("^%d+[%.%-_]%d+[%.%-_]%d+[%.%-_](%d+)")
        return {
            raw = str,
            clean = clean,
            type = "date",
            is_date = true,
            year = dy,
            month = dm,
            day = dd,
            patch = tonumber(extra_part) or 0,
            parts = { dy, dm, dd, tonumber(extra_part) or 0 },
        }
    end

    -- Remove build metadata (+build...)
    local without_build = clean:gsub("%+.*$", "")
    -- Extract pre-release (-beta.1, -alpha, -rc.2)
    local version_core, prerelease = without_build:match("^([0-9%.]+)%-(.+)$")
    if not version_core then
        version_core = without_build:match("^([0-9%.]+)") or clean
        prerelease = nil
    end

    local parts = {}
    for part in version_core:gmatch("(%d+)") do
        table.insert(parts, tonumber(part))
    end

    if #parts > 0 then
        return {
            raw = str,
            clean = clean,
            type = "semver",
            is_date = false,
            major = parts[1] or 0,
            minor = parts[2] or 0,
            patch = parts[3] or 0,
            parts = parts,
            prerelease = prerelease,
        }
    end

    -- Fallback raw
    return {
        raw = str,
        clean = clean,
        type = "raw",
        is_date = false,
        parts = {},
    }
end

-- Extracts a valid version string from a Git tag
function StorifyVersion.parseVersionFromTag(tag_name)
    if not tag_name or tag_name == "" then
        return nil
    end

    local cleaned = StorifyVersion.stripVersionPrefix(tag_name)
    if cleaned == "" then
        return nil
    end

    local is_date, y, m, d = StorifyVersion.isDateBasedVersion(cleaned)
    if is_date then
        local matched_date = cleaned:match("^(%d+[%.-_]%d+[%.-_]%d+)") or cleaned:match("^(%d%d%d%d%d%d%d%d)")
        return matched_date
    end

    local patterns = {
        "^(%d+%.%d+%.%d+[%w%.%-_]*)",
        "^(%d+%.%d+)",
        "^(%d+)",
    }

    for _, pattern in ipairs(patterns) do
        local ver = cleaned:match(pattern)
        if ver then
            return ver
        end
    end

    return nil
end

-- Pre-release rank helper (alpha < beta < rc < release)
local function comparePrereleases(p1, p2)
    if p1 == p2 then
        return 0
    end
    -- If one has no prerelease, it is a final release and thus NEWER
    if not p1 and p2 then
        return 1
    end
    if p1 and not p2 then
        return -1
    end

    -- Split prerelease by '.' or '-'
    local function splitPre(p)
        local chunks = {}
        for c in tostring(p):gmatch("([^%.%-]+)") do
            local num = tonumber(c)
            table.insert(chunks, num or c)
        end
        return chunks
    end

    local c1 = splitPre(p1)
    local c2 = splitPre(p2)
    local max_len = math.max(#c1, #c2)

    local rank_map = {
        dev = 1,
        alpha = 2,
        a = 2,
        beta = 3,
        b = 3,
        rc = 4,
        preview = 4,
    }

    for i = 1, max_len do
        local a = c1[i]
        local b = c2[i]
        if a == nil and b ~= nil then return -1 end
        if a ~= nil and b == nil then return 1 end

        if type(a) == "number" and type(b) == "number" then
            if a > b then return 1 end
            if a < b then return -1 end
        elseif type(a) == "string" and type(b) == "string" then
            local r1 = rank_map[a:lower()]
            local r2 = rank_map[b:lower()]
            if r1 and r2 then
                if r1 > r2 then return 1 end
                if r1 < r2 then return -1 end
            else
                if a > b then return 1 end
                if a < b then return -1 end
            end
        else
            -- Number vs string: numbers are lower according to SemVer spec or string representation
            if tostring(a) > tostring(b) then return 1 end
            if tostring(a) < tostring(b) then return -1 end
        end
    end

    return 0
end

-- Compares two version strings or tables:
-- Returns:
--  1 if v1 > v2
-- -1 if v1 < v2
--  0 if v1 == v2
function StorifyVersion.compareVersions(v1_input, v2_input)
    if v1_input == nil and v2_input == nil then
        return 0
    end
    if v1_input ~= nil and v2_input == nil then
        return 1
    end
    if v1_input == nil and v2_input ~= nil then
        return -1
    end

    local v1 = (type(v1_input) == "table" and v1_input.type) and v1_input or StorifyVersion.parseVersion(v1_input)
    local v2 = (type(v2_input) == "table" and v2_input.type) and v2_input or StorifyVersion.parseVersion(v2_input)

    if not v1 and not v2 then
        return 0
    end
    if v1 and not v2 then
        return 1
    end
    if not v1 and v2 then
        return -1
    end

    -- Compare numeric segments
    local p1 = v1.parts or {}
    local p2 = v2.parts or {}
    local max_len = math.max(#p1, #p2)

    for i = 1, max_len do
        local n1 = p1[i] or 0
        local n2 = p2[i] or 0
        if n1 > n2 then
            return 1
        end
        if n1 < n2 then
            return -1
        end
    end

    -- Compare pre-releases
    return comparePrereleases(v1.prerelease, v2.prerelease)
end

-- Returns true if v1 > v2 (e.g. remote > local)
function StorifyVersion.isVersionNewer(v1_str, v2_str)
    if not v1_str or not v2_str then
        return false
    end
    return StorifyVersion.compareVersions(v1_str, v2_str) == 1
end

return StorifyVersion
