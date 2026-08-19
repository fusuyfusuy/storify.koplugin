-- tests/storify_version_test.lua
-- Unit tests for core/storify_version.lua

local Version = require("storify_version")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

local function assert_true(cond, msg)
    if not cond then
        error(msg or "expected true, got false/nil", 2)
    end
end

local function assert_false(cond, msg)
    if cond then
        error(msg or "expected false, got true", 2)
    end
end

print("--> [storify_version_test] Starting test suite...")

-- 1. Prefix Stripping & Tag Cleaning
do
    assert_eq(Version.stripVersionPrefix("v1.2.3"), "1.2.3", "Strip leading v")
    assert_eq(Version.stripVersionPrefix("V2.0.0"), "2.0.0", "Strip leading V")
    assert_eq(Version.stripVersionPrefix("release-v1.4.0"), "1.4.0", "Strip release-v")
    assert_eq(Version.stripVersionPrefix("version-1.0"), "1.0", "Strip version-")
    assert_eq(Version.stripVersionPrefix("plugin-0.9.1"), "0.9.1", "Strip plugin-")
    assert_eq(Version.stripVersionPrefix("release/v3.0.0"), "3.0.0", "Strip release/v")
    assert_eq(Version.stripVersionPrefix("1.0.0"), "1.0.0", "No prefix unchanged")
    assert_eq(Version.stripVersionPrefix(nil), nil, "Nil handling")
    assert_eq(Version.stripVersionPrefix(""), "", "Empty string handling")
end

-- 2. Tag Cleaning & Version from Tag Extraction
do
    assert_eq(Version.cleanTagName("  v1.2.3  "), "1.2.3", "Clean whitespace and prefix")
    assert_eq(Version.parseVersionFromTag("v1.2.3"), "1.2.3", "Parse basic semver from tag")
    assert_eq(Version.parseVersionFromTag("release-2.5.1"), "2.5.1", "Parse version from release tag")
    assert_eq(Version.parseVersionFromTag("plugin-v0.8"), "0.8", "Parse 2-part version from tag")
    assert_eq(Version.parseVersionFromTag("v2026.01.15"), "2026.01.15", "Parse date-based tag")
    assert_eq(Version.parseVersionFromTag(nil), nil, "Parse nil tag")
    assert_eq(Version.parseVersionFromTag("not-a-version"), nil, "Parse invalid tag")
end

-- 3. SemVer Parsing
do
    local v1 = Version.parseVersion("1.2.3")
    assert_eq(v1.type, "semver", "Semver type")
    assert_eq(v1.major, 1, "Semver major")
    assert_eq(v1.minor, 2, "Semver minor")
    assert_eq(v1.patch, 3, "Semver patch")
    assert_eq(v1.prerelease, nil, "Semver no prerelease")

    local v2 = Version.parseVersion("v2.10.4-beta.2+build.42")
    assert_eq(v2.major, 2, "Semver major with v and prerelease")
    assert_eq(v2.minor, 10, "Semver minor")
    assert_eq(v2.patch, 4, "Semver patch")
    assert_eq(v2.prerelease, "beta.2", "Semver prerelease string")

    local v3 = Version.parseVersion("3.0")
    assert_eq(v3.major, 3, "2-part semver major")
    assert_eq(v3.minor, 0, "2-part semver minor")
    assert_eq(v3.patch, 0, "2-part semver default patch")
end

-- 4. Date Version Parsing
do
    local d1 = Version.parseVersion("v2026.08.18")
    assert_eq(d1.type, "date", "Date type")
    assert_eq(d1.is_date, true, "is_date flag")
    assert_eq(d1.year, 2026, "Date year")
    assert_eq(d1.month, 8, "Date month")
    assert_eq(d1.day, 18, "Date day")

    local d2 = Version.parseVersion("2024-12-05")
    assert_eq(d2.type, "date", "Dash date type")
    assert_eq(d2.year, 2024, "Dash date year")
    assert_eq(d2.month, 12, "Dash date month")
    assert_eq(d2.day, 5, "Dash date day")

    local d3 = Version.parseVersion("20250130")
    assert_eq(d3.type, "date", "Compact date type")
    assert_eq(d3.year, 2025, "Compact date year")
    assert_eq(d3.month, 1, "Compact date month")
    assert_eq(d3.day, 30, "Compact date day")
end

