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
    # Bank Bobbery. Same account once more, so the same key reaches it, and the
    # same two steps: `bankupdate`, then `bsyssl`.
    bank-bobbery = {
      url = "git+ssh://git@github.com/Oibadaohnana/bankbobbery?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Bims. Same account, so the same key reaches it; only the relay is built
    # from it (`packages.bims-server`), so the box never needs a GPU stack.
    # Two steps to move it: `bimsupdate`, then `bsyssl`.
    bims = {
      url = "git+ssh://git@github.com/Oibadaohnana/bims_bevy?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Grimgobber, the Rust Bank Bobbery at grim.buggly.de. Same account, so the
    # same key reaches it; only the headless server is built from it
    # (`packages.grimgobber-server`). Two steps to move it: `grimupdate`, then
    # `bsyssl`.
    grimgobber = {
      url = "git+ssh://git@github.com/Oibadaohnana/grimgobber?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Shared expenses, split between friends. Same account again, so the same
    # key reaches it, and the same two steps: `splitupdate`, then `bsyss`.
    split = {
      url = "git+ssh://git@github.com/Oibadaohnana/split?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The LAN game shelf with shared votes, at gtp.buggly.de. Same account, so
    # the same key reaches it, and the same two steps: `gtpupdate`, then `bsyss`.
    gtp = {
      url = "git+ssh://git@github.com/Oibadaohnana/games_to_play?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The shared calendar at calendar.buggly.de. Same account, so the same key
    # reaches it, and the same two steps: `calendarupdate`, then `bsyss`.
    calendar = {
      url = "git+ssh://git@github.com/Oibadaohnana/calendar?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Encrypted secrets, decrypted on the server at activation. Public repo or
    # not, an API token with write access to the DNS zone does not belong in
    # git as plaintext -- and /nix/store is world-readable on every machine
    # that builds this, which rules out simply pointing at a file here.
    sops-nix = {
      url = "github:Mic92/sops-nix";
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

      specialArgs = { inherit inputs; };

      modules = [
        ./configuration.nix
        ./fonts.nix
        ./hyprland.nix
        ./garbage_collect.nix
        ./hardware/desktop.nix
        ./vm.nix
        ./ableton.nix
        ./pkgs/dayz/module.nix
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
        ./pkgs/dayz/module.nix
        { networking.hostName = "benji-framework"; }
      ];
    };
    nixosConfigurations."server" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      # Only the modules that package something need inputs, so hand them
      # just those rather than the whole inputs set.
      specialArgs = { inherit (inputs) bobby-dangling worms-whup todo makinglist bank-bobbery split bims grimgobber gtp calendar; };

      modules = [
        inputs.sops-nix.nixosModules.sops
        ./server_configuration.nix
        ./garbage_collect.nix
        ./hardware/server.nix
        { networking.hostName = "benji-server"; }
      ];
    };
  };
}
