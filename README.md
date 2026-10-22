# nix-kaneo

Nix packages and a NixOS module for self-hosting [Kaneo](https://kaneo.app)
([usekaneo/kaneo](https://github.com/usekaneo/kaneo)) natively, no
containers. See `nix/modules/kaneo.nix` for the process model.
## Architecture

```text
nginx vhost (from publicUri; mirrors apps/web/nginx.kaneo.conf)
├─ /                  → kaneo-web SPA (store; env.sh-substituted at build)
├─ /api/ + websockets → kaneo-api 127.0.0.1:1337 (migrations at boot)
├─ mcp-oauth-*.json   → static, SPA web root
└─ postgres / S3 / SMTP / OIDC — host-provided or external
```

Two services: `kaneo-api` and the nginx vhost. There is no web unit —
the SPA is served from the store, its `publicUri` placeholders
substituted at build time by upstream's own `env.sh`. The API runs
drizzle migrations at boot; upstream hardcodes the port (`:1337`) and
binds all interfaces — the package patches it to loopback; nginx is
the only front door.

Secrets and the database URI flow through `environment`; option-less
values land verbatim in the world-readable unit file. File-backed env
vars (`AUTH_SECRET_FILE`, `CUSTOM_OAUTH_CLIENT_SECRET_FILE`) keep the
value itself out — only the path is exposed, so make those files
readable by the `kaneo` user (e.g. sops-nix owner/mode). Upstream reads
`*_FILE` only for those two; everything else (`DATABASE_URL`, SMTP/S3
secrets) is a plain value, as in upstream's own Compose deployments.

## Quickstart

```nix
{
  inputs.nix-kaneo.url = "github:debling/nix-kaneo";
  imports = [ inputs.nix-kaneo.nixosModules.default ];

  services.kaneo = {
    enable = true;
    publicUri = "https://kaneo.example.com";
    environment = {
      DATABASE_URL = "postgresql://kaneo:…@127.0.0.1:5432/kaneo";
      AUTH_SECRET_FILE = "/run/secrets/kaneo/auth-secret";
    };
  };

  # Example local database; the module provisions nothing
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "kaneo" ];
    ensureUsers = [{ name = "kaneo"; ensureDBOwnership = true; }];
    authentication = lib.mkBefore "host kaneo kaneo 127.0.0.1/32 trust";
  };
}
```

Generate the auth secret with `openssl rand -base64 32` (≥ 32 chars).

## Options

Generated env: `KANEO_CLIENT_URL`, `KANEO_API_URL` (`publicUri` +
`/api`), `NODE_ENV`. Everything else comes from `environment`, mapped
1:1 to its upstream name:

| Option | Default | Notes |
|---|---|---|
| `package.api` / `package.web` | from the flake | component overrides |
| `user` / `group` | `kaneo` | systemd identity |
| `publicUri` | required | bare origin; drives URLs, vhost, substitution |
| `nginx.enable` / `nginx.forceHttps` | `true` / `false` | vhost |
| `environment` | `{}` | API env, exact upstream names (see below) |

`environment` needs `DATABASE_URL` and either `AUTH_SECRET` or
`AUTH_SECRET_FILE` (`openssl rand -base64 32`, ≥ 32 chars). Beyond
that: the six `DISABLE_*` auth flags; the `CUSTOM_OAUTH_*` SSO set plus
`CUSTOM_OAUTH_{AUTHORIZATION,TOKEN,USER_INFO}_URL`; `S3_*`
(attachments) and `SMTP_*` (mail), including `S3_SECRET_ACCESS_KEY` and
`SMTP_PASSWORD`; `COOKIE_DOMAIN`, `CORS_ORIGINS`, `TRUSTED_PROXIES`
(upstream defaults fit one same-origin host — leave unset);
`KANEO_ALLOW_PRIVATE_WEBHOOK_DESTINATIONS`; `REDIS_URL` (multi-replica
WebSocket fan-out — host-provided; a single replica uses the in-memory
adapter). The one rule for secrets: `*_FILE` paths beat literal values
— a path in the world-readable unit file, the value stays private.

## OIDC / SSO

IdP redirect URI: `{publicUri}/api/auth/oauth2/callback/custom`.

```nix
services.kaneo.environment = {
  CUSTOM_OAUTH_CLIENT_ID = "kaneo";
  CUSTOM_OAUTH_CLIENT_SECRET_FILE = "/run/secrets/kaneo/oidc-secret";
  CUSTOM_OAUTH_DISCOVERY_URL = "https://keycloak.example.com/realms/main/.well-known/openid-configuration";

  # Logins only using the OIDC provider
  # DISABLE_LOGIN_FORM = "true";
};
```

Pre-existing local accounts whose emails are unverified in the IdP get
`account_not_linked`. Keep the login form (and auto-login unset) until
those users sign in once via email OTP, which verifies the address.
See [upstream's custom-OAuth docs](https://kaneo.app/docs/core/social-providers/custom-oauth).

## Attachments (S3)

```nix
services.kaneo.environment = {
  S3_ENDPOINT = "https://s3.example.com";  # reachable by API and browsers
  S3_BUCKET = "kaneo";
  S3_ACCESS_KEY_ID = "kaneo";
  S3_SECRET_ACCESS_KEY = "…";  # world-readable in the unit file
};
```

## Demo VM / dev

`nix run .#kaneo-vm` — demo VM at http://localhost:8080, serial console
on stdout, Ctrl-C stops.

```bash
nix build .#kaneo-api .#kaneo-web              # packages
nix build .#checks.x86_64-linux.kaneo-vm-test  # e2e VM test (long)
nix flake check --no-build                     # eval-time sanity
nix fmt                                        # format
```

## Updating

1. Bump the `kaneo` input (`nix flake update kaneo`).
2. Re-hash `kaneo-pnpm-deps`: `hash = lib.fakeHash` → `nix build
   .#kaneo-pnpm-deps` → paste the `got:` hash.
3. Rebuild, re-run the VM test.
4. Re-check the upstream contract (Dockerfile stages, `env.sh`/`env.awk`
   placeholders, `nginx.kaneo.conf` routes, env vars, `*_FILE` support)
   and fix divergences here.
