-- Tests for the tab bar in wezterm.lua: the active tab keeps its whole title
-- when the bar is full, instead of WezTerm's equal share for every tab.
--
-- Run from anywhere:  luajit tests/wezterm_tab_bar_test.lua [path/to/wezterm.lua]
--
-- It loads the real config with a stand-in `wezterm` module, captures the
-- format-tab-title handler, and runs it through a copy of the layout steps of
-- WezTerm 20240203's retro tab bar (wezterm-gui/src/tabbar.rs, TabBarState::new):
-- a first pass at tab_max_width, the fit check, the equal-share clamp when the
-- titles do not fit, the second pass at each tab's own width, and the cells
-- reserved for the macOS window buttons and the new-tab button.
-- The stand-in measures text in code points, so titles here are ASCII.

local script_dir = (arg[0]:match("^(.*)/[^/]*$") or ".")
local config_path = arg[1] or (script_dir .. "/../wezterm.lua")

-- Stand-in wezterm module -----------------------------------------------------

local function utf8_len(s)
	local _, n = s:gsub("[^\128-\191]", "")
	return n
end

local function utf8_prefix(s, cols)
	local out, n = {}, 0
	for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if n >= cols then
			break
		end
		out[#out + 1] = ch
		n = n + 1
	end
	return table.concat(out)
end

local function load_handler(path)
	local handlers = {}
	local wezterm = {
		GLOBAL = {},
		home_dir = "/home/test",
		config_builder = function()
			return {}
		end,
		font_with_fallback = function(f)
			return f
		end,
		on = function(name, fn)
			handlers[name] = fn
		end,
		action_callback = function(fn)
			return fn
		end,
		column_width = utf8_len,
		truncate_right = utf8_prefix,
		action = setmetatable({}, {
			__index = function(_, name)
				return function(...)
					return { name, ... }
				end
			end,
		}),
	}
	package.loaded["wezterm"] = wezterm
	local config = dofile(path)
	package.loaded["wezterm"] = nil
	assert(handlers["format-tab-title"], "format-tab-title handler not registered")
	return handlers["format-tab-title"], config
end

-- Copy of WezTerm's retro tab bar layout -------------------------------------

local MACOS_BUTTON_CELLS = 10
local NEW_TAB_BUTTON_CELLS = 3
local HUGE = 2 ^ 31

local function render(items)
	local text = {}
	for _, item in ipairs(items) do
		if item.Text then
			text[#text + 1] = item.Text
		end
	end
	return table.concat(text)
end

-- title_width is the bar's width in cells (window width / cell width).
local function layout(handler, config, tabs, panes, title_width, hover_tab)
	local first = {}
	local titles_len = 0
	for i, tab in ipairs(tabs) do
		first[i] = utf8_len(render(handler(tab, tabs, panes, config, false, config.tab_max_width)))
		titles_len = titles_len + first[i]
	end
	local n = #tabs
	local available = math.max(0, title_width - ((n - 1) + NEW_TAB_BUTTON_CELLS))
	local tab_width_max = available >= titles_len and HUGE or math.floor(available / n)
	tab_width_max = math.min(tab_width_max, config.tab_max_width)

	local result = { clamped = tab_width_max < config.tab_max_width, texts = {}, widths = {} }
	local x = MACOS_BUTTON_CELLS
	for i, tab in ipairs(tabs) do
		local tab_title_len = math.min(first[i], tab_width_max)
		local hover = (i == hover_tab) and not tab.is_active
		local text = render(handler(tab, tabs, panes, config, hover, tab_title_len))
		if utf8_len(text) > tab_width_max then
			text = utf8_prefix(text, tab_width_max)
		end
		result.texts[i] = text
		result.widths[i] = utf8_len(text)
		x = x + result.widths[i]
	end
	result.end_x = x + NEW_TAB_BUTTON_CELLS
	return result
end

-- Fixtures --------------------------------------------------------------------

local function make_tabs(titles, active)
	local tabs = {}
	for i, title in ipairs(titles) do
		tabs[i] = {
			tab_id = 100 + i,
			tab_index = i - 1,
			is_active = (i == active),
			tab_title = title,
			active_pane = { pane_id = 200 + i, foreground_process_name = "/bin/zsh" },
		}
	end
	return tabs
end

-- One full-width pane, or two side by side, `cols` wide in total.
local function make_panes(cols, split)
	if split then
		local left = math.floor(cols / 2)
		return {
			{ left = 0, width = left - 1 },
			{ left = left, width = cols - left },
		}
	end
	return { { left = 0, width = cols } }
end

local function many_titles(n)
	local t = {}
	for i = 1, n do
		t[i] = string.format("project-%02d feature work and notes", i)
	end
	return t
end

-- Window padding adds about two cells to the bar beyond the terminal columns.
local PADDING_CELLS = 2

-- Tests -----------------------------------------------------------------------

local failures, checks = 0, 0
local function check(cond, msg)
	checks = checks + 1
	if not cond then
		failures = failures + 1
		print("FAIL: " .. msg)
	end
end

local handler, config = load_handler(config_path)
local function title_of(tab)
	return tab.tab_title
end

-- 1. Few tabs that fit: every tab is drawn in full, with the expected text.
do
	local tabs = make_tabs({ "api", "web", "notes" }, 2)
	local cols = 120
	local r = layout(handler, config, tabs, make_panes(cols), cols + PADDING_CELLS)
	check(not r.clamped, "fits: WezTerm should not clamp")
	check(r.texts[1] == " 1 ○ api ", "fits: inactive tab text, got '" .. r.texts[1] .. "'")
	check(r.texts[2] == " 2 ○ web ", "fits: active tab text, got '" .. r.texts[2] .. "'")
	check(r.texts[3] == " 3 ○ notes ", "fits: last tab text, got '" .. r.texts[3] .. "'")
end

-- 2. A full bar: the active tab keeps its whole title, nothing is clamped,
-- and the bar ends inside the window, across tab counts, window widths,
-- active positions, split panes and hover.
for _, cols in ipairs({ 100, 160, 220, 300 }) do
	for _, n in ipairs({ 6, 8, 12, 15, 20 }) do
		for _, active in ipairs({ 1, math.ceil(n / 2), n }) do
			for _, split in ipairs({ false, true }) do
				local tabs = make_tabs(many_titles(n), active)
				local panes = make_panes(cols, split)
				local title_width = cols + PADDING_CELLS
				local label = string.format("cols=%d tabs=%d active=%d split=%s", cols, n, active, tostring(split))

				-- Skip combinations where even index-and-dot per tab cannot fit;
				-- case 4 covers those.
				local min_total = 0
				for i = 1, n do
					min_total = min_total + #string.format(" %d ", i) + 3
				end
				local expected_full = " " .. active .. " ○ " .. title_of(tabs[active]) .. " "
				if min_total - (#string.format(" %d ", active) + 3) + #expected_full
					<= cols - NEW_TAB_BUTTON_CELLS - math.max(MACOS_BUTTON_CELLS, n - 1)
				then
					local natural_total = 0
					for i = 1, n do
						natural_total = natural_total
							+ math.min(#string.format(" %d ", i) + 3 + #title_of(tabs[i]), config.tab_max_width)
					end
					local full = natural_total > cols - NEW_TAB_BUTTON_CELLS - math.max(MACOS_BUTTON_CELLS, n - 1)

					local r = layout(handler, config, tabs, panes, title_width)
					check(not r.clamped, label .. ": WezTerm clamped the tabs")
					check(r.texts[active] == expected_full, label .. ": active tab cut, got '" .. r.texts[active] .. "'")
					check(r.end_x <= title_width, label .. ": bar overflows the window (" .. r.end_x .. " > " .. title_width .. ")")
					for i = 1, n do
						if i ~= active then
							check(r.widths[i] >= #string.format(" %d ", i) + 3, label .. ": tab " .. i .. " lost its index or dot")
							if full then
								check(r.widths[i] < r.widths[active], label .. ": inactive tab " .. i .. " not narrower than active")
							end
						end
					end
					local hovered = layout(handler, config, tabs, panes, title_width, active == 1 and 2 or 1)
					for i = 1, n do
						check(hovered.widths[i] == r.widths[i], label .. ": hover changed the width of tab " .. i)
					end
				end
			end
		end
	end
end

-- 3. Short inactive titles give their unused space to long ones, and the
-- even split never leaves one inactive title much shorter than another.
do
	local titles = { "a", "b", "long title number one here", "c", "another long inactive title", "active tab with a long descriptive name", "d", "e", "f", "g" }
	local tabs = make_tabs(titles, 6)

	-- Tight: fewer spare cells than inactive tabs. Short titles still whole.
	local cols = 120
	local r = layout(handler, config, tabs, make_panes(cols), cols + PADDING_CELLS)
	check(not r.clamped, "mixed tight: WezTerm clamped the tabs")
	check(r.texts[6] == " 6 ○ active tab with a long descriptive name ", "mixed tight: active tab cut, got '" .. r.texts[6] .. "'")
	for _, i in ipairs({ 1, 2, 4, 7, 8, 9, 10 }) do
		check(r.texts[i] == " " .. i .. " ○ " .. titles[i] .. " ", "mixed tight: short title " .. i .. " should be whole, got '" .. r.texts[i] .. "'")
	end
	check(r.end_x <= cols + PADDING_CELLS, "mixed tight: bar overflows the window")

	-- Roomier: the long inactive titles share what is left.
	cols = 150
	r = layout(handler, config, tabs, make_panes(cols), cols + PADDING_CELLS)
	check(not r.clamped, "mixed: WezTerm clamped the tabs")
	check(r.texts[6] == " 6 ○ active tab with a long descriptive name ", "mixed: active tab cut, got '" .. r.texts[6] .. "'")
	check(r.texts[1] == " 1 ○ a ", "mixed: short title should be kept whole, got '" .. r.texts[1] .. "'")
	local w3, w5 = r.widths[3], r.widths[5]
	check(math.abs(w3 - w5) <= 1, "mixed: long inactive titles should share evenly, got " .. w3 .. " and " .. w5)
	check(r.texts[3]:find("…", 1, true) ~= nil, "mixed: a cut title should end with an ellipsis, got '" .. r.texts[3] .. "'")
end

-- 4. Far too many tabs for index-and-dot: the handler steps aside and WezTerm's
-- equal share applies, without errors.
do
	local n = 40
	local tabs = make_tabs(many_titles(n), 5)
	local cols = 100
	local ok, r = pcall(layout, handler, config, tabs, make_panes(cols), cols + PADDING_CELLS)
	check(ok, "crowded: handler raised an error: " .. tostring(r))
	if ok then
		check(r.clamped, "crowded: expected WezTerm's equal share to apply")
	end
end

-- 5. No pane information: no allocation, plain behavior, no error.
do
	local tabs = make_tabs(many_titles(15), 3)
	local ok, r = pcall(layout, handler, config, tabs, {}, 120)
	check(ok, "no panes: handler raised an error: " .. tostring(r))
end

-- 6. A title longer than tab_max_width is capped at tab_max_width, with an
-- ellipsis, even when it is the active tab of a full bar.
do
	local titles = many_titles(12)
	titles[4] = string.rep("x", 100)
	local tabs = make_tabs(titles, 4)
	local cols = 220
	local r = layout(handler, config, tabs, make_panes(cols), cols + PADDING_CELLS)
	check(r.widths[4] == config.tab_max_width, "cap: active tab should be tab_max_width wide, got " .. r.widths[4])
	check(r.texts[4]:find("…", 1, true) ~= nil, "cap: capped title should end with an ellipsis")
end

-- 7. A cut that lands right after a space does not leave "word …".
do
	local titles = many_titles(16)
	for i = 1, 16 do
		titles[i] = "mac runner maintenance"
	end
	titles[6] = "dotfiles wezterm tabs"
	local tabs = make_tabs(titles, 6)
	local cols = 220
	local r = layout(handler, config, tabs, make_panes(cols), cols + PADDING_CELLS)
	for i = 1, 16 do
		check(r.texts[i]:find(" …", 1, true) == nil, "space before ellipsis in tab " .. i .. ": '" .. r.texts[i] .. "'")
	end
	check(r.widths[6] == #" 6 ○ dotfiles wezterm tabs " - 2, "space: active tab cut, got '" .. r.texts[6] .. "'")
end

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
