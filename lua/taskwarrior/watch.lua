--- Auto-reload: watch `$TASKDATA` (and the Taskchampion data files inside it)
--- and refresh the list when something else writes to the database — another
--- terminal, `task sync`, a cron job.
local M = {}

local config = require("taskwarrior.config")

--- Active `uv_fs_event_t` handles.
local watched = {}
--- Timestamp (ms) of the last render or command, used to ignore the fs events
--- our own `task` invocations cause.
local last_activity = 0
--- Everything before this timestamp is ignored after a mutating command.
local absorbed_until = 0
--- Refresh function supplied by the plugin entry point.
local refresh = nil
--- Bumped on every scheduled refresh so only the last one runs.
local generation = 0
--- `VimResized` autocmd id.
local resize_autocmd = nil

local function now_ms()
	if vim.uv and vim.uv.hrtime then
		return math.floor(vim.uv.hrtime() / 1e6)
	end
	return vim.fn.localtime() * 1000
end

--- Register the function that reloads the list.
function M.set_refresh(fn)
	refresh = fn
end

--- Record that the plugin just talked to `task`.
function M.note_activity()
	last_activity = now_ms()
end

--- Ignore filesystem events for the next 1.5 s (a write the plugin caused).
function M.absorb()
	absorbed_until = now_ms() + 1500
end

--- Directory holding the Taskwarrior data.
function M.data_dir()
	local dir = vim.env.TASKDATA
	if not dir or dir == "" then
		dir = (vim.env.HOME or "") .. "/.task"
	end
	return dir
end

local function stop_watching()
	for _, handle in ipairs(watched) do
		pcall(function()
			handle:stop()
		end)
		pcall(function()
			handle:close()
		end)
	end
	watched = {}
end

local function schedule_refresh()
	generation = generation + 1
	local mine = generation
	vim.defer_fn(function()
		if mine ~= generation or not refresh then
			return
		end
		refresh({ silent = true })
	end, config.options.refresh_debounce_ms or 200)
end

local function on_event()
	vim.schedule(function()
		if not config.options.watch then
			return
		end
		if now_ms() < absorbed_until then
			return
		end
		if now_ms() - last_activity < 500 then
			return
		end
		schedule_refresh()
	end)
end

local function watch_path(path)
	local uv = vim.uv
	local handle
	if not pcall(function()
		handle = uv.new_fs_event()
	end) or not handle then
		return
	end
	if not pcall(function()
		handle:start(path, {}, on_event)
	end) then
		pcall(function()
			handle:close()
		end)
		return
	end
	watched[#watched + 1] = handle
end

--- Start watching, if `watch` is enabled and `vim.uv` supports fs events.
--- Silently degrades: `r` and plugin-triggered refresh still work.
function M.start()
	if not config.options.watch or #watched > 0 then
		return
	end
	local uv = vim.uv
	if not uv or type(uv.new_fs_event) ~= "function" then
		return
	end
	local dir = M.data_dir()
	if vim.fn.isdirectory(dir) == 0 then
		return
	end
	-- The directory watch catches creation and atomic replacement…
	watch_path(dir)
	-- …the file watches catch in-place writes to the SQLite database.
	for _, name in ipairs({ "taskchampion.sqlite3", "taskchampion.data" }) do
		local path = dir .. "/" .. name
		if vim.fn.filereadable(path) == 1 then
			watch_path(path)
		end
	end
	for _, path in ipairs(vim.fn.glob(dir .. "/*.data", false, true)) do
		watch_path(path)
	end
	if not resize_autocmd then
		resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
			callback = function()
				-- The report width changed; a refresh re-wraps the columns.
				if refresh then
					schedule_refresh()
				end
			end,
		})
		vim.api.nvim_create_autocmd("VimLeavePre", {
			callback = function()
				M.stop()
			end,
		})
	end
end

--- Stop watching and cancel any pending refresh.
function M.stop()
	stop_watching()
	generation = generation + 1
	if resize_autocmd then
		pcall(vim.api.nvim_del_autocmd, resize_autocmd)
		resize_autocmd = nil
	end
end

return M
