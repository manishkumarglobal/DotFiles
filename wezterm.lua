local wezterm = require("wezterm")
local act = wezterm.action

local config = wezterm.config_builder()

--------------------------------------------------------------------------------
-- Appearance
--------------------------------------------------------------------------------
config.color_scheme = "Tokyo Night"
config.font = wezterm.font_with_fallback({
	"JetBrains Mono",
	"Menlo",
})
config.font_size = 13.0
config.line_height = 1.1

config.window_background_opacity = 0.98
config.macos_window_background_blur = 20
-- No separate macOS title bar: the tab bar is the top of the window.
-- INTEGRATED_BUTTONS keeps the native close / minimize / zoom buttons, drawn
-- over the left end of the tab bar (the retro tab bar reserves room for them).
config.window_decorations = "INTEGRATED_BUTTONS|RESIZE"
-- The retro tab bar is exactly one text row tall with no padding of its own,
-- so it sat flush against the window's top edge. A top border in the tab
-- bar's colour gives it breathing room and a taller band for the window
-- buttons, without changing the terminal's own line spacing.
-- TAB_BAR_BG is Tokyo Night's tab bar background. The border and the
-- inactive tabs (see format-tab-title) both use it, so the bar reads as one
-- surface, matching the strip reserved behind the window buttons.
local TAB_BAR_BG = "#191b28"
config.window_frame = {
	border_top_height = "8px",
	border_top_color = TAB_BAR_BG,
}
config.window_padding = {
	left = 8,
	right = 8,
	top = 8,
	bottom = 8,
}

-- Auto-resize the window when the available screen space changes (e.g., when
-- unplugging an external monitor). WezTerm adjusts the window to fit the new
-- screen dimensions rather than staying at the old fixed size.
config.adjust_window_size_when_changing_font_size = true

