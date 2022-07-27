{ lib, pkgs, config, ... }:

with builtins; with lib;
{
  options.wsl = with types;
    let
      coercedToStr = coercedTo (oneOf [ bool path int ]) (toString) str;
    in
    {
      enable = mkEnableOption "support for running NixOS as a WSL distribution";
      automountPath = mkOption {
        type = str;
        default = "/mnt";
        description = "The path where windows drives are mounted (e.g. /mnt/c)";
      };
      automountOptions = mkOption {
        type = str;
        default = "metadata,uid=1000,gid=100,umask=22,fmask=11,case=dir";
        description = "Options to use when mounting windows drives";
      };
      defaultUser = mkOption {
        type = str;
        default = "nixos";
        description = "The name of the default user";
      };
      defaultHostname = mkOption {
        type = str;
        default = "NIXOS";
        description = "The hostname of the WSL instance";
      };
      startMenuLaunchers = mkEnableOption "shortcuts for GUI applications in the windows start menu";
      wslConf = mkOption {
        type = attrsOf (attrsOf (oneOf [ string int bool ]));
        description = "Entries that are added to /etc/wsl.conf";
      };
      wslg = mkOption {
        type = bool;
        default = true;
        description = "Fix user runtime mount so it points to /mnt/wslg/runtime-dir";
      };
    };

  config =
    let
      cfg = config.wsl;
      syschdemd = import ../syschdemd.nix { inherit lib pkgs config; defaultUser = cfg.defaultUser; defaultUserHome = config.users.users.${cfg.defaultUser}.home; };
    in
    mkIf cfg.enable {

      wsl.wslConf = {
        automount = {
          enabled = true;
          ldconfig = false;
          mountFsTab = true;
          root = "${cfg.automountPath}/";
          options = cfg.automountOptions;
        };
        network = {
          hostname = "${cfg.defaultHostname}";
          generateResolvConf = mkDefault true;
          generateHosts = mkDefault true;
        };
      };

      # WSL is closer to a container than anything else
      boot.isContainer = true;

      environment.noXlibs = lib.mkForce false; # override xlibs not being installed (due to isContainer) to enable the use of GUI apps
      hardware.opengl.enable = true; # Enable GPU acceleration

      environment.systemPackages = with pkgs; [
        git
        wget
        fzf
        unzip
        zip
        unrar
        exa
        lsd
        wslu
        wsl-open
        aria2
        tmux
      ];

      environment = {

        etc = {
          "wsl.conf".text = generators.toINI { } cfg.wslConf;

          # DNS settings are managed by WSL
          hosts.enable = !config.wsl.wslConf.network.generateHosts;
          "resolv.conf".enable = !config.wsl.wslConf.network.generateResolvConf;
        };

        shellAliases = {
          diff = "diff --color=auto";
          grep = "grep --color=auto --exclude-dir={.bzr,CVS,.git,.hg,.svn}";
          exa = "exa -gahHF@ --group-directories-first --time-style=long-iso --color-scale --icons --git";
          l = "ls -l";
          ll = "lsd -AFl --group-dirs first --total-size";
          ls = "exa -lG";
          lt = "ls -T";
          tree = "tree -aC -I .git --dirsfirst";
        };

        systemPackages = [
          (pkgs.runCommand "wslpath" { } ''
            mkdir -p $out/bin
            ln -s /init $out/bin/wslpath
          '')
          pkgs.git
          pkgs.wget
          pkgs.fzf
          pkgs.unzip
          pkgs.zip
          pkgs.unrar
          pkgs.exa
          pkgs.lsd
          pkgs.wslu
          pkgs.wsl-open
          pkgs.aria2
          pkgs.tmux
        ];
      };

      # Set your time zone.
      time.timeZone = "America/Phoenix";

      # Select internationalisation properties.
      i18n.defaultLocale = "en_US.UTF-8";

      programs = {
        zsh = {
          enable = true;
          enableCompletion = true;
          autosuggestions.enable = true;
          setOptions = [ "EXTENDED_HISTORY" ];
        };
        bash.enableCompletion = true;
        command-not-found.enable = true;
        fuse.userAllowOther = true;
        tmux.enable = true;
      };

      services = {
        samba.enable = false;
        blueman.enable = false;
        printing.enable = false;
        journald.extraConfig = ''
          MaxRetentionSec=1week
          SystemMaxUse=200M
        '';
      };
    };

    networking.dhcpcd.enable = false;

    users.users.${cfg.defaultUser} = {
      isNormalUser = true;
      shell = pkgs.zsh;
      uid = 1000;
      extraGroups = [ "wheel" "lp" "docker" "networkmanager" "audio" "video" "plugdev" "kvm" "cdrom" "bluetooth" ]; # Allow the default user to use sudo
    };

    users.users.root = {
      shell = "${syschdemd}/bin/syschdemd";
      # Otherwise WSL fails to login as root with "initgroups failed 5"
      extraGroups = [ "root" ];
    };

    security.sudo = {
      extraConfig = ''
        Defaults env_keep+=INSIDE_NAMESPACE
      '';
      wheelNeedsPassword = mkDefault false; # The default user will not have a password by default
    };

    system.activationScripts = {
      copy-launchers = mkIf cfg.startMenuLaunchers (
        stringAfter [ ] ''
          for x in applications icons; do
            echo "Copying /usr/share/$x"
            mkdir -p /usr/share/$x
            ${pkgs.rsync}/bin/rsync -ar --delete $systemConfig/sw/share/$x/. /usr/share/$x
          done
        ''
      );
      populateBin = stringAfter [ ] ''
        echo "setting up /bin..."
        ln -sf /init /bin/wslpath
        ln -sf ${pkgs.bashInteractive}/bin/bash /bin/sh
        ln -sf ${pkgs.util-linux}/bin/mount /bin/mount
      '';
    };

    systemd = {
      # Disable systemd units that don't make sense on WSL
      services = {
        "serial-getty@ttyS0".enable = false;
        "serial-getty@hvc0".enable = false;
        "getty@tty1".enable = false;
        "autovt@".enable = false;
        firewall.enable = false;
        systemd-resolved.enable = false;
        systemd-udevd.enable = false;
        "user-runtime-dir@".serviceConfig = mkIf cfg.wslg (
          lib.mkOverride 0 {
            ExecStart = ''/run/wrappers/bin/mount --bind /mnt/wslg/runtime-dir /run/user/%i'';
            ExecStop = ''/run/wrappers/bin/umount /run/user/%i'';
          }
        );
      };

      tmpfiles.rules = [
        # Don't remove the X11 socket
        "d /tmp/.X11-unix 1777 root root"
      ];

      suppressedSystemUnits = [
        "systemd-networkd.service"
        "systemd-networkd-wait-online.service"
        "networkd-dispatcher.service"
        "systemd-resolved.service"
        "ModemManager.service"
        "NetworkManager.service"
        "NetworkManager-wait-online.service"
        "pulseaudio.service"
        "pulseaudio.socket"
        "dirmngr.service"
        "dirmngr.socket"
        "sys-kernel-debug.mount"
      ];

      # Don't allow emergency mode, because we don't have a console.
      enableEmergencyMode = false;
    };
    warnings = (optional (config.systemd.services.systemd-resolved.enable && config.wsl.wslConf.network.generateResolvConf) "systemd-resolved is enabled, but resolv.conf is managed by WSL");
  };
}
