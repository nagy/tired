# Read directories with Emacs primitives

Dired parses `ls -l` output.  This package instead calls
`directory-files` and `file-attributes` and keeps the result in
`tired-entry` structs.  The listing therefore has no dependency on an
external binary, its locale, or its quoting rules, and attributes have
types instead of needing a parser.  Alternative shelling out to `ls`
or `find` was rejected: both make the buffer depend on external tool
output and encoding.
