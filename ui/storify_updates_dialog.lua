-- ui/storify_updates_dialog.lua
-- Full-screen updates management dialog and pure ViewModel logic.

local Device = require("device")
local UIManager = require("ui/uimanager")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local Blitbuffer = (pcall(require, "ffi/blitbuffer") and require("ffi/blitbuffer")) or {
    COLOR_WHITE = 0xFFFFFF,
    COLOR_BLACK = 0x000000,
    COLOR_LIGHT_GRAY = 0xCCCCCC,
}
local _ = (pcall(require, "storify_gettext") and require("storify_gettext"))
    or (pcall(require, "l10n/storify_gettext") and require("l10n/storify_gettext")) or function(s) return s end
local Widgets = (pcall(require, "ui/storify_widgets") and require("ui/storify_widgets"))
    or (pcall(require, "storify_widgets") and require("storify_widgets")) or {}
local Version = (pcall(require, "core/storify_version") and require("core/storify_version"))
    or (pcall(require, "storify_version") and require("storify_version")) or {}
local UpdatesListItem = Widgets.UpdatesListItem or {}

local UpdatesModel = {}

-- =========================================================================
-- Pure ViewModel Logic (Candidates, Batch Selection, Ignore Version, Summary)
-- =========================================================================

local function isRemoteVersionNewer(local_ver, remote_ver)
    if Version and Version.isVersionNewer then
        return Version.isVersionNewer(remote_ver, local_ver)
    end
    if not remote_ver or remote_ver == "" then return false end
    if not local_ver or local_ver == "" then return true end
    return local_ver ~= remote_ver
end

function UpdatesModel.prepareUpdateCandidates(installed_plugins, installed_patches, remote_metadata, ignored_versions)
    installed_plugins = installed_plugins or {}
    installed_patches = installed_patches or {}
    remote_metadata = remote_metadata or {}
    ignored_versions = ignored_versions or {}

    local repos_meta = remote_metadata.repos or {}
    local patches_meta = remote_metadata.patches or {}
    local candidates = {}

    -- 1. Installed Plugins
    for key, plugin in pairs(installed_plugins) do
        local id = plugin.id or plugin.name or key
        local repo_key = plugin.repo_full_name or (plugin.repo_owner and plugin.repo_name and (plugin.repo_owner .. "/" .. plugin.repo_name))
        local remote = repo_key and (repos_meta[repo_key] or repos_meta[plugin.repo_name or ""])

        local cand = {
            id = id,
            name = plugin.name or id,
            kind = "plugin",
            current_version = plugin.version,
            repo_owner = plugin.repo_owner,
            repo_name = plugin.repo_name,
            repo_full_name = repo_key,
            has_backup = plugin.has_backup,
            backup_version = plugin.backup_version,
            dirname = plugin.dirname,
            dir_path = plugin.dir_path,
            side_loaded = plugin.side_loaded,
            unlinked = plugin.unlinked,
        }

        if remote then
            local latest_ver = remote.latest_version or remote.latest_tag or remote.version
            cand.latest_version = latest_ver

            -- latest_ver is nil whenever the catalog has no version info for
            -- this repo (the common case -- awesome.koreader entries rarely
            -- carry one). Without the latest_ver truthiness check, `nil ==
            -- nil` made every such linked-but-unversioned plugin register as
            -- "ignored" instead of "up to date".
            local is_ignored = repo_key and latest_ver and latest_ver ~= ""
                and (ignored_versions[repo_key] == latest_ver)
            if is_ignored then
                cand.status = "ignored"
                cand.has_update = false
                cand.can_update = false
            elseif isRemoteVersionNewer(plugin.version, latest_ver) then
                cand.status = "update_available"
                cand.has_update = true
                cand.can_update = true
            else
                cand.status = "up_to_date"
                cand.has_update = false
                cand.can_update = false
            end
        else
            cand.status = "unlinked"
            cand.has_update = false
            cand.can_update = false
        end

        cand.selected_for_batch = cand.has_update
        table.insert(candidates, cand)
    end

    -- 2. Installed Patches
    for key, patch in pairs(installed_patches) do
        local id = patch.filename or patch.name or key
        local patch_key = (patch.owner and patch.repo and patch.path)
            and string.format("%s/%s:%s", patch.owner, patch.repo, patch.path)
            or id
        local remote = patches_meta[patch_key] or patches_meta[id]

        local cand = {
            id = id,
            name = patch.filename or id,
            kind = "patch",
            current_sha = patch.sha,
            owner = patch.owner,
            repo = patch.repo,
            path = patch.path,
        }

        if remote then
            cand.latest_sha = remote.sha
            cand.download_url = remote.download_url
            if remote.sha and patch.sha and remote.sha ~= patch.sha then
                cand.status = "update_available"
                cand.has_update = true
                cand.can_update = true
            else
                cand.status = "up_to_date"
                cand.has_update = false
                cand.can_update = false
            end
        else
            cand.status = "unlinked"
            cand.has_update = false
            cand.can_update = false
        end

        cand.selected_for_batch = cand.has_update
        table.insert(candidates, cand)
    end

    table.sort(candidates, function(a, b)
        if a.has_update ~= b.has_update then
            return a.has_update
        end
        return string.lower(a.name or "") < string.lower(b.name or "")
    end)

    return candidates
