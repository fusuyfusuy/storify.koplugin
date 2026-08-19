-- ui/storify_browser_dialog.lua
-- Full-screen catalog browser dialog and pure ViewModel logic.

local Device = require("device")
local UIManager = require("ui/uimanager")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local Button = require("ui/widget/button")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local LineWidget = (pcall(require, "ui/widget/linewidget") and require("ui/widget/linewidget")) or {}
local SpinWidget = (pcall(require, "ui/widget/spinwidget") and require("ui/widget/spinwidget")) or {}
local Blitbuffer = (pcall(require, "ffi/blitbuffer") and require("ffi/blitbuffer")) or {
    COLOR_WHITE = 0xFFFFFF,
    COLOR_BLACK = 0x000000,
    COLOR_LIGHT_GRAY = 0xCCCCCC,
}
local _ = (pcall(require, "storify_gettext") and require("storify_gettext"))
    or (pcall(require, "l10n/storify_gettext") and require("l10n/storify_gettext")) or function(s) return s end
local Widgets = (pcall(require, "ui/storify_widgets") and require("ui/storify_widgets"))
    or (pcall(require, "storify_widgets") and require("storify_widgets")) or {}
local StorifyListItem = Widgets.StorifyListItem or {}

local BrowserModel = {}

-- =========================================================================
-- Pure ViewModel Logic (Filtering, Searching, Sorting, Pagination)
-- =========================================================================

local function matchQuery(item, query_words)
    if not query_words or #query_words == 0 then
        return true
    end

    local text_corpus = string.lower(table.concat({
        item.name or "",
        item.full_name or "",
        item.description or "",
        item.owner or item.author or "",
        type(item.topics) == "table" and table.concat(item.topics, " ") or (item.topics or ""),
    }, " "))

    for _, word in ipairs(query_words) do
        if not text_corpus:find(word, 1, true) then
            return false
        end
    end
    return true
end

function BrowserModel.filterItems(items, filter_mode, search_query, installed_set)
    items = items or {}
    filter_mode = filter_mode or "all"
    installed_set = installed_set or {}

    local query_words = {}
    if search_query and search_query ~= "" then
        for w in string.gmatch(string.lower(search_query), "%S+") do
            table.insert(query_words, w)
        end
    end

    local result = {}
    for _, item in ipairs(items) do
        local kind = item.kind or (item.is_patch and "patch" or "plugin")
        local is_installed = (item.installed == true) or (installed_set[item.id] == true) or (installed_set[item.name] == true)

        local kind_match = true
        if filter_mode == "plugins" or filter_mode == "all_plugins" then
            kind_match = (kind == "plugin")
        elseif filter_mode == "patches" or filter_mode == "user_patches" then
            kind_match = (kind == "patch")
        elseif filter_mode == "installed_plugins" then
            kind_match = (kind == "plugin") and is_installed
        elseif filter_mode == "installed_patches" then
            kind_match = (kind == "patch") and is_installed
        elseif filter_mode == "installed" then
            kind_match = is_installed
        end

        if kind_match and matchQuery(item, query_words) then
            table.insert(result, item)
        end
    end
    return result
end

function BrowserModel.sortItems(items, sort_mode)
    items = items or {}
    sort_mode = sort_mode or "stars_desc"

    local copy = {}
    for _, it in ipairs(items) do
        table.insert(copy, it)
    end

    if sort_mode == "stars_desc" then
        table.sort(copy, function(a, b)
            local sa = tonumber(a.stars) or 0
            local sb = tonumber(b.stars) or 0
            if sa ~= sb then
                return sa > sb
            end
            return string.lower(a.name or "") < string.lower(b.name or "")
        end)
    elseif sort_mode == "name_asc" then
        table.sort(copy, function(a, b)
            return string.lower(a.name or "") < string.lower(b.name or "")
        end)
    elseif sort_mode == "updated_desc" then
        table.sort(copy, function(a, b)
            local ua = tostring(a.pushed_at or a.updated_at or a.fetched_at or "")
            local ub = tostring(b.pushed_at or b.updated_at or b.fetched_at or "")
            if ua ~= ub then
                return ua > ub
            end
            return string.lower(a.name or "") < string.lower(b.name or "")
        end)
    end

    return copy
