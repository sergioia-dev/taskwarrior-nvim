--- The CLI boundary: everything that knows about the `task` executable lives
--- here. Render invocations capture stdout for the list buffer; run
--- invocations report their result through a notification.
local M = {}

local config = require("taskwarrior.config")

--- Configured `task` executable.
function M.binary()
	return config.options.task_cmd or "task"
end

--- Whether the configured binary can be executed.
function M.exists()
	local cmd = M.binary()
	if cmd == "" then
		return false
	end
	return vim.fn.executable(cmd) == 1
end

--- Notify that the configured binary is not executable.
function M.notify_missing()
	vim.notify(
		string.format("taskwarrior: '%s' not found; set task_cmd to its full path", M.binary()),
		vim.log.levels.ERROR
	)
end

--- How many tasks the command targets: the number of bare numeric IDs in
--- `args`, and at least one so a filter-only command still gets an answer.
---
--- Taskwarrior asks one yes/no question per task it is about to change, so a
--- `:Task 1,2,3 delete` (expanded to `task 1 2 3 delete`) needs three answers.
--- Over-answering is harmless: it stops reading stdin once it is done.
function M.target_count(args)
	local count = 0
	for _, arg in ipairs(args) do
		if arg:match("^%d+$") then
			count = count + 1
		end
	end
	return math.max(1, count)
end

--- `"yes\n"` per targeted task for verbs listed in `auto_yes`, `false` (closed
--- stdin, immediate EOF) for everything else. Interactive prompts cannot be
--- served headless, so only the verbs the user opted into get an answer.
function M.stdin_for(args)
	local auto = config.options.auto_yes
	for _, verb in ipairs(auto or {}) do
		if args[1] == verb then
			return string.rep("yes\n", M.target_count(args))
		end
	end
	return false
end

