# Kaneo web (React/Vite/Tailwind static SPA) — reproduces the `web-builder`
# stage of upstream Dockerfile.kaneo: build packages/permissions, then
# apps/web, delete the .map files, ship the dist tree plus upstream's
# env.sh/env.awk substitution scripts (the module runs them at build time
# and serves the result straight from the store).
{
  lib,
  stdenv,
  nodejs_24,
  pnpm_10,
  pnpmConfigHook,
  version,
  kaneo,
  kaneo-pnpm-deps,
}:
stdenv.mkDerivation {
  pname = "kaneo-web";
  inherit version;
  src = kaneo;
  pnpmDeps = kaneo-pnpm-deps;

  nativeBuildInputs = [
    nodejs_24
    pnpm_10
    pnpmConfigHook
  ];

  env.NODE_OPTIONS = "--max-old-space-size=8192";

  buildPhase = ''
    runHook preBuild
    echo "Building packages/permissions"
    ( cd packages/permissions && pnpm build )
    echo "Building apps/web"
    ( cd apps/web && pnpm build )
    find apps/web/dist -type f -name '*.map' -delete
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/kaneo/web $out/share/kaneo/web-env
    cp -r apps/web/dist/. $out/share/kaneo/web/
    install -Dm0755 apps/web/env.sh $out/share/kaneo/web-env/env.sh
    install -Dm0644 apps/web/env.awk $out/share/kaneo/web-env/env.awk
    runHook postInstall
  '';

  meta = {
    description = "Kaneo web frontend (static Vite SPA)";
    homepage = "https://kaneo.app";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
