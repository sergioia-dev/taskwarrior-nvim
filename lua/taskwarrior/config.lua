--- Options for taskwarrior-nvim.
---
--- `setup()` merges the given table over `defaults`; only keys listed in
--- `known` are accepted, so typos are ignored rather than silently stored.
---
--- ```lua
--- require("taskwarrior").setup({
--- 	task_cmd = "task",
--- 	default_report = "next",
--- 	height_ratio = 0.5,
--- 	auto_yes = { "undo" },
--- })
--- ```
local M = {}

--- Default options.
M.defaults = {
	--- Executable name or absolute path of the `task` binary.
	task_cmd = "task",
	--- Report prepended when only filters or IDs are given.
	default_report = "next",
	--- Split height as a fraction of `vim.o.lines`.
	height_ratio = 0.5,
	--- Absolute rows, or `"NN%"`, overriding `height_ratio`. `nil` disables it.
	size = nil,
	--- Hard timeout, in milliseconds, for any `task` invocation.
	timeout_ms = 30000,
	--- Verbs that receive `"yes\n"` on stdin (everything else gets EOF).
	auto_yes = { "undo" },
	--- Enable the `$TASKDATA` auto-reload watcher.
	watch = true,
	--- Debounce, in milliseconds, for watcher and resize refreshes.
	refresh_debounce_ms = 200,
	--- Output lines included in a notification before truncation.
	notify_output_lines = 10,
	--- Close the split as soon as focus moves to another window.
	close_on_focus_lost = false,
}

--- Keys accepted by `setup()`.
M.known = {
	task_cmd = true,
	default_report = true,
	height_ratio = true,
	size = true,
	timeout_ms = true,
	auto_yes = true,
	watch = true,
	refresh_debounce_ms = true,
	notify_output_lines = true,
	close_on_focus_lost = true,
}

--- Active options (`defaults` merged with the last `setup()` call).
M.options = vim.deepcopy(M.defaults)

--- Merge user options over the defaults.
---
--- Unknown keys are ignored so a stale or mistyped option cannot break the
--- plugin. Returns the merged option table.
function M.setup(opts)
	if type(opts) ~= "table" then
		return M.options
	end
	for key, value in pairs(opts) do
		if M.known[key] then
			M.options[key] = value
		end
	end
	return M.options
end

return M
