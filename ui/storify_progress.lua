-- ui/storify_progress.lua
-- E-ink optimized non-modal progress bar dialog with rate-limited repaint and cooperative event pumping.

local Blitbuffer = (pcall(require, "ffi/blitbuffer") and require("ffi/blitbuffer")) or {
    COLOR_WHITE = 0xFFFFFF,
    COLOR_BLACK = 0x000000,
}
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = (pcall(require, "ui/gesturerange") and require("ui/gesturerange")) or {}
local CenterContainer = (pcall(require, "ui/widget/container/centercontainer") and require("ui/widget/container/centercontainer")) or FrameContainer
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = (pcall(require, "ui/widget/progresswidget") and require("ui/widget/progresswidget")) or FrameContainer
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local time = (pcall(require, "ui/time") and require("ui/time")) or {
    now = function() return os.time() end,
    to_s = function(t) return t end,
}
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen or {
    getWidth = function() return 800 end,
    getHeight = function() return 1200 end,
    getSize = function() return Geom:new{ w = 800, h = 1200 } end,
    scaleBySize = function(s) return s end,
}

local StorifyProgress = InputContainer:extend{
    title = nil,
    cancel_callback = nil,
    redraw_interval = 1.5,
}

function StorifyProgress:init()
    self.align = "center"
    self.dimen = Screen.getSize and Screen:getSize() or Geom:new{ w = 800, h = 1200 }
    self._last_redraw = time.now()
    self._fraction = 0
    self._cancelled = false

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

    if Device.isTouchDevice and Device:isTouchDevice() and GestureRange.new then
        self.ges_events = self.ges_events or {}
        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = function() return self.frame and self.frame.dimen or Geom:new{} end,
            },
        }
    end

    local screen_w = Screen.getWidth and Screen:getWidth() or 800
    local width = math.floor(screen_w * 0.8)
    local is_touch = Device.isTouchDevice and Device:isTouchDevice()
    local pad = Size.padding and Size.padding.large or 16

    self.title_bar = TitleBar:new{
        width = width,
        align = "left",
        title = self.title or "",
        with_bottom_line = true,
        close_callback = is_touch and function()
            self:cancel()
        end or nil,
        show_parent = self,
    }

    local bar_h = Screen.scaleBySize and Screen:scaleBySize(18) or 18
    self.progress_bar = ProgressWidget:new{
        width = width - 2 * pad,
        height = bar_h,
        percentage = 0,
        fillcolor = Blitbuffer.COLOR_BLACK,
    }

    self.frame = FrameContainer:new{
        radius = Size.radius and Size.radius.window or 8,
        bordersize = Size.border and Size.border.window or 2,
        padding = pad,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            self.title_bar,
            VerticalSpan:new{ width = pad },
            self.progress_bar,
        },
    }

    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.frame,
    }
end

function StorifyProgress:show()
    UIManager:show(self, "ui")
    if UIManager.forceRePaint then
        UIManager:forceRePaint()
    end
end

function StorifyProgress:setFraction(fraction)
    fraction = tonumber(fraction) or 0
    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end
    self._fraction = fraction

    if self.progress_bar and self.progress_bar.setPercentage then
        self.progress_bar:setPercentage(fraction)
    end

    local now = time.now()
    local diff = time.to_s and time.to_s(now - self._last_redraw) or (now - self._last_redraw)
    if diff < self.redraw_interval then
        return false
    end
    self._last_redraw = now

    if UIManager.setDirty then
        UIManager:setDirty(self, "fast", self.progress_bar and self.progress_bar.dimen)
    end
    if UIManager.forceRePaint then
        UIManager:forceRePaint()
    end
    self:pump()
    return true
end

function StorifyProgress:pump()
    local co, is_main = coroutine.running()
    if not co or is_main then
        return
    end
    local resume = function() coroutine.resume(co, true) end
    if UIManager.scheduleIn then
        pcall(function()
            UIManager:scheduleIn(0.05, resume)
            coroutine.yield()
            if UIManager.unschedule then
                UIManager:unschedule(resume)
            end
        end)
    end
end

function StorifyProgress:setTitle(title)
    self.title = title
    if self.title_bar and self.title_bar.setTitle then
        self.title_bar:setTitle(title)
    end
    if UIManager.setDirty then
        UIManager:setDirty(self, "ui", self.frame and self.frame.dimen)
    end
    if UIManager.forceRePaint then
        UIManager:forceRePaint()
    end
end

function StorifyProgress:cancelled()
    return self._cancelled
end

function StorifyProgress:cancel()
    if self._cancelled then
        return
    end
    self._cancelled = true
    if self.cancel_callback then
        self.cancel_callback()
    end
    if self.title_bar and self.title_bar.setTitle then
        self.title_bar:setTitle(self.stopping_title or self.title or "")
    end
    if UIManager.setDirty then
        UIManager:setDirty(self, "ui", self.frame and self.frame.dimen)
    end
    if UIManager.forceRePaint then
        UIManager:forceRePaint()
    end
end

function StorifyProgress:onClose()
    self:cancel()
    return true
end

function StorifyProgress:onTapClose()
    return true
end

return StorifyProgress
