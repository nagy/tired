# Collapse single-entry directory chains eagerly

A directory whose subtree holds exactly one file shows as one row for
that file, named relative to the listed directory.  The row uses the
file attributes and keeps the directory's sort position.  Every listed
directory gets inspected on refresh, and the inspection stops at the
first branch.  Alternatives were rejected: inspecting only inserted
sections hides the collapse until the user expands a path, and an
on-demand command keeps the tree noisy by default.  Consequences: one
`directory-files` call per listed directory per refresh, a cache that
lives until the next refresh, and a row whose sort key follows the
directory while its columns show the file.
