{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    kdePackages.kate
    omnisharp-roslyn
    kdePackages.konsole
    dotnet-sdk
    mono
    ];
}
