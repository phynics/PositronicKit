{
  description = "SPM Project Dev Shell with Auto-Build";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.swift
            pkgs.swiftpm
            pkgs.apple-sdk_26
          ];

          shellHook = ''
            echo "🍎 Setting up Swift environment for macOS..."
            echo "🚀 Building targets..."
            swift build -c release
          '';
        };
      }
    );
}
