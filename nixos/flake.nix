{
  description = "Fuck Hyperland -- for now";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }: {
    nixosConfigurations."benji" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      modules = [
        ./configuration.nix
        ./hardware-configuration.nix
        ./vscode.nix
        ./kate.nix
        ./sway.nix
      ];
    };
  };
}