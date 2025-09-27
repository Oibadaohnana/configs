{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    pkgs.vscode
    pkgs.alejandra
    pkgs.gcc
    pkgs.gdb
    pkgs.cmake
  ];
}
