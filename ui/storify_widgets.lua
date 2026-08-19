-- ui/storify_widgets.lua
-- Reusable UI widgets, badges, rating stars, pagination, and D-pad focusable list items.

local Device = require("device")
local UIManager = require("ui/uimanager")
local Font = (pcall(require, "ui/font") and require("ui/font")) or {}
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = (pcall(require, "ui/gesturerange") and require("ui/gesturerange")) or {}
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = (pcall(require, "ui/widget/textboxwidget") and require("ui/widget/textboxwidget")) or TextWidget
local Button = require("ui/widget/button")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local LineWidget = (pcall(require, "ui/widget/linewidget") and require("ui/widget/linewidget")) or {}
local OverlapGroup = (pcall(require, "ui/widget/overlapgroup") and require("ui/widget/overlapgroup")) or {}
local RightContainer = (pcall(require, "ui/widget/container/rightcontainer") and require("ui/widget/container/rightcontainer")) or {}
local Blitbuffer = (pcall(require, "ffi/blitbuffer") and require("ffi/blitbuffer")) or {
    COLOR_WHITE = 0xFFFFFF,
    COLOR_BLACK = 0x000000,
    COLOR_LIGHT_GRAY = 0xCCCCCC,
    COLOR_DARK_GRAY = 0x555555,
}
local _ = (pcall(require, "storify_gettext") and require("storify_gettext"))
    or (pcall(require, "l10n/storify_gettext") and require("l10n/storify_gettext")) or function(s) return s end

local StorifyWidgets = {}

local function getListFace()
    local face
    if TextWidget.getDefaultFace then
        face = TextWidget:getDefaultFace()
    end
    if (not face) and Font and Font.getFace then
        face = Font:getFace("smallinfofont")
            or Font:getFace("infofont")
            or Font:getFace("x_smalltfont")
            or Font:getFace("ffont")
            or Font:getFace("infont")
    end
    return face
end

-- =========================================================================
-- 1. Status Badges
-- =========================================================================

local STATUS_LABELS = {
    installed = _("Installed"),
    update_available = _("Update Available"),
    up_to_date = _("Up to Date"),
    unlinked = _("Unlinked"),
    ignored = _("Ignored"),
}

function StorifyWidgets.formatStatusBadge(status, opts)
    opts = opts or {}
    local label = STATUS_LABELS[status] or tostring(status or "")
    if opts.raw then
        return label
    end
    if status == "installed" then
        return string.format("[✓ %s]", label)
    elseif status == "update_available" then
        return string.format("[▲ %s]", label)
    elseif status == "up_to_date" then
        return string.format("[%s]", label)
    elseif status == "unlinked" then
        return string.format("[? %s]", label)
    elseif status == "ignored" then
        return string.format("[⊘ %s]", label)
    end
    return string.format("[%s]", label)
end

function StorifyWidgets.createBadgeWidget(status, opts)
    opts = opts or {}
    local label = StorifyWidgets.formatStatusBadge(status, opts)
    local face = opts.face or getListFace()
    local fgcolor = Blitbuffer.COLOR_BLACK
    if status == "ignored" or status == "unlinked" then
        fgcolor = Blitbuffer.COLOR_DARK_GRAY
    end

    local text_w = TextWidget:new{
        text = label,
        face = face,
        fgcolor = fgcolor,
    }

    return FrameContainer:new{
        padding = Size.padding and Size.padding.small or 4,
        bordersize = Size.border and Size.border.thin or 1,
        radius = Size.radius and Size.radius.button or 4,
        background = Blitbuffer.COLOR_WHITE,
        text_w,
    }
end

-- =========================================================================
-- 2. Rating Stars
-- =========================================================================

function StorifyWidgets.formatStars(count)
    count = tonumber(count) or 0
    if count >= 10000 then
        return string.format("★ %.1fk", count / 1000)
    elseif count >= 1000 then
        return string.format("★ %.1fk", count / 1000)
    else
        return string.format("★ %d", count)
    end
end

