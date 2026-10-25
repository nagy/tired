# Trash-backed file operations with an undo hook

Copy, move, delete, mkdir and touch act at once.  They ask no
confirmation question and they never call a shell.  Delete moves each
path into `tired-trash-directory`, a session directory under
`temporary-file-directory`.  A copy or a move that replaces an
existing path moves the old path into that trash first.  Each command
hands one undo function to `tired-undo-push-functions`.  While that
hook is empty, the function waits on `tired--undo-actions` for
`tired-undo`.

Rejected alternatives: a confirmation prompt per delete, because the
command should be immediate and an undo system should reverse a
mistake; the freedesktop trash with `.trashinfo` files, because it
needs a spec implementation and a per-volume rule for the same undo
guarantee; the system trash through `move-file-to-trash`, because
Emacs does not report the destination, so undo cannot find the path
again.  Refusing an existing destination was rejected as well, because
trashing the old path keeps the action immediate and keeps undo
complete.

Consequences: the trash sits on another file system in the common
case, so Emacs copies and deletes a large tree instead of renaming it;
a path deleted before a reboot cannot come back after the reboot; the
trash holds bytes until the system clears `/tmp`; and undo of an
overwriting copy also leaves the replaced copy in the trash.
