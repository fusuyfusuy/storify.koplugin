-- tests/storify_browser_model_test.lua
-- Unit tests for StorifyBrowserDialog and its ViewModel logic

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

local Browser = require("storify_browser_dialog")
local BrowserModel = Browser.Model or Browser

-- =========================================================================
-- 1. Test Browser Filtering Logic
-- =========================================================================
print("\n--- 1. Testing Browser Filtering ---")

local sample_items = {
    { id = "plugin-1", name = "Cover Browser", kind = "plugin", is_plugin = true, description = "Book cover view for KOReader", owner = "koreader", stars = 150, pushed_at = "2026-05-01" },
    { id = "plugin-2", name = "Wallabag Plugin", kind = "plugin", is_plugin = true, description = "Read Wallabag articles", owner = "wallabag", stars = 80, pushed_at = "2026-06-10" },
    { id = "plugin-3", name = "Zotero Sync", kind = "plugin", is_plugin = true, description = "Sync with Zotero library", owner = "zotero", stars = 210, pushed_at = "2026-08-01" },
    { id = "patch-1", name = "20-invert-screen.lua", kind = "patch", is_patch = true, description = "Invert e-ink screen colors", owner = "patchdev", stars = 25, pushed_at = "2026-01-15" },
    { id = "patch-2", name = "30-custom-gestures.lua", kind = "patch", is_patch = true, description = "Custom multi-touch gestures", owner = "gestures", stars = 40, pushed_at = "2026-07-20" },
}

local installed_set = {
    ["plugin-1"] = true,
    ["patch-1"] = true,
}

