# 0038 Read a Parquet footer in Elisp

## Context

A Parquet file is a binary container, so the listing needs a way to
show its schema.  The two candidates were a pure Elisp reader of the
metadata at the end of the file, and an external tool — `duckdb`’s SQL
functions, `pqrs` or `parquet-tools` — driven by `call-process`.

`tired-elements.el` already read the Parquet footer to fill the
Elements column with the row count.  It carried a Thrift compact
protocol reader: `tired--thrift-byte`, `-varint`, `-zigzag`, `-skip`,
`-skip-struct` and the depth limit, plus the tail magic check and a
byte range reader.  The layers that were missing were the
`SchemaElement` struct, the `FileMetaData` fields and the tree.

## Decision

Read the footer in Elisp, in a new bottom-layer library
`tired-parquet.el`, and let `tired-elements.el` and `tired-sections.el`
require it.

The reader stops at field 4 of `FileMetaData`.  Field 6 holds the name
of the writer, but it lies behind the row groups, and walking those
costs 700 ms on a file of 2000 row groups where the stop costs one.  The
count of row groups comes from the header of the list at field 4.

A LIST or MAP field inserts a `REPEATED` group named `list` or
`key_value`, and that row carries no fact that the parent does not
already show, so the handler hides it and lifts its child one level.  A
group without a logical type prints `STRUCT`, which the format names
nowhere.

## Consequences

A 41-megabyte file shows its schema in about a millisecond, because the
reader touches the eight byte tail and the footer alone.  Nothing enters
the package closure, so a user who never opens a Parquet file pays
nothing, and the handler returns nil when a file has no footer rather
than naming a program that it could not find.

`bindat` cannot do this work.  A Bindat type describes a layout that the
bytes before it fix, and every integer of the compact protocol is a
varint whose width its value decides.  A field id is a delta against the
field before it, a bool lives in the field header and takes no value
byte, and a footer that arrives in chunks needs a reader that says "read
more".  The only fixed layout in a Parquet file is the eight byte tail,
which the reader spells out in five lines.

`duckdb` would have brought one feature that this reader has not: a
column row could open a SQL session over the file.  It would also have
brought a 69-megabyte runtime dependency, a version-pinned output format
and a SQL string that a file name could escape.  `pqrs` and
`parquet-tools` flatten the schema into a list of leaf columns, so
neither shows the nesting that a struct or a list needs.

The cost is that `created_by` stays out of the title row, because it
sits behind the row groups, and that a footer above
`tired-parquet-footer-limit` shows nothing.  See `docs/adr/0039` for the
handler contract that keeps the read cheap, and `docs/adr/0016` for the
same choice on tar headers.