function StorifyWidgets.createStarsWidget(count, opts)
    opts = opts or {}
    local text = StorifyWidgets.formatStars(count)
    local face = opts.face or getListFace()
    return TextWidget:new{
        text = text,
        face = face,
        fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK,
    }
end

-- =========================================================================
-- 3. Pagination Controls
-- =========================================================================

function StorifyWidgets.calculatePagination(total_items, page_size, current_page)
    total_items = tonumber(total_items) or 0
    page_size = math.max(1, tonumber(page_size) or 10)
    current_page = tonumber(current_page) or 1

    if total_items <= 0 then
        return {
            total_items = 0,
            page_size = page_size,
            total_pages = 1,
            current_page = 1,
            start_index = 0,
            end_index = 0,
            has_prev = false,
            has_next = false,
            has_first = false,
            has_last = false,
        }
    end

    local total_pages = math.max(1, math.ceil(total_items / page_size))
    if current_page < 1 then
        current_page = 1
    elseif current_page > total_pages then
        current_page = total_pages
    end

    local start_index = (current_page - 1) * page_size + 1
    local end_index = math.min(current_page * page_size, total_items)

    return {
        total_items = total_items,
        page_size = page_size,
        total_pages = total_pages,
        current_page = current_page,
        start_index = start_index,
        end_index = end_index,
        has_prev = current_page > 1,
        has_next = current_page < total_pages,
        has_first = current_page > 1,
        has_last = current_page < total_pages,
    }
end

function StorifyWidgets.createPaginationButtons(opts)
    opts = opts or {}
    local page = opts.page or 1
    local total_pages = opts.total_pages or 1

    local first_button = Button:new{
        text = "◀◀",
        menu_style = true,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        callback = opts.on_first_page,
    }
    if first_button.enableDisable then
        first_button:enableDisable(page > 1)
    end

    local prev_button = Button:new{
        text = "◀",
        menu_style = true,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        callback = opts.on_prev_page,
    }
    if prev_button.enableDisable then
        prev_button:enableDisable(page > 1)
    end

    local page_button = Button:new{
        text = string.format(_("Page %d / %d"), page, math.max(1, total_pages)),
        menu_style = true,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        callback = opts.on_goto_page,
    }

    local next_button = Button:new{
        text = "▶",
        menu_style = true,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        callback = opts.on_next_page,
    }
    if next_button.enableDisable then
        next_button:enableDisable(page < total_pages)
    end

    local last_button = Button:new{
        text = "▶▶",
        menu_style = true,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        callback = opts.on_last_page,
    }
    if last_button.enableDisable then
        last_button:enableDisable(page < total_pages)
    end

    return {
        first_button = first_button,
        prev_button = prev_button,
        page_button = page_button,
        next_button = next_button,
        last_button = last_button,
    }
end

-- =========================================================================
-- 4. Text and Layout Helpers
-- =========================================================================

