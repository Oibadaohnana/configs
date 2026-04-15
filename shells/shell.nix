{ pkgs ? import <nixpkgs> {} }:
  pkgs.mkShell {
    nativeBuildInputs = with pkgs.buildPackages; [ 
      python313Packages.python-telegram-bot
      python313Packages.python-telegram
      python313Packages.matplotlib
      python313Packages.pyyaml
      python313Packages.notify2
      python313Packages.click 
      python313Packages.scipy
      python313Packages.tkinter
      python313Packages.pandas
      ruff
      
      #Rust stuff here:
      rustup

      #C# Shi I will never use again...
      dotnetCorePackages.dotnet_8.sdk
      dotnet-sdk_8
      ];
}