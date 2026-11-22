# Refuse a parent and child rename in one commit

A name edit can hold a directory row and a row below it.  The commit
reaches the rows in display order, so the parent moved first and the
child then called `rename-file` on a source path that the parent
rename had already left behind.  The command renamed the tree, failed
the child, reported one failed path and kept the child row editable
with a source that no longer existed.  Refreshing while the edit mode
holds repairs nothing, because the mode keeps the buffer text, so the
retry could never succeed.

The commit now refuses the whole batch before it touches the disk and
keeps the typed names, so the user renames the parent first and the
child second.  Renaming the child first would reach the same tree, but
it would also move the child out of the way of the parent in one
step, and one undo would have to reverse both steps in an order that
the current journal of `push`-ed pairs does not describe.  Dependent
renames are therefore not a feature that this commit lost; the
combined operation never worked.

The alternative was to rewrite the source of every descendant after a
parent move, and to check each destination against the tree that the
earlier steps produced.  That machinery would carry the undo order
too: `tired--undo-move` restores its pairs in list order, and
`push` already reverses the execution order, so a child-first loop
would have to build its journal the other way.  A listing that holds
a directory and its child is rare, and a message that names the two
paths costs the user one extra command, so the refusal stays.

The check walks the parents of every source, one hash lookup per
level, so a commit of a thousand names reads a few thousand strings
and no file.  A sibling rename beside a parent rename still commits
in one step, because no source of the batch sits under another.
