#!/usr/bin/env bash
# Headless test suite for taskwarrior-nvim.
#
#   bash test/run.sh
#
# Runs each spec in its own headless Neovim, with `test/bin` ahead of the real
# `task` on PATH and a throwaway TASKDATA so nothing touches the real database.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export TASKDATA="$work/taskdata"
export TW_STUB_LOG="$work/stub.log"
export TW_STUB_STDIN="$work/stdin"
export TW_STUB_OUT='ID AGE DESCRIPTION\n1 buy milk\n2 write tests\n'
export TW_STUB_ERR=''
export TW_STUB_EXIT=0
export TW_PLUGIN_TEST_WORK="$work"

mkdir -p "$TASKDATA"
: >"$TW_STUB_LOG"
: >"$TW_STUB_STDIN"
# The watcher only attaches to data files that already exist.
: >"$TASKDATA/taskchampion.sqlite3"

# A spec that errors before its own `qa!`/`cquit` leaves headless Neovim waiting
# for input forever, so bound each run and turn a load error into a failure.
run_spec() {
	local spec="$1"
	echo "== $spec =="
	PATH="$root/test/bin:$PATH" timeout 90 nvim --headless -u "$root/test/minimal_init.vim" \
		-c "lua local ok, err = pcall(vim.cmd, 'luafile $root/test/$spec.lua'); if not ok then io.stderr:write('spec error: ' .. tostring(err) .. '\n'); vim.cmd('cquit 1') end" \
		-c 'qa!'
}

status=0
for spec in dispatch_spec plugin_spec; do
	if ! run_spec "$spec"; then
		status=1
	fi
done

if [ "$status" -eq 0 ]; then
	echo "all specs passed"
else
	echo "specs failed"
fi
exit "$status"
