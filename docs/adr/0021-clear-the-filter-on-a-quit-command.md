# Clear the filter on a quit command, by command name and not by key

The filter hides rows, so a kept filter changes the listing that every
later command reads.  Evil clears the highlight of a search when the user
presses `C-g`, `ESC` or `M-x keyboard-quit`, and a reader who narrows a
listing with `f` or `/` expects the same escape.

Evil reaches one clear from three kinds of entry point without binding a
key for any of them.  The highlight lives in one named overlay group, and
`evil-ex-delete-hl` removes it.  A `condition-case` around the
`read-string` of the minibuffer catches the `quit` signal of `C-g` and
`ESC`.  A buffer-local `pre-command-hook` entry, `evil-flash-hook`, runs
before every command and clears the highlight unless `this-command`
belongs to a whitelist of search commands, so any other command clears
it.  A `quit-flag` test in `evil-visual-post-command` covers the visual
state.

Tired copies the second shape and not the first.  The listing reads
`this-command` in `pre-command-hook` and compares it against
`tired-filter-quit-commands`.  `keyboard-quit` from its own key, from
`M-x` and from a user binding gives one symbol, so one list covers every
path.  `tired-evil.el` appends `evil-force-normal-state`, and that symbol
names the evil `ESC` in every state.  Core names no evil function, so the
dependency keeps pointing one way.  The minibuffer needs no entry at all:
`tired-filter` already catches the `quit` signal and restores the previous
filter, the way Evil's own handler does.

Rejected: a `C-g` binding in `tired-mode-map` plus a remap of
`evil-force-normal-state`.  It shadows no key and needs no hook, but it
enumerates the entry points by hand.  `M-x keyboard-quit` would miss the
clear, and so would every user rebinding of the two commands.  Rejected as
well: `advice-add` on `keyboard-quit`, the way `evil-integration.el`
aborts repeat.  Advice reaches every binding of that one command and no
other, so the evil quit path still needs its own entry.

The hook reads one buffer-local variable and one symbol, so a command in
a listing without a filter costs less than a microsecond.  The clear
redraws the listing, and that redraw costs a millisecond on a small
directory, so it runs on quit commands alone.  The redraw sits in the
hook, not in a timer, so the next command reads the listing that the user
asked for.

## Consequences

A command hook drops its function after a signal in that function, so the
clear keeps its own guard and catches `quit` and `error`.  A `quit` that
arrives during the redraw would otherwise remove the hook for the buffer.
The guard covers the clear alone: the command that follows still quits.

The hook carries no `permanent-local-hook`, unlike the two evil entries.
A change of major mode drops `tired-mode` and its hook together, and a
hook that outlived the mode would read a filter variable that no longer
names anything.

A user who adds a command symbol to `tired-filter-quit-commands` clears
the filter from that command, whatever key runs it.  A user who wants the
filter to outlive a quit command removes the symbol from the list, and
`F` keeps the explicit clear.
