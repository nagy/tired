# Exclude a directory from the recursive size walk by regexp

`file-remote-p` names a TRAMP path alone.  A directory that a local mount
serves, such as a network mount, answers no handler and looks local, so
the idle size walk reads a whole network tree and a listing of its parent
freezes Emacs.  `tired-directory-size-exclude` holds regexps, and
`tired--size-skip-p` answers every size question with the remote check and
that list together: the size cell, the empty-directory mark, the mode line
byte sum, the queue and the walk.

Alternatives were rejected.  A list of directory names alone cannot cover
the subtree of a mount without a second walk of the mount to collect its
children.  A walk that only stops below a mount still reads the mount
itself and still shows a number that hides bytes.  A timeout or a budget on
one directory read cannot stop a read that a file system blocks inside.

## Consequences

An excluded directory takes no walk, shows an empty size cell, adds no byte
to the total of a parent directory and counts as no byte in the mode line.
It keeps the plain directory face, because the empty-directory mark needs a
total, the same way a remote directory does.  A regexp matches the absolute
name with and without a trailing slash, so one rule covers a subtree and a
string-end anchor covers one directory alone.

The walk tests a child against `tired--size-excluded-p` alone, because a
`file-remote-p` call per child costs one handler lookup per directory.  The
Elements column, the single-child collapse, the watches and the section
handlers keep their own guards, so an excluded directory still counts its
items and still collapses.
