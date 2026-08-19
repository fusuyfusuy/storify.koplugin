-- tests/test_runner.lua
-- Standalone Headless Test Runner for storify.koplugin

package.path = "./?.lua;./core/?.lua;./data/?.lua;./net/?.lua;./ui/?.lua;./l10n/?.lua;./tests/stubs/?.lua;./tests/?.lua;" .. package.path

-- Load Mock Stubs
require("tests/stubs/koreader_stubs")

local target_filter = arg[1]

local p = io.popen("ls tests/*_test.lua 2>/dev/null")
local test_files = {}
if p then
    for file in p:lines() do
        if not target_filter or file:find(target_filter) then
            table.insert(test_files, file)
        end
    end
    p:close()
end

if #test_files == 0 then
    print("No test files found matching: " .. tostring(target_filter or "tests/*_test.lua"))
    os.exit(0)
end

print("==================================================")
print(string.format("Running %d test suite(s)...", #test_files))
print("==================================================")

local total_suites = #test_files
local failed_suites = 0

for _, test_file in ipairs(test_files) do
    print(string.format("\n--> Executing: %s", test_file))
    local ok, err = pcall(dofile, test_file)
    if not ok then
        failed_suites = failed_suites + 1
        print(string.format("❌ ERROR in suite %s:\n%s", test_file, tostring(err)))
    else
        print(string.format("✓ SUITE %s COMPLETED", test_file))
    end
end

print("\n==================================================")
if failed_suites == 0 then
    print(string.format("🎉 ALL %d TEST SUITES PASSED", total_suites))
    print("==================================================")
    os.exit(0)
else
    print(string.format("❌ %d OF %d TEST SUITES FAILED", failed_suites, total_suites))
    print("==================================================")
    os.exit(1)
end
