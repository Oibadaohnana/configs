{
  description = "Fuck Hyperland -- for now";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Private repo -- fetched over ssh with the server's github_serverssh key.
    # ?ref=main pins the branch; the commit itself is pinned in flake.lock, so
    # picking up new work is an explicit `nix flake update bobby-dangling`.
    bobby-dangling = {
      url = "git+ssh://git@github.com/Oibadaohnana/bobby_dangling?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Same account, so the same github_serverssh key already reaches it. Pinned
    # and bumped the same way: `wormsupdate`, then `bsyss`.
    worms-whup = {
      url = "git+ssh://git@github.com/Oibadaohnana/worms_whup?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The to-do list. Same account again, so the same key already reaches it,
    # and the same two steps to move it: `todoupdate`, then `bsyss`.
    todo = {
      url = "git+ssh://git@github.com/Oibadaohnana/todo?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The recipe book. Same account once more, so the same key reaches it, and
    # the same two steps: `makinglistupdate`, then `bsyss`.
    makinglist = {
      url = "git+ssh://git@github.com/Oibadaohnana/makinglist?ref=main";
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

      # Only the modules that package something need inputs, so hand them
      # just those rather than the whole inputs set.
      specialArgs = { inherit (inputs) bobby-dangling worms-whup todo makinglist; };

      modules = [
        ./server_configuration.nix
        ./garbage_collect.nix
        ./hardware/server.nix
        { networking.hostName = "benji-server"; }
      ];
    };
  };
}
