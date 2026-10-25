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
          # Package expression lives in nix/ to keep this file lean.
          tired = pkgs.callPackage ./nix/default.nix { inherit version; };
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
            lint = pkgs.callPackage ./nix/lint.nix { inherit (tired) src; };
          };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.emacs
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
