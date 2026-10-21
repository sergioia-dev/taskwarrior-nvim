--- Taskwarrior lists in a bottom split, everything else headless.
---
--- ```lua
--- require("taskwarrior").setup({ default_report = "next" })
--- ```
---
--- `:Task` opens the list split; `:Task <report|filter|id>` shows that instead;
--- any other invocation (`:Task add …`, `:Task 1 done`, …) runs headless and
--- reports through a notification. See `README.md` for the full surface.
local M = {}

local config = require("taskwarrior.config")
local dispatch = require("taskwarrior.dispatch")
local task = require("taskwarrior.task")
local window = require("taskwarrior.window")
local watch = require("taskwarrior.watch")

--- Configure the plugin. Unknown keys are ignored.
function M.setup(opts)
	config.setup(opts)
	dispatch.reset()
	return config.options
end

--- Active options.
function M.options()
	return config.options
end

--- Whether the list split is open.
function M.is_open()
	return window.is_open()
end

--- Close the list split.
function M.close()
	window.close()
end

--- Reports or filters that were typed on their own get `default_report`
--- prepended; a report name or `context` is used as is.
local function normalized(args, reports)
	if #args == 0 then
		return { config.options.default_report }
	end
	local first = args[1]
	if reports[first] or first == "context" then
		return args
	end
	local out = { config.options.default_report }
	vim.list_extend(out, args)
	return out
end

local function render_into(buf, nargs, view, notify_errors)
	watch.note_activity()
	if
		not task.render(nargs, {
			width = window.width(),
			notify_errors = notify_errors,
			on_done = function(result)
				-- The buffer may have been closed, or re-rendered for another
				-- view, while `task` was running.
				if not window.is_open() or window.buffer() ~= buf or window.view() ~= view then
					return
				end
				local text = task.text(result)
				if result.code == 0 or task.no_matches(result) then
					window.fill(buf, text)
					return
				end
				local existing = window.text(buf)
				if existing == nil or existing == "" then
					window.fill(buf, text)
				end
			end,
		})
	then
		-- The binary vanished between the check and the call.
		window.close()
	end
end

--- Show a report, filter or ID list in the split. The same view toggles it
--- closed; a different one re-renders in place.
function M.render(args, opts)
	opts = opts or {}
	local nargs = normalized(args, dispatch.reports())
	local view = table.concat(nargs, " ")

	if not opts.force and window.is_open() and window.view() == view then
		window.close()
		return
	end

	if not task.exists() then
		task.notify_missing()
		return
	end

	local buf = window.show(view, nargs)
	watch.start()
	render_into(buf, nargs, view, opts.notify_errors ~= false)
end

--- Re-run the current view. Background refreshes are silent on failure.
function M.refresh(opts)
	opts = opts or {}
	local buf = window.buffer()
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local nargs, view = window.args(), window.view()
	if not nargs or not view then
		return
	end
	if not task.exists() then
		task.notify_missing()
		return
	end
	render_into(buf, nargs, view, opts.notify_errors == true)
end

--- Run a command with no window; on success the open list reloads itself.
--- `opts.on_done(result)` runs after that, which is how `M.add_selection`
--- chains its commands one after the other.
function M.run(args, opts)
	opts = opts or {}
	-- `:Task 1,2,3 delete` runs as `task 1 2 3 delete`. Every run command
	-- funnels through here, so this is the one place the list is expanded.
	args = dispatch.expand_id_lists(args)
	if not task.exists() then
		task.notify_missing()
		return
	end
	task.run(args, {
		on_done = function(result)
			if result.code == 0 then
				watch.absorb()
				if window.is_open() then
					M.refresh({ silent = true })
				end
			end
			if opts.on_done then
				opts.on_done(result)
			end
		end,
	})
end

--- The non-empty selected lines, each split into the words of one `task add`
--- call. A selection is treated linewise: only the whole lines it touches are
--- used. Each line is tokenized like a typed `:Task add`, so attributes such
--- as `project:home` or `+work` apply; sent as a single argument they would
--- stay description text.
local function selected_lines(line1, line2)
	local first = math.min(line1, line2)
	local last = math.max(line1, line2)
	local lines = vim.api.nvim_buf_get_lines(0, first - 1, last, false)
	local out = {}
	for _, line in ipairs(lines) do
		local words = vim.split(vim.trim(line), "%s+", { trimempty = true })
		if #words > 0 then
			out[#out + 1] = words
		end
	end
	return out
end

--- Add every non-empty line of the current buffer's `line1`..`line2` as its
--- own task, e.g. after selecting lines and running `:'<,'>Task add`. The
--- commands run one after the other: Taskwarrior locks its data files, so two
--- writers at once would fail. A failed line does not stop the rest.
function M.add_selection(line1, line2)
	if not task.exists() then
		task.notify_missing()
		return
	end
	local lines = selected_lines(line1, line2)
	local function add_next(index)
		local words = lines[index]
		if not words then
			return
		end
		M.run(vim.list_extend({ "add" }, words), {
			on_done = function()
				add_next(index + 1)
			end,
		})
	end
	add_next(1)
end

--- Entry point for `:Task`: render, or run headless, or toggle.
function M.toggle(args)
	args = args or {}
	if dispatch.classify(args, dispatch.reports()) == "run" then
		return M.run(args)
	end
	return M.render(args, { notify_errors = true })
end

watch.set_refresh(function()
	M.refresh({ silent = true })
end)
window.state.on_reload = function()
	M.refresh({ silent = true })
end
window.state.on_close = function()
	watch.stop()
end

return M
