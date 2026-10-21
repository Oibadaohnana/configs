{ pkgs, inputs, ... }:
{
  environment.systemPackages = [
    inputs.dzgui-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
