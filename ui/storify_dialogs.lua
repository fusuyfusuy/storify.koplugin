-- ui/storify_dialogs.lua
-- Modals, popups, and detail views for plugins, patches, mirrors, and confirmations.

local UIManager = require("ui/uimanager")
local function safeWidget(name)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" and type(mod.new) == "function" then
        return mod
    end
    return {
        new = function(self, args)
            local o = args or {}
            if o.buttons == nil then o.buttons = {} end
            return o
        end
    }
end

local ConfirmBox = safeWidget("ui/widget/confirmbox")
local InfoMessage = safeWidget("ui/widget/infomessage")
local InputDialog = safeWidget("ui/widget/inputdialog")
local ButtonDialog = safeWidget("ui/widget/buttondialog")
local _ = (pcall(require, "storify_gettext") and require("storify_gettext"))
    or (pcall(require, "l10n/storify_gettext") and require("l10n/storify_gettext")) or function(s) return s end
local Widgets = (pcall(require, "ui/storify_widgets") and require("ui/storify_widgets"))
    or (pcall(require, "storify_widgets") and require("storify_widgets")) or {}

local StorifyDialogs = {}

-- =========================================================================
-- 1. Plugin Details Dialog
-- =========================================================================

function StorifyDialogs.showPluginDetails(repo, opts)
    repo = repo or {}
    opts = opts or {}

    local title = repo.full_name or repo.name or _("Plugin Details")
    local lines = {}

    if repo.name then
        table.insert(lines, string.format(_("Name: %s"), repo.name))
    end
    if repo.owner then
        table.insert(lines, string.format(_("Author: %s"), repo.owner))
    end
    if repo.stars then
        table.insert(lines, string.format(_("Stars: %s"), Widgets.formatStars(repo.stars)))
    end
    if opts.installed_version then
        table.insert(lines, string.format(_("Installed Version: %s"), opts.installed_version))
    end
    if opts.latest_version or repo.latest_tag then
        table.insert(lines, string.format(_("Latest Version: %s"), opts.latest_version or repo.latest_tag))
    end
    if repo.homepage and repo.homepage ~= "" then
        table.insert(lines, string.format(_("Homepage: %s"), repo.homepage))
    end
    if repo.description and repo.description ~= "" then
        table.insert(lines, "")
        table.insert(lines, Widgets.softWrapLongTokens(repo.description, 50))
    end

    local dialog
    local other_buttons = {}

    -- Action buttons row
    local action_row = {}
    if opts.on_install then
        local label = opts.is_installed and _("Reinstall") or _("Install")
        if opts.has_update then
            label = _("Update")
        end
        table.insert(action_row, {
            text = label,
            is_enter_default = true,
            callback = function()
                UIManager:close(dialog)
                opts.on_install(repo)
            end,
        })
    end

    if opts.on_readme then
        table.insert(action_row, {
            text = _("View README"),
            callback = function()
                UIManager:close(dialog)
                opts.on_readme(repo)
            end,
        })
    end

    if opts.on_uninstall and opts.is_installed then
        table.insert(action_row, {
            text = _("Uninstall"),
            callback = function()
                UIManager:close(dialog)
                opts.on_uninstall(repo)
            end,
        })
    end

    if #action_row > 0 then
        table.insert(other_buttons, action_row)
    end

    dialog = ConfirmBox:new{
        text = title,
        cancel_text = _("Close"),
        no_ok_button = true,
        custom_content = Widgets.makeTextBox(table.concat(lines, "\n")),
        other_buttons_first = true,
        other_buttons = #other_buttons > 0 and other_buttons or nil,
        dismiss_callback = opts.on_close,
    }
    UIManager:show(dialog)
    return dialog
end

-- =========================================================================
-- 2. Patch Details Dialog
-- =========================================================================

