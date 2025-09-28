{
  description = "Flake for C# development environment";

  inputs.nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

  outputs = { self, nixpkgs}:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          mono
          dotnet-sdk
          omnisharp-roslyn
          ];
        shellHook = ''
          echo "Welcome to the devShell!"
        '';
      };
    };
}