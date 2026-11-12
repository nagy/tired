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

      # checkdoc, package-lint and relint catch style, packaging and
      # regexp problems that byte-compilation does not.  Keep this in
      # `checks', not in the package: lint findings must not block an
      # otherwise buildable package forever.
      mkLint =
        { pkgs, src }:
        pkgs.runCommand "tired-lint"
          {
            nativeBuildInputs = [
              (pkgs.emacsPackages.emacsWithPackages (epkgs: [
                epkgs.package-lint
                epkgs.relint
              ]))
            ];
            inherit src;
            meta.description = "tired checkdoc, package-lint and relint checks";
          }
          ''
            export HOME=$TMPDIR
            # The lint surface spans the libraries and the `test/' tree, so
            # copy the whole source rather than a file list.
            cp -r "$src"/. .

            # package-lint exits non-zero on any finding.  The package has
            # no external dependencies, so it needs no package-alist
            # stubs.  The test files carry no `Package-Requires' header,
            # so `package-lint-main-file' names the file that supplies
            # one, and the test files join the run.  tired-evil.el stays
            # out, because a secondary file earns a header warning alone.
            emacs --batch -l package-lint \
              --eval '(setq package-lint-main-file "tired.el")' \
              -f package-lint-batch-and-exit \
              tired.el test/*.el

            # checkdoc and relint exit 0 even when they report
            # problems; gate on output.  The test files join the gate so
            # they keep the header, docstring and prefix rules.
            for file in tired.el tired-core.el tired-sections.el \
              tired-elements.el tired-file-ops.el tired-export.el \
              tired-evil.el test/*.el; do
              doc=$(emacs --batch -l checkdoc \
                --eval "(checkdoc-file \"$file\")" 2>&1)
              if [ -n "$doc" ]; then
                printf '%s\n' "$doc"
                exit 1
              fi
            done

            # relint reads a Lisp form and a file, so give it one file
            # per run.  A regexp finding prints a line for each problem.
            for file in tired.el tired-core.el tired-sections.el \
              tired-elements.el tired-file-ops.el tired-export.el \
              tired-evil.el test/*.el; do
              report=$(emacs --batch -l relint \
                --eval "(relint-file \"$file\")" 2>&1)
              if [ -n "$report" ]; then
                printf '%s\n' "$report"
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
          # The package stays overridable, so a consumer can swap the
          # Emacs, the evil package or the grammar set:
          #   inputs.tired.packages.${system}.tired.override {
          #     emacs = pkgs.emacs-nox;
          #   }
          # The flake passes the commit-derived version, because a plain
          # import of the expression cannot know it.
          tired = pkgs.lib.makeOverridable (
            {
              # One Emacs package set supplies every dependency, so
              # an override of this argument moves all of them.
              emacs ? pkgs.emacs,
              # `melpaBuild' closes over the Emacs of its package set, so
              # an `emacs' argument on the build does nothing.  Build the
              # set against a wrapper instead, one that carries evil on
              # its load path, so the install byte-compile and the ERT
              # suite find the library without an EMACSLOADPATH export.
              emacsPackages ? pkgs.emacsPackagesFor (emacs.pkgs.withPackages (_: [ evil ])),
              melpaBuild ? emacsPackages.melpaBuild,
              version ? "0.1.0",
              # Tree-sitter grammars for the check phase only.  A handler
              # whose grammar is absent returns no sections, so the file
              # row stays plain and the ERT test skips itself.  A null value
              # keeps the build small and still passes.
              treesitGrammars ? emacs.pkgs.treesit-grammars.with-grammars (p: [
                p.tree-sitter-rust
                p.tree-sitter-go
                p.tree-sitter-markdown
                p.tree-sitter-markdown-inline
                p.tree-sitter-python
                p.tree-sitter-toml
              ]),
              # Evil reaches the build Emacs only.  tired-evil.el needs the
              # library to byte-compile, and the ERT suite tests its key
              # bindings, so the build cannot drop it.  The package metadata
              # still names no dependency.
              evil ? emacs.pkgs.evil,
            }:
            melpaBuild {
              pname = "tired";
              inherit version;
              # `./.' is the repository root.  cleanSource drops VCS metadata
              # and editor backup files, so only real package sources enter
              # the store.
              src = pkgs.lib.cleanSource ./.;

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

              # The ERT suite reads this variable, so the Rust and Go
              # handler tests find their grammar and do not skip.
              checkInputs = pkgs.lib.optional (treesitGrammars != null) treesitGrammars;

              checkPhase = ''
                runHook preCheck
                # The archive tests compress a fixture with zstd and read
                # it back through jka-compr.  A check input does not reach
                # the path of this build, so the path grows here.
                export PATH="${pkgs.lib.makeBinPath [ pkgs.zstd ]}:$PATH"
                ${pkgs.lib.optionalString (treesitGrammars != null) ''
                  export TREESIT_EXTRA_LOAD_PATH="${treesitGrammars}/lib"
                ''}
                # Byte-compile the libraries and the suites together, so a
                # test file keeps the same warning-free bar as its library.
                emacs --batch -L . -L test \
                  --eval '(setq byte-compile-error-on-warn t)' \
                  -f batch-byte-compile *.el test/*.el
                # Glob the suites instead of listing them: a new
                # `test/<unit>-test.el' needs no flake edit.  failglob makes
                # an empty glob a shell error, so the `||' guard fires even
                # without `set -e'.  The unquoted $test_args is intentional:
                # the words split back into `-l <file>' pairs, and test file
                # names hold no spaces.
                shopt -s failglob
                test_args=$(printf -- "-l %s " test/*-test.el) || { echo 'no tests matched test/*-test.el' >&2; exit 1; }
                shopt -u failglob
                emacs --batch -L . -L test \
                  $test_args \
                  -f ert-run-tests-batch-and-exit
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
                license = pkgs.lib.licenses.agpl3Plus;
                homepage = "https://github.com/nagy/tired";
                maintainers = with pkgs.lib.maintainers; [ nagy ];
                # Pure Elisp and no native dependency, so Linux and Darwin
                # both work.
                platforms = pkgs.lib.platforms.unix;
              };
            }
          ) { inherit version; };
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
              # outside Nix too, and zstd builds the archive fixtures.
              (pkgs.emacsPackages.emacsWithPackages (epkgs: [ epkgs.evil ]))
              pkgs.git
              pkgs.zstd
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
