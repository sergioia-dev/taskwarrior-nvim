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

io.write(string.format("%d checks, %d failures\n", checks, failures))
if failures > 0 then
	vim.cmd("cquit 1")
else
	vim.cmd("qa!")
end
