{
  lib,
  stdenv,
  nodejs_24,
  pnpm_10,
  pnpmConfigHook,
  makeWrapper,
  version,
  kaneo,
  kaneo-pnpm-deps,
}:
stdenv.mkDerivation {
  pname = "kaneo-api";
  inherit version;
  src = kaneo;
  pnpmDeps = kaneo-pnpm-deps;

  nativeBuildInputs = [
    nodejs_24
    pnpm_10
    pnpmConfigHook
    makeWrapper
  ];

  env.NODE_OPTIONS = "--max-old-space-size=8192";

  # Upstream binds every interface on the hardcoded port (no HOST env
  # exists). nginx is this module's only front door, so bind loopback
  # instead. `      port,` is unique in the file.
  postPatch = ''
    substituteInPlace apps/api/src/index.ts \
      --replace-fail '      port,' '      port, hostname: "127.0.0.1",'
  '';

  buildPhase = ''
    runHook preBuild
    for ws in email permissions importers mcp; do
      echo "Building packages/$ws"
      ( cd "packages/$ws" && pnpm build )
    done
    echo "Building apps/api"
    ( cd apps/api && pnpm build )
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # Runtime tree, upstream api-runtime-stage layout: a fresh prod
    # install (offline from the pnpm store) materializes only the runtime
    # graph of the shipped members — shipping the build tree's
    # node_modules would carry every dev package too (pnpm's --filter
    # prunes importer links but never garbage-collects .pnpm).
    # --frozen-lockfile is omitted: frozen mode requires an on-disk
    # manifest per lockfile importer, and shipping six members means not
    # carrying the six we don't have; offline resolution saturates from
    # the same store either way.
    R=$out/lib/kaneo-api
    mkdir -p $R/apps/api $R/packages
    cp package.json pnpm-workspace.yaml pnpm-lock.yaml $R/
    cp apps/api/package.json $R/apps/api/
    for pkg in email permissions importers mcp; do
      mkdir -p "$R/packages/$pkg"
      cp "packages/$pkg/package.json" "$R/packages/$pkg/"
    done
    cp -r --parents \
      packages/{email,permissions} \
      packages/importers/dist \
      packages/mcp/dist \
      apps/api/dist \
      apps/api/drizzle \
      $R/

    # Root importer "kaneo" — apps/api's `--packages=external` bundle
    # imports the root-only dep dotenv-mono.
    ( cd $R && env HUSKY=0 NODE_ENV=production CI=true \
        pnpm install --prod --offline --ignore-scripts \
        --no-optional --filter=kaneo --filter=@kaneo/api... )

    # Nothing reads the bootstrap manifests (or the store bookkeeping the
    # install rewrites) at runtime; .modules.yaml &co. embed the
    # sandbox-local store path and a wall-clock timestamp — drop them so
    # the output stays deterministic.
    rm -f $R/pnpm-workspace.yaml $R/pnpm-lock.yaml
    find $R \( -name '.modules.yaml' \
             -o -name 'lock.yaml' -path '*/.pnpm/*' \
             -o -name '.pnpm-workspace-state*' \) | xargs -r rm -rf
    # Copied links may aim at peers not shipped here — nothing may
    # resolve into them.
    find $R -xtype l -delete

    # Same runtime-layout check as upstream's Docker build: runtime deps
    # resolve from apps/api, the built workspace deps are present, and
    # the root-only dep exists in the root node_modules.
    ( cd $R/apps/api && node -e "
      const fs = require('fs');
      for (const m of ['bcryptjs','hono','pg','drizzle-orm','better-auth','ioredis','valibot','octokit','@modelcontextprotocol/sdk'])
        fs.accessSync('node_modules/' + m + '/package.json');
      for (const m of ['email','permissions','importers'])
        fs.accessSync('node_modules/@kaneo/' + m + '/dist/index.js');
      fs.accessSync(process.argv[1] + '/node_modules/dotenv-mono/package.json');
    " "$R" )

    runHook postInstall
  '';

  postFixup = ''
    makeWrapper ${nodejs_24}/bin/node $out/bin/kaneo-api \
      --set-default NODE_ENV production \
      --add-flags "--enable-source-maps" \
      --add-flags "$out/lib/kaneo-api/apps/api/dist/index.js"
  '';

  meta = {
    description = "Kaneo API server (Hono + better-auth + drizzle/postgres)";
    homepage = "https://kaneo.app";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "kaneo-api";
  };
}