function StorifyDialogs.showPatchDetails(repo, patch, opts)
    repo = repo or {}
    patch = patch or {}
    opts = opts or {}

    local repo_title = repo.full_name or repo.name or _("Repository")
    local lines = {
        string.format(_("Patch: %s"), patch.filename or patch.name or _("Unknown")),
        string.format(_("Repository: %s"), repo_title),
    }

    if patch.path and patch.path ~= patch.filename then
        table.insert(lines, string.format(_("Path: %s"), patch.path))
    end
    if patch.branch then
        table.insert(lines, string.format(_("Branch: %s"), patch.branch))
    end
    if patch.size then
        table.insert(lines, string.format(_("Size: %d bytes"), patch.size))
    end
    if repo.description and repo.description ~= "" then
        table.insert(lines, "")
        table.insert(lines, Widgets.softWrapLongTokens(repo.description, 50))
    end

    local dialog
    local other_buttons = {}
    local action_row = {}

    if opts.is_matching then
        table.insert(action_row, {
            text = _("Match this remote patch"),
            is_enter_default = true,
            callback = function()
                UIManager:close(dialog)
                if opts.on_match then
                    opts.on_match(repo, patch)
                end
            end,
        })
    else
        if opts.on_install then
            local label = opts.is_installed and _("Update patch") or _("Install patch")
            table.insert(action_row, {
                text = label,
                is_enter_default = true,
                callback = function()
                    UIManager:close(dialog)
                    opts.on_install(repo, patch)
                end,
            })
        end
        if opts.on_uninstall and opts.is_installed then
            table.insert(action_row, {
                text = _("Delete patch"),
                callback = function()
                    UIManager:close(dialog)
                    opts.on_uninstall(repo, patch)
                end,
            })
        end
    end

    if opts.on_readme then
        table.insert(action_row, {
            text = _("View README"),
            callback = function()
                UIManager:close(dialog)
                opts.on_readme(repo)
            end,
        })
    end

    if #action_row > 0 then
        table.insert(other_buttons, action_row)
    end

    dialog = ConfirmBox:new{
        text = patch.filename or repo_title,
        cancel_text = _("Close"),
        no_ok_button = true,
        custom_content = Widgets.makeTextBox(table.concat(lines, "\n")),
        other_buttons_first = true,
        other_buttons = #other_buttons > 0 and other_buttons or nil,
        dismiss_callback = opts.on_close,
    }
    UIManager:show(dialog)
    return dialog
end

-- =========================================================================
-- 3. Mirror Configuration Selector
-- =========================================================================

function StorifyDialogs.showMirrorDialog(opts)
    opts = opts or {}
    local presets = opts.presets or {}
    local current_preset = opts.current_preset or "direct"

    local buttons = {}
    for _, preset in ipairs(presets) do
        local is_current = (preset.id == current_preset)
        local mark = is_current and "● " or "○ "
        table.insert(buttons, {
            {
                text = mark .. (preset.name or preset.id),
                callback = function()
                    if opts.on_select_preset then
                        opts.on_select_preset(preset.id)
                    end
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Custom mirror URL…"),
            callback = function()
                if opts.on_custom_url then
                    opts.on_custom_url()
                end
            end,
        },
    })

    local dialog = ButtonDialog:new{
        title = _("Download Mirror / Proxy"),
        buttons = buttons,
    }
    UIManager:show(dialog)
    return dialog
end

-- =========================================================================
-- 4. Custom URL Input Dialog
-- =========================================================================

