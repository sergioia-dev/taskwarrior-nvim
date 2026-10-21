--- Unit spec for the pure part of the plugin: report discovery parsing and the
--- render/run classification. No Neovim window, no `task` invocation.
local dispatch = require("taskwarrior.dispatch")

local failures = 0
local checks = 0

local function check(label, cond, extra)
	checks = checks + 1
	if cond then
		io.write("ok   - " .. label .. "\n")
	else
		failures = failures + 1
		io.write("FAIL - " .. label .. (extra and (" :: " .. tostring(extra)) or "") .. "\n")
	end
end

local function eq(label, actual, expected)
	check(label, actual == expected, "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

-- Report names discovered from `task show` output.
local parsed = dispatch.report_set(dispatch.parse_reports([[
report.next.filter                 status:pending
report.all.filter
report.custom.columns              id,description
report.urgent.filter               urgency > 10
not a report line
]]))
check("parse_reports finds next", parsed.next == true)
check("parse_reports finds custom", parsed.custom == true)
check("parse_reports ignores noise", parsed["not a report line"] == nil)

local reports = dispatch.report_set({ "next", "all", "custom", "calendar" })
check("builtin reports are always available", dispatch.builtin_reports().list == true)

local cases = {
	{ args = {}, want = "render", why = "empty argv shows the default report" },
	{ args = { "next" }, want = "render", why = "a report name renders" },
	{ args = { "calendar" }, want = "render", why = "a builtin report renders" },
	{ args = { "+work" }, want = "render", why = "a lone filter renders" },
	{ args = { "all", "+work" }, want = "render", why = "a report plus a filter renders" },
	{ args = { "12" }, want = "render", why = "an ID renders as a filter" },
	{ args = { "context" }, want = "render", why = "a bare context renders" },
	{ args = { "context", "work" }, want = "run", why = "context with an argument acts" },
	{ args = { "1", "done" }, want = "run", why = "an ID plus a verb acts" },
	{ args = { "add", "x", "done" }, want = "run", why = "a leading verb acts" },
	{ args = { "sync" }, want = "run", why = "sync acts" },
	{ args = { "all", "modify", "project:home" }, want = "render", why = "a report name wins over a later verb" },
	{ args = { "12", "modify", "project:home" }, want = "run", why = "a verb after a filter acts" },
}
for _, case in ipairs(cases) do
	local got = dispatch.classify(case.args, reports)
	eq("classify " .. vim.inspect(case.args) .. " -> " .. case.want .. " (" .. case.why .. ")", got, case.want)
end

local names = dispatch.report_names(reports)
local sorted = vim.deepcopy(names)
table.sort(sorted)
check("report_names is sorted", vim.deepcopy(names) ~= nil and vim.deepcopy(names) ~= nil and #names > 0)
check("report_names order", vim.inspect(names) == vim.inspect(sorted))
--- `expand_id_lists` turns `1,2,3` into separate IDs and leaves everything else
--- alone, so `:Task 1,2,3 delete` can run as `task 1 2 3 delete`.
local expansions = {
	{ args = { "1,2,3", "delete" }, want = { "1", "2", "3", "delete" }, why = "a leading comma list splits" },
	{ args = { "delete", "1,2" }, want = { "delete", "1", "2" }, why = "a trailing comma list splits" },
	{ args = { "1,2", "modify", "project:home" }, want = { "1", "2", "modify", "project:home" }, why = "only the ID token changes" },
	{ args = { "1,,2", "done" }, want = { "1", "2", "done" }, why = "empty parts are dropped" },
	{ args = { "add", "1,2,3" }, want = { "add", "1,2,3" }, why = "an add description is free text" },
	{ args = { "log", "1,2,3" }, want = { "log", "1,2,3" }, why = "a log description is free text" },
	{ args = { "1-3", "delete" }, want = { "1-3", "delete" }, why = "a native range is left to taskwarrior" },
	{ args = { "1", "done" }, want = { "1", "done" }, why = "a single ID is unchanged" },
	{ args = { "a1b2c3d4-0000-4000-8000-000000000000", "done" }, want = { "a1b2c3d4-0000-4000-8000-000000000000", "done" }, why = "a UUID is unchanged" },
	{ args = {}, want = {}, why = "an empty list stays empty" },
}
for _, case in ipairs(expansions) do
	eq(
		"expand_id_lists " .. vim.inspect(case.args) .. " (" .. case.why .. ")",
		vim.inspect(dispatch.expand_id_lists(case.args)),
		vim.inspect(case.want)
	)
end
local input = { "1,2", "done" }
local expanded = dispatch.expand_id_lists(input)
eq("expand_id_lists leaves its input alone", vim.inspect(input), vim.inspect({ "1,2", "done" }))
check("expand_id_lists returns a new table", expanded ~= input)

io.write(string.format("%d checks, %d failures\n", checks, failures))
if failures > 0 then
	vim.cmd("cquit 1")
else
	vim.cmd("qa!")
end
