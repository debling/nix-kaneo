{
  fetchPnpmDeps,
  pnpm_12,
  kaneo,
}:
fetchPnpmDeps {
  pname = "kaneo-pnpm-deps";
  src = kaneo;
  pnpm = pnpm_12;
  fetcherVersion = 5;
  # Only the importers kaneo-api/kaneo-web build from. A missing member
  # fails the api/web builds loudly (ERR_PNPM_NO_OFFLINE_TARBALL) — add
  # it here, consumer pnpmWorkspaces, and regen the hash.
  pnpmWorkspaces = [
    "kaneo" # root: dotenv-mono, prod dep of the api runtime tree
    "@kaneo/api"
    "@kaneo/web"
    "@kaneo/email"
    "@kaneo/permissions"
    "@kaneo/importers"
    "@kaneo/mcp"
    "@kaneo/editor" # web devDep, built via vp dependsOn
    "@kaneo/libs"
    "@kaneo/typescript-config"
  ];
  hash = "sha256-WnLNNqhiSLoAH06lqRNNbeVKACGBMHt4KcthY1/bqAg=";
}
