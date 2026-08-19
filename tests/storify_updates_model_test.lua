-- tests/storify_updates_model_test.lua
-- Unit tests for StorifyUpdatesDialog and its ViewModel logic

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

local WidgetContainer = require("ui/widget/container/widgetcontainer")
if WidgetContainer and not WidgetContainer.new then
    function WidgetContainer:new(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        if o.init then o:init() end
        return o
    end
    function WidgetContainer:getSize()
        return self.dimen or { w = 100, h = 30 }
    end
    function WidgetContainer:getHeight()
        return (self.dimen and self.dimen.h) or 30
    end
    function WidgetContainer:getWidth()
        return (self.dimen and self.dimen.w) or 100
    end
end

local Updates = require("storify_updates_dialog")
local UpdatesModel = Updates.Model or Updates

-- =========================================================================
-- 1. Test Update Candidate List Preparation
-- =========================================================================
print("\n--- 1. Testing Candidate List Preparation ---")

local installed_plugins = {
    ["plugin_a.koplugin"] = {
        name = "plugin_a.koplugin",
        version = "1.0.0",
        repo_owner = "author1",
        repo_name = "plugin_a",
        repo_full_name = "author1/plugin_a",
    },
    ["plugin_b.koplugin"] = {
        name = "plugin_b.koplugin",
        version = "2.0.0",
        repo_owner = "author2",
        repo_name = "plugin_b",
        repo_full_name = "author2/plugin_b",
    },
    ["plugin_c.koplugin"] = {
        name = "plugin_c.koplugin",
        version = "3.0.0-dev",
        repo_owner = "author3",
        repo_name = "plugin_c",
        repo_full_name = "author3/plugin_c",
    },
    ["plugin_unlinked.koplugin"] = {
        name = "plugin_unlinked.koplugin",
        version = "0.5.0",
    },
    ["plugin_ignored.koplugin"] = {
        name = "plugin_ignored.koplugin",
        version = "1.0.0",
        repo_owner = "author5",
        repo_name = "plugin_ignored",
        repo_full_name = "author5/plugin_ignored",
    },
}

local installed_patches = {
    ["10-test-patch.lua"] = {
        filename = "10-test-patch.lua",
        sha = "1111111111111111111111111111111111111111",
        owner = "patchdev",
        repo = "patches-repo",
        path = "10-test-patch.lua",
    },
    ["20-uptodate-patch.lua"] = {
        filename = "20-uptodate-patch.lua",
        sha = "2222222222222222222222222222222222222222",
        owner = "patchdev",
        repo = "patches-repo",
        path = "20-uptodate-patch.lua",
    },
}

local remote_metadata = {
    repos = {
        ["author1/plugin_a"] = {
            owner = "author1",
            name = "plugin_a",
            latest_version = "1.2.0",
            latest_tag = "v1.2.0",
        },
        ["author2/plugin_b"] = {
            owner = "author2",
            name = "plugin_b",
            latest_version = "2.0.0",
            latest_tag = "v2.0.0",
        },
        ["author3/plugin_c"] = {
            owner = "author3",
            name = "plugin_c",
            latest_version = "2.5.0",
            latest_tag = "v2.5.0",
        },
        ["author5/plugin_ignored"] = {
            owner = "author5",
            name = "plugin_ignored",
            latest_version = "2.0.0",
            latest_tag = "v2.0.0",
        },
    },
    patches = {
        ["patchdev/patches-repo:10-test-patch.lua"] = {
            sha = "9999999999999999999999999999999999999999",
            download_url = "https://example.com/10-test-patch.lua",
        },
        ["patchdev/patches-repo:20-uptodate-patch.lua"] = {
            sha = "2222222222222222222222222222222222222222",
            download_url = "https://example.com/20-uptodate-patch.lua",
        },
    },
}

local ignored_versions = {
    ["author5/plugin_ignored"] = "2.0.0",
}

local candidates = UpdatesModel.prepareUpdateCandidates(
    installed_plugins,
    installed_patches,
    remote_metadata,
    ignored_versions
)

assert_true(#candidates >= 5, "Candidate list should contain entries for all installed items")

local candidate_map = {}
for _, c in ipairs(candidates) do
    candidate_map[c.id] = c
end

-- Plugin A: Update available (1.0.0 -> 1.2.0)
local cand_a = candidate_map["plugin_a.koplugin"]
assert_true(cand_a ~= nil, "Plugin A candidate exists")
assert_eq(cand_a.status, "update_available", "Plugin A status should be update_available")
assert_true(cand_a.has_update, "Plugin A has_update is true")
assert_true(cand_a.can_update, "Plugin A can_update is true")
assert_eq(cand_a.current_version, "1.0.0", "Plugin A current version")
assert_eq(cand_a.latest_version, "1.2.0", "Plugin A latest version")

-- Plugin B: Up to date (2.0.0 == 2.0.0)
local cand_b = candidate_map["plugin_b.koplugin"]
assert_true(cand_b ~= nil, "Plugin B candidate exists")
assert_eq(cand_b.status, "up_to_date", "Plugin B status should be up_to_date")
assert_false(cand_b.has_update, "Plugin B has_update is false")

-- Plugin C: Up to date / dev ahead (3.0.0-dev > 2.5.0)
local cand_c = candidate_map["plugin_c.koplugin"]
assert_true(cand_c ~= nil, "Plugin C candidate exists")
assert_eq(cand_c.status, "up_to_date", "Plugin C status should be up_to_date")
assert_false(cand_c.has_update, "Plugin C has_update is false")

-- Plugin Unlinked
local cand_u = candidate_map["plugin_unlinked.koplugin"]
assert_true(cand_u ~= nil, "Plugin unlinked candidate exists")
assert_eq(cand_u.status, "unlinked", "Plugin unlinked status should be unlinked")
assert_false(cand_u.has_update, "Plugin unlinked has_update is false")

-- Plugin Ignored
local cand_i = candidate_map["plugin_ignored.koplugin"]
assert_true(cand_i ~= nil, "Plugin ignored candidate exists")
assert_eq(cand_i.status, "ignored", "Plugin ignored status should be ignored")
assert_false(cand_i.has_update, "Plugin ignored has_update is false")

-- Patch 1: Update available (SHA changed)
local cand_p1 = candidate_map["10-test-patch.lua"]
assert_true(cand_p1 ~= nil, "Patch 1 candidate exists")
assert_eq(cand_p1.status, "update_available", "Patch 1 status should be update_available")
assert_true(cand_p1.has_update, "Patch 1 has_update is true")

-- Patch 2: Up to date (SHA matching)
local cand_p2 = candidate_map["20-uptodate-patch.lua"]
assert_true(cand_p2 ~= nil, "Patch 2 candidate exists")
assert_eq(cand_p2.status, "up_to_date", "Patch 2 status should be up_to_date")
assert_false(cand_p2.has_update, "Patch 2 has_update is false")

print("  ✓ PASS: Candidate list correctly categorizes update_available, up_to_date, unlinked, and ignored items")

-- =========================================================================
-- 2. Test Batch Selection Toggling
-- =========================================================================
print("\n--- 2. Testing Batch Selection Toggling ---")

-- Initialize default selection (items with update available default to selected)
UpdatesModel.initBatchSelection(candidates)
assert_true(cand_a.selected_for_batch, "Plugin A initially selected for batch")
assert_true(cand_p1.selected_for_batch, "Patch 1 initially selected for batch")
assert_false(cand_b.selected_for_batch, "Plugin B not selected for batch")

-- Get selected batch items
local selected_items = UpdatesModel.getSelectedBatchItems(candidates)
assert_eq(#selected_items, 2, "Initially 2 items selected for batch")

-- Toggle single item off
UpdatesModel.toggleBatchSelection(candidates, "plugin_a.koplugin", false)
assert_false(cand_a.selected_for_batch, "Plugin A toggled off")
local selected_after_toggle = UpdatesModel.getSelectedBatchItems(candidates)
assert_eq(#selected_after_toggle, 1, "Now 1 item selected for batch")
assert_eq(selected_after_toggle[1].id, "10-test-patch.lua", "Remaining selected item is Patch 1")

-- Toggle Select All off
UpdatesModel.toggleSelectAll(candidates, false)
local none_selected = UpdatesModel.getSelectedBatchItems(candidates)
assert_eq(#none_selected, 0, "No items selected after select all false")

-- Toggle Select All on
UpdatesModel.toggleSelectAll(candidates, true)
local all_updateable = UpdatesModel.getSelectedBatchItems(candidates)
assert_eq(#all_updateable, 2, "All updateable items selected (2 items)")

print("  ✓ PASS: Batch selection initialization, single toggle, and toggle-all verified")

-- =========================================================================
-- 3. Test Ignore Release Action Logic
-- =========================================================================
print("\n--- 3. Testing Ignore Release Logic ---")

local test_ignored = {}

-- 1. Ignore new release
local ok_add = UpdatesModel.toggleIgnoreVersion(test_ignored, "author1/plugin_a", "1.2.0")
assert_true(ok_add, "toggleIgnoreVersion returns true when newly ignored")
assert_true(UpdatesModel.isReleaseIgnored(test_ignored, "author1/plugin_a", "1.2.0"), "1.2.0 is ignored")
assert_false(UpdatesModel.isReleaseIgnored(test_ignored, "author1/plugin_a", "1.3.0"), "1.3.0 is not ignored")

-- 2. Un-ignore same release
local ok_remove = UpdatesModel.toggleIgnoreVersion(test_ignored, "author1/plugin_a", "1.2.0")
assert_false(ok_remove, "toggleIgnoreVersion returns false when un-ignored")
assert_false(UpdatesModel.isReleaseIgnored(test_ignored, "author1/plugin_a", "1.2.0"), "1.2.0 is no longer ignored")

-- 3. Update ignored release to newer version
UpdatesModel.toggleIgnoreVersion(test_ignored, "author1/plugin_a", "1.2.0")
UpdatesModel.toggleIgnoreVersion(test_ignored, "author1/plugin_a", "1.3.0")
assert_true(UpdatesModel.isReleaseIgnored(test_ignored, "author1/plugin_a", "1.3.0"), "1.3.0 is now ignored")
assert_false(UpdatesModel.isReleaseIgnored(test_ignored, "author1/plugin_a", "1.2.0"), "1.2.0 is no longer ignored")

print("  ✓ PASS: Ignore version toggle and check logic verified")

-- =========================================================================
-- 4. Test Summary Statistics Calculation
-- =========================================================================
print("\n--- 4. Testing Summary Statistics ---")

local summary = UpdatesModel.calculateUpdateSummary(candidates)
assert_eq(summary.total_tracked, 7, "Total tracked items count (5 plugins + 2 patches)")
assert_eq(summary.updates_count, 2, "Updates count should be 2")
assert_eq(summary.up_to_date_count, 3, "Up to date count should be 3")
assert_eq(summary.unlinked_count, 1, "Unlinked count should be 1")
assert_eq(summary.ignored_count, 1, "Ignored count should be 1")

print("  ✓ PASS: Update summary statistics accurately computed")

-- =========================================================================
-- 5. Test Rollback Information Extraction
-- =========================================================================
print("\n--- 5. Testing Rollback Capability ---")

local item_with_backup = {
    id = "plugin_a.koplugin",
    name = "plugin_a.koplugin",
    version = "1.2.0",
    has_backup = true,
    backup_version = "1.0.0",
}
local rollback_info = UpdatesModel.getRollbackInfo(item_with_backup)
assert_true(rollback_info.can_rollback, "can_rollback should be true when backup exists")
assert_eq(rollback_info.rollback_version, "1.0.0", "Rollback version matches backup")

local item_without_backup = {
    id = "plugin_b.koplugin",
    name = "plugin_b.koplugin",
    version = "2.0.0",
    has_backup = false,
}
local no_rollback = UpdatesModel.getRollbackInfo(item_without_backup)
assert_false(no_rollback.can_rollback, "can_rollback is false when no backup exists")

print("  ✓ PASS: Rollback metadata helper verified")

-- =========================================================================
-- 6. Test StorifyUpdatesDialog Widget Instantiation
-- =========================================================================
print("\n--- 6. Testing StorifyUpdatesDialog Widget Instantiation ---")

local check_called = false
local scan_called = false
local filter_called = false
local match_called = false
local switch_called = false
local update_all_called = false
local linked_item = nil

local updates_dialog = Updates.StorifyUpdatesDialog:new{
    title = "Storify · Updates",
    summary_text = "2 updates available",
    filter_label = "Show needs update",
    on_check_updates = function() check_called = true end,
    on_scan_request = function() scan_called = true end,
    on_link_item = function(item) linked_item = item end,
    on_toggle_filter = function() filter_called = true end,
    on_match = function() match_called = true end,
    on_switch_target = function() switch_called = true end,
    on_update_all = function(selected) update_all_called = true end,
}

assert_true(updates_dialog ~= nil, "Updates dialog instantiates cleanly")
assert_eq(updates_dialog.title, "Storify · Updates", "Updates dialog title matches")

-- Regression: summary_widget must be constructed with a non-nil face, or
-- KOReader's real TextWidget:updateSize()/Font:getAdjustedFace() crashes the
-- whole app (attempt to index local 'face' (a nil value)).
assert_true(updates_dialog.summary_widget ~= nil, "summary_widget was created")
assert_true(updates_dialog.summary_widget.face ~= nil, "summary_widget has a non-nil face")

-- Update items dynamically with an unlinked item
updates_dialog:setItems({
    { text = "Plugin A (1.0.0 -> 1.2.0)", callback = function() end },
    { text = "Plugin B (2.0.0)", dim = true },
    { text = "Unlinked Plugin", status = "unlinked", id = "unlinked_test" },
})
assert_eq(#updates_dialog.items, 3, "Items count updated")

-- Test tapping unlinked item wires on_link_item
local unlinked_entry = updates_dialog.items[3]
assert_true(unlinked_entry.callback ~= nil, "Unlinked item received callback")
unlinked_entry.callback()
assert_true(linked_item ~= nil and linked_item.id == "unlinked_test", "on_link_item invoked for unlinked entry")

-- Update summary and filter labels
updates_dialog:setSummary("All plugins up to date")
updates_dialog:setFilterLabel("Show all")

-- Test button callback triggers
if updates_dialog.check_button and updates_dialog.check_button.callback then
    updates_dialog.check_button.callback()
    assert_true(check_called, "check_button callback invoked")
end

if updates_dialog.scan_button and updates_dialog.scan_button.callback then
    updates_dialog.scan_button.callback()
    assert_true(scan_called, "scan_button callback invoked")
end

if updates_dialog.filter_button and updates_dialog.filter_button.callback then
    updates_dialog.filter_button.callback()
    assert_true(filter_called, "filter_button callback invoked")
end

if updates_dialog.match_button and updates_dialog.match_button.callback then
    updates_dialog.match_button.callback()
    assert_true(match_called, "match_button callback invoked")
end

if updates_dialog.switch_button and updates_dialog.switch_button.callback then
    updates_dialog.switch_button.callback()
    assert_true(switch_called, "switch_button callback invoked")
end

assert_true(updates_dialog:onClose(), "onClose handled")

print("  ✓ PASS: StorifyUpdatesDialog widget instantiates and wires events properly")

print("\n--- 7. Testing packButtonsIntoRows: Toolbar Wrap + Overflow ---")
-- Regression for the on-device finding: 5 toolbar buttons in one
-- HorizontalGroup overflowed the real 1264px Kobo screen width, leaving two
-- buttons entirely off-screen and untappable. Deterministic fake "buttons"
-- (plain tables with getSize()) decouple this from the headless test stubs'
-- generic 800px-wide widget mock, which would mask real packing behavior.
local function fakeButton(w)
    return { getSize = function() return { w = w } end }
end

-- All fit on one row: nothing wraps, nothing overflows.
do
    local b1, b2, b3 = fakeButton(100), fakeButton(100), fakeButton(100)
    local row1, row2, overflow = Updates.UpdatesModel.packButtonsIntoRows({ b1, b2, b3 }, 400)
    assert_eq(#row1, 3, "all 3 narrow buttons fit on row 1")
    assert_eq(#row2, 0, "row 2 empty when everything fits on row 1")
    assert_eq(#overflow, 0, "nothing overflows when everything fits on row 1")
end

-- Wraps to a second row, nothing left over.
do
    local buttons = { fakeButton(300), fakeButton(300), fakeButton(300), fakeButton(300) }
    local row1, row2, overflow = Updates.UpdatesModel.packButtonsIntoRows(buttons, 700)
    assert_eq(#row1, 2, "row 1 takes as many 300px buttons as fit under 700px")
    assert_eq(#row2, 2, "remainder wraps to row 2")
    assert_eq(#overflow, 0, "still nothing overflows -- 2 rows was enough")
end

-- Doesn't fit in two rows: the excess must overflow, not render past the edge.
do
    local buttons = { fakeButton(300), fakeButton(300), fakeButton(300), fakeButton(300), fakeButton(300) }
    local row1, row2, overflow = Updates.UpdatesModel.packButtonsIntoRows(buttons, 700)
    assert_eq(#row1, 2, "row 1 fits 2 of the 300px buttons under 700px")
    assert_eq(#row2, 2, "row 2 fits another 2")
    assert_eq(#overflow, 1, "the 5th button overflows instead of rendering off-screen")
end

-- A single button wider than the row still gets placed (never stuck in an
-- infinite loop / dropped silently), per the `#row1 == 0 or ...` escape hatch.
do
    local row1, row2, overflow = Updates.UpdatesModel.packButtonsIntoRows({ fakeButton(9000) }, 400)
    assert_eq(#row1, 1, "an oversized single button is still placed on row 1")
    assert_eq(#overflow, 0, "an oversized single button is not sent to overflow")
end

print("  ✓ PASS: packButtonsIntoRows wraps to a second row and overflows only what still doesn't fit")

print("\n🎉 [storify_updates_model_test] ALL TESTS PASSED!")
