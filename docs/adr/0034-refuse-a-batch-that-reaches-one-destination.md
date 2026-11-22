# Refuse a batch that reaches one destination twice

`tired-copy` and `tired-move` used to compute each destination inside
the loop that changed the disk.  Two sources from different directories
can carry one base name, so a batch into one directory mapped both onto
one destination.  The later source parked the destination that the
earlier source had just created in the trash, and one `tired-undo`
could not put both sources back: the trash held the first copy, and the
source it came from stayed missing.

The commands now compute every destination first, in
`tired--destination-plan`, and refuse the whole batch with a
`user-error` before any target moves, any destination goes to the
trash, or any undo entry forms.  A last-target-wins rule was the other
candidate, and it fails on the reverse direction: undo would have to
restore two sources from a journal that names one destination twice.
A partial batch was a third, and it leaves the user with a listing that
matches neither the disk nor the plan.

Two destinations count as one when their expanded spellings match, or
when both exist and reach one device and inode.  The inode pair covers
a hard link and a symbolic link that a destination directory already
holds, which one string comparison would miss.  An absent destination
keys on its spelling alone: no file system call settles a case-only
difference before the command creates the file, so a case-insensitive
file system still accepts a batch that two names would merge.  The
alternative was to fold case whenever the destination directory sits on
a case-insensitive file system, and that check needs a volume probe per
batch for a case that a user reaches by accident alone.

The plan is one hash table from source to destination, and the loop
that changes the disk reads the target from it.  Preflight, execution
and the undo journal thus describe one operation, and the executor no
longer recomputes a name that the plan already settled.
