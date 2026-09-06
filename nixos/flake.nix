{
  description = "Fuck Hyperland -- for now";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Private repo -- fetched over ssh with the server's github_serverssh key.
    # ?ref=main pins the branch; the commit itself is pinned in flake.lock, so
    # picking up new work is an explicit `nix flake update robo-rally`.
    robo-rally = {
      url = "git+ssh://git@github.com/Oibadaohnana/robo_rally?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    flake-utils,
    ...
  }: {
    nixosConfigurations."benji-desktop" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      modules = [
        ./configuration.nix
        ./fonts.nix
        ./hyprland.nix
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
        ./fonts.nix
        ./plasma.nix
        ./hyprland.nix
        ./garbage_collect.nix
        ./hardware/framework.nix
        ./vm.nix
        { networking.hostName = "benji-framework"; }
      ];
    };
    nixosConfigurations."server" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      # Only the game module needs an input, so hand it just that one
      # rather than the whole inputs set.
      specialArgs = { inherit (inputs) robo-rally; };

      modules = [
        ./server_configuration.nix
        ./garbage_collect.nix
        ./hardware/server.nix
        { networking.hostName = "benji-server"; }
      ];
    };
  };
}
