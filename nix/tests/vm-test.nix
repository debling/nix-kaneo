# End-to-end VM test: boots the full Kaneo stack (postgres + api behind
# nginx, SPA served from the store) and probes the upstream nginx contract
# on every routed layer.
{ self }:
{
  name = "kaneo-vm-test";

  nodes.machine =
    { ... }:
    {
      imports = [
        # Module + package defaults, same as a real user would add.
        self.nixosModules.default
        ./kaneo-config.nix
      ];

      virtualisation.memorySize = 3072;
      # /var only holds the swapfile and PG data; the closure comes from
      # the host store share.
      virtualisation.diskSize = 8192;
      # Absorb memory spikes during restarts (migrations at API boot).
      swapDevices = [
        {
          device = "/var/swapfile";
          size = 2048;
        }
      ];
      virtualisation.graphics = false;
    };

  testScript = ''
    import json

    machine.start()

    # First boot: local infra, drizzle migrations inside the API boot —
    # generous timeout. The API runs migrations before it listens on
    # :1337, so this gates every later check on a fully-started API.
    machine.wait_for_unit("kaneo-api.service", timeout=600)
    machine.wait_until_succeeds(
      "curl -fsS http://127.0.0.1:1337/api/health | grep -q '\"status\":\"ok\"'", timeout=300
    )

    # --- secret wiring -------------------------------------------------------
    # Everything runs through the unit's environment; DATABASE_URL must
    # be present and AUTH_SECRET passed through (demo: plain value).
    unit_env = machine.succeed("systemctl cat kaneo-api.service")
    assert "DATABASE_URL=" in unit_env, "DATABASE_URL missing from kaneo-api unit"
    assert "AUTH_SECRET=" in unit_env, "AUTH_SECRET missing from kaneo-api unit"

    # --- static web (baked via upstream env.sh at build; store-served) --------
    # The rendered MCP discovery file carries the derived KANEO_API_URL.
    mcp_desc = machine.succeed("curl -fsS http://localhost:8080/mcp-oauth-authorization.json")
    assert "localhost:8080" in mcp_desc, f"web substitution missing the public URI: {mcp_desc}"

    # --- loopback-only bind (patched; nginx is the only front door) -----------
    lan_ip = machine.succeed("hostname -I | tr ' ' '\\n' | grep -v '^127\\.' | head -n1").strip()
    assert lan_ip, "no non-loopback address found"
    machine.fail(f"curl -fsS --max-time 5 http://{lan_ip}:1337/api/health")

    # --- database ownership ---------------------------------------------------
    db_owner = machine.succeed(
      "sudo -u postgres psql -tAc \"SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='kaneo'\""
    ).strip()
    assert db_owner == "kaneo", f"database kaneo owned by {db_owner}, expected kaneo"

    # --- migrations (ran inside the API boot) ---------------------------------
    tables = machine.succeed(
      "sudo -u postgres psql -d kaneo -tAc \"SELECT string_agg(table_name, ' ') FROM information_schema.tables WHERE table_schema='public'\""
    )
    for expected in ["user", "session", "workspace", "task"]:
        assert expected in tables, f"expected table {expected} in\n{tables}"

    # --- instance status (public route, proves the DB round-trip) -------------
    status = json.loads(machine.wait_until_succeeds(
      "curl -fsS http://localhost:8080/api/instance/status", timeout=120
    ))
    assert status["hasUsers"] is False, f"instance status: {status}"

    # --- HTTP through the vhost -------------------------------------------------
    # API via /api/
    machine.wait_until_succeeds(
      "curl -fsS http://localhost:8080/api/health | grep -q '\"status\":\"ok\"'", timeout=60
    )
    # SPA served straight from the baked store path. Assert in Python:
    # curl | grep -q is a SIGPIPE race (grep exits on the first chunk
    # and curl reports exit 23).
    spa = machine.succeed("curl -fsS http://localhost:8080/")
    assert "<!doctype html>" in spa.lower(), f"SPA not served: {spa[:200]}"

    # security headers exactly once (all layers are ours now)
    headers = machine.succeed("curl -fsSI http://localhost:8080/api/health")
    for name in ["X-Content-Type-Options", "X-Frame-Options", "X-XSS-Protection", "Referrer-Policy"]:
        assert sum(1 for line in headers.splitlines() if line.lower().startswith(name.lower())) == 1, (
            f"{name} headers: {headers}"
        )

    # --- roundtrip: create the first admin through the signup API -------------
    # The response drops the session cookie into a jar for the websocket
    # probe below.
    status2 = json.loads(machine.succeed(
      "curl -s -X POST http://localhost:8080/api/auth/sign-up/email "
      "-H 'Content-Type: application/json' -c /tmp/kaneo-jar "
      "-d '{\"name\":\"Admin\",\"email\":\"admin@nixos.test\",\"password\":\"Correct-Horse-42-Battery!!\"}'"
    ))
    assert status2.get("user", {}).get("id"), f"sign-up returned: {status2}"
    # status flip: the first user has registered
    status = json.loads(machine.succeed("curl -fsS http://localhost:8080/api/instance/status"))
    assert status["hasUsers"] is True, f"instance status after signup: {status}"

    # --- authenticated websocket upgrade through nginx ------------------------
    # Pins the full upgrade dance: session auth + Origin check in the app,
    # Upgrade/Connection mapping in nginx. --max-time lets curl exit after
    # the 101 while the socket idles.
    ws_status = machine.execute(
      "curl -s -o /dev/null -w '%{http_code}' --max-time 10 --http1.1 "
      "-b /tmp/kaneo-jar -H 'Origin: http://localhost:8080' "
      "-H 'Upgrade: websocket' -H 'Connection: Upgrade' "
      "-H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' "
      "http://localhost:8080/api/ws/user"
    )[1].strip()
    assert ws_status == "101", f"/api/ws/user returned {ws_status}, expected 101"

    # --- restart semantics -------------------------------------------------------
    machine.execute("systemctl restart kaneo-api.service")
    machine.wait_for_unit("kaneo-api.service", timeout=300)
    machine.wait_until_succeeds(
      "curl -fsS http://127.0.0.1:1337/api/health | grep -q '\"status\":\"ok\"'", timeout=120
    )
    # The vhost keeps serving through the restart, since the SPA is
    # store content.
    spa = machine.succeed("curl -fsS http://localhost:8080/")
    assert "<!doctype html>" in spa.lower(), f"SPA not served: {spa[:200]}"
  '';
}
