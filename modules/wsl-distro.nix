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
        type = attrsOf (attrsOf coercedToStr);
        description = "Entries that are added to /etc/wsl.conf";
      };

      interop = {
        register = mkOption {
          type = bool;
          default = true;
          description = "Explicitly register the binfmt_misc handler for Windows executables";
        };

        includePath = mkOption {
          type = bool;
          default = true;
          description = "Include Windows PATH in WSL PATH";
        };
      };

      wslg = mkOption {
        type = bool;
        default = true;
        description = "Fix user runtime mount so it points to /mnt/wslg/runtime-dir";
      };

      compatibility = {
        interopPreserveArgvZero = mkOption {
          type = nullOr bool;
          default = true;
          description = ''
            Register binfmt interpreter for Windows executables with 'preserves argv[0]' flag.

            Default (null): autodetect, at some performance cost.
            To avoid the performance cost, set this to true for WSL Preview 0.58 and up,
            or to false for older versions (including pre-Microsoft Store).
          '';
        };
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
          enabled = "true";
          ldconfig = "false";
          mountFsTab = "true";
          options = cfg.automountOptions;
          root = "${cfg.automountPath}/";
        };

        network = {
          hostname = "${cfg.defaultHostname}";
        };
      };

      # WSL is closer to a container than anything else
      boot = {
        isContainer = true;
        enableContainers = true;

        binfmt.registrations = mkIf cfg.interop.register {
          WSLInterop =
            let
              compat = cfg.compatibility.interopPreserveArgvZero;

              # WSL Preview 0.58 and up registers the /init binfmt interp for Windows executable
              # with the "preserve argv[0]" flag, so if you run `./foo.exe`, the interp gets invoked
              # as `/init foo.exe ./foo.exe`.
              #   argv[0] --^        ^-- actual path
              #
              # Older versions expect to be called without the argv[0] bit, simply as `/init ./foo.exe`.
              #
              # We detect that by running `/init /known-not-existing-path.exe` and checking the exit code:
              # the new style interp expects at least two arguments, so exits with exit code 1,
              # presumably meaning "parsing error"; the old style interp attempts to actually run
              # the executable, fails to find it, and exits with 255.
              compatWrapper = pkgs.writeShellScript "nixos-wsl-binfmt-hack" ''
                /init /nixos-wsl-does-not-exist.exe
                [ $? -eq 255 ] && shift
                exec /init $@
              '';

              # use the autodetect hack if unset, otherwise call /init directly
              interpreter = if compat == null then compatWrapper else "/init";

              # enable for the wrapper and autodetect hack
              preserveArgvZero = if compat == false then false else true;
            in
            {
              magicOrExtension = "MZ";
              fixBinary = true;
              inherit interpreter preserveArgvZero;
            };
        };
      };

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

      environment.noXlibs = lib.mkForce false; # override xlibs not being installed (due to isContainer) to enable the use of GUI apps

      environment = {
        # Include Windows %PATH% in Linux $PATH.
        extraInit = mkIf cfg.interop.includePath ''PATH="$PATH:$WSLPATH"'';

        etc = {
          "wsl.conf".text = generators.toINI { } cfg.wslConf;

          # DNS settings are managed by WSL
          hosts.enable = false;
          "resolv.conf".enable = false;
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

      system.activationScripts.copy-launchers = mkIf cfg.startMenuLaunchers (
        stringAfter [ ] ''
          for x in applications icons; do
            echo "Copying /usr/share/$x"
            mkdir -p /usr/share/$x
            ${pkgs.rsync}/bin/rsync -ar --delete $systemConfig/sw/share/$x/. /usr/share/$x
          done
        ''
      );

      systemd.services."user-runtime-dir@".serviceConfig = mkIf cfg.wslg (
        lib.mkOverride 0 {
          ExecStart = ''/run/wrappers/bin/mount --bind /mnt/wslg/runtime-dir /run/user/%i'';
          ExecStop = ''/run/wrappers/bin/umount /run/user/%i'';
        }
      );

      systemd.services.firewall.enable = false;
      systemd.services.systemd-resolved.enable = false;
      systemd.services.systemd-udevd.enable = false;

      systemd.suppressedSystemUnits = [
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
    };
}
