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
  hash = "sha256-9iIqkS7FIMZfI3gVmM7UaPcEo2DunLHoPwaUTxWEl3I=";
}