function StorifyWidgets.softWrapLongTokens(text, max_len)
    max_len = tonumber(max_len) or 60
    if not text or text == "" then
        return ""
    end
    text = tostring(text)
    local res = text:gsub("(%S+)", function(token)
        if #token <= max_len then
            return token
        end
        if token:match("[\128-\255]") then
            return token
        end
        local parts = {}
        local i = 1
        while i <= #token do
            parts[#parts + 1] = token:sub(i, i + max_len - 1)
            i = i + max_len
        end
        return table.concat(parts, "\n")
    end)
    return res
end

function StorifyWidgets.makeTextBox(text, opts)
    opts = opts or {}
    local screen_w = Device.screen and Device.screen:getWidth() or 800
    local width = opts.width or math.floor(screen_w * 0.8)
    local face = opts.face or getListFace()
    return TextBoxWidget:new{
        text = text or "",
        width = width,
        face = face,
        fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK,
        alignment = opts.alignment or "left",
    }
end

function StorifyWidgets.makeScrollableTextBox(text, opts)
    opts = opts or {}
    local screen_w = Device.screen and Device.screen:getWidth() or 800
    local screen_h = Device.screen and Device.screen:getHeight() or 1200
    local width = opts.width or math.floor(screen_w * 0.9)
    local height = opts.height or math.floor(screen_h * 0.7)
    local face = opts.face or getListFace()

    local box = TextBoxWidget:new{
        text = text or "",
        width = width - 2 * (Size.padding and Size.padding.default or 8),
        face = face,
        fgcolor = opts.fgcolor or Blitbuffer.COLOR_BLACK,
    }
    local frame = FrameContainer:new{
        padding = Size.padding and Size.padding.default or 8,
        bordersize = 0,
        box,
    }
    return ScrollableContainer:new{
        dimen = Geom:new{ w = width, h = height },
        show_parent = opts.show_parent,
        frame,
    }
end

-- =========================================================================
-- 5. List Item Containers with D-Pad Focus Support
-- =========================================================================

local StorifyListItem = InputContainer:extend{
    entry = nil,
    width = nil,
    dialog = nil,
    show_parent = nil,
}

function StorifyListItem:init()
    local entry = self.entry or {}
    self.entry = entry
    local screen_w = Device.screen and Device.screen:getWidth() or 800
    local screen_h = Device.screen and Device.screen:getHeight() or 1200
    local content_width = self.width or math.floor(math.min(screen_w, screen_h) * 0.9)
    local text_color = (entry.dim or entry.select_enabled == false)
        and Blitbuffer.COLOR_DARK_GRAY
        or Blitbuffer.COLOR_BLACK

    local face = getListFace()
    local face_size = (face and face.size) or 16
    local line_height_px = math.floor(face_size * 1.4)
    local max_height = line_height_px * 3
    local pad = Size.padding and Size.padding.default or 8
    local content_inner = content_width - 2 * pad

    local check, mark_reserve
    if entry.installed and content_inner > 0 then
        local base_size = (face and (face.orig_size or face.size)) or 18
        local check_face = Font.getFace and Font:getFace("smallinfofont", base_size * 2) or face
        check = TextWidget:new{
            text = "✓",
            face = check_face,
            fgcolor = text_color,
        }
        local check_size = check and check.getSize and check:getSize()
        local check_w = check_size and check_size.w or 20
        mark_reserve = math.min(check_w + pad, math.floor(content_inner / 2))
    end

    local text_box = TextBoxWidget:new{
        text = entry.text or "",
        width = math.max(1, content_inner - (mark_reserve or 0)),
        face = face,
        fgcolor = text_color,
        alignment = "left",
        justified = false,
        height = max_height,
        height_overflow_show_ellipsis = true,
        height_adjust = true,
    }

    local row_widget = text_box
    if check and OverlapGroup.new and RightContainer.new then
        local row_size = text_box and text_box.getSize and text_box:getSize()
        local row_h = row_size and row_size.h or line_height_px
        row_widget = OverlapGroup:new{
            dimen = Geom:new{ w = content_inner, h = row_h },
            text_box,
            RightContainer:new{
                dimen = Geom:new{ w = content_inner, h = row_h },
                check,
            },
        }
    end

    local is_control = entry.callback and not entry.is_entry and entry.select_enabled ~= false
    self.frame = FrameContainer:new{
        padding = pad,
        bordersize = is_control and (Size.border and Size.border.button or 1) or 0,
        radius = is_control and (Size.radius and Size.radius.button or 4) or nil,
        row_widget,
    }
    self[1] = self.frame
    self.dimen = (self.frame and self.frame.getSize and self.frame:getSize())
        or Geom:new{ x = 0, y = 0, w = content_inner, h = line_height_px }

    if entry.callback or entry.hold_callback then
        local tap_range = function()
            return Geom:new{
                x = self.dimen.x,
                y = self.dimen.y,
                w = self.dimen.w,
                h = self.dimen.h,
            }
        end
        if GestureRange.new then
            self.ges_events = {
                StorifyTap = {
                    GestureRange:new{ ges = "tap", range = tap_range },
                },
            }
            if entry.hold_callback then
                self.ges_events.StorifyHold = {
                    GestureRange:new{ ges = "hold", range = tap_range },
                }
            end
        end
    end
end

function StorifyListItem:onStorifyTap()
    if self.dialog and self.dialog.onEntryActivated then
        self.dialog:onEntryActivated(self.entry)
    elseif self.entry and self.entry.callback then
        self.entry.callback()
    end
    return true
end

function StorifyListItem:onStorifyHold()
    if self.entry and self.entry.hold_callback then
        self.entry.hold_callback()
    end
    return true
end

function StorifyListItem:isFocusable()
    if not self.entry then
        return false
    end
    if self.entry.select_enabled == false then
        return false
    end
    return self.entry.callback ~= nil or self.entry.hold_callback ~= nil
end

function StorifyListItem:onFocus()
    if not self.frame then
        return true
    end
    self.frame.invert = true
    if UIManager.setDirty then
        UIManager:setDirty(self.show_parent or self, "fast")
    end
    return true
end

function StorifyListItem:onUnfocus()
    if not self.frame then
        return true
    end
    self.frame.invert = false
    if UIManager.setDirty then
        UIManager:setDirty(self.show_parent or self, "fast")
    end
    return true
end

function StorifyListItem:onTapSelect()
    return self:onStorifyTap()
end

function StorifyListItem:onHoldSelect()
    return self:onStorifyHold()
end

-- UpdatesListItem
local UpdatesListItem = InputContainer:extend{
    entry = nil,
    width = nil,
    dialog = nil,
    show_parent = nil,
}

function UpdatesListItem:init()
    local entry = self.entry or {}
    self.entry = entry
    local screen_w = Device.screen and Device.screen:getWidth() or 800
    local screen_h = Device.screen and Device.screen:getHeight() or 1200
    local content_width = self.width or math.floor(math.min(screen_w, screen_h) * 0.9)
    local pad = Size.padding and Size.padding.default or 8

    local text_args = {
        text = entry.text or "",
        alignment = "left",
        width = content_width - 2 * pad,
    }
    local face = getListFace()
    if face then
        text_args.face = face
    end
    local text_widget = TextWidget:new(text_args)
    local background = entry.dim and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE
    self.frame = FrameContainer:new{
        padding = pad,
        bordersize = 0,
        background = background,
        text_widget,
    }
    self[1] = self.frame
    self.dimen = (self.frame and self.frame.getSize and self.frame:getSize())
        or Geom:new{ x = 0, y = 0, w = content_inner, h = line_height_px }

    if entry.callback and GestureRange.new then
        local tap_range = function()
            return Geom:new{ x = self.dimen.x, y = self.dimen.y, w = self.dimen.w, h = self.dimen.h }
        end
        self.ges_events = {
            UpdatesTap = {
                GestureRange:new{ ges = "tap", range = tap_range },
            },
        }
    end
end

function UpdatesListItem:onUpdatesTap()
    if self.entry and self.entry.callback then
        self.entry.callback()
    end
    return true
end

function UpdatesListItem:isFocusable()
    return self.entry and self.entry.callback ~= nil
end

function UpdatesListItem:onFocus()
    if not self.frame then
        return true
    end
    self.frame.invert = true
    if UIManager.setDirty then
        UIManager:setDirty(self.show_parent or self, "fast")
    end
    return true
end

function UpdatesListItem:onUnfocus()
    if not self.frame then
        return true
    end
    self.frame.invert = false
    if UIManager.setDirty then
        UIManager:setDirty(self.show_parent or self, "fast")
    end
    return true
end

function UpdatesListItem:onTapSelect()
    return self:onUpdatesTap()
end

StorifyWidgets.StorifyListItem = StorifyListItem
StorifyWidgets.StorifyListItem = StorifyListItem
StorifyWidgets.UpdatesListItem = UpdatesListItem
StorifyWidgets.getListFace = getListFace

return StorifyWidgets
