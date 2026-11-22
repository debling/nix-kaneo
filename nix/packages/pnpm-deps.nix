{
  fetchPnpmDeps,
  pnpm_12,
  kaneo,
}:
fetchPnpmDeps {
  pname = "kaneo-pnpm-deps";
  src = kaneo;
  pnpm = pnpm_12;
  fetcherVersion = 4;
  hash = "sha256-idf9VBfFeDnDtM5+PvRT3yhB/5tNCQCWKlgXvfiM33Q=";
}