end

function BrowserModel.calculatePagination(total_items, page_size, current_page)
    return Widgets.calculatePagination(total_items, page_size, current_page)
end

function BrowserModel.paginateItems(items, page, page_size)
    items = items or {}
    local p_info = BrowserModel.calculatePagination(#items, page_size, page)
    local sliced = {}
    if p_info.start_index > 0 and p_info.end_index >= p_info.start_index then
        for i = p_info.start_index, p_info.end_index do
            table.insert(sliced, items[i])
        end
    end
    return sliced, p_info
end

function BrowserModel.resolveInitialFocus(initial_focus, focusable_items, layout_indices)
    focusable_items = focusable_items or {}
    layout_indices = layout_indices or {}
    local first_list_row_index = layout_indices.first_list_row_index or 1

    if initial_focus then
        if initial_focus.entry == "first" then
            for idx, item in ipairs(focusable_items) do
                local entry = item.entry or item
                if entry.is_entry then
                    return { x = 1, y = first_list_row_index + idx - 1 }
                end
            end
        elseif initial_focus.entry == "last" then
            for idx = #focusable_items, 1, -1 do
                local item = focusable_items[idx]
                local entry = item.entry or item
                if entry.is_entry then
                    return { x = 1, y = first_list_row_index + idx - 1 }
                end
            end
        elseif initial_focus.id then
            for idx, item in ipairs(focusable_items) do
                local entry = item.entry or item
                if entry.focus_id == initial_focus.id or entry.id == initial_focus.id then
                    return { x = 1, y = first_list_row_index + idx - 1 }
                end
            end
        elseif initial_focus.toolbar and layout_indices.toolbar_row_index and layout_indices.toolbar_ids then
            for col, b in ipairs(layout_indices.toolbar_ids) do
                if b.id == initial_focus.toolbar then
                    return { x = col, y = layout_indices.toolbar_row_index }
                end
            end
        elseif initial_focus.footer and layout_indices.footer_row_index and layout_indices.footer_buttons then
            local order = initial_focus.direction == "backward"
                and { initial_focus.footer, "prev", "first", "page" }
                or { initial_focus.footer, "next", "last", "page" }
            for _, btn_id in ipairs(order) do
                for col, b in ipairs(layout_indices.footer_buttons) do
                    if b.id == btn_id then
                        return { x = col, y = layout_indices.footer_row_index }
                    end
                end
            end
        end
    end

    if #focusable_items > 0 then
        return { x = 1, y = first_list_row_index }
    end
    return { x = 1, y = 1 }
end

-- =========================================================================
-- StorifyBrowserDialog (FocusManager Full-Screen Catalog UI)
-- =========================================================================

local StorifyBrowserDialog = FocusManager:extend{
    title = "",
    items = nil,
    width = nil,
    height = nil,
    page = 1,
    total_pages = 1,
    scroll_offset = nil,
    initial_focus = nil,
    toolbar_buttons = nil,
    on_settings_tap = nil,
    on_refresh = nil,
    on_filter = nil,
    on_sort = nil,
    on_switch_tab = nil,
    on_first_page = nil,
    on_prev_page = nil,
    on_goto_page = nil,
    on_next_page = nil,
    on_last_page = nil,
    on_dismiss = nil,
}

function StorifyBrowserDialog:init()
    self.show_parent = self
    local screen_w = Device.screen and Device.screen:getWidth() or 800
    local screen_h = Device.screen and Device.screen:getHeight() or 1200
    self.screen_w = screen_w
    self.screen_h = screen_h
    self.width = screen_w
    self.height = screen_h
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }

    if Device.hasKeys and Device:hasKeys() then
        local Input = Device.input or {}
        local group = Input.group or {}
        self.key_events = self.key_events or {}
        if group.Back then
            self.key_events.Close = { { group.Back } }
        end
        if Device.hasFewKeys and Device:hasFewKeys() then
            self.key_events.Close = { { "Left" } }
        end
        if group.PgFwd then
            self.key_events.NextPage = { { group.PgFwd } }
        end
        if group.PgBack then
            self.key_events.PrevPage = { { group.PgBack } }
        end
        self.key_events.ShowMenu = { { "Menu" } }
    end

    if Device.hasKeyboard and Device:hasKeyboard() then
        self.key_events = self.key_events or {}
        self.key_events.HotkeyRefresh = { { "R" } }
        self.key_events.HotkeyFilter = { { "F" } }
        self.key_events.HotkeySort = { { "S" } }
        self.key_events.HotkeySwitchTab = { { "T" } }
    end

    self.title_bar = TitleBar:new{
        width = self.width,
        title = self.title or _("Storify"),
        fullscreen = false,
        with_bottom_line = true,
        left_icon = "appbar.settings",
        left_icon_tap_callback = function()
            if self.on_settings_tap then
                self.on_settings_tap()
            end
        end,
        close_callback = function()
            UIManager:close(self)
        end,
        show_parent = self,
    }

    self._focusable_items = {}
    self._focusable_row_offsets = {}

    local list_group = VerticalGroup:new{}
    local entry_width = self:getListEntryWidth()
    local span_v = Size.span and Size.span.vertical_default or 8
    local pad = Size.padding and Size.padding.default or 8

    if self.items then
        for idx, entry in ipairs(self.items) do
            local item_widget = StorifyListItem:new{
                entry = entry,
                width = entry_width,
                dialog = self,
                show_parent = self,
            }
            list_group[#list_group + 1] = item_widget
            if item_widget:isFocusable() then
                self._focusable_items[#self._focusable_items + 1] = item_widget
            end
            if entry.separator and idx < #self.items and LineWidget.new then
                list_group[#list_group + 1] = LineWidget:new{
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                    dimen = Geom:new{ w = entry_width, h = Size.line and Size.line.thin or 1 },
                }
            else
                list_group[#list_group + 1] = VerticalSpan:new{ width = span_v }
            end
        end
    end

    self.list_container = FrameContainer:new{
        padding = pad,
        bordersize = 0,
        list_group,
    }
    self._list_group = list_group

    local pag_buttons = Widgets.createPaginationButtons{
        page = self.page,
        total_pages = self.total_pages,
        on_first_page = function() if self.on_first_page then self.on_first_page() end end,
        on_prev_page = function() if self.on_prev_page then self.on_prev_page() end end,
        on_goto_page = function()
            if self.total_pages <= 1 then return end
            if SpinWidget.new then
                UIManager:show(SpinWidget:new{
                    title_text = _("Go to page"),
                    value = self.page,
                    value_min = 1,
                    value_max = self.total_pages,
                    ok_text = _("Go"),
                    callback = function(spin)
                        if self.on_goto_page then
                            self.on_goto_page(spin.value)
                        end
                    end,
                })
            end
        end,
        on_next_page = function() if self.on_next_page then self.on_next_page() end end,
        on_last_page = function() if self.on_last_page then self.on_last_page() end end,
    }

    local first_button = pag_buttons.first_button
    local prev_button = pag_buttons.prev_button
    local page_button = pag_buttons.page_button
    local next_button = pag_buttons.next_button
    local last_button = pag_buttons.last_button

    local toolbar_height = 0
    if self.toolbar_buttons and #self.toolbar_buttons > 0 then
        local tb = HorizontalGroup:new{}
        self._toolbar_widgets = {}
        self._toolbar_ids = {}
        for i, spec in ipairs(self.toolbar_buttons) do
            if i > 1 then
                table.insert(tb, HorizontalSpan:new{ width = Size.span and Size.span.horizontal_default or 8 })
            end
            local btn = Button:new{
                text = spec.text,
                radius = Size.radius and Size.radius.button or 4,
                callback = spec.callback,
            }
            table.insert(tb, btn)
            self._toolbar_widgets[#self._toolbar_widgets + 1] = btn
            self._toolbar_ids[#self._toolbar_ids + 1] = { id = spec.id }
        end
        self.toolbar = tb
        local tb_size = tb and tb.getSize and tb:getSize()
        toolbar_height = (tb_size and tb_size.h or 30) + span_v
    end

    local span_h = Size.span and Size.span.horizontal_default or 8
    self.footer = HorizontalGroup:new{
        first_button,
        HorizontalSpan:new{ width = span_h },
        prev_button,
        HorizontalSpan:new{ width = span_h },
        page_button,
        HorizontalSpan:new{ width = span_h },
        next_button,
        HorizontalSpan:new{ width = span_h },
        last_button,
    }

    local title_height = self.title_bar and self.title_bar.getHeight and self.title_bar:getHeight() or 40
    local footer_size = self.footer and self.footer.getSize and self.footer:getSize()
    local footer_height = footer_size and footer_size.h or 36
    local body_height = self.screen_h - title_height - footer_height - toolbar_height - 3 * span_v
    if body_height < math.floor(self.screen_h * 0.4) then
        body_height = math.floor(self.screen_h * 0.4)
    end

    local scroller_ignore_events = self.total_pages > 1
        and { "key_pg_back", "key_pg_fwd" } or nil

    self.list_scroller = ScrollableContainer:new{
        dimen = Geom:new{ w = self.width, h = body_height },
        show_parent = self,
        ignore_events = scroller_ignore_events,
        self.list_container,
    }
    self.cropping_widget = self.list_scroller

    self.content = VerticalGroup:new{
        self.title_bar,
        VerticalSpan:new{ width = span_v },
    }
    if self.toolbar then
        table.insert(self.content, self.toolbar)
        table.insert(self.content, VerticalSpan:new{ width = span_v })
    end
    table.insert(self.content, self.list_scroller)
    table.insert(self.content, VerticalSpan:new{ width = span_v })
    table.insert(self.content, self.footer)

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        dimen = self.dimen,
        self.content,
    }

    self._first_button = first_button
    self._prev_button = prev_button
    self._page_button = page_button
    self._next_button = next_button
    self._last_button = last_button

    do
        local cursor_y = pad
        for _, child in ipairs(list_group) do
            local size = child.getSize and child:getSize() or { h = 0 }
            local h = size.h or 0
            if child.isFocusable and child:isFocusable() then
                self._focusable_row_offsets[child] = { y = cursor_y, h = h }
            end
            cursor_y = cursor_y + h
        end
    end

    self.layout = {}
    if self.title_bar and self.title_bar.generateHorizontalLayout then
        local title_rows = self.title_bar:generateHorizontalLayout()
        for _, row in ipairs(title_rows) do
            table.insert(self.layout, row)
        end
    end
    if self._toolbar_widgets and #self._toolbar_widgets > 0 then
        table.insert(self.layout, self._toolbar_widgets)
        self._toolbar_row_index = #self.layout
    end
    local first_list_row_index = #self.layout + 1
    self._first_list_row_index = first_list_row_index
    for _, item_widget in ipairs(self._focusable_items) do
        table.insert(self.layout, { item_widget })
    end
    local footer_row = {}
    local footer_ids = {}
    if self.page > 1 then
        table.insert(footer_row, first_button); table.insert(footer_ids, { id = "first" })
        table.insert(footer_row, prev_button); table.insert(footer_ids, { id = "prev" })
    end
    if self.total_pages > 1 then
        table.insert(footer_row, page_button); table.insert(footer_ids, { id = "page" })
    end
    if self.page < self.total_pages then
        table.insert(footer_row, next_button); table.insert(footer_ids, { id = "next" })
        table.insert(footer_row, last_button); table.insert(footer_ids, { id = "last" })
    end
    if #footer_row > 0 then
        table.insert(self.layout, footer_row)
        self._footer_row_index = #self.layout
        self._footer_buttons = footer_ids
    end

    self.selected = BrowserModel.resolveInitialFocus(self.initial_focus, self._focusable_items, {
        first_list_row_index = first_list_row_index,
        toolbar_row_index = self._toolbar_row_index,
        toolbar_ids = self._toolbar_ids,
        footer_row_index = self._footer_row_index,
        footer_buttons = self._footer_buttons,
    })

    if self.scroll_offset then
        self:setScrollOffset(self.scroll_offset)
    end

    if Device.hasDPad and Device:hasDPad() and #self.layout > 0 and self.moveFocusTo then
        UIManager:nextTick(function()
            self:moveFocusTo(self.selected.x, self.selected.y, FocusManager.FOCUS_ONLY_ON_NT)
            self:_ensureFocusedVisible()
        end)
    end
end

function StorifyBrowserDialog:getListEntryWidth()
    local pad = Size.padding and Size.padding.default or 8
    local sb_w = ScrollableContainer.scroll_bar_width or 10
    local width = self.width - 2 * pad - 3 * sb_w
    if width < 0 then
        width = self.width - 2 * pad
    end
    return math.max(width, 0)
end

function StorifyBrowserDialog:onEntryActivated(entry)
    if not entry or entry.select_enabled == false then
        return true
    end
    if entry.callback then
        entry.callback()
    end
    if not entry.keep_menu_open then
        UIManager:close(self)
    end
    return true
end

function StorifyBrowserDialog:onCloseWidget()
    if self.on_dismiss then
        self.on_dismiss(self:getScrollOffset())
    end
end

function StorifyBrowserDialog:onClose()
    UIManager:close(self)
    return true
end

function StorifyBrowserDialog:onNextPage()
    if self.page < self.total_pages and self.on_next_page then
        self.on_next_page()
    end
    return true
end

function StorifyBrowserDialog:onPrevPage()
    if self.page > 1 and self.on_prev_page then
        self.on_prev_page()
    end
    return true
end

function StorifyBrowserDialog:onShowMenu()
    if self.on_settings_tap then self.on_settings_tap() end
    return true
end

function StorifyBrowserDialog:onHotkeyRefresh()
    if self.on_refresh then self.on_refresh() end
    return true
end

function StorifyBrowserDialog:onHotkeyFilter()
    if self.on_filter then self.on_filter() end
    return true
end

function StorifyBrowserDialog:onHotkeySort()
    if self.on_sort then self.on_sort() end
    return true
end

function StorifyBrowserDialog:onHotkeySwitchTab()
    if self.on_switch_tab then self.on_switch_tab() end
    return true
end

function StorifyBrowserDialog:_ensureFocusedVisible()
    local focused = self.getFocusItem and self:getFocusItem()
    if not focused or not self.list_scroller then
        return
    end
    local offset = self._focusable_row_offsets and self._focusable_row_offsets[focused]
    if not offset then
        return
    end
    local scroller = self.list_scroller
    if not scroller._is_scrollable then
        return
    end
    local scroll_y = scroller._scroll_offset_y or 0
    local crop_h = scroller._crop_h or (scroller.dimen and scroller.dimen.h) or 0
    if crop_h <= 0 then
        return
    end
    local target_top = offset.y
    local target_bottom = offset.y + offset.h
    if target_top < scroll_y then
        scroller:_scrollBy(0, target_top - scroll_y)
    elseif target_bottom > scroll_y + crop_h then
        scroller:_scrollBy(0, target_bottom - (scroll_y + crop_h))
    end
end

function StorifyBrowserDialog:onFocusMove(args)
    local handled = FocusManager.onFocusMove and FocusManager.onFocusMove(self, args)
    self:_ensureFocusedVisible()
    return handled
end

function StorifyBrowserDialog:getScrollOffset()
    if self.list_scroller and self.list_scroller.getScrolledOffset then
        return self.list_scroller:getScrolledOffset()
    end
end

function StorifyBrowserDialog:setScrollOffset(offset)
    if offset and self.list_scroller and self.list_scroller.setScrolledOffset then
        self.list_scroller:setScrolledOffset(offset)
    end
end

function StorifyBrowserDialog:resetScroll()
    if self.list_scroller and self.list_scroller.setScrolledOffset then
        self.list_scroller:setScrolledOffset({ x = 0, y = 0 })
    end
end

local Module = {
    Model = BrowserModel,
    StorifyBrowserDialog = StorifyBrowserDialog,
    StorifyBrowserDialog = StorifyBrowserDialog,
}

-- Support direct index passthrough
setmetatable(Module, {
    __index = function(t, k)
        return BrowserModel[k] or StorifyBrowserDialog[k]
    end,
})

return Module
