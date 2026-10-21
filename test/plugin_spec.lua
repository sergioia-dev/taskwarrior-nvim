--- Integration spec for the taskwarrior plugin: split geometry, buffer options,
--- the `q` / `r` maps, render/run dispatch through `:Task`, notifications,
--- stdin policy and the TASKDATA watcher.
---
--- Everything is driven through a stub `task` on PATH, so no real task database
--- is touched. Assertions use `check`/`eq` and the script exits non-zero (via
--- `cquit`) when anything failed: a bare `assert` in a `luafile` cannot fail a
--- headless run.
local plugin = require("taskwarrior")
local window = require("taskwarrior.window")
local watch = require("taskwarrior.watch")

local checks = 0
local failures = 0

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

-- Capture notifications instead of letting them reach the real handler.
local notifications = {}
vim.notify = function(msg, level)
	notifications[#notifications + 1] = { msg = tostring(msg), level = level or vim.log.levels.INFO }
end

local function last_notification()
	return notifications[#notifications]
end

local function notified(pred, ms)
	return vim.wait(ms or 5000, function()
		for _, note in ipairs(notifications) do
			if pred(note) then
				return true
			end
		end
		return false
	end, 10)
end

local function stub_argv()
	local ok, lines = pcall(vim.fn.readfile, vim.env.TW_STUB_LOG)
	if not ok then
		return {}
	end
	local argv = {}
	for _, line in ipairs(lines) do
		local entry = line:match("^ARGV\t(.*)$")
		if entry then
			argv[#argv + 1] = entry
		end
	end
	return argv
end

--- The argument list of every recorded call, one table per invocation. A
--- spec that cares whether words stayed apart (`add buy milk` vs one
--- argument) has to look at these, not at the space-joined `ARGV` lines.
local function stub_invocations()
	local ok, lines = pcall(vim.fn.readfile, vim.env.TW_STUB_LOG)
	if not ok then
		return {}
	end
	local calls, current = {}, nil
	for _, line in ipairs(lines) do
		local index, arg = line:match("^ARG(%d+)\t(.*)$")
		if index == "0" then
			current = { arg }
			calls[#calls + 1] = current
		elseif index and current then
			current[#current + 1] = arg
		end
	end
	return calls
end

local function raw_stdin()
	local handle = io.open(vim.env.TW_STUB_STDIN, "rb")
	if not handle then
		return nil
	end
	local data = handle:read("*a")
	handle:close()
	return data
end

local function reset_stub()
	vim.fn.writefile({}, vim.env.TW_STUB_LOG)
	notifications = {}
end

local function wait_for_content(ms)
	return vim.wait(ms or 5000, function()
		local buf = window.buffer()
		if not (buf and vim.api.nvim_buf_is_valid(buf)) then
			return false
		end
		-- A fresh scratch buffer always holds one empty line, so "has lines"
		-- is true before the render lands; wait for text it actually wrote.
		return window.text(buf) ~= ""
	end, 10)
end

--- Wait until the last `task` argv the stub saw matches `pattern`.
local function last_argv_matches(pattern, ms)
	return vim.wait(ms or 5000, function()
		local argv = stub_argv()
		local last = argv[#argv]
		return last ~= nil and last:match(pattern) ~= nil
	end, 10)
end

-- 1 ─ the command is registered by the plugin script alone.
eq(":Task is registered", vim.fn.exists(":Task"), 2)

-- 2 ─ `:Task` opens a bottom split with the default report.
reset_stub()
vim.cmd("Task")
check(":Task opens the list", wait_for_content())
local buf = window.buffer()
local win = window.window()
check("split is a real window", win ~= nil and vim.api.nvim_win_is_valid(win))
eq("split height is half the editor", vim.api.nvim_win_get_height(win), 12)
eq("buffer is a scratch buffer", vim.bo[buf].buftype, "nofile")
eq("buffer is not modifiable", vim.bo[buf].modifiable, false)
eq("buffer is wiped when hidden", vim.bo[buf].bufhidden, "wipe")
eq("buffer filetype", vim.bo[buf].filetype, "taskwarrior")
eq("buffer name", vim.api.nvim_buf_get_name(buf), "taskwarrior://next")
eq("no absolute line numbers", vim.wo[win].number, false)
eq("no relative line numbers", vim.wo[win].relativenumber, false)
local bar = vim.wo[win].winbar
	check("winbar shows the blue Taskwarrior label",
		bar:find("%#TaskwarriorWinbar# Taskwarrior", 1, true) == 1, bar)
	eq("winbar label is blue", vim.api.nvim_get_hl(0, { name = "TaskwarriorWinbar" }).fg, 0x89b4fa)
	local rule = window.winbar_rule()
	eq("blue rule fills the bar", vim.fn.strchars(rule), vim.api.nvim_win_get_width(win) - #" Taskwarrior ")
	check("blue rule is a line", rule == string.rep("─", vim.fn.strchars(rule)), rule)
	-- Evaluate the real `%{}` item the way the winbar is drawn, so a broken
	-- expression fails here instead of erroring on every redraw.
	local drawn = vim.api.nvim_eval_statusline(bar,
		{ winid = win, highlights = true, maxwidth = vim.api.nvim_win_get_width(win) })
	eq("winbar draws to the window width", vim.fn.strchars(drawn.str), vim.api.nvim_win_get_width(win))
	eq("drawn winbar is all blue", drawn.highlights[1].group, "TaskwarriorWinbar")
eq("rendered the stub output", vim.inspect(vim.api.nvim_buf_get_lines(buf, 0, -1, false)),
	vim.inspect({ "ID AGE DESCRIPTION", "1 buy milk", "2 write tests" }))
check("render argv asks for plain output and a width",
	last_argv_matches("^rc%.color=off rc%.defaultwidth=%d+ next$"), stub_argv()[#stub_argv()])

-- 3 ─ `q` closes the split and wipes its buffer.
local mapping = vim.fn.maparg("q", "n", false, true)
check("q is a buffer-local map", type(mapping) == "table" and mapping.buffer == 1, vim.inspect(mapping))
vim.api.nvim_buf_call(buf, function()
	vim.cmd("normal q")
end)
check("q closes the split", not plugin.is_open())
check("q wipes the buffer", not vim.api.nvim_buf_is_valid(buf))

-- 4 ─ a second `:Task` with the same view toggles the split closed.
vim.cmd("Task")
check("reopened", wait_for_content())
local before_toggle = #stub_argv()
vim.cmd("Task")
check("same view toggles closed", not plugin.is_open())
eq("toggle does not run task again", #stub_argv(), before_toggle)

-- 5 ─ a different report re-renders in place, reusing the split.
vim.cmd("Task")
check("opened for the re-render test", wait_for_content())
local windows_before = #vim.api.nvim_list_wins()
local calls_before = #stub_argv()
vim.cmd("Task all")
vim.wait(5000, function()
	return #stub_argv() > calls_before and window.view() == "all"
end, 10)
eq("no extra window is created", #vim.api.nvim_list_wins(), windows_before)
eq("view switched", window.view(), "all")
eq("buffer renamed", vim.api.nvim_buf_get_name(window.buffer()), "taskwarrior://all")

-- 6 ─ a mutating command runs headless: no window, argv without rc overrides.
plugin.close()
reset_stub()
vim.cmd("Task add buy milk")
check("run command completes", notified(function(entry)
	return entry.msg:find("ID AGE DESCRIPTION", 1, true) ~= nil and entry.msg:find("-> exit", 1, true) == nil
end))
eq("run argv is the plain command", stub_argv()[#stub_argv()], "add buy milk")
eq("single window remains", #vim.api.nvim_list_wins(), 1)
check("no split opened for a run command", not plugin.is_open())
local note = last_notification()
eq("run command reports success", note and note.level, vim.log.levels.INFO)
check("notification shows the result, not the command echo",
	note ~= nil and note.msg:find("-> exit", 1, true) == nil
		and note.msg:find("ID AGE DESCRIPTION", 1, true) ~= nil, note and note.msg)

-- 7 ─ stdin policy: `auto_yes` verbs get "yes", everything else EOF.
reset_stub()
vim.cmd("Task undo")
check("undo completes", notified(function(entry)
	return entry.msg:find("ID AGE DESCRIPTION", 1, true) ~= nil and entry.msg:find("-> exit", 1, true) == nil
end))
eq("undo was auto-confirmed on stdin", raw_stdin(), "yes\n")

reset_stub()
vim.cmd("Task add x")
check("add completes", notified(function(entry)
	return entry.msg:find("ID AGE DESCRIPTION", 1, true) ~= nil and entry.msg:find("-> exit", 1, true) == nil
end))
eq("add got no stdin", raw_stdin(), "")

-- 8 ─ a failing render keeps the previous content and reports the error.
plugin.close()
vim.env.TW_STUB_EXIT = "0"
reset_stub()
vim.cmd("Task")
check("opened for the failure test", wait_for_content())
local previous = window.text(window.buffer())
vim.env.TW_STUB_EXIT = "1"
notifications = {}
vim.cmd("Task all")
check("failed render notifies", notified(function(entry)
	return entry.msg:match("exit 1") ~= nil
end))
eq("failed render keeps the old content", window.text(window.buffer()), previous)
local failure = last_notification()
eq("failed render notifies at ERROR level", failure and failure.level, vim.log.levels.ERROR)
vim.env.TW_STUB_EXIT = "0"
plugin.close()

-- 8b ─ an empty report ("No matches.") is a result, not an error.
plugin.close()
vim.env.TW_STUB_EXIT = "1"
vim.env.TW_STUB_OUT = ""
vim.env.TW_STUB_ERR = "No matches.\n"
reset_stub()
vim.cmd("Task all")
check("no-matches render notifies", notified(function(entry)
	return entry.msg:find("No matches.", 1, true) ~= nil
end))
local empty_note = last_notification()
eq("no-matches notification is INFO, not ERROR", empty_note and empty_note.level, vim.log.levels.INFO)
check("no-matches notification omits the error header",
	empty_note ~= nil and empty_note.msg:find("-> exit", 1, true) == nil, empty_note and empty_note.msg)
vim.env.TW_STUB_EXIT = "0"
vim.env.TW_STUB_OUT = nil
vim.env.TW_STUB_ERR = nil
plugin.close()

-- 8c ─ the refresh after `:Task delete 1` that empties the list must show
-- "No matches." instead of keeping the row of the task that is gone.
reset_stub()
vim.env.TW_STUB_EXIT = "0"
vim.cmd("Task")
check("opened before the delete", wait_for_content())
local stale = window.text(window.buffer())
check("list had rows to go stale", stale:find("buy milk", 1, true) ~= nil, stale)
vim.env.TW_STUB_EXIT = "1"
vim.env.TW_STUB_OUT = ""
vim.env.TW_STUB_ERR = "No matches.\n"
plugin.refresh() -- what a successful `:Task delete 1` does to the open list
check("empty refresh lands", vim.wait(5000, function()
	return window.text(window.buffer()) == "No matches."
end, 10))
eq("deleted task left no stale row", window.text(window.buffer()), "No matches.")
vim.env.TW_STUB_EXIT = "0"
vim.env.TW_STUB_OUT = nil
vim.env.TW_STUB_ERR = nil
plugin.close()

-- 9 ─ a missing binary is reported before any window is opened.
plugin.setup({ task_cmd = "definitely-missing-xyz" })
reset_stub()
vim.cmd("Task")
check("missing binary notifies", notified(function(entry)
	return entry.msg:match("not found") ~= nil
end, 2000))
local missing = last_notification()
check("missing binary message mentions task_cmd",
	missing ~= nil and missing.msg:match("set task_cmd") ~= nil, missing and missing.msg)
eq("missing binary message level", missing and missing.level, vim.log.levels.ERROR)
check("missing binary opens no window", not plugin.is_open())
plugin.setup({ task_cmd = "task" })

-- 10 ─ an external write to the database reloads the list.
local db = watch.data_dir() .. "/taskchampion.sqlite3"
if vim.fn.filereadable(db) ~= 1 then
	check("watcher skipped: no data file in TASKDATA", true)
else
	vim.wait(1600) -- outlast the absorb window left by the mutating commands
	reset_stub()
	vim.cmd("Task")
	check("opened for the watcher test", wait_for_content())
	local calls = #stub_argv()
	vim.wait(600) -- outlast the "we just talked to task" guard
	vim.fn.writefile({ "changed" }, db, "a")
	local reloaded = vim.wait(4000, function()
		return #stub_argv() > calls
	end, 50)
	check("filesystem event reloads the list", reloaded,
		string.format("task calls before=%d after=%d", calls, #stub_argv()))
	plugin.close()
end

-- 11 ─ close_on_focus_lost hands the split back when focus moves (m00298).
plugin.setup({ close_on_focus_lost = true })
reset_stub()
vim.cmd("Task")
check("opened for the focus test", wait_for_content())
vim.cmd("new")
check("focus loss closes the split when enabled", vim.wait(5000, function()
	return not plugin.is_open()
end, 20))
vim.cmd("only")
plugin.setup({ close_on_focus_lost = false })
vim.cmd("Task")
check("opened for the keep-focus test", wait_for_content())
vim.cmd("new")
vim.wait(400)
check("focus loss keeps the split when disabled", plugin.is_open())
vim.cmd("only")

-- 12 ─ captured stderr drops the override notices caused by our own rc.* flags.
local task_module = require("taskwarrior.task")
local stripped = task_module.text({
	stdout = "ID Age\n",
	stderr = "Configuration override rc.color=off\n"
		.. "Configuration override rc.defaultwidth=190\n"
		.. "task: warning\n",
})
eq("override notices are stripped from captured stderr", stripped, "ID Age\ntask: warning\n")
eq("stderr without notices is kept", task_module.text({ stdout = "", stderr = "boom\n" }), "boom\n")

-- 13 ─ a command taskwarrior will not run without an answer asks the user first.
local default_confirm = task_module.confirm
local asked = nil
task_module.confirm = function(question)
	asked = question
	return true
end
reset_stub()
vim.env.TW_STUB_EXIT = "2"
vim.env.TW_STUB_OUT = "Delete task 1 'test'? (yes/no) Deleting task 1 'test'.\nDeleted 1 task.\n"
vim.env.TW_STUB_ERR = ""
vim.cmd("Task delete test")
check("a confirmed run succeeds", notified(function(entry)
	return entry.msg:find("Deleted 1 task.", 1, true) ~= nil and entry.msg:find("-> exit", 1, true) == nil
end))
local confirmed_note = last_notification()
check("the confirmed notification drops the question", confirmed_note ~= nil and confirmed_note.msg:find("(yes/no)", 1, true) == nil and confirmed_note.msg:find("Deleted 1 task.", 1, true) ~= nil, confirmed_note and confirmed_note.msg)
check("the question is taskwarrior's own and names the command", asked ~= nil and asked:match("^task delete test\n") ~= nil and asked:match("Delete task 1 'test'%? %(yes/no%)") ~= nil, asked)
eq("the confirmed run got the answer on stdin", raw_stdin(), "yes\n")
check("the confirmed run repeated the command", #stub_argv() == 2, vim.inspect(stub_argv()))

-- 13b ─ declining the question keeps taskwarrior's refusal.
task_module.confirm = function()
	return false
end
reset_stub()
vim.cmd("Task delete test")
check("a declined run reports the refusal", notified(function(entry)
	return entry.msg:match("^task delete test %-> exit 2") ~= nil
end))
eq("a declined run is not repeated", #stub_argv(), 1)

task_module.confirm = default_confirm
vim.env.TW_STUB_EXIT = "0"
vim.env.TW_STUB_ERR = ""

-- 14 ─ `<range>Task add` adds one task per selected line.
plugin.close()
reset_stub()
vim.env.TW_STUB_OUT = "Created 1 task.\n"
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(scratch)
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "buy milk", "   ", "", "write tests project:test1" })
vim.cmd("normal! ggVG\27")
eq("the selection covers the buffer", vim.fn.line("'>") - vim.fn.line("'<") + 1, 4)
vim.cmd("'<,'>Task add")
check("both selected lines were added", vim.wait(5000, function()
	return #stub_argv() >= 2
end, 10), vim.inspect(stub_argv()))
eq("one add per non-empty line, in order", vim.inspect(stub_argv()),
	vim.inspect({ "add buy milk", "add write tests project:test1" }))
eq("each line is tokenized, so attributes reach taskwarrior", vim.inspect(stub_invocations()),
	vim.inspect({
		{ "add", "buy", "milk" },
		{ "add", "write", "tests", "project:test1" },
	}))
--- How many notifications so far mention `text`.
local function noted(text)
	local count = 0
	for _, note in ipairs(notifications) do
		if note.msg:find(text, 1, true) then
			count = count + 1
		end
	end
	return count
end
check("each added task reports itself", vim.wait(5000, function()
	return noted("Created 1 task.") == 2
end, 10), noted("Created 1 task."))

-- A typed description without a range is still a single command.
reset_stub()
vim.cmd("Task add typed line")
check("the typed add ran", vim.wait(5000, function()
	return #stub_argv() >= 1
end, 10), vim.inspect(stub_argv()))
eq("a typed add stays one command", vim.inspect(stub_argv()), vim.inspect({ "add typed line" }))
eq("a typed add sends the same word split", vim.inspect(stub_invocations()),
	vim.inspect({ { "add", "typed", "line" } }))
check("the typed add reported itself", vim.wait(5000, function()
	return noted("Created 1 task.") == 1
end, 10), noted("Created 1 task."))

-- Extra arguments keep the normal behaviour: the typed text wins and the
-- range is not turned into a selection.
reset_stub()
vim.cmd("1,2Task add extra words")
check("the ranged add with arguments ran", vim.wait(5000, function()
	return #stub_argv() >= 1
end, 10), vim.inspect(stub_argv()))
eq("a range with extra arguments falls back to the typed command", vim.inspect(stub_argv()),
	vim.inspect({ "add extra words" }))
eq("the fallback is tokenized like any typed command", vim.inspect(stub_invocations()),
	vim.inspect({ { "add", "extra", "words" } }))
check("the fallback run reported itself", vim.wait(5000, function()
	return #stub_argv() == 1 and noted("Created 1 task.") == 1
end, 10), vim.inspect(notifications))

-- A selection of blank lines is a silent no-op.
reset_stub()
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "", "   " })
vim.cmd("1,2Task add")
vim.wait(300, function()
	return #stub_argv() > 0
end, 10)
eq("a blank selection adds nothing", vim.inspect(stub_argv()), "{}")
eq("a blank selection says nothing", #notifications, 0)
vim.api.nvim_buf_delete(scratch, { force = true })

io.write(string.format("%d checks, %d failures\n", checks, failures))
if failures > 0 then
	vim.cmd("cquit 1")
else
	vim.cmd("qa!")
end