--- Argv for a render: colour off and an explicit width, because the output is
--- shown in a non-editable buffer rather than a terminal.
function M.render_argv(args, width)
	local argv = { M.binary(), "rc.color=off", "rc.defaultwidth=" .. tostring(width or vim.o.columns - 1) }
	for _, a in ipairs(args) do
		argv[#argv + 1] = a
	end
	return argv
end

--- Argv for a headless run: the user's own configuration and width apply.
function M.run_argv(args)
	local argv = { M.binary() }
	for _, a in ipairs(args) do
		argv[#argv + 1] = a
	end
	return argv
end

--- Spawn `argv` asynchronously, always invoking `on_exit` from the main loop.
local function spawn(argv, stdin, on_exit)
	local ok, err = pcall(vim.system, argv, {
		text = true,
		stdin = stdin,
		timeout = config.options.timeout_ms,
	}, function(result)
		vim.schedule(function()
			on_exit(result)
		end)
	end)
	if not ok then
		vim.schedule(function()
			on_exit({ code = 1, signal = 0, stdout = "", stderr = tostring(err) })
		end)
	end
end

--- Taskwarrior prints one `Configuration override rc.<key>=<value>` line on
--- stderr for every command line override when the user's `verbose` setting
--- contains the `override` token. Those notices are only there because the
--- plugin itself passes `rc.color`/`rc.defaultwidth`, so they are stripped
--- from captured stderr. Only stderr is filtered: report data on stdout can
--- never be removed by this.
local function strip_override_notices(text)
	local kept = {}
	for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
		if not line:match("^Configuration override ") then
			kept[#kept + 1] = line
		end
	end
	return table.concat(kept, "\n")
end

--- Output lines of a finished process, without the trailing empty line.
local function output_lines(result)
	local combined = (result.stdout or "") .. strip_override_notices(result.stderr)
	local lines = vim.split(combined, "\n", { plain = true })
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

--- Taskwarrior reports an empty result (e.g. `next` with no tasks) as "No matches."
--- on stderr with exit code 1, which is a result, not an error.
local function no_matches_only(lines)
	local seen = false
	for _, line in ipairs(lines) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			if seen or not trimmed:match("^No matches%.?$") then
				return false
			end
			seen = true
		end
	end
	return seen
end

--- Whether a finished task run is only taskwarrior's "No matches." answer,
--- i.e. the query was valid but selected nothing. Such a result belongs in
--- the list buffer, unlike a real error, which leaves the buffer alone.
--- @param result table vim.system result
--- @return boolean
function M.no_matches(result)
	return no_matches_only(output_lines(result))
end

--- Notify the result of a headless run. On success (or an empty "No matches."
--- result) the notification is task's own output without the
--- "task <cmd> -> exit <code>" prefix; on a real failure it also names the
--- command and exit status. Longer output is echoed into `:messages` in full.
function M.notify_result(argv, result)
	local cmdline = table.concat(argv, " ")
	local lines = output_lines(result)
	local limit = config.options.notify_output_lines or 10
	local success = result.code == 0 or no_matches_only(lines)
	local level = success and vim.log.levels.INFO or vim.log.levels.ERROR
	local shown = {}
	for i = 1, math.min(#lines, limit) do
		shown[#shown + 1] = lines[i]
	end
	if #lines > limit then
		shown[#shown + 1] = string.format("... (+%d lines, full output in :messages)", #lines - limit)
		vim.api.nvim_echo({ { table.concat(lines, "\n") } }, true, {})
	end
	local body = table.concat(shown, "\n")
	if success then
		vim.notify(body ~= "" and body or cmdline, level)
	else
		local msg = string.format("%s -> exit %s", cmdline, tostring(result.code))
		if body ~= "" then
			msg = msg .. "\n" .. body
		end
		vim.notify(msg, level)
	end
end

--- Run a rendering command and hand the raw result to `opts.on_done`.
---
--- Returns `false` when the binary is missing (after notifying), `true`
--- otherwise. `opts.width` is the report width, `opts.notify_errors` (default
--- true) controls whether a non-zero exit announces itself.
function M.render(args, opts)
	opts = opts or {}
	if not M.exists() then
		M.notify_missing()
		return false
	end
	local argv = M.render_argv(args, opts.width)
	spawn(argv, false, function(result)
		if result.code ~= 0 and opts.notify_errors ~= false then
			M.notify_result(argv, result)
		end
		if opts.on_done then
			opts.on_done(result, argv)
		end
	end)
	return true
end

--- Ask the user to confirm a command taskwarrior refused to run with stdin
--- closed. Exposed as a field so tests (and users) can replace the prompt.
--- @param question string command line followed by taskwarrior's own question
--- @return boolean
M.confirm = function(question)
	return vim.fn.confirm(question, "&Yes\n&No", 2) == 1
end

--- The `(yes/no)` question taskwarrior prints when it wants an answer on
--- stdin, or `nil` when `result` carries no such question.
--- @param result table vim.system result
--- @return string|nil
local function confirmation_question(result)
	local text = (result.stdout or "") .. (result.stderr or "")
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		local pos = line:find("(yes/no)", 1, true)
		if pos then
			return vim.trim(line:sub(1, pos + 7))
		end
	end
	return nil
end
--- Remove taskwarrior's `(yes/no)` prompts from `text` (the start of each
--- prompt's line through the closing ")"), one per task it asked about; the
--- messages that follow each answer are kept. Returns `text` unchanged when
--- there is no prompt.
local function strip_yesno(text)
	if text == nil or text == "" then
		return text
	end
	local kept = {}
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		local s = line:find("(yes/no)", 1, true)
		if s then
			line = line:sub(s + 8):gsub("^%s+", "")
		end
		kept[#kept + 1] = line
	end
	return table.concat(kept, "\n")
end

--- Run a mutating command headless and notify its result. A command that
--- taskwarrior refuses to run without an interactive answer asks the user
--- first (`M.confirm`) and is then re-run with that answer on stdin.
function M.run(args, opts)
	opts = opts or {}
	if not M.exists() then
		M.notify_missing()
		return false
	end
	local argv = M.run_argv(args)
	local stdin = M.stdin_for(args)
	spawn(argv, stdin, function(result)
		local question = stdin == false and confirmation_question(result) or nil
		if question and M.confirm(string.format("%s\n%s", table.concat(argv, " "), question)) then
			-- The user agreed, so only the outcome of the confirmed run is
			-- announced. A refused or cancelled question reports the original
			-- "prevented from running" result instead.
			spawn(argv, string.rep("yes\n", M.target_count(args)), function(confirmed)
				local cleaned = vim.tbl_extend("force", {}, confirmed)
				cleaned.stdout = strip_yesno(confirmed.stdout)
				cleaned.stderr = strip_yesno(confirmed.stderr)
				M.notify_result(argv, cleaned)
				if opts.on_done then
					opts.on_done(confirmed, argv)
				end
			end)
			return
		end
		M.notify_result(argv, result)
		if opts.on_done then
			opts.on_done(result, argv)
		end
	end)
	return true
end

--- Combined stdout and stderr of a finished process.
function M.text(result)
	return (result.stdout or "") .. strip_override_notices(result.stderr)
end

return M
