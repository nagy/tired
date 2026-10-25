{
  lib,
  emacsPackages,
  melpaBuild ? emacsPackages.melpaBuild,
  # The flake passes the version derived from the commit date.  Keep a
  # plain default so the expression also evaluates outside the flake.
  version ? "0.1.0",
}:

melpaBuild {
  pname = "tired";
  inherit version;
  # `./..' is the repository root.  cleanSource drops VCS metadata and
  # editor backup files, so only real package sources enter the store.
  src = lib.cleanSource ./..;

  # No external Elisp packages; everything used ships with Emacs.
  packageRequires = [ ];

  # The installed directory name comes from `pname' + `version', while
  # package.el reads `;; Version:' from the header.  Keep both equal so
  # package-lint, package.el and the store path agree.
  postPatch = ''
    substituteInPlace tired.el \
      --replace-fail ';; Version: 0.1.0' ';; Version: ${version}'
  '';

  # A byte-compile warning fails the build.  This is the cheapest lint
  # the package gets, and it keeps the source warning-free.
  turnCompilationWarningToError = true;

  checkPhase = ''
    runHook preCheck
    emacs --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile tired.el tired-tests.el
    emacs --batch -L . -l tired-tests.el -f ert-run-tests-batch-and-exit
    runHook postCheck
  '';

  doCheck = true;

  meta = {
    description = "Tabulated list directory editor";
    longDescription = ''
      Shows a directory as a `tabulated-list-mode' buffer.  Entries come
      from `directory-files' and `file-attributes', so the listing never
      parses `ls -l' output.  Provides column sorting, name filtering,
      hidden file toggling, and a transient selection that file commands
      act on.
    '';
    license = lib.licenses.agpl3Plus;
    homepage = "https://github.com/nagy/tired";
    maintainers = with lib.maintainers; [ nagy ];
    # Pure Elisp and no native dependency, so Linux and Darwin both work.
    platforms = lib.platforms.unix;
  };
}
