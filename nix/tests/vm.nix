# Runnable demo VM: `nix run .#kaneo-vm`
# (or use the flake.nixosConfigurations.kaneo-vm attribute with your VM tool).
{
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/virtualisation/qemu-vm.nix")
    ./kaneo-config.nix
  ];

  # Node + PostgreSQL + migrations; 3 GB + a comfortable disk is plenty for
  # the runtime VM (builds are not part of its life).
  virtualisation.memorySize = 3072;
  virtualisation.diskSize = 8192;
  # Headless: serial console only (no GTK window on a server without a display).
  virtualisation.graphics = false;

  # QEMU user-mode networking forwards nothing by default — expose the
  # nginx vhost (publicUri http://localhost:8080) and ssh to the host.
  virtualisation.forwardPorts = [
    {
      from = "host";
      host.port = 8080;
      guest.port = 8080;
    }
    {
      from = "host";
      host.port = 2222;
      guest.port = 22;
    }
  ];

  networking.firewall.allowedTCPPorts = [
    8080
    22
  ];
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
  };

  users.users.demo = {
    isNormalUser = true;
    # Demo VM convenience login; not for production.
    initialPassword = "demo";
  };

  system.stateVersion = "26.11";
}
