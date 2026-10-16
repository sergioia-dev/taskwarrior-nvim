" Minimal init for the headless test suite: no user configuration, just the
" plugin under test on the runtimepath. `-u` with this file means nothing else
" is loaded, so `:Task` existing proves the plugin's `plugin/` script ran.
set nocompatible
let s:plugin_root = expand('<sfile>:p:h:h')
execute 'set runtimepath^=' . fnameescape(s:plugin_root)
set noswapfile
set shortmess+=c
