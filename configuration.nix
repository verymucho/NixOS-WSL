{ lib, pkgs, config, modulesPath, ... }:

with lib;
let
  nixos-wsl = import ./default.nix;
in
{
  imports = [
    "${modulesPath}/profiles/headless.nix"

    nixos-wsl.nixosModules.wsl
  ];

  wsl = {
    enable = true;
    automountPath = "/mnt";
    defaultUser = "nixos";
    startMenuLaunchers = true;

    # Enable native Docker support
    # docker-native.enable = true;

    # Enable integration with Docker Desktop (needs to be installed)
    # docker.enable = true;

    # Enable authenticating sudo prompts with Windows Hello
    # DO NOT USE THIS FOR ANYTHING SECURITY-CRITICAL
    # windowsHello.enable = true;
  };

  # Enable nix flakes
  nixpkgs.config.allowUnfree = true;
  nix.autoOptimiseStore = true;
  nix.gc.automatic = true;
  nix.package = pkgs.nixFlakes;
  nix.trustedUsers = [ "root" "$defaultUser" "@wheel" ];
  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  system.stateVersion = "22.05";
}
