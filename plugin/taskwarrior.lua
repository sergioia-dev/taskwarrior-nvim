--- Registers `:Task` as soon as the runtimepath is set up; nothing has to be
--- required for the command to exist.
local M = {}

--- Completion candidates for the first argument: report names plus the verbs
--- that make `:Task` run headless.
local function candidates()
	local config = require("taskwarrior.config")
	local dispatch = require("taskwarrior.dispatch")

	local names = dispatch.report_names(dispatch.reports(config.options.task_cmd))
	local verbs = {}
	for verb in pairs(dispatch.MUTATING) do
		verbs[#verbs + 1] = verb
	end
	table.sort(verbs)
	vim.list_extend(names, { "context" })
	vim.list_extend(names, verbs)
	table.sort(names)
	return names
end

vim.api.nvim_create_user_command("Task", function(args)
	local argv = vim.split(vim.trim(args.args), "%s+", { trimempty = true })
	require("taskwarrior").toggle(argv)
end, {
	nargs = "*",
	desc = "Taskwarrior: render tasks in a split or run a task command",
	complete = function(arg_lead, cmd_line)
		local before = cmd_line:sub(1, #cmd_line - #arg_lead)
		local rest = before:gsub("^%s*%S+%s*", "", 1)
		if rest:match("%S") then
			return {}
		end
		local out = {}
		for _, name in ipairs(candidates()) do
			if vim.startswith(name, arg_lead) then
				out[#out + 1] = name
			end
		end
		return out
	end,
})

return M