-- Filter: All
local all_items = BrowserModel.filterItems(sample_items, "all")
assert_eq(#all_items, 5, "Filter 'all' should return 5 items")

-- Filter: Plugins
local plugins = BrowserModel.filterItems(sample_items, "plugins")
assert_eq(#plugins, 3, "Filter 'plugins' should return 3 items")
for _, item in ipairs(plugins) do
    assert_eq(item.kind, "plugin", "Filtered item kind should be plugin")
end

-- Filter: Patches
local patches = BrowserModel.filterItems(sample_items, "patches")
assert_eq(#patches, 2, "Filter 'patches' should return 2 items")
for _, item in ipairs(patches) do
    assert_eq(item.kind, "patch", "Filtered item kind should be patch")
end

-- Filter: Installed Plugins
local installed_plugins = BrowserModel.filterItems(sample_items, "installed_plugins", nil, installed_set)
assert_eq(#installed_plugins, 1, "Filter 'installed_plugins' should return 1 item")
assert_eq(installed_plugins[1].id, "plugin-1", "Installed plugin should be plugin-1")

-- Filter: Installed Patches
local installed_patches = BrowserModel.filterItems(sample_items, "installed_patches", nil, installed_set)
assert_eq(#installed_patches, 1, "Filter 'installed_patches' should return 1 item")
assert_eq(installed_patches[1].id, "patch-1", "Installed patch should be patch-1")

print("  ✓ PASS: Filtering by kind and installed status works as expected")

-- =========================================================================
-- 2. Test Search Query Filtering
-- =========================================================================
print("\n--- 2. Testing Search Query Filtering ---")

-- Search by name
local res_name = BrowserModel.filterItems(sample_items, "all", "zotero")
assert_eq(#res_name, 1, "Search 'zotero' should find 1 item")
assert_eq(res_name[1].id, "plugin-3", "Found item should be Zotero Sync")

-- Search by description
local res_desc = BrowserModel.filterItems(sample_items, "all", "articles")
assert_eq(#res_desc, 1, "Search 'articles' should find 1 item")
assert_eq(res_desc[1].id, "plugin-2", "Found item should be Wallabag Plugin")

-- Search by owner
local res_owner = BrowserModel.filterItems(sample_items, "all", "patchdev")
assert_eq(#res_owner, 1, "Search 'patchdev' should find 1 item")
assert_eq(res_owner[1].id, "patch-1", "Found item should be 20-invert-screen.lua")

-- Search case-insensitive
local res_case = BrowserModel.filterItems(sample_items, "all", "COVER")
assert_eq(#res_case, 1, "Search 'COVER' case-insensitive should find 1 item")
assert_eq(res_case[1].id, "plugin-1", "Found item should be Cover Browser")

-- Search with topics
local items_with_topics = {
    { id = "t-1", name = "Item 1", kind = "plugin", topics = { "reading", "tools" } },
    { id = "t-2", name = "Item 2", kind = "plugin", topics = "dictionary translation" },
}
local res_topics1 = BrowserModel.filterItems(items_with_topics, "all", "reading")
assert_eq(#res_topics1, 1, "Search topic array match should return 1 item")
local res_topics2 = BrowserModel.filterItems(items_with_topics, "all", "translation")
assert_eq(#res_topics2, 1, "Search topic string match should return 1 item")

-- Empty / Whitespace search
local res_empty = BrowserModel.filterItems(sample_items, "all", "   ")
assert_eq(#res_empty, 5, "Whitespace query should return all items")

-- No match
local res_nomatch = BrowserModel.filterItems(sample_items, "all", "nonexistentxyz")
assert_eq(#res_nomatch, 0, "Non-matching query should return 0 items")

print("  ✓ PASS: Search query filtering works across name, desc, owner, and topics")

-- =========================================================================
-- 3. Test Sort Ordering
-- =========================================================================
print("\n--- 3. Testing Sort Ordering ---")

-- Sort by stars descending
local sorted_stars = BrowserModel.sortItems(sample_items, "stars_desc")
assert_eq(sorted_stars[1].id, "plugin-3", "Highest stars first (210)")
assert_eq(sorted_stars[2].id, "plugin-1", "Second highest stars (150)")
assert_eq(sorted_stars[5].id, "patch-1", "Lowest stars last (25)")

-- Sort by name ascending
local sorted_name = BrowserModel.sortItems(sample_items, "name_asc")
assert_eq(sorted_name[1].name, "20-invert-screen.lua", "Alphabetical first")
assert_eq(sorted_name[2].name, "30-custom-gestures.lua", "Alphabetical second")
assert_eq(sorted_name[5].name, "Zotero Sync", "Alphabetical last")

-- Sort by updated_desc (pushed_at descending)
local sorted_updated = BrowserModel.sortItems(sample_items, "updated_desc")
assert_eq(sorted_updated[1].id, "plugin-3", "Most recently updated first (2026-08-01)")
assert_eq(sorted_updated[2].id, "patch-2", "Second most recently updated (2026-07-20)")
assert_eq(sorted_updated[5].id, "patch-1", "Oldest updated last (2026-01-15)")

-- Sort with nil fields
local items_with_nils = {
    { id = "n-1", name = "Alpha", stars = nil, pushed_at = nil },
    { id = "n-2", name = "Beta", stars = 50, pushed_at = "2026-01-01" },
}
local sorted_nil_stars = BrowserModel.sortItems(items_with_nils, "stars_desc")
assert_eq(sorted_nil_stars[1].id, "n-2", "Non-nil stars ranked higher than nil")

print("  ✓ PASS: Sort ordering works for stars_desc, name_asc, updated_desc")

-- =========================================================================
-- 4. Test Pagination Math & Slicing
-- =========================================================================
print("\n--- 4. Testing Pagination Calculations ---")

-- 0 items
local p0 = BrowserModel.calculatePagination(0, 10, 1)
assert_eq(p0.total_pages, 1, "0 items has 1 total page")
assert_eq(p0.current_page, 1, "0 items current page is 1")
assert_eq(p0.start_index, 0, "0 items start index is 0")
assert_eq(p0.end_index, 0, "0 items end index is 0")
assert_false(p0.has_prev, "0 items has_prev should be false")
assert_false(p0.has_next, "0 items has_next should be false")

-- 25 items with page_size 10
local p1 = BrowserModel.calculatePagination(25, 10, 1)
assert_eq(p1.total_pages, 3, "25 items page size 10 has 3 pages")
assert_eq(p1.current_page, 1, "Page 1 current_page")
assert_eq(p1.start_index, 1, "Page 1 start_index")
assert_eq(p1.end_index, 10, "Page 1 end_index")
assert_false(p1.has_prev, "Page 1 has_prev false")
assert_true(p1.has_next, "Page 1 has_next true")

local p2 = BrowserModel.calculatePagination(25, 10, 2)
assert_eq(p2.current_page, 2, "Page 2 current_page")
assert_eq(p2.start_index, 11, "Page 2 start_index")
assert_eq(p2.end_index, 20, "Page 2 end_index")
assert_true(p2.has_prev, "Page 2 has_prev true")
assert_true(p2.has_next, "Page 2 has_next true")

local p3 = BrowserModel.calculatePagination(25, 10, 3)
assert_eq(p3.current_page, 3, "Page 3 current_page")
assert_eq(p3.start_index, 21, "Page 3 start_index")
assert_eq(p3.end_index, 25, "Page 3 end_index")
assert_true(p3.has_prev, "Page 3 has_prev true")
assert_false(p3.has_next, "Page 3 has_next false")

-- Out of bounds page clamping
local p_clamp_high = BrowserModel.calculatePagination(25, 10, 99)
assert_eq(p_clamp_high.current_page, 3, "Page 99 clamped to 3")
local p_clamp_low = BrowserModel.calculatePagination(25, 10, -5)
assert_eq(p_clamp_low.current_page, 1, "Page -5 clamped to 1")

-- Slicing items
local sliced, pagination_info = BrowserModel.paginateItems(sample_items, 1, 2)
assert_eq(#sliced, 2, "Slice page 1 size 2 should have 2 items")
assert_eq(sliced[1].id, "plugin-1", "First item of page 1")
assert_eq(sliced[2].id, "plugin-2", "Second item of page 1")
assert_eq(pagination_info.total_pages, 3, "Sample 5 items page size 2 -> 3 pages")

print("  ✓ PASS: Pagination calculation, clamping, and slice ranges verified")

-- =========================================================================
-- 5. Test Focus Selection Transitions
-- =========================================================================
print("\n--- 5. Testing Focus Selection Transitions ---")

local focusable_items = {
    { entry = { is_entry = false, focus_id = "filter" } },
    { entry = { is_entry = false, focus_id = "sort" } },
    { entry = { is_entry = true, id = "plugin-1" } },
    { entry = { is_entry = true, id = "plugin-2" } },
}

local layout_indices = {
    first_list_row_index = 2,
    toolbar_row_index = 1,
    toolbar_ids = { { id = "switch" }, { id = "refresh" }, { id = "manage" } },
    footer_row_index = 6,
    footer_buttons = { { id = "first" }, { id = "prev" }, { id = "page" }, { id = "next" }, { id = "last" } },
}

-- Default focus (no initial_focus specified)
local sel_default = BrowserModel.resolveInitialFocus(nil, focusable_items, layout_indices)
assert_eq(sel_default.x, 1, "Default focus x is 1")
assert_eq(sel_default.y, 2, "Default focus y lands on first list row")

-- Focus target by id
local sel_id = BrowserModel.resolveInitialFocus({ id = "sort" }, focusable_items, layout_indices)
assert_eq(sel_id.x, 1, "Sort focus x is 1")
assert_eq(sel_id.y, 3, "Sort focus y lands on sort row (row 2 + offset 1)")

-- Focus first entry
local sel_first_entry = BrowserModel.resolveInitialFocus({ entry = "first" }, focusable_items, layout_indices)
assert_eq(sel_first_entry.x, 1, "First entry focus x is 1")
assert_eq(sel_first_entry.y, 4, "First entry focus y lands on plugin-1 (row 2 + index 2)")

-- Focus toolbar button
local sel_tb = BrowserModel.resolveInitialFocus({ toolbar = "refresh" }, focusable_items, layout_indices)
assert_eq(sel_tb.x, 2, "Refresh toolbar button is at column 2")
assert_eq(sel_tb.y, 1, "Toolbar row index is 1")

-- Focus footer next
local sel_footer = BrowserModel.resolveInitialFocus({ footer = "next", direction = "forward" }, focusable_items, layout_indices)
assert_eq(sel_footer.x, 4, "Footer next button is at column 4")
assert_eq(sel_footer.y, 6, "Footer row index is 6")

print("  ✓ PASS: Focus resolution handles entries, control ids, toolbars, and footers")

-- =========================================================================
-- 6. Test StorifyBrowserDialog Instantiation & Key Actions
-- =========================================================================
print("\n--- 6. Testing StorifyBrowserDialog Widget Instantiation ---")

local refresh_called = false
local filter_called = false
local sort_called = false
local switch_called = false
local next_page_called = false
local prev_page_called = false
local settings_called = false

local dialog = Browser.StorifyBrowserDialog:new{
    title = "Storify · Plugins",
    items = sample_items,
    page = 1,
    total_pages = 2,
    on_refresh = function() refresh_called = true end,
    on_filter = function() filter_called = true end,
    on_sort = function() sort_called = true end,
    on_switch_tab = function() switch_called = true end,
    on_next_page = function() next_page_called = true end,
    on_prev_page = function() prev_page_called = true end,
    on_settings_tap = function() settings_called = true end,
}

assert_true(dialog ~= nil, "Browser dialog instantiates")
assert_eq(dialog.title, "Storify · Plugins", "Dialog title matches")

-- Test action dispatchers
assert_true(dialog:onHotkeyRefresh(), "HotkeyRefresh handled")
assert_true(refresh_called, "on_refresh callback executed")

assert_true(dialog:onHotkeyFilter(), "HotkeyFilter handled")
assert_true(filter_called, "on_filter callback executed")

assert_true(dialog:onHotkeySort(), "HotkeySort handled")
assert_true(sort_called, "on_sort callback executed")

assert_true(dialog:onHotkeySwitchTab(), "HotkeySwitchTab handled")
assert_true(switch_called, "on_switch_tab callback executed")

assert_true(dialog:onNextPage(), "onNextPage handled")
assert_true(next_page_called, "on_next_page callback executed")

assert_true(dialog:onShowMenu(), "onShowMenu handled")
assert_true(settings_called, "on_settings_tap callback executed")

print("  ✓ PASS: StorifyBrowserDialog widget correctly routes actions and hotkeys")

-- =========================================================================
-- 7. Test StorifyWidgets
-- =========================================================================
print("\n--- 7. Testing StorifyWidgets ---")

local Widgets = require("storify_widgets")

-- Badge formatting
assert_eq(Widgets.formatStatusBadge("installed", { raw = true }), "Installed", "Raw installed badge")
assert_eq(Widgets.formatStatusBadge("installed"), "[✓ Installed]", "Formatted installed badge")
assert_eq(Widgets.formatStatusBadge("update_available"), "[▲ Update Available]", "Formatted update_available badge")
assert_eq(Widgets.formatStatusBadge("up_to_date"), "[Up to Date]", "Formatted up_to_date badge")
assert_eq(Widgets.formatStatusBadge("unlinked"), "[? Unlinked]", "Formatted unlinked badge")
assert_eq(Widgets.formatStatusBadge("ignored"), "[⊘ Ignored]", "Formatted ignored badge")

local badge_w = Widgets.createBadgeWidget("installed")
assert_true(badge_w ~= nil, "createBadgeWidget returned widget")

-- Star ratings
assert_eq(Widgets.formatStars(0), "★ 0", "Stars 0")
assert_eq(Widgets.formatStars(123), "★ 123", "Stars 123")
assert_eq(Widgets.formatStars(1500), "★ 1.5k", "Stars 1.5k")
assert_eq(Widgets.formatStars(12500), "★ 12.5k", "Stars 12.5k")

local stars_w = Widgets.createStarsWidget(123)
assert_true(stars_w ~= nil, "createStarsWidget returned widget")

-- Soft wrap
local wrapped = Widgets.softWrapLongTokens("https://example.com/very/long/url/that/should/be/broken/into/multiple/lines", 20)
assert_true(wrapped:find("\n") ~= nil, "Long token was soft-wrapped")

-- Text box widgets
local tb = Widgets.makeTextBox("Test Description")
assert_true(tb ~= nil, "makeTextBox returned widget")

local stb = Widgets.makeScrollableTextBox("Long scrollable description")
assert_true(stb ~= nil, "makeScrollableTextBox returned widget")

-- StorifyListItem focus / activation
local item_activated = false
local item_held = false
local list_item = Widgets.StorifyListItem:new{
    entry = {
        name = "Test Item",
        text = "Test Item Display",
        callback = function() item_activated = true end,
        hold_callback = function() item_held = true end,
    },
}
assert_true(list_item:isFocusable(), "Item with callback is focusable")
assert_true(list_item:onFocus(), "onFocus handled")
assert_true(list_item:onUnfocus(), "onUnfocus handled")
assert_true(list_item:onTapSelect(), "onTapSelect handled")
assert_true(item_activated, "Callback invoked on tap select")
assert_true(list_item:onHoldSelect(), "onHoldSelect handled")
assert_true(item_held, "Hold callback invoked on hold select")

print("  ✓ PASS: Badges, star ratings, text boxes, and StorifyListItem tested")

-- =========================================================================
-- 8. Test StorifyDialogs
-- =========================================================================
print("\n--- 8. Testing StorifyDialogs ---")

local Dialogs = require("storify_dialogs")

-- Plugin details
local install_clicked = false
local readme_clicked = false
local plugin_dlg = Dialogs.showPluginDetails(sample_items[1], {
    installed_version = "1.0.0",
    latest_version = "1.2.0",
    is_installed = true,
    has_update = true,
    on_install = function() install_clicked = true end,
    on_readme = function() readme_clicked = true end,
})
assert_true(plugin_dlg ~= nil, "showPluginDetails created dialog")

-- Patch details
local patch_installed = false
local patch_dlg = Dialogs.showPatchDetails(sample_items[4], { filename = "20-invert-screen.lua", path = "20-invert-screen.lua" }, {
    on_install = function() patch_installed = true end,
})
assert_true(patch_dlg ~= nil, "showPatchDetails created dialog")

-- Mirror dialog
local preset_chosen = nil
local custom_clicked = false
local mirror_dlg = Dialogs.showMirrorDialog{
    presets = { { id = "direct", name = "Direct (GitHub.com)" }, { id = "ghfast", name = "ghfast.top" } },
    current_preset = "direct",
    on_select_preset = function(id) preset_chosen = id end,
    on_custom_url = function() custom_clicked = true end,
}
assert_true(mirror_dlg ~= nil, "showMirrorDialog created dialog")

-- Custom URL dialog
local custom_url_saved = nil
local custom_url_dlg = Dialogs.showCustomUrlDialog{
    current_url = "https://mirror.example.com/",
    on_save = function(url) custom_url_saved = url end,
}
assert_true(custom_url_dlg ~= nil, "showCustomUrlDialog created dialog")

-- Restart dialog
local restarted = false
local restart_dlg = Dialogs.showRestartDialog("Plugin installed successfully.", {
    on_restart = function() restarted = true end,
})
assert_true(restart_dlg ~= nil, "showRestartDialog created dialog")

-- Delete confirm
local delete_confirmed = false
local delete_dlg = Dialogs.showDeleteConfirm("Delete Plugin", "Are you sure?", function() delete_confirmed = true end)
assert_true(delete_dlg ~= nil, "showDeleteConfirm created dialog")

-- Commit compare
local compare_dlg = Dialogs.showCommitCompare("koreader", "koreader", "v2026.01", "v2026.02", {
    { sha = "abc1234567", message = "Fix page flip rendering" },
    { sha = "def9876543", message = "Add e-ink refresh optimization" },
})
assert_true(compare_dlg ~= nil, "showCommitCompare created dialog")

print("  ✓ PASS: StorifyDialogs modals, prompts, and confirm boxes verified")

-- =========================================================================
-- 9. Test StorifyProgress
-- =========================================================================
print("\n--- 9. Testing StorifyProgress ---")

local Progress = require("storify_progress")
local cancel_fired = false

local prog = Progress:new{
    title = "Refreshing Catalog…",
    cancel_callback = function() cancel_fired = true end,
    redraw_interval = 0, -- instant for testing
}
assert_true(prog ~= nil, "StorifyProgress instantiates")
prog:show()
assert_true(prog:setFraction(0.5), "setFraction(0.5)")
assert_eq(prog._fraction, 0.5, "Fraction stored")

prog:setTitle("Fetching Repositories…")
assert_eq(prog.title, "Fetching Repositories…", "Title updated")

assert_false(prog:cancelled(), "Initially not cancelled")
prog:cancel()
assert_true(prog:cancelled(), "Cancelled is true")
assert_true(cancel_fired, "Cancel callback executed")

print("  ✓ PASS: StorifyProgress e-ink progress dialog verified")

print("\n🎉 [storify_browser_model_test] ALL TESTS PASSED!")