end

function UpdatesModel.initBatchSelection(candidates)
    candidates = candidates or {}
    for _, c in ipairs(candidates) do
        c.selected_for_batch = (c.has_update == true and c.status ~= "ignored")
    end
end

function UpdatesModel.toggleBatchSelection(candidates, id, state)
    candidates = candidates or {}
    for _, c in ipairs(candidates) do
        if c.id == id or c.name == id then
            if state ~= nil then
                c.selected_for_batch = state
            else
                c.selected_for_batch = not c.selected_for_batch
            end
            return c.selected_for_batch
        end
    end
    return false
end

function UpdatesModel.toggleSelectAll(candidates, select_all)
    candidates = candidates or {}
    for _, c in ipairs(candidates) do
        if c.has_update then
            c.selected_for_batch = (select_all == true)
        else
            c.selected_for_batch = false
        end
    end
end

function UpdatesModel.getSelectedBatchItems(candidates)
    candidates = candidates or {}
    local selected = {}
    for _, c in ipairs(candidates) do
        if c.selected_for_batch and c.has_update then
            table.insert(selected, c)
        end
    end
    return selected
end

function UpdatesModel.toggleIgnoreVersion(ignored_map, item_id, version)
    ignored_map = ignored_map or {}
    if not item_id or not version then return false end

    if ignored_map[item_id] == version then
        ignored_map[item_id] = nil
        return false
    else
        ignored_map[item_id] = version
        return true
    end
end

function UpdatesModel.isReleaseIgnored(ignored_map, item_id, version)
    if not ignored_map or not item_id or not version then return false end
    return ignored_map[item_id] == version
end

function UpdatesModel.calculateUpdateSummary(candidates)
    candidates = candidates or {}
    local summary = {
        total_tracked = #candidates,
        updates_count = 0,
        up_to_date_count = 0,
        unlinked_count = 0,
        ignored_count = 0,
    }

    for _, c in ipairs(candidates) do
        if c.status == "update_available" then
            summary.updates_count = summary.updates_count + 1
        elseif c.status == "up_to_date" then
            summary.up_to_date_count = summary.up_to_date_count + 1
        elseif c.status == "unlinked" then
            summary.unlinked_count = summary.unlinked_count + 1
        elseif c.status == "ignored" then
            summary.ignored_count = summary.ignored_count + 1
        end
    end

    return summary
end

