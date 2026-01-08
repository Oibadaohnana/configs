{
  description = "Fuck Hyperland -- for now";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils,... }: {
    nixosConfigurations."benji-desktop" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      modules = [
        ./configuration.nix
        ./vscode.nix
        ./hardware/desktop.nix
        { networking.hostName = "benji-desktop"; }
      ];
    };
    nixosConfigurations."benji-framework" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      modules = [
        ./configuration.nix
        ./vscode.nix
        ./hardware/framework.nix
        { networking.hostName = "benji-framework"; }
      ];
    };
  };
} 
