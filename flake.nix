{
  description = "Tabulated list directory editor for Emacs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    # Single formatter entry point for the repo: `nix fmt` formats every
    # tracked file with the configured programs.
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{
      flake-parts,
      treefmt-nix,
      ...
    }:
    let
      # Date of the last commit as YYYY-MM-DD, folded into the version
      # string.  Flake source info gives it as e.g. "20260922133522";
      # slice out the year, month and day.  A plain path import has no
      # git metadata, so fall back to the epoch instead of failing.
      sourceInfo = inputs.self.sourceInfo or { };
      lastModifiedDate = sourceInfo.lastModifiedDate or "19700101000000";
      commitDate = "${builtins.substring 0 4 lastModifiedDate}-${
        builtins.substring 4 2 lastModifiedDate
      }-${builtins.substring 6 2 lastModifiedDate}";
      version = "0.1.0-unstable-${commitDate}";

      # The package expression takes its dependencies as arguments, so
      # the flake can pass the commit-derived version and the grammar
      # set, and a plain `callPackage' elsewhere still evaluates.
      mkTired =
        {
          lib,
          emacsPackages,
          melpaBuild ? emacsPackages.melpaBuild,
          # Tree-sitter grammars for the check phase only.  A handler
          # whose grammar is absent returns no sections, so the file
          # row stays plain and the ERT test skips itself.  A null value
          # keeps the build small and still passes.
          treesitGrammars ? emacsPackages.treesit-grammars.with-grammars (p: [
            p.tree-sitter-rust
            p.tree-sitter-markdown
            p.tree-sitter-markdown-inline
          ]),
          # Evil is optional at run time.  The evil bindings live in
          # tired-evil.el, which needs the library to byte-compile.  A
          # null value keeps the build free of evil, and the ERT test
          # skips itself.
          evil ? null,
          # The flake passes the version derived from the commit date.
          # Keep a plain default so the expression also evaluates outside
          # the flake.
          version ? "0.1.0",
        }:

        melpaBuild {
          pname = "tired";
          inherit version;
          # `./.' is the repository root.  cleanSource drops VCS metadata
          # and editor backup files, so only real package sources enter
          # the store.
          src = lib.cleanSource ./.;

          # No external Elisp packages; everything used ships with Emacs.
          # The package never requires evil: tired-evil.el only loads
          # when the user asks for the evil bindings.
          packageRequires = [ ];

          # The install phase compiles every file, so tired-evil.el
          # needs evil on the load path there.  The wrapped build Emacs
          # merges EMACSLOADPATH from the environment.
          preInstall = lib.optionalString (evil != null) ''
            export EMACSLOADPATH="${evil}/share/emacs/site-lisp/elpa/evil-${evil.version}:''${EMACSLOADPATH-}"
          '';

          # The installed directory name comes from `pname' + `version',
          # while package.el reads `;; Version:' from the header.  Keep
          # both equal so package-lint, package.el and the store path
          # agree.
          postPatch = ''
            substituteInPlace tired.el \
              --replace-fail ';; Version: 0.1.0' ';; Version: ${version}'
          '';

          # A byte-compile warning fails the build.  This is the cheapest
          # lint the package gets, and it keeps the source warning-free.
          turnCompilationWarningToError = true;

          # The ERT suite reads this variable, so the Rust handler test
          # finds libtree-sitter-rust and does not skip.
          checkInputs = lib.optional (treesitGrammars != null) treesitGrammars;

          checkPhase = ''
            runHook preCheck
            ${lib.optionalString (treesitGrammars != null) ''
              export TREESIT_EXTRA_LOAD_PATH="${treesitGrammars}/lib"
            ''}
            ${lib.optionalString (evil != null) ''
              export EMACSLOADPATH="${evil}/share/emacs/site-lisp/elpa/evil-${evil.version}:''${EMACSLOADPATH-}"
            ''}
            emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
              -f batch-byte-compile tired.el tired-evil.el tired-tests.el
            emacs --batch -L . -l tired-tests.el -f ert-run-tests-batch-and-exit
            runHook postCheck
          '';

          doCheck = true;

          meta = {
            description = "Tabulated list directory editor";
            longDescription = ''
              Shows a directory as a `tabulated-list-mode' buffer.  Entries
              come from `directory-files' and `file-attributes', so the
              listing never parses `ls -l' output.  Provides column
              sorting, name filtering, hidden file toggling, and a
              transient selection that file commands act on.
            '';
            license = lib.licenses.agpl3Plus;
            homepage = "https://github.com/nagy/tired";
            maintainers = with lib.maintainers; [ nagy ];
            # Pure Elisp and no native dependency, so Linux and Darwin
            # both work.
            platforms = lib.platforms.unix;
          };
        };

      # checkdoc and package-lint catch style and packaging problems that
      # byte-compilation does not.  Keep this in `checks', not in the
      # package: lint findings must not block an otherwise buildable
      # package forever.
      mkLint =
        { pkgs, src }:
        pkgs.runCommand "tired-lint"
          {
            nativeBuildInputs = [
              (pkgs.emacsPackages.emacsWithPackages (epkgs: [
                epkgs.package-lint
              ]))
            ];
            inherit src;
            meta.description = "tired checkdoc and package-lint checks";
          }
          ''
            export HOME=$TMPDIR
            for file in tired.el tired-evil.el; do
              cp "$src/$file" .
            done

            # package-lint exits non-zero on any finding.  The package has
            # no external dependencies, so it needs no package-alist
            # stubs.  It only accepts the main file, so tired-evil.el
            # goes through checkdoc alone.
            emacs --batch -l package-lint -f package-lint-batch-and-exit tired.el

            # checkdoc exits 0 even when it reports problems; gate on
            # output.
            for file in tired.el tired-evil.el; do
              doc=$(emacs --batch -l checkdoc \
                --eval "(checkdoc-file \"$file\")" 2>&1)
              if [ -n "$doc" ]; then
                printf '%s\n' "$doc"
                exit 1
              fi
            done

            touch $out
          '';
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ treefmt-nix.flakeModule ];
      # Pure Elisp, so every supported architecture works and Darwin
      # needs no extra native dependencies.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        {
          pkgs,
          config,
          ...
        }:
        let
          tired = pkgs.callPackage mkTired {
            inherit version;
            inherit (pkgs.emacsPackages) evil;
          };
        in
        {
          packages = {
            tired = tired;
            default = tired;
          };

          checks = {
            # melpaBuild byte-compiles with warnings as errors and runs
            # the ERT suite in checkPhase, so the package is the check.
            default = tired;
            # checkdoc and package-lint catch what compilation cannot.
            lint = pkgs.callPackage mkLint { inherit (tired) src; };
          };

          devShells.default = pkgs.mkShell {
            packages = [
              # The evil package lets the ERT tests for tired-evil.el run
              # outside Nix too.
              (pkgs.emacsPackages.emacsWithPackages (epkgs: [ epkgs.evil ]))
              pkgs.git
              config.treefmt.build.wrapper
            ];
          };

          # nixfmt only.  Elisp has no formatter in this stack, so the
          # sources stay untouched and checkdoc/package-lint guard style.
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
          };
        };
    };
}