-- 5. SemVer Comparison (compareVersions & isVersionNewer)
do
    -- Basic ordering
    assert_eq(Version.compareVersions("1.0.0", "1.0.1"), -1, "1.0.0 < 1.0.1")
    assert_eq(Version.compareVersions("1.0.1", "1.0.0"), 1, "1.0.1 > 1.0.0")
    assert_eq(Version.compareVersions("1.0.0", "1.0.0"), 0, "1.0.0 == 1.0.0")
    assert_eq(Version.compareVersions("v1.0.0", "1.0.0"), 0, "v1.0.0 == 1.0.0 (v prefix stripped)")

    assert_eq(Version.compareVersions("1.1.0", "1.0.9"), 1, "1.1.0 > 1.0.9")
    assert_eq(Version.compareVersions("2.0.0", "1.99.99"), 1, "2.0.0 > 1.99.99")
    assert_eq(Version.compareVersions("1.2", "1.2.0"), 0, "1.2 == 1.2.0")
    assert_eq(Version.compareVersions("1.2.1", "1.2"), 1, "1.2.1 > 1.2")

    -- isVersionNewer helper (remote > local)
    assert_true(Version.isVersionNewer("1.0.1", "1.0.0"), "1.0.1 is newer than 1.0.0")
    assert_false(Version.isVersionNewer("1.0.0", "1.0.1"), "1.0.0 is not newer than 1.0.1")
    assert_false(Version.isVersionNewer("1.0.0", "1.0.0"), "Identical versions not newer")
    assert_false(Version.isVersionNewer("v1.4.2", "1.4.2"), "v1.4.2 vs 1.4.2 not newer")
    assert_true(Version.isVersionNewer("v1.4.3", "1.4.2"), "v1.4.3 is newer than 1.4.2")
end

-- 6. Pre-release Version Comparison
do
    -- Normal release is newer than pre-release
    assert_eq(Version.compareVersions("1.0.0-beta.1", "1.0.0"), -1, "1.0.0-beta.1 < 1.0.0")
    assert_eq(Version.compareVersions("1.0.0", "1.0.0-alpha"), 1, "1.0.0 > 1.0.0-alpha")

    -- Pre-release ordering: alpha < beta < rc
    assert_eq(Version.compareVersions("1.0.0-alpha", "1.0.0-beta"), -1, "alpha < beta")
    assert_eq(Version.compareVersions("1.0.0-beta.1", "1.0.0-beta.2"), -1, "beta.1 < beta.2")
    assert_eq(Version.compareVersions("1.0.0-beta.2", "1.0.0-rc.1"), -1, "beta.2 < rc.1")
    assert_eq(Version.compareVersions("1.0.0-rc.1", "1.0.0"), -1, "rc.1 < final")
end

-- 7. Date Version Comparison
do
    assert_eq(Version.compareVersions("v2026.01.15", "v2026.08.18"), -1, "Jan 2026 < Aug 2026")
    assert_eq(Version.compareVersions("2026.08.18", "2026.01.15"), 1, "Aug 2026 > Jan 2026")
    assert_eq(Version.compareVersions("2024-05-01", "2024-05-01"), 0, "Same dates equal")
    assert_true(Version.isVersionNewer("2026.08.18", "2026.08.01"), "Date is newer")
    assert_false(Version.isVersionNewer("2026.01.01", "2026.08.01"), "Date is older")
end

-- 8. Graceful Fallbacks & Edge Cases
do
    assert_false(Version.isVersionNewer(nil, "1.0.0"), "Nil remote not newer")
    assert_false(Version.isVersionNewer("1.0.0", nil), "Nil local not newer (local unknown)")
    assert_false(Version.isVersionNewer(nil, nil), "Nil vs nil not newer")
    assert_eq(Version.compareVersions(nil, nil), 0, "Nil vs nil compare 0")
    assert_eq(Version.compareVersions("1.0.0", nil), 1, "1.0.0 > nil")
    assert_eq(Version.compareVersions(nil, "1.0.0"), -1, "nil < 1.0.0")

    -- Multi-segment versions
    assert_eq(Version.compareVersions("1.2.3.4", "1.2.3.5"), -1, "4-part semver")
    assert_eq(Version.compareVersions("1.2.3.5", "1.2.3.4"), 1, "4-part semver")
    assert_eq(Version.compareVersions("1.2.3.4", "1.2.3.4"), 0, "4-part semver equal")
end

print("✓ [storify_version_test] All version tests passed successfully.")
return true
