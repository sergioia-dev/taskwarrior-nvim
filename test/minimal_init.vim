" Minimal init for the headless test suite: no user configuration, just the
" plugin under test on the runtimepath. `-u` with this file means nothing else
" is loaded, so `:Task` existing proves the plugin's `plugin/` script ran.
set nocompatible
let s:plugin_root = expand('<sfile>:p:h:h')

" A wrapper around `nvim` (nix, asdf, …) may paste its own runtimepath and
" packpath ahead of ours, which would load a user config's `plugin/` scripts and
" a packaged copy of this plugin on top of the one under test. Pin both to the
" plugin and $VIMRUNTIME so a run only ever sees this checkout.
execute 'set runtimepath=' . fnameescape(s:plugin_root) . ',' . fnameescape($VIMRUNTIME)
execute 'set packpath=' . fnameescape($VIMRUNTIME)

" The specs drive a stub `task` from `test/bin` and assert on its argv, so that
" directory has to win over any `task` a wrapper pasted ahead of $PATH before
" nvim even started.
let $PATH = s:plugin_root . '/test/bin:' . $PATH

set noswapfile
set shortmess+=c
