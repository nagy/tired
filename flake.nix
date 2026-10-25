{
  description = "Tabulated list directory editor for Emacs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      flake-parts,
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
      # Elisp is architecture-independent, so evaluate on every Linux
      # architecture at no extra cost.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
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
            inherit tired;
            # checkdoc and package-lint catch what compilation cannot.
            lint = pkgs.callPackage ./nix/lint.nix { inherit (tired) src; };
          };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.emacs
              pkgs.git
            ];
          };

          formatter = pkgs.nixfmt;
        };
    };
}
