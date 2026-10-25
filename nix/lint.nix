{
  pkgs,
  src,
}:

# checkdoc and package-lint catch style and packaging problems that
# byte-compilation does not.  Keep this in `checks', not in the package:
# lint findings must not block an otherwise buildable package forever.
pkgs.runCommand "tired-lint"
  {
    nativeBuildInputs = [
      (pkgs.emacsPackages.emacsWithPackages (epkgs: [ epkgs.package-lint ]))
    ];
    inherit src;
    meta.description = "tired checkdoc and package-lint checks";
  }
  ''
    export HOME=$TMPDIR
    cp "$src"/tired.el .

    # package-lint exits non-zero on any finding.  The package has no
    # external dependencies, so it needs no package-alist stubs.
    emacs --batch -l package-lint -f package-lint-batch-and-exit tired.el

    # checkdoc exits 0 even when it reports problems; gate on output.
    doc=$(emacs --batch -l checkdoc --eval '(checkdoc-file "tired.el")' 2>&1)
    if [ -n "$doc" ]; then
      printf '%s\n' "$doc"
      exit 1
    fi

    touch $out
  ''