-- Set initial window dimensions to reasonable defaults that work on most
-- screens (will be overridden if you've explicitly sized the window before).
-- When a screen disconnects, WezTerm will respect the available space on the
-- remaining screen(s) rather than forcing the old size.
config.initial_cols = 220
config.initial_rows = 50

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------
config.enable_tab_bar = true
config.hide_tab_bar_if_only_one_tab = true
-- Retro (not fancy) tab bar, so tab names are not cut. The fancy bar gives
-- every tab the same fixed share of the window width (window width divided by
-- the number of tabs), whatever its title, and clips anything longer; with
-- many tabs open that cuts even short names. The retro bar sizes each tab to
-- its own title, so short names leave room for long ones, and only shrinks
-- tabs once their combined width no longer fits the window.
config.use_fancy_tab_bar = false
config.tab_bar_at_bottom = false
-- Upper bound on a single tab's width, in cells, so one very long title can't
-- crowd out the rest.
config.tab_max_width = 60

--------------------------------------------------------------------------------
-- Close confirmation (always ask, in every scenario)
--------------------------------------------------------------------------------
-- Goal: closing a tab, a pane, or a window ALWAYS shows a confirmation prompt,
-- whether or not a command is currently running. Closing a tab throws away its
-- scrollback, so an idle shell prompt is not "nothing to lose": it still holds
-- the output of everything that already ran there.
--
-- By default WezTerm treats a short list of processes (bash, sh, zsh, fish,
-- tmux, nu, and the Windows shells) as "stateless" and closes those without
-- asking. That is why a tab running a command asked for confirmation but a tab
-- sitting at the shell prompt vanished on a stray Cmd+W or a misclick on the
-- tab's X.
--
-- Three settings are needed, because each covers a different path:
--
--   1. skip_close_confirmation_for_processes_named = {}
--      Empties the "safe to close" list so no process is exempt.
--
--   2. the mux-is-process-stateful handler below
--      The authoritative override. It is consulted before the name list, so
--      returning true forces a prompt regardless of which process is running.
--      This is what makes the behavior unconditional rather than dependent on
--      matching process names.
--
--   3. window_close_confirmation = "AlwaysPrompt"
--      Closing the window takes every tab in it with it, so this is the most
--      destructive path of all. It was previously "NeverPrompt".
config.skip_close_confirmation_for_processes_named = {}
config.window_close_confirmation = "AlwaysPrompt"

-- Report every process as stateful so the close prompt is never skipped.
-- Returning nil here would fall back to the process-name list above.
wezterm.on("mux-is-process-stateful", function(_)
	return true
end)

--------------------------------------------------------------------------------
-- Behavior
--------------------------------------------------------------------------------
config.scrollback_lines = 10000
config.audible_bell = "Disabled"
config.default_cursor_style = "SteadyBar"
config.check_for_updates = false
config.automatically_reload_config = true

--------------------------------------------------------------------------------
-- Key bindings
--------------------------------------------------------------------------------
config.keys = {
	-- Tabs: switch left / right
	{ key = "LeftArrow", mods = "CMD", action = act.ActivateTabRelative(-1) },
	{ key = "RightArrow", mods = "CMD", action = act.ActivateTabRelative(1) },

	-- Tabs: move (reorder) current tab left / right
	{ key = "LeftArrow", mods = "CMD|SHIFT", action = act.MoveTabRelative(-1) },
	{ key = "RightArrow", mods = "CMD|SHIFT", action = act.MoveTabRelative(1) },

	-- Tabs: new (always opens in the home directory, not the current pane's cwd)
	{ key = "t", mods = "CMD", action = act.SpawnCommandInNewTab({ cwd = wezterm.home_dir }) },
	{ key = "w", mods = "CMD", action = act.CloseCurrentTab({ confirm = true }) },

	-- Tabs: rename the current tab (inline prompt at the bottom of the window)
	{
		key = "e",
		mods = "CMD|SHIFT",
		action = act.PromptInputLine({
			description = "Rename tab:",
			action = wezterm.action_callback(function(window, _, line)
				-- line is nil if the prompt was cancelled with Esc.
				if line ~= nil then
					window:active_tab():set_title(line)
				end
			end),
		}),
	},

	-- Panes: split horizontally / vertically
	{ key = "d", mods = "CMD", action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
	{ key = "d", mods = "CMD|SHIFT", action = act.SplitVertical({ domain = "CurrentPaneDomain" }) },

	-- Panes: navigate with Cmd+Alt+Arrow
	{ key = "LeftArrow", mods = "CMD|ALT", action = act.ActivatePaneDirection("Left") },
	{ key = "RightArrow", mods = "CMD|ALT", action = act.ActivatePaneDirection("Right") },
	{ key = "UpArrow", mods = "CMD|ALT", action = act.ActivatePaneDirection("Up") },
	{ key = "DownArrow", mods = "CMD|ALT", action = act.ActivatePaneDirection("Down") },

	-- Panes: close current pane
	{ key = "w", mods = "CMD|SHIFT", action = act.CloseCurrentPane({ confirm = true }) },

	-- Shell: word-wise cursor movement with Opt+Arrow.
	-- Sent as the Alt-b / Alt-f readline word motions, which shells, editors and
	-- terminal UIs already understand, rather than as an arrow escape sequence
	-- most of them ignore. ALT is WezTerm's name for the macOS Option key.
	-- Distinct from the Cmd+Alt+Arrow pane navigation above, which keeps CMD.
	{ key = "LeftArrow", mods = "ALT", action = act.SendKey({ key = "b", mods = "ALT" }) },
	{ key = "RightArrow", mods = "ALT", action = act.SendKey({ key = "f", mods = "ALT" }) },

	-- Font size
	{ key = "=", mods = "CMD", action = act.IncreaseFontSize },
	{ key = "-", mods = "CMD", action = act.DecreaseFontSize },
	{ key = "0", mods = "CMD", action = act.ResetFontSize },

	-- Clipboard
	-- Cmd+C: explicitly read the current selection and copy it to the clipboard.
	-- Does nothing when there is no selection (normal macOS Cmd+C behavior).
	{
		key = "c",
		mods = "CMD",
		action = wezterm.action_callback(function(window, pane)
			local sel = window:get_selection_text_for_pane(pane)
			if sel and sel ~= "" then
				window:copy_to_clipboard(sel, "Clipboard")
			end
		end),
	},
	{ key = "v", mods = "CMD", action = act.PasteFrom("Clipboard") },
}

--------------------------------------------------------------------------------
-- Mouse
--------------------------------------------------------------------------------
-- Don't auto-copy on select. The mouse-release does Nop (nothing), so no
-- selection is ever routed to a clipboard buffer. The drag still creates and
-- highlights the selection; nothing lands on the clipboard until you press
-- Cmd+C, which explicitly reads the highlighted selection (see the Cmd+C
-- binding above). Nop is used instead of CompleteSelection("PrimarySelection")
-- because on macOS the primary selection is aliased to the clipboard, so
-- completing into it was still auto-copying.
--
-- Because plain click no longer opens hyperlinks, Ctrl+click is bound for that.
config.mouse_bindings = {
	{
		event = { Up = { streak = 1, button = "Left" } },
		mods = "NONE",
		action = act.Nop,
	},
	-- Double / triple click select words / lines without copying either.
	{
		event = { Up = { streak = 2, button = "Left" } },
		mods = "NONE",
		action = act.Nop,
	},
	{
		event = { Up = { streak = 3, button = "Left" } },
		mods = "NONE",
		action = act.Nop,
	},
	-- Ctrl+click opens hyperlinks (plain click no longer does).
	{
		event = { Up = { streak = 1, button = "Left" } },
		mods = "CTRL",
		action = act.OpenLinkAtMouseCursor,
	},
}

-- Cmd+1 .. Cmd+9 to jump directly to a tab by index
for i = 1, 9 do
	table.insert(config.keys, {
		key = tostring(i),
		mods = "CMD",
		action = act.ActivateTab(i - 1),
	})
end

--------------------------------------------------------------------------------
-- Tab activity indicator (iTerm2-style running / done / idle dot)
--------------------------------------------------------------------------------
-- The terminal can only see a tab's foreground *process*. That works for plain
-- commands, but a long-lived TUI app (Claude Code, vim, a REPL) stays the
-- foreground process the whole session, so "process is running" is true from
-- launch to quit and never reflects whether the app is busy or waiting on you.
--
-- The one thing an app emits when it finishes a turn and wants attention is the
-- terminal bell. We hook the `bell` event to flip the tab to a green "done"
-- dot, and clear it again once you focus that tab.
--
-- Shells that count as "at the prompt" (idle). If the tab's foreground process
-- is one of these, nothing is running; anything else means a command is active.
local SHELLS = {
	["zsh"] = true,
	["bash"] = true,
	["fish"] = true,
	["sh"] = true,
	["-zsh"] = true,
	["-bash"] = true,
}

local RUNNING_DOT = "●" -- solid: a command / app is running in this tab
local DONE_DOT = "●" -- solid: rang the bell = finished, wants your attention
local IDLE_DOT = "○" -- hollow: sitting at the prompt (idle)

-- Colors tuned for the Tokyo Night scheme.
local RUNNING_COLOR = "#e0af68" -- amber while running
local DONE_COLOR = "#9ece6a" -- green: done / needs attention (bell fired)
local IDLE_COLOR = "#565f89" -- dim: idle

-- The retro tab bar is flat, and the scheme's active and inactive tab
-- backgrounds are nearly identical, so the formatter styles the active tab
-- itself: a solid blue block with bold white text, while inactive titles are
-- dimmed. The blue is deliberately mid-tone rather than Tokyo Night's bright
-- #7aa2f7, so the amber and green dots stay readable on it; the dim idle dot
-- would vanish on blue, so the active tab uses a light idle color instead.
local ACTIVE_TAB_BG = "#3d59a1"
local ACTIVE_TAB_FG = "#ffffff"
local ACTIVE_IDLE_COLOR = "#c0caf5"
local INACTIVE_TAB_FG = "#737aa2"
local INACTIVE_INDEX_FG = "#545c7e"
-- Hovering an inactive tab lifts it to Tokyo Night's highlight background with
-- brighter text: clearly reactive, but never blue or bold, so it can't be
-- mistaken for the active tab.
local HOVER_TAB_BG = "#292e42"
local HOVER_TAB_FG = "#c0caf5"
local HOVER_INDEX_FG = "#737aa2"

-- Panes that have rung the bell and not yet been looked at. Persisted in
-- wezterm.GLOBAL so it survives config reloads. Keyed by pane id (as string).
local function set_done(pane_id, value)
	local t = wezterm.GLOBAL.done_panes or {}
	t[tostring(pane_id)] = value or nil
	wezterm.GLOBAL.done_panes = t
end

local function is_done(pane_id)
	local t = wezterm.GLOBAL.done_panes or {}
	return t[tostring(pane_id)] == true
end

-- Bell fired in a pane -> mark it "done / needs attention".
wezterm.on("bell", function(_, pane)
	set_done(pane:pane_id(), true)
end)

-- The currently focused pane can't be "unseen" -> clear its done flag.
-- Background tabs are untouched, so their green dot persists until you switch
-- to them. Fires on focus changes and periodic status updates.
wezterm.on("update-status", function(_, pane)
	if pane then
		set_done(pane:pane_id(), false)
	end
end)

local function basename(path)
	if not path then
		return ""
	end
	return path:gsub("(.*[/\\])(.*)", "%2")
end

wezterm.on("format-tab-title", function(tab, tabs, panes, conf, hover, max_width)
	local pane = tab.active_pane
	local proc = basename(pane.foreground_process_name)

	local dot, dot_color
	if is_done(pane.pane_id) then
		-- Bell fired here and you haven't looked yet.
		dot, dot_color = DONE_DOT, DONE_COLOR
	elseif proc ~= "" and not SHELLS[proc] then
		dot, dot_color = RUNNING_DOT, RUNNING_COLOR
	else
		dot, dot_color = IDLE_DOT, IDLE_COLOR
	end

	-- Title: prefer the tab's own title, else the foreground process name.
	local title = tab.tab_title
	if not title or #title == 0 then
		title = proc ~= "" and proc or "shell"
	end

	-- Leave room for the tab index, the dot, its space, and the trailing space
	-- (the 3 below must match the dot + space + trailing space rendered after
	-- the prefix). Measure in display columns, not bytes, so non-ASCII titles
	-- are neither cut early nor split mid-character. The prefix is kept compact
	-- because every column of per-tab overhead is multiplied by the tab count.
	local prefix = string.format(" %d ", tab.tab_index + 1)
	local budget = max_width - wezterm.column_width(prefix) - 3
	if wezterm.column_width(title) > budget and budget > 1 then
		title = wezterm.truncate_right(title, budget - 1) .. "…"
	end

	if tab.is_active then
		if dot_color == IDLE_COLOR then
			dot_color = ACTIVE_IDLE_COLOR
		end
		return {
			{ Background = { Color = ACTIVE_TAB_BG } },
			{ Attribute = { Intensity = "Bold" } },
			{ Foreground = { Color = ACTIVE_TAB_FG } },
			{ Text = prefix },
			{ Foreground = { Color = dot_color } },
			{ Text = dot .. " " },
			{ Foreground = { Color = ACTIVE_TAB_FG } },
			{ Text = title .. " " },
		}
	end

	return {
		{ Background = { Color = hover and HOVER_TAB_BG or TAB_BAR_BG } },
		{ Foreground = { Color = hover and HOVER_INDEX_FG or INACTIVE_INDEX_FG } },
		{ Text = prefix },
		{ Foreground = { Color = dot_color } },
		{ Text = dot .. " " },
		{ Foreground = { Color = hover and HOVER_TAB_FG or INACTIVE_TAB_FG } },
		{ Text = title .. " " },
	}
end)

return config
