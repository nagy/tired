# Cache the size of an immutable file

A Git object store gains files without changing the files that it
already holds, because its names carry their content.  The subtree
rule of `tired-persistent-directories` cannot serve it: that rule
answers from one cached total and never reads the directory again, so a
new object would stay invisible.  Every size walk therefore took the
attributes of every object, 8.6 us per name here, and a repository with
fifty thousand objects paid half a second per walk.

A new option, `tired-persistent-files`, holds regexps over the absolute
file name, and a new session table holds path and size.  The walk
consults the table before it reads an attribute, so a warm name costs
two string operations, about 0.3 us.  The table fills from the
attribute read that the walk already makes, and only for a regular
file, so a hit means "regular file, this many bytes" and never a
subtree.

Alternatives were rejected.  A guess from the shape of the name, with
no option, would cache a file that a user edits and keep a wrong size
for the session.  A cache on disk would outlive Emacs and outlive the
rule that a user changed.  The whole attribute list per row costs about
four times the size alone, and the size walk needs the size alone.  A
table of directory totals keyed the same way fails the case that
motivates the option, where a directory gains a child.

Consequences: the first walk of a matched tree pays one extra
`directory-files` call and one match per name, about 20 percent here,
and every later walk drops to one name read per directory.  A row
outlives an edit to the file, so a build that rewrites a name under a
rule keeps the stale size until `tired-clear-caches`.  The rule states
that the name never changes, the way a permanent directory rule states
that a subtree never changes.  `tired--size-walk-whole-read-p` reads a
whole directory only while its pending names make up a third of it,
because `directory-files-and-attributes` costs about a third of one
`file-attributes` call per name.
