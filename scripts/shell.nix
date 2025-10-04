{ pkgs ? import <nixpkgs> {}}:

pkgs.mkShell {
  packages = [pkgs.nodejs pkgs.python3];

  inputsFrom = [pkgs.bat ];

  shellHook =  ''
    echo "this is the nix shell!"
    '';


  LD_LIBRARY_PATH =
    "${pkgs.lib.makeLibraryPath [pkgs.ncurses]}";

  
  RUST_BACKTRACE = 1;
}