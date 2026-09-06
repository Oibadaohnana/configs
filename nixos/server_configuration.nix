{
  config,
  lib,
  pkgs,
  ...
}: {
  # The server's own layers. Kept here, not in flake.nix, so adding a game
  # touches the server config instead of the top-level flake.
  imports = [
    ./server/web.nix
    ./server/games/robo-rally.nix
  ];

  nix.settings.experimental-features = ["nix-command" "flakes"];

  nixpkgs.config.allowUnfree = true;

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    # compinit moved into configs/zshrc so it can run cached (-C). This only
    # drops the /etc/zshrc call -- enableCompletion still links share/zsh and
    # pulls nix-zsh-completions, so fpath is unchanged.
    enableGlobalCompInit = false;
    # prompt suse costs ~7ms and configs/zshrc overrides PROMPT right after.
    promptInit = "";
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
    shellAliases = {
      ll = "ls -l";
      edit = "sudo -e";
      update = "sudo nixos-rebuild switch";
    };

    histSize = 10000;
    histFile = "$HOME/.zsh_history";
    setOptions = [
      "HIST_IGNORE_ALL_DUPS"
    ];
  };

  environment.systemPackages = with pkgs; [
    micro
    git
    btop
    unrar
  ];

  environment.sessionVariables = {
    EDITOR = "micro";
    VISUAL = "micro";
    MICRO_TRUECOLOR = "1";
  };

  # System basics
  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "de_DE.UTF-8";
    LC_IDENTIFICATION = "de_DE.UTF-8";
    LC_MEASUREMENT = "de_DE.UTF-8";
    LC_MONETARY = "de_DE.UTF-8";
    LC_NAME = "de_DE.UTF-8";
    LC_NUMERIC = "de_DE.UTF-8";
    LC_PAPER = "de_DE.UTF-8";
    LC_TELEPHONE = "de_DE.UTF-8";
    LC_TIME = "de_DE.UTF-8";
  };
  console.keyMap = "de";

  users.users.benji = {
    isNormalUser = true;
    description = "Benjamin Wüst";
    shell = pkgs.zsh;
    # headless: no networkmanager/plugdev/adbusers here. Those groups only exist
    # when their services are enabled, and usermod fails on a missing group.
    extraGroups = ["wheel"];
    # Must exist before first boot -- without it useradd locks the account and
    # sshd refuses the login. Also what sudo prompts for. mkpasswd -m sha-512.
    hashedPassword = "$6$9xpPGismIJ/t4QFb$troHqmzQlmy2roQ.wdL/6QDpxy9EIkcfEzYdiqirre7Bc2OB81Eb1fD5jNMnPQjX1vBLCjrjMDQhrdtrV84fI1";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOUaqYeDiY5Iabghr9SqChM+gpq0MNxvp6eguzzKHSGR bennywuest@gmail.com"
    ];
  };

  # Bootloader
  boot.loader.grub = { enable = true; device = "/dev/vda"; };

  # System version
  system.stateVersion = "25.05";

  # Unlike the desktop, sshd MUST start at boot -- it is the only way in. Do not
  # copy the sshon/sshoff wantedBy override from configuration.nix.
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      # key-only; the authorizedKeys above is the sole remote credential.
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = ["benji"];
      MaxAuthTries = 3;
      # authfail blocks the source IP for an hour -- no local console to fall
      # back on here, so a fumbled login means waiting it out.
      PerSourcePenalties = "crash:3600s authfail:3600s max:86400s";
    };
  };

  # Nix fetches the private robo_rally flake input over ssh at build time, and
  # with --build-host that fetch happens here, as benji. System-wide so it does
  # not depend on a hand-written ~/.ssh/config surviving a reinstall.
  programs.ssh.extraConfig = ''
    Host github.com
      User git
      IdentityFile /home/benji/.ssh/github_serverssh
      IdentitiesOnly yes
  '';
}