function UpdatesModel.getRollbackInfo(installed_item)
    installed_item = installed_item or {}
    return {
        can_rollback = (installed_item.has_backup == true),
        rollback_version = installed_item.backup_version,
    }
end

-- Greedily wraps toolbar buttons across two rows by measured width, so the
-- toolbar never renders wider than the screen regardless of translation
-- length or device width (found via real on-device testing: a plain
-- single-row HorizontalGroup left the last two of five buttons entirely
-- off-screen and untappable on a 1264px-wide Kobo). Buttons that don't fit
-- in either row are returned as `overflow` for the caller to fold behind a
-- "More" button instead of silently rendering past the screen edge.
function UpdatesModel.packButtonsIntoRows(buttons, max_row_width)
    local row1, row2, overflow = {}, {}, {}
    local w1, w2 = 0, 0
    for _, btn in ipairs(buttons) do
        local w = (btn.getSize and btn:getSize().w) or 0
        if #row1 == 0 or w1 + w <= max_row_width then
            table.insert(row1, btn)
            w1 = w1 + w
        elseif #row2 == 0 or w2 + w <= max_row_width then
            table.insert(row2, btn)
            w2 = w2 + w
        else
            table.insert(overflow, btn)
        end
    end
    return row1, row2, overflow
end

-- =========================================================================
-- StorifyUpdatesDialog (FocusManager Full-Screen Updates Dialog)
-- =========================================================================

local StorifyUpdatesDialog = FocusManager:extend{
    title = "",
    items = nil,
    summary_text = nil,
    filter_label = nil,
    on_check_updates = nil,
    on_scan_request = nil,
    on_link_item = nil,
    on_toggle_filter = nil,
    on_match = nil,
    on_switch_target = nil,
    on_update_all = nil,
    on_close = nil,
}

function StorifyUpdatesDialog:init()
    self.show_parent = self
    local screen_w = Device.screen and Device.screen:getWidth() or 800
    local screen_h = Device.screen and Device.screen:getHeight() or 1200
    self.screen_w = screen_w
    self.screen_h = screen_h
    self.width = screen_w
    self.height = screen_h
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    local pad = Size.padding and Size.padding.default or 8
    local span_v = Size.span and Size.span.vertical_default or 8

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
    end

    self.title_bar = TitleBar:new{
        width = self.width,
        title = self.title or _("Storify · Updates"),
        fullscreen = false,
        with_bottom_line = true,
        close_callback = function()
            UIManager:close(self)
        end,
        show_parent = self,
    }

    self.check_button = Button:new{
        text = _("Check all updates"),
        menu_style = true,
        callback = function()
            if self.on_check_updates then
                self.on_check_updates()
            end
        end,
    }

    self.scan_button = Button:new{
        text = _("Scan disk"),
        menu_style = true,
        callback = function()
            if self.on_scan_request then
                self.on_scan_request()
            end
        end,
    }

    self.filter_button = Button:new{
        text = self.filter_label or _("Show needs update"),
        menu_style = true,
        callback = function()
            if self.on_toggle_filter then
                self.on_toggle_filter()
            end
        end,
    }

    self.match_button = Button:new{
        text = _("Match with repo"),
        menu_style = true,
        callback = function()
            if self.on_match then
                self.on_match()
            end
        end,
    }

    self.switch_button = Button:new{
        text = _("Switch to patches"),
        menu_style = true,
        callback = function()
            if self.on_switch_target then
                self.on_switch_target()
            end
        end,
    }

    local max_row_width = self.width - 2 * pad
    local row1, row2, overflow = UpdatesModel.packButtonsIntoRows({
        self.check_button,
        self.scan_button,
        self.filter_button,
        self.match_button,
        self.switch_button,
    }, max_row_width)

    if #overflow > 0 then
        self.more_button = Button:new{
            text = _("More") .. " ▾",
            menu_style = true,
            callback = function() self:_showOverflowActions() end,
        }
        local more_w = self.more_button:getSize().w
        local row2_w = 0
        for _, btn in ipairs(row2) do row2_w = row2_w + btn:getSize().w end
        while #row2 > 0 and row2_w + more_w > max_row_width do
            local evicted = table.remove(row2)
            table.insert(overflow, 1, evicted)
            row2_w = row2_w - evicted:getSize().w
        end
        table.insert(row2, self.more_button)
        self._overflow_buttons = overflow
    end

    self.controls = VerticalGroup:new{
        HorizontalGroup:new(row1),
        HorizontalGroup:new(row2),
    }

    self.summary_widget = TextWidget:new{
        text = self.summary_text or _("No plugins tracked yet."),
        face = Widgets.getListFace and Widgets.getListFace(),
        alignment = "left",
    }

    self.list_group = VerticalGroup:new{}
    self.list_container = FrameContainer:new{
        padding = pad,
        bordersize = 0,
        self.list_group,
    }

    local title_h = self.title_bar and self.title_bar.getHeight and self.title_bar:getHeight() or 40
    local controls_size = self.controls and self.controls.getSize and self.controls:getSize()
    local controls_h = controls_size and controls_size.h or 40
    local list_height = self.screen_h - title_h - controls_h - 3 * span_v
    if list_height < math.floor(self.screen_h * 0.4) then
        list_height = math.floor(self.screen_h * 0.4)
    end

    self.scroller = ScrollableContainer:new{
        dimen = Geom:new{ w = self.width, h = list_height },
        show_parent = self,
        self.list_container,
    }
    self.cropping_widget = self.scroller

    self.content = VerticalGroup:new{
        self.title_bar,
        self.controls,
        FrameContainer:new{ padding = pad, self.summary_widget },
        self.scroller,
    }

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        self.content,
    }

    self:setItems(self.items or {})

    if Device.hasDPad and Device:hasDPad() and self.layout and #self.layout > 0 and self.moveFocusTo then
        UIManager:nextTick(function()
            self:moveFocusTo(self.selected.x, self.selected.y, FocusManager.FOCUS_ONLY_ON_NT)
            self:_ensureFocusedVisible()
        end)
    end
