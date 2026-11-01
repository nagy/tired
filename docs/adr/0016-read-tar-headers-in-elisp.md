# Read tar headers in Elisp and let `jka-compr` decompress

Bug a8979eb proposes one `call-process` per archive format: `tar -tf`,
`unzip -Z1` and `7z l`.  Tired starts with the tar family, `.tar`,
`.tar.gz` and `.tar.zst`, and that plan costs more than it returns for
this format.

Emacs already reads a tar in two layers.  `insert-file-contents` sends
a compressed suffix through `jka-compr`, so the handler in
`tired--call-handler` receives the decompressed tar bytes for all
three suffixes.  Emacs 31 carries the `zstd` entry itself, so `.tar.zst`
needs that program but no code of ours.  A tar header then costs a loop
over 512-byte blocks, and `tar-mode` in the same Emacs parses pax and
GNU long names, so the format rules are known.

Decision: `tired-file-sections-tar` parses the 512-byte headers itself.
It reads the name field, the ustar prefix, the type flag, an octal or a
GNU base-256 size, the GNU long-name `L` record and the pax `x` and `g`
records for `path`, `size` and `linkpath`.  The handler sets the buffer
unibyte, because a header holds NUL bytes and the byte offsets decide
every block.

Every member becomes a section with a synthetic `:line` ordinal, a
`:level` from the depth of its path and a `:kind` of `directory` or
`file`.  The action re-reads the archive, slices the bytes of the data
block, writes them to a temporary file and visits that copy.  So
extraction needs no `tar` program either.  A directory and a link
refuse, because they hold no bytes, and a name that leaves the archive
reads as no member.

`tired-section-file-size-limit` guards the read, because
`tired--call-handler` loads the whole file before a handler runs.  A
skipped file writes no section cache entry, so a raised limit takes
effect on the next redraw.

Rejected alternatives: `call-process "tar" "-tf"`, which lists 20,000
members in 0.03 s against 0.17 s for the Elisp walk, because those
0.14 s buy a runtime dependency, name quoting trouble and a tool that
must exist on every machine; the `tar-mode` index, which is fewer lines
and handles pax, because it leans on private variables, invents a
`buffer-file-name`, leaves a `*tar-data*` buffer to clean and stores
marker offsets in another buffer; a background `make-process`, because
the section read is synchronous and cached by modification time, so a
0.2 s parse needs no queue, no placeholder row and no reprint; a
sparse-file map, because a sparse member reads as an empty file and no
archive from a normal `tar` run needs one.

Consequences: one parser serves `.tar`, `.tar.gz` and `.tar.zst`, and a
user with Emacs 31 and the `zstd` program expands any of them.  A
member label shows the base name, so the level carries the path.  The
`.zip` and `.7z` handlers stay open in the bug, and `archive-mode` is
the same precedent for a zip read in Elisp.  The Elements column counts
the members at depth zero through its section fallback, so the count
lands with no dissector.  A tar of one million members costs seconds in
one redraw, and that is the point where the Elements queue becomes the
answer.
