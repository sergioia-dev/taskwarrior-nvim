# taskwarrior.nvim

Read your [Taskwarrior](https://taskwarrior.org) tasks in a bottom split, run
everything else headless. `:Task` renders any report, filter or ID list; `:Task
add …`, `:Task 12 done`, `:Task sync` act on your data and report back through a
notification instead of a terminal window.

> [!NOTE]
> This plugin doesn't look to remake the way we interact with taskwarrior, it only integrate it to make it easily usable inside neovim.

## Requirements

- Neovim 0.10 or newer (`vim.system`, `vim.uv.fs_event`)
- The `task` executable on `PATH` (set `task_cmd` if it lives elsewhere)

Taskwarrior itself is not bundled: the plugin shells out to the `task` you
already use, with the same `TASKDATA`, `TASKRC` and config as your shell.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "sergioia-dev/taskwarrior-nvim",
  opts = {
    default_report = "next",
    height_ratio = 0.5,
  },
}
```

Or with any other plugin manager, calling `setup` yourself:

```lua
require("taskwarrior").setup({
  task_cmd = "/usr/local/bin/task",
  default_report = "next",
  height_ratio = 0.5,
})
```

`setup` is optional — every option has a default — but calling it early (from
your config, not lazily) lets tab completion discover your custom reports right
away.

## Command

`:Task [args…]` is the whole surface:

| Invocation | What happens |
|---|---|
| `:Task` | Renders `default_report` in the split |
| `:Task next`, `:Task all`, `:Task calendar`, … | Renders that report |
| `:Task +work`, `:Task project:home`, `:Task 12` | Renders `default_report` with those filters or IDs |
| `:Task add buy milk`, `:Task 12 done`, `:Task sync`, `:Task undo` | Runs headless, reports the result |
| `:Task context` | Renders; `:Task context work` runs |

The arguments are classified, not guessed: a report name, a filter or an ID
renders, a mutating verb (`add`, `done`, `modify`, `undo`, `sync`, …) runs.
Repeat the same view to toggle the split closed; a different report re-renders
in place, without opening a second window. Completion offers your report names
and the mutating verbs.

## Keys

Inside the list split:

| Key | Action |
|---|---|
| `q` | Close the split and wipe the buffer |
| `r` | Reload the current view |

`:close`, `:bd` or closing the window by hand reset the same state and stop the
watcher.

## Options

| Option | Default | Meaning |
|---|---|---|
| `task_cmd` | `"task"` | Executable name or absolute path |
| `default_report` | `"next"` | Report used when only filters or IDs are given |
| `height_ratio` | `0.5` | Split height as a fraction of the editor |
| `size` | `nil` | Absolute rows (`30`) or a percentage (`"50%"`), overrides `height_ratio` |
| `timeout_ms` | `30000` | Hard timeout for any `task` invocation |
| `auto_yes` | `{ "undo" }` | Verbs that get `"yes\n"` on stdin; everything else gets EOF |
| `watch` | `true` | Reload when `$TASKDATA` changes on disk |
| `refresh_debounce_ms` | `200` | Debounce for watcher events and resizes |
| `notify_output_lines` | `10` | Output lines included in a notification |
| `close_on_focus_lost` | `false` | Close the split as soon as focus moves to another window |

Unknown keys are ignored. `require("taskwarrior").options()` returns the
effective options.

## Behaviour worth knowing

- **Rendering is async.** The split opens immediately and fills in when `task`
  returns; the cursor is never blocked. Results for a view you already replaced
  are discarded.
- **Failures never empty the buffer.** If a report fails, the previous content
  stays and an error notification explains why. Only the first render into an
  empty buffer shows the failure text itself.
- **Notifications are self-contained.** Each one names the command, its exit
  status and (truncated to `notify_output_lines`) what it printed. When output
  is cut short, the full text is echoed to `:messages`.
- **Auto-reload.** While the split is open, `$TASKDATA` (and the Taskchampion
  SQLite file inside it) is watched, so a `task add` in another terminal or a
  `task sync` refreshes the list. Writes the plugin itself causes are ignored,
  and resizing the editor re-wraps the columns.
- **Rendering is colorless on purpose.** Reports are rendered with
  `rc.color=off` and a width that matches the split, so no escape codes or
  clipped columns end up in the buffer.

## Limitations

- **Interactive commands cannot be served.** Prompts other than `auto_yes`
  (`task edit`, `task import`) run with stdin at EOF; use them in a real
  terminal. `auto_yes` exists because `task undo` asks a yes/no question that
  can be answered on stdin.
- The list is read-only — it is a pager, not an editor. There are no per-task
  keymaps beyond `q` and `r`, no syntax highlighting and no filter UI.
- The watcher needs `vim.uv.fs_event` (Linux, macOS, Windows). Where it is
  unavailable the plugin still works: `r` and the automatic reload after its own
  mutating commands refresh the list.

## License

MIT
