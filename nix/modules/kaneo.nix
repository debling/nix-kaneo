# NixOS module for self-hosting Kaneo (usekaneo/kaneo) natively — no
# containers. Mirrors the upstream bundled image: an internal nginx
# serving the web SPA in front of a Node API.
#
#   kaneo-api     the API (Hono + better-auth + drizzle); binds loopback
#                 :1337 only (patched in the package) and runs drizzle
#                 migrations at boot
#   nginx vhost   mirrors apps/web/nginx.kaneo.conf: SPA fallback (public
#                 vars and mcp-oauth-*.json substituted at build time)
#                 and the /api/ websocket proxy
#   the database (and, for multi-replica fan-out, redis) servers are the
#   host's business — point {env}`DATABASE_URL` (via `environment`) at
#   the postgres it must use
#
# Environment model: everything is a plain systemd `environment` attribute
# of the api unit — unit files are world-readable, the trade-off upstream's
# own Compose deployments accept. Pass file-backed secrets as `*_FILE`
# env vars (only the path is world-readable) and make those files
# readable by the service user.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.kaneo;

  # Upstream hardcoded port (apps/api src/index.ts; no bind-port env).
  apiPort = 1337;

  # `scheme://host[:port]` → { host, port or null }; null otherwise (the
  # match anchors both ends, so a path component fails). An unparseable
  # publicUri surfaces the module's own assertion, not a generation crash.
  parseUri =
    uri:
    let
      m = builtins.match "[A-Za-z][A-Za-z0-9+.-]*://([^:/?#]+)(:([0-9]{1,5}))?" uri;
    in
    if m == null then
      null
    else
      {
        host = builtins.elemAt m 0;
        port = builtins.elemAt m 2;
      };

  publicUri = parseUri cfg.publicUri;
  listenPort = if publicUri != null && publicUri.port != null then lib.toInt publicUri.port else 80;

  kaneoApiUrl = "${lib.removeSuffix "/" cfg.publicUri}/api";

  apiEnv = {
    KANEO_CLIENT_URL = cfg.publicUri;
    KANEO_API_URL = kaneoApiUrl;
    NODE_ENV = "production";
  }
  // cfg.environment;

  # The served SPA: upstream's env.sh substitution of the public
  # placeholders runs at *build* time; nginx serves it straight from the
  # store. A publicUri change re-runs only this cheap derivation, never
  # the pnpm build.
  webRoot =
    pkgs.runCommand "kaneo-web-configured"
      {
        env = {
          KANEO_CLIENT_URL = cfg.publicUri;
          KANEO_API_URL = kaneoApiUrl;
        };
      }
      ''
        set -euo pipefail
        web=$out/share/kaneo/web
        mkdir -p "$web"
        # --no-preserve=mode: store read-only modes must not propagate —
        # env.sh writes temp files beside each asset and moves them over.
        cp -r --no-preserve=mode ${cfg.package.web}/share/kaneo/web/. "$web/"
        # env.sh finds env.awk beside itself and hardcodes the container
        # asset root; point it at our copy.
        cp ${cfg.package.web}/share/kaneo/web-env/env.sh env.sh
        cp ${cfg.package.web}/share/kaneo/web-env/env.awk env.awk
        substituteInPlace env.sh --replace-fail /usr/share/nginx/html "$web"
        sh env.sh
      '';

  # Proxy header block from apps/web/nginx.kaneo.conf — upstream strips
  # the two client-supplied IP headers (spoofing guard). The /api/
  # location gets proxy_http_version from proxyWebsockets.
  kaneoProxyHeaders = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header CF-Connecting-IP "";
    proxy_set_header X-Kaneo-Client-IP "";
  '';

  commonServiceConfig = {
    PrivateTmp = true;
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
      # libuv (node) enumerates interfaces via netlink.
      "AF_NETLINK"
    ];
    LockPersonality = true;
    RestrictRealtime = true;
    SystemCallArchitectures = "native";
    Restart = "on-failure";
    RestartSec = 5;
    User = cfg.user;
    Group = cfg.group;
  };