function StorifyDialogs.showCustomUrlDialog(opts)
    opts = opts or {}
    local current_url = opts.current_url or ""

    local dialog
    dialog = InputDialog:new{
        title = _("Custom Mirror URL"),
        input = current_url,
        description = _("Enter GitHub download mirror prefix (e.g. https://ghfast.top/):"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                        if opts.on_cancel then opts.on_cancel() end
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local val = dialog:getInputText()
                        UIManager:close(dialog)
                        if opts.on_save then opts.on_save(val) end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return dialog
end

-- =========================================================================
-- 5. Confirmation Boxes
-- =========================================================================

function StorifyDialogs.showInfoMessage(text)
    local uim = UIManager or require("ui/uimanager")
    if InfoMessage and InfoMessage.new then
        uim:show(InfoMessage:new{ text = tostring(text), timeout = 4 })
    end
end

function StorifyDialogs.showRestartDialog(msg, opts)
    opts = opts or {}
    local prompt = msg or _("Restart KOReader to activate changes?")
    local dialog = ConfirmBox:new{
        text = prompt,
        ok_text = opts.confirm_text or _("Restart Now"),
        cancel_text = opts.cancel_text or _("Later"),
        ok_callback = function()
            if opts.on_confirm then
                opts.on_confirm()
            elseif opts.on_restart then
                opts.on_restart()
            else
                local UIManager = require("ui/uimanager")
                local Device = require("device")
                if Device and Device.restartKOReader then
                    Device:restartKOReader()
                else
                    UIManager:close()
                end
            end
        end,
        cancel_callback = opts.on_cancel or opts.on_later,
    }
    UIManager:show(dialog)
    return dialog
end

function StorifyDialogs.showDeleteConfirm(title, msg, on_confirm, on_cancel)
    local dialog = ConfirmBox:new{
        text = title or _("Confirm Delete"),
        custom_content = Widgets.makeTextBox(msg or _("Are you sure you want to delete this item?")),
        ok_text = _("Delete"),
        cancel_text = _("Cancel"),
        ok_callback = on_confirm,
        cancel_callback = on_cancel,
    }
    UIManager:show(dialog)
    return dialog
end

-- =========================================================================
-- 6. Commit Compare Dialog
-- =========================================================================

function StorifyDialogs.showCommitCompare(owner, repo, base_tag, head_tag, commits, opts)
    commits = commits or {}
    opts = opts or {}

    local lines = {
        string.format(_("Commit diff: %s → %s"), tostring(base_tag), tostring(head_tag)),
        string.format(_("Repository: %s/%s"), tostring(owner), tostring(repo)),
        string.format(_("Total commits: %d"), #commits),
        "",
    }

    for _, c in ipairs(commits) do
        local sha = (c.sha or ""):sub(1, 7)
        local msg = (c.commit and c.commit.message) or c.message or ""
        msg = msg:match("^[^\r\n]+") or msg
        table.insert(lines, string.format("• %s - %s", sha, msg))
    end

    local dialog = ConfirmBox:new{
        text = _("Commit Comparison"),
        cancel_text = _("Close"),
        no_ok_button = true,
        custom_content = Widgets.makeScrollableTextBox(table.concat(lines, "\n")),
        dismiss_callback = opts.on_close,
    }
    UIManager:show(dialog)
    return dialog
end

-- =========================================================================
-- 7. Manual Link Dialog
-- =========================================================================

function StorifyDialogs.showManualLinkDialog(item, cached_repos, opts)
    item = item or {}
    cached_repos = cached_repos or {}
    opts = opts or {}

    local plugin_name = item.name or item.id or _("Plugin")
    local buttons = {}

    local Matcher = (pcall(require, "core/storify_matcher") and require("core/storify_matcher"))
        or (pcall(require, "storify_matcher") and require("storify_matcher")) or nil

    local candidate_repos = {}
    if Matcher and Matcher.normalizeIdentifier then
        local plugin_slug = Matcher.normalizeIdentifier(item.name or item.id or item.dirname)
        for i, repo in ipairs(cached_repos) do
            local repo_slug = Matcher.normalizeIdentifier(repo.name or "")
            if plugin_slug ~= "" and (repo_slug == plugin_slug or repo_slug:find(plugin_slug, 1, true) or plugin_slug:find(repo_slug, 1, true)) then
                table.insert(candidate_repos, repo)
                if #candidate_repos >= 3 then break end
            end
        end
    end

    for i, repo in ipairs(candidate_repos) do
        local full_name = repo.full_name or string.format("%s/%s", repo.owner or "", repo.name or "")
        table.insert(buttons, {
            {
                text = string.format(_("Link to %s"), full_name),
                callback = function()
                    if opts.on_link then
                        opts.on_link(full_name, repo)
                    end
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Enter GitHub repo (owner/repo)…"),
            callback = function()
                local input_dialog
                input_dialog = InputDialog:new{
                    title = _("Link GitHub Repository"),
                    input = item.repo_full_name or "",
                    description = _("Enter GitHub repository (e.g. owner/repo):"),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(input_dialog)
                                    if opts.on_cancel then opts.on_cancel() end
                                end,
                            },
                            {
                                text = _("Link"),
                                is_enter_default = true,
                                callback = function()
                                    local val = input_dialog:getInputText()
                                    UIManager:close(input_dialog)
                                    if val and val ~= "" and opts.on_link then
                                        opts.on_link(val)
                                    end
                                end,
                            },
                        },
                    },
                }
                UIManager:show(input_dialog)
            end,
        },
    })

    if opts.on_delete then
        table.insert(buttons, {
            {
                text = _("Delete plugin files"),
                callback = function()
                    opts.on_delete(item)
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                if opts.on_cancel then opts.on_cancel() end
            end,
        },
    })

    local dialog = ButtonDialog:new{
        title = string.format(_("Link '%s' to GitHub"), plugin_name),
        buttons = buttons,
    }
    UIManager:show(dialog)
    return dialog
end

-- =========================================================================
-- 6. Patch File List (Browse Patches drill-down)
-- =========================================================================

-- Lists the individual .lua patch files inside one patch-collection repo.
-- Files are indexed lazily (see Crawler.fetchPatchFileTree) so this can be
-- called with an already-fetched list or, on first visit to a repo, an empty
-- one -- the caller is responsible for distinguishing "not fetched yet" from
-- "fetched, genuinely empty" and messaging accordingly before showing this.
function StorifyDialogs.showPatchFileList(title, files, opts)
    opts = opts or {}
    local buttons = {}
    for _, file in ipairs(files or {}) do
        table.insert(buttons, {
            {
                text = file.filename or file.path or _("Patch file"),
                callback = function()
                    if opts.on_select then opts.on_select(file) end
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                if opts.on_cancel then opts.on_cancel() end
            end,
        },
    })

    local dialog = ButtonDialog:new{
        title = title or _("Patch Files"),
        buttons = buttons,
    }
    UIManager:show(dialog)
    return dialog
end

return StorifyDialogs
