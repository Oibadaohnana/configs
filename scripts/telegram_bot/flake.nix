{
  description = "Python Telegram Bot Dev Shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        python = pkgs.python311;
        pythonEnv = python.withPackages (ps: with ps; [
          python-telegram-bot
          # add other libs here
        ]);
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [ pythonEnv ];
        };
      });
}
