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
        ./hyprland.nix
        ./vscode.nix
        ./garbage_collect.nix
        ./hardware/desktop.nix
        ./vm.nix
        { networking.hostName = "benji-desktop"; }
      ];
    };
    nixosConfigurations."benji-framework" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      modules = [
        ./configuration.nix
        ./hyprland.nix
        ./vscode.nix
        ./garbage_collect.nix
        ./hardware/framework.nix
        ./vm.nix
        { networking.hostName = "benji-framework"; }
      ];
    };
  };
} 
