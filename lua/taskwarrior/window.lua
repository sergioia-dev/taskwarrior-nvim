--- The list split and its buffer: geometry, buffer options, lifecycle and the
--- `q` / `r` mappings. Nothing here talks to `task`.
local M = {}

local config = require("taskwarrior.config")

--- Live state of the list split. `view` is the space-joined argument list that
--- produced the current content; `on_reload` / `on_close` are hooks set by the
--- plugin entry point.
M.state = {
	buf = nil,
	win = nil,
	view = nil,
	args = nil,
	on_reload = nil,
	on_close = nil,
	focus_au = nil,
}

--- Highlight used for the winbar label and rule. Catppuccin Mocha blue, with
--- a 256-colour fallback so the split still reads as "the task list" without
--- true colour support. Set once, and only when still undefined, so a
--- colourscheme or the user can override it.
local WINBAR_HL = "TaskwarriorWinbar"
local WINBAR_LABEL = " Taskwarrior " -- visible width 13, see `winbar_rule`.

local function ensure_winbar_hl()
	if vim.fn.hlexists(WINBAR_HL) == 1 then
		return
	end
	vim.api.nvim_set_hl(0, WINBAR_HL, { fg = "#89b4fa", ctermfg = 12, bold = true })
end

--- Blue rule that fills the winbar to the right edge. `%{}` re-evaluates it on
--- every redraw, so the line follows the window across resizes.
function M.winbar_rule()
	local win = tonumber(vim.g.statusline_winid) or 0
	if win == 0 or not vim.api.nvim_win_is_valid(win) then
		win = vim.api.nvim_get_current_win()
	end
	return string.rep("─", math.max(0, vim.api.nvim_win_get_width(win) - #WINBAR_LABEL))
end

--- Winbar value for the list split: blue label plus the blue rule.
function M.winbar()
	return string.format("%%#%s#%s%%{%%v:lua.require'taskwarrior.window'.winbar_rule()%%}", WINBAR_HL, WINBAR_LABEL)
end

--- Buffer showing the list, or `nil`.
function M.buffer()
	return M.state.buf
end

--- Window showing the list, or `nil`.
function M.window()
	return M.state.win
end

--- Argument list that produced the current content, or `nil`.
function M.args()
	return M.state.args
end

--- View key (space-joined arguments) of the current content, or `nil`.
function M.view()
	return M.state.view
end

--- Whether the list split is currently displayed.
function M.is_open()
	local buf, win = M.state.buf, M.state.win
	return buf ~= nil
		and vim.api.nvim_buf_is_valid(buf)
		and win ~= nil
		and vim.api.nvim_win_is_valid(win)
end

--- Height of the split in rows, from `size` (number of rows or `"NN%"`) or
--- `height_ratio`, clamped so at least three rows of editor remain visible.
function M.height()
	local total = math.max(3, vim.o.lines)
	local rows
	local size = config.options.size
	if type(size) == "number" then
		rows = size
	elseif type(size) == "string" then
		local pct = tonumber(size:match("^(%d+%.?%d*)%%$"))
		if pct then
			rows = total * pct / 100
		end
	end
	if not rows then
		rows = total * (tonumber(config.options.height_ratio) or 0.5)
	end
	return math.max(3, math.min(total - 3, math.floor(rows)))
end

--- Width available for the report: the split's width when it is open, the
--- editor's width otherwise.
function M.width()
	local win = M.state.win
	local cols = vim.o.columns
	if win and vim.api.nvim_win_is_valid(win) then
		cols = vim.api.nvim_win_get_width(win)
	end
	return math.max(20, cols - 1)
end

--- A window the split may be created from: the current one when it is a real
--- (non-floating, non-terminal, non-taskwarrior) window, otherwise the first
--- such window.
local function principal_window()
	local current = vim.api.nvim_get_current_win()
	local function usable(win)
		if not vim.api.nvim_win_is_valid(win) then
			return false
		end
		if vim.api.nvim_win_get_config(win).relative ~= "" then
			return false
		end
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.bo[buf].buftype == "terminal" then
			return false
		end
		return vim.bo[buf].filetype ~= "taskwarrior"
	end
	if usable(current) then
		return current
	end
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if usable(win) then
			return win
		end
	end
	return current
end

--- Reset the state and close the window. Called from the `BufWipeout` autocmd
--- so `:close`, `:bd` and `q` all end up in the same place.
local function forget(buf)
	if M.state.buf ~= buf then
		return
	end
	local win = M.state.win
	local hook = M.state.on_close
	M.state.buf, M.state.win, M.state.view, M.state.args = nil, nil, nil, nil
	if M.state.focus_au then
		pcall(vim.api.nvim_del_autocmd, M.state.focus_au)
		M.state.focus_au = nil
	end
	if hook then
		hook()
	end
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
end

--- Create the split and its buffer.
function M.create()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "taskwarrior"
	ensure_winbar_hl()

	vim.api.nvim_set_current_win(principal_window())
	vim.cmd("botright " .. M.height() .. "split")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.wo[win].winfixheight = true
	vim.wo[win].wrap = false
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].winbar = M.winbar()
	vim.wo[win].signcolumn = "no"
	vim.wo[win].cursorline = false
	vim.wo[win].foldenable = false

	-- Optional: give the window back as soon as focus moves elsewhere
	-- (`close_on_focus_lost`). The option is read at event time, so `setup()`
	-- can still switch the behaviour for an already open split.
	M.state.focus_au = vim.api.nvim_create_autocmd("WinLeave", {
		buffer = buf,
		callback = function()
			if not config.options.close_on_focus_lost then
				return
			end
			-- Leaving for the command line or a scheduled redraw fires this event
			-- as well, so only close once focus landed in another window.
			vim.schedule(function()
				if not M.is_open() or vim.fn.getcmdwintype() ~= "" then
					return
				end
				if vim.api.nvim_get_current_win() == win then
					return
				end
				M.close()
			end)
		end,
	})

	M.state.buf, M.state.win = buf, win

	vim.keymap.set("n", "q", function()
		M.close()
	end, { buffer = buf, nowait = true, silent = true, desc = "Close the task list" })
	vim.keymap.set("n", "r", function()
		if M.state.on_reload then
			M.state.on_reload()
		end
	end, { buffer = buf, nowait = true, silent = true, desc = "Reload the task list" })

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			forget(buf)
		end,
	})

	return buf, win
