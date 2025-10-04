{
  description = "Fuck Hyperland -- for now";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    vscode-server.url = "github:nix-community/nixos-vscode-server";
  };

  outputs = { self, nixpkgs, flake-utils, vscode-server, ... }: {
    nixosConfigurations."benji" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      modules = [
        vscode-server.nixosModules.default
        ./configuration.nix
        ./hardware-configuration.nix
        ./vscode.nix
        #./emacs.nix
        ./sway.nix
        ({ config, pkgs, ... }: {
          services.vscode-server.enable = true;
        })
      ];
    };
  };
}