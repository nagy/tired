# 0039 Pass a path to a handler that reads it

## Context

`tired--call-handler` puts the whole file into the temporary buffer
before it calls a handler, because the tree-sitter modes, Org and Emacs
Lisp parse that buffer, and the SQLite and tar handlers read it.  A
handler that needs a range of a file therefore pays for a copy of the
whole file first.

The Parquet handler needs the last few kilobytes alone.  On a
41-megabyte fixture the copy cost 122 ms and a 42-megabyte buffer, while
the footer read and the parse together cost about one millisecond, and a
one-gigabyte file would cost a gigabyte of buffer and seconds of
decoding before the handler ran.

## Decision

A new option, `tired-section-path-handlers`, names the handler symbols
that read the bytes they want from the file name.  `tired--call-handler`
skips the insert for a handler in that list and hands it the empty
buffer.  The list holds symbols and the check is `memq`, so a handler of
another package joins it by name.

The Parquet handler is the one handler that ships in the list.

The same change adds the file size to the key that the section cache
compares, beside the modification time, the handler and its options.  A
tool that rewrites a file and restores its timestamp would otherwise
serve the parse of the bytes before.

## Consequences

Expanding a 41-megabyte Parquet file costs 2.5 ms instead of 136 ms, and
the memory of the listing no longer follows the size of the file that it
shows.

The contract now has two shapes, and a handler that reads the path
itself must join the list or it runs with a buffer that holds the file —
which is safe, and slow.  A handler in the list must not read the buffer
contents, because a later change to `tired--call-handler` may hand it
nothing at all.

`tired-section-file-size-limit` keeps its job for the handlers that do
read the whole file.  It stays nil by default, because a user who opens
a large text file expects the sections of it.
