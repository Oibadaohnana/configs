{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    pkgs.vscode
    dotnet-sdk_8
    dotnetCorePackages.dotnet_8.sdk
    vscode-extensions.ms-dotnettools.csharp
    vscode-extensions.ms-dotnettools.csdevkit
    /* pkgs.alejandra
    pkgs.gcc
    pkgs.gdb
    pkgs.cmake
    mono
    dotnet-sdk
    omnisharp-roslyn
    dotnet-sdk_8
    dotnet-runtime_8
    dotnetCorePackages.dotnet_8.sdk
    dotnetCorePackages.dotnet_9.sdk
    vscode-extensions.ms-dotnettools.csharp
    vscode-extensions.ms-dotnettools.csdevkit */
  ];
}