end

function StorifyUpdatesDialog:setItems(items)
    self.items = items or {}
    if self.list_group.clear then
        self.list_group:clear()
    else
        for i = 1, #self.list_group do self.list_group[i] = nil end
    end

    self._focusable_items = {}
    self._focusable_row_offsets = {}
    local pad = Size.padding and Size.padding.default or 8
    local span_v = Size.span and Size.span.vertical_default or 8

    for idx, entry in ipairs(self.items) do
        if (entry.status == "unlinked" or entry.unlinked) and not entry.callback and self.on_link_item then
            entry.callback = function()
                if self.on_link_item then
                    self.on_link_item(entry)
                end
            end
        end
        local item = UpdatesListItem:new{
            entry = entry,
            width = self.width - 2 * pad,
            dialog = self,
            show_parent = self,
        }
        self.list_group[#self.list_group + 1] = item
        if item:isFocusable() then
            self._focusable_items[#self._focusable_items + 1] = item
        end
        if idx < #self.items then
            self.list_group[#self.list_group + 1] = VerticalSpan:new{ width = span_v }
        end
    end
    self:_rebuildLayout()
    if UIManager.setDirty then
        UIManager:setDirty(self)
    end
end

function StorifyUpdatesDialog:_rebuildLayout()
    self.layout = {}
    local pad = Size.padding and Size.padding.default or 8

    if self.title_bar and self.title_bar.generateHorizontalLayout then
        local title_rows = self.title_bar:generateHorizontalLayout()
        for _, row in ipairs(title_rows) do
            table.insert(self.layout, row)
        end
    end

    -- Only lay out toolbar buttons that are actually visible: anything
    -- packButtonsIntoRows() folded behind self.more_button isn't painted in
    -- self.controls any more, so it must be excluded here too or D-pad focus
    -- navigation would land on an invisible widget.
    local overflowing = {}
    for _, btn in ipairs(self._overflow_buttons or {}) do
        overflowing[btn] = true
    end
    local controls_row = {}
    for _, btn in ipairs({ self.check_button, self.scan_button, self.filter_button, self.match_button, self.switch_button }) do
        if btn and not overflowing[btn] then
            table.insert(controls_row, btn)
        end
    end
    if self.more_button then
        table.insert(controls_row, self.more_button)
    end
    if #controls_row > 0 then
        table.insert(self.layout, controls_row)
    end

    local first_list_row_index = #self.layout + 1
    for _, item in ipairs(self._focusable_items or {}) do
        table.insert(self.layout, { item })
    end

    do
        local cursor_y = pad
        for _, child in ipairs(self.list_group) do
            local size = child.getSize and child:getSize() or { h = 0 }
            local h = size.h or 0
            if child.isFocusable and child:isFocusable() then
                self._focusable_row_offsets[child] = { y = cursor_y, h = h }
            end
            cursor_y = cursor_y + h
        end
    end

    if not self.selected then
        self.selected = { x = 1, y = 1 }
    end
    if not (self.layout[self.selected.y] and self.layout[self.selected.y][self.selected.x]) then
        if #self._focusable_items > 0 then
            self.selected = { x = 1, y = first_list_row_index }
        elseif #self.layout > 0 then
            self.selected = { x = 1, y = 1 }
        end
    end
end

function StorifyUpdatesDialog:setSummary(text)
    if self.summary_widget and self.summary_widget.setText then
        self.summary_widget:setText(text or "")
        if UIManager.setDirty then
            UIManager:setDirty(self)
        end
    end
end

function StorifyUpdatesDialog:setFilterLabel(text)
    if self.filter_button and text and self.filter_button.setText then
        self.filter_button:setText(text)
        if UIManager.setDirty then
            UIManager:setDirty(self)
        end
    end
end

-- Lists any toolbar buttons packButtonsIntoRows() couldn't fit in two rows,
-- reusing each button's own text/callback so this stays correct regardless
-- of which buttons end up overflowing.
function StorifyUpdatesDialog:_showOverflowActions()
    if not self._overflow_buttons or #self._overflow_buttons == 0 then
        return
    end
    local rows = {}
    for _, btn in ipairs(self._overflow_buttons) do
        table.insert(rows, {
            {
                text = btn.text,
                callback = function()
                    UIManager:close(self._overflow_dialog)
                    if btn.callback then btn.callback() end
                end,
            },
        })
    end
    self._overflow_dialog = ButtonDialog:new{
        title = _("More actions"),
        buttons = rows,
    }
    UIManager:show(self._overflow_dialog)
end

function StorifyUpdatesDialog:onCloseWidget()
    if self.on_close then
        self.on_close()
    end
end

function StorifyUpdatesDialog:onClose()
    UIManager:close(self)
    return true
end

function StorifyUpdatesDialog:_ensureFocusedVisible()
    local focused = self.getFocusItem and self:getFocusItem()
    if not focused or not self.scroller then
        return
    end
    local offset = self._focusable_row_offsets and self._focusable_row_offsets[focused]
    if not offset then
        return
    end
    local scroller = self.scroller
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

function StorifyUpdatesDialog:onFocusMove(args)
    local handled = FocusManager.onFocusMove and FocusManager.onFocusMove(self, args)
    self:_ensureFocusedVisible()
    return handled
end

local Module = {
    Model = UpdatesModel,
    UpdatesModel = UpdatesModel,
    StorifyUpdatesDialog = StorifyUpdatesDialog,
    StorifyUpdatesDialog = StorifyUpdatesDialog,
}

setmetatable(Module, {
    __index = function(t, k)
        return UpdatesModel[k] or StorifyUpdatesDialog[k]
    end,
})

return Module