in
{
  options.services.kaneo = {
    enable = mkEnableOption "the Kaneo project-management server";

    package = mkOption {
      description = "Component packages (the flake's module sets the defaults).";
      type = types.submodule {
        options = {
          api = mkOption {
            type = types.package;
            description = "API server (Node; binds loopback :${toString apiPort}).";
          };
          web = mkOption {
            type = types.package;
            description = ''
              Static web frontend; {option}`publicUri` placeholders
              substituted via upstream's `env.sh` at build time.
            '';
          };
        };
      };
    };

    user = mkOption {
      type = types.str;
      default = "kaneo";
      description = "System user the Kaneo services run as.";
    };

    group = mkOption {
      type = types.str;
      default = "kaneo";
      description = "System group for the Kaneo services.";
    };

    publicUri = mkOption {
      type = types.str;
      example = "https://kaneo.example.com";
      description = ''
        Origin users reach Kaneo at. Drives {env}`KANEO_CLIENT_URL`, the
        derived {env}`KANEO_API_URL`, the nginx vhost and the web asset
        substitution; must be a bare origin (the API lives under
        {file}`/api/`, same-origin).
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        API environment variables under their exact upstream names. The
        required ones: {env}`DATABASE_URL` and either {env}`AUTH_SECRET`
        or {env}`AUTH_SECRET_FILE` (needed because a host-native API
        cannot generate a temporary secret). Typical extras: the
        auth/registration flags ({env}`DISABLE_*`), mail ({env}`SMTP_*`
        incl. {env}`SMTP_PASSWORD`), attachments ({env}`S3_*`), SSO
        ({env}`CUSTOM_OAUTH_*` incl. `CUSTOM_OAUTH_CLIENT_SECRET_FILE`),
        {env}`COOKIE_DOMAIN`, {env}`TRUSTED_PROXIES`, {env}`CORS_ORIGINS`,
        {env}`REDIS_URL` (multi-replica WebSocket fan-out) and
        {env}`KANEO_ALLOW_PRIVATE_WEBHOOK_DESTINATIONS`. Upstream has no
        `_FILE` support for DATABASE_URL/SMTP/S3 secrets, so plain values
        here are world-readable in the unit file; file-backed secrets go
        in as `*_FILE` paths made readable by the service user. Entries
        are applied last (they override generated values).
      '';
    };

    nginx = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          The nginx vhost (mirrors upstream's apps/web/nginx.kaneo.conf;
          gzip comes from nixpkgs' {option}`recommendedGzipSettings`).
        '';
      };
      forceHttps = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Redirect HTTP to HTTPS in the vhost — only meaningful once TLS
          is configured on this host.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
      };
      users.groups.${cfg.group} = { };

      systemd.services.kaneo-api = {
        description = "Kaneo API server (Hono + better-auth + drizzle/postgres)";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${cfg.package.api}/bin/kaneo-api";
          # Websocket listeners hold the process after SIGTERM; hit the
          # whole group quickly.
          KillMode = "mixed";
          TimeoutStopSec = 20;
        }
        // commonServiceConfig;
        environment = apiEnv;
      };

      assertions = [
        {
          assertion = publicUri != null && cfg.publicUri != "";
          message = "services.kaneo.publicUri must be a scheme://host[:port] origin without a path component.";
        }
        {
          assertion = !(elem "KANEO_CLOUD" (attrNames cfg.environment));
          message = "KANEO_CLOUD must not be set — self-hosted deployments leave it unset (services.kaneo.environment).";
        }
      ];

      warnings = optional (hasPrefix "http://" cfg.publicUri) "services.kaneo.publicUri uses plain HTTP; configure TLS and set nginx.forceHttps for production use.";
    }

    # --- nginx vhost (reproduces apps/web/nginx.kaneo.conf) -------------------
    (mkIf (cfg.nginx.enable) {
      services.nginx = {
        enable = mkDefault true;
        recommendedGzipSettings = mkDefault true;
        virtualHosts.${publicUri.host} = {
          listen = [
            {
              addr = "0.0.0.0";
              port = listenPort;
            }
          ]
          # Serve both stacks (only when IPv6 is on; nginx's
          # ipv6only=on keeps the v6 socket additive).
          ++ optional config.networking.enableIPv6 {
            addr = "[::]";
            port = listenPort;
          };
          extraConfig = ''
            # Larger header buffers for long OAuth/Better-Auth session
            # cookies (upstream).
            client_header_buffer_size 8k;
            large_client_header_buffers 4 32k;
            client_max_body_size 25m;

            add_header X-Content-Type-Options "nosniff" always;
            add_header X-Frame-Options "SAMEORIGIN" always;
            add_header X-XSS-Protection "0" always;
            add_header Referrer-Policy "strict-origin-when-cross-origin" always;
          ''
          + optionalString cfg.nginx.forceHttps ''
            # HSTS only with forceHttps — it would brick plain-HTTP
            # local setups.
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
            if ( $scheme = http ) {
              return 301 https://$host$request_uri;
            }
          '';
          locations = {
            "/" = {
              root = "${webRoot}/share/kaneo/web";
              tryFiles = "$uri $uri/ /index.html";
            };

            # The API (path preserved: the app routes carry the /api
            # prefix). Upstream clears the two client-supplied IP
            # headers; recommendedProxySettings would keep them, hence
            # the explicit block.
            "/api/" = {
              proxyPass = "http://127.0.0.1:${toString apiPort}";
              proxyWebsockets = true;
              recommendedProxySettings = false;
              extraConfig = kaneoProxyHeaders;
            };
          };
        };
      };
    })
  ]);
}
