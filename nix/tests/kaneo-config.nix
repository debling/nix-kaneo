# Shared services.kaneo configuration for the demo VM and the VM test.
{
  lib,
  pkgs,
  ...
}:
{
  services.kaneo = {
    enable = true;
    # The VM test probes the nginx vhost on this origin.
    publicUri = "http://localhost:8080";
    # Demo-only values: in production prefer file-backed env vars
    # (AUTH_SECRET_FILE / CUSTOM_OAUTH_CLIENT_SECRET_FILE) over literal
    # secrets — only the path is world-readable in the unit file.
    environment = {
      DATABASE_URL = "postgresql://kaneo@127.0.0.1:5432/kaneo";
      AUTH_SECRET = "demo-only-32b78c31d9ac4f0dbf7f86b2a1d2f7ba-use-sops-nix-in-prod";
    };
  };

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;
    ensureDatabases = [ "kaneo" ];
    ensureUsers = [
      {
        name = "kaneo";
        ensureDBOwnership = true;
      }
    ];
    # Loopback TCP from the API; trust is fine on loopback (the rule must
    # precede the default ones).
    authentication = lib.mkBefore ''
      host kaneo kaneo 127.0.0.1/32 trust
    '';
  };
}
