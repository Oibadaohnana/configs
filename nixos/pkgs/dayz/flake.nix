{
  description = "Terminal browser for DayOne and official DayZ servers";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system}.default = pkgs.callPackage ./package.nix { };
      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/dayz";
      };
      nixosModules.default = ./module.nix;
    };
}
