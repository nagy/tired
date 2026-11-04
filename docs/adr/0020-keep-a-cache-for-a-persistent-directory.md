# Keep a cache for a directory whose content never changes

A Nix store path, an IPFS mount point and a container image directory carry
their hash in the name, so no byte below them changes.  The two cache
windows do not know that.  `tired-size-cache-ttl` drops the total of a
store path after 60 seconds, and `tired-refresh` queues a walk of every
directory that it shows, so a listing of `/nix/store` reads thousands of
subtrees at every `g` and again after every window.  The same holds for the
element counts of the files there, through `tired-elements-cache-ttl`.

`tired-persistent-directories` holds regexps, and `tired--persistent-p`
matches an absolute name with and without a trailing slash, the way
`tired-directory-size-exclude` matches.  One rule covers a subtree, and a
string-end anchor covers one directory alone.

Two tables, not one with a flag.  `tired--size-cache-permanent` and
`tired--elements-cache-permanent` take the entries of a written path, and
the windowed tables keep their own.  The alternative was one table whose
prune skips a key that matches a rule.  That shape puts
`tired--persistent-p` inside the prune loop, which runs on every refresh
and calls `expand-file-name` twice per key, and it leaves every read site
one predicate away from a rule match.  Two tables keep the prune of the
windowed table unchanged, spend the one match at the write site, which runs
once per walk, and let a read answer with two hash lookups and no match at
all.

The permanent tables held one entry per walked directory, so the first
listing of a root pays one walk of every directory that the listing shows,
and no later listing pays one.  `tired--size-enqueue` skips a key that the
permanent table holds, before the FORCE of `tired-refresh` and before the
age test, so a refresh of a persistent root queues no walk.

## Consequences

A total outlives a change inside the subtree, and the rule states that no
such change happens.  A path that the disk no longer holds keeps its stale
total, which no row prints, and a rule that leaves the list flushes both
permanent tables at the next refresh: `tired--size-cache-prune` and
`tired--elements-prune` each compare the value they filled under.  The
command `tired-clear-caches` empties every table, windowed and permanent,
so a wrong rule costs one command and not a restart.

A path under a rule takes no auto-revert watch, because no change arrives
there, so a new child of a watched root reaches the listing through
`tired-refresh` alone.  The permanent tables live for the Emacs session, so
the memory grows with what a read reached and never shrinks; a nil value
keeps the bound of the two windows.
