{
  description = "Pounce — keyboard-driven navigation for macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
      modules = import ./nix/modules.nix self;
    in
    {
      packages = forAll (pkgs: {
        default = pkgs.callPackage ./nix/package.nix {
          commit = self.shortRev or self.dirtyShortRev or "unknown";
        };
      });

      apps = forAll (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/pounce";
        };
      });

      # Uses the host Xcode/CLT toolchain for fast iteration (SourceKit, newer Swift).
      devShells = forAll (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            pkgs.nixfmt
            pkgs.swift-format
          ];
        };
      });

      darwinModules.default = modules.darwin;
      homeManagerModules.default = modules.homeManager;

      formatter = forAll (pkgs: pkgs.nixfmt);
    };
}
