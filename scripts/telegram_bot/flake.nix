{
  description = "Python Telegram Bot Dev Shell (with matplotlib)";

  inputs = {
    # Pin nixpkgs to nixos-24.05 release branch (Sept 2024) → Tcl 8.6
    nixpkgs.url = "github:NixOS/nixpkgs/release-24.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Pick the Python version
        python = pkgs.python311;

        # Define your Python environment
        pythonEnv = python.withPackages (ps: with ps; [
          python-telegram-bot
          matplotlib
          pyyaml
        ]);
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [ pythonEnv ];
        };
      });
}