end

--- Show the list for `view` (the space-joined `args`), creating the split when
--- it does not exist yet and reusing it otherwise. Focuses the split.
function M.show(view, args)
	local buf, win = M.state.buf, M.state.win
	if not (buf and vim.api.nvim_buf_is_valid(buf)) or not (win and vim.api.nvim_win_is_valid(win)) then
		buf, win = M.create()
	end
	M.state.view, M.state.args = view, args
	-- `:Task bogus (report the user deleted)` may collide with a hidden buffer
	-- of the same name; a failed rename is harmless.
	pcall(vim.api.nvim_buf_set_name, buf, "taskwarrior://" .. (view ~= "" and view or "next"))
	vim.api.nvim_set_current_win(win)
	return buf, win
end

--- Close the split and wipe its buffer; the `BufWipeout` autocmd does the
--- state reset and stops the watcher.
function M.close()
	local win, buf = M.state.win, M.state.buf
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	if M.state.buf ~= nil then
		-- Defensive: the wipe autocmd did not fire (buffer not loaded).
		forget(M.state.buf)
	end
end

--- Replace the buffer content with `text`, leaving the buffer non-modifiable.
function M.fill(buf, text)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local lines = vim.split(text or "", "\n", { plain = true })
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end
	vim.bo[buf].modifiable = true
	local ok = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	if not ok then
		return
	end
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
		end
	end
end

--- Current buffer content as a single string, or `nil` when the buffer is gone.
function M.text(buf)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return nil
	end
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

return M
