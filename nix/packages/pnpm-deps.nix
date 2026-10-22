# Offline pre-fetch of the Kaneo JS workspace dependencies (FOD) — one
# shared store for both packages (same pnpm 10 lockfile); its hash tracks
# the lockfile, not the app sources.
#
# ON A KANEO BUMP: set hash to lib.fakeHash, run
#   nix build .#kaneo-pnpm-deps
# and copy the `got:` hash from the mismatch error back here.
{
  fetchPnpmDeps,
  pnpm_10,
  kaneo,
}:
fetchPnpmDeps {
  pname = "kaneo-pnpm-deps";
  src = kaneo;
  # Pin the major: guards against store-format breakage on nixpkgs bumps.
  pnpm = pnpm_10;
  fetcherVersion = 4;
  hash = "sha256-x3Mz7oC3XZOaKKWSSIc3Qcr/nh+hZ4oay7aFSuExPzU=";
}
