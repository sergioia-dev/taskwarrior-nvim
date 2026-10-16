--- Decide whether a `:Task` invocation renders the task list or runs a command
--- headless, and discover the report names Taskwarrior knows about.
---
--- Everything here is pure or side-effect-free apart from `discover()`, which
--- shells out to `task show` exactly once per session, so the whole module can
--- be unit tested without a real Taskwarrior database.
local M = {}

--- Reports shipped with Taskwarrior; the fallback when `task show` cannot be
--- read (binary missing, broken config, …).
M.BUILTIN_REPORTS = {
	"next",
	"all",
	"list",
	"ls",
	"long",
	"active",
	"blocked",
	"completed",
	"recurrent",
	"waiting",
	"unblocked",
	"ready",
	"overdue",
	"newest",
	"oldest",
	"calendar",
	"projects",
	"tags",
	"columns",
	"info",
	"summary",
	"minimal",
}

--- Verbs that change the database; running them in a list buffer would render
--- their output as a report. `context` is handled separately because it is both
--- a report (bare) and a mutating verb (with an argument).
M.MUTATING = {
	add = true,
	log = true,
	annotate = true,
	append = true,
	prepend = true,
	denotate = true,
	delete = true,
	done = true,
	duplicate = true,
	edit = true,
	modify = true,
	purge = true,
	start = true,
	stop = true,
	undo = true,
	sync = true,
	import = true,
}

--- Build a lookup set from a list of report names.
function M.report_set(names)
	local set = {}
	for _, name in ipairs(names) do
		set[name] = true
	end
	return set
end

--- Lookup set of the built-in reports.
function M.builtin_reports()
	return M.report_set(M.BUILTIN_REPORTS)
end

--- Classify an argument list as `"render"` or `"run"`.
---
--- `reports` is a set of known report names (see `reports()`).
function M.classify(args, reports)
	local first = args[1]
	if not first then
		return "render"
	end
	if reports[first] then
		return "render"
	end
	if first == "context" then
		-- `:Task context` shows the context report, `:Task context work` sets it.
		return #args == 1 and "render" or "run"
	end
	if M.MUTATING[first] then
		return "run"
	end
	for i = 2, #args do
		if M.MUTATING[args[i]] then
			return "run"
		end
	end
	-- Filters (`+work`, `project:x`), IDs and anything else render.
	return "render"
end

--- Report names mentioned by `task show` output, as `report.<name>.<key>` lines.
function M.parse_reports(output)
	local names, seen = {}, {}
	for line in (output or ""):gmatch("[^\n]+") do
		local name = line:match("^report%.([%w_%-]+)%.")
		if name and not seen[name] then
			seen[name] = true
			names[#names + 1] = name
		end
	end
	return names
end

local discovered = nil

--- Known report set: built-ins plus whatever `task show` reports, cached for
--- the session. Falls back to the built-ins when `task show` fails.
function M.discover(task_cmd)
	if discovered then
		return discovered
	end
	local set = M.builtin_reports()
	local ok, output = pcall(vim.fn.system, { task_cmd or "task", "show" })
	if ok then
		for _, name in ipairs(M.parse_reports(output)) do
			set[name] = true
		end
	end
	discovered = set
	return set
end

--- Alias of `discover()`.
function M.reports(task_cmd)
	return M.discover(task_cmd)
end

--- Sorted report names, for `:Task` completion.
function M.report_names(reports)
	local names = {}
	for name in pairs(reports) do
		names[#names + 1] = name
	end
	table.sort(names)
	return names
end

--- Forget the cached discovery (called by `setup()`).
function M.reset()
	discovered = nil
end

return M
