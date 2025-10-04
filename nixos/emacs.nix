{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Emacs with packages
    (pkgs.emacs.pkgs.withPackages (epkgs: with epkgs; [
      use-package
      magit
      vertico
      orderless
      consult
      which-key
      doom-themes
      projectile
      lsp-mode
      vterm 
    ]))

    # Language servers and tools
    rust-analyzer
    pyright
    nodePackages.typescript-language-server
    nodePackages.prettier
    black
    isort
  ];
}
