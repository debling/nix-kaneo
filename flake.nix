{
  description = "Nix packages and NixOS module for self-hosting Kaneo";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    kaneo.url = "github:usekaneo/kaneo/v2.46.2";
    kaneo.flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      kaneo,
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
      pkgsFor = system: import nixpkgs { inherit system; };

      kaneoVersion = (builtins.fromJSON (builtins.readFile "${kaneo}/package.json")).version;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          inherit (pkgs) callPackage;
          kaneo-pnpm-deps = callPackage ./nix/packages/pnpm-deps.nix { inherit kaneo; };
        in
        {
          inherit kaneo-pnpm-deps;
          kaneo-api = callPackage ./nix/packages/api.nix {
            inherit kaneo kaneo-pnpm-deps;
            version = kaneoVersion;
          };
          kaneo-web = callPackage ./nix/packages/web.nix {
            inherit kaneo kaneo-pnpm-deps;
            version = kaneoVersion;
          };

          kaneo-vm = pkgs.writeShellScriptBin "kaneo-vm" ''
            exec ${self.nixosConfigurations.kaneo-vm.config.system.build.vm}/bin/run-nixos-vm \
              -display none -serial stdio -monitor none
          '';
        }
      );

      # The wrapper sets the package defaults from this flake's packages.
      nixosModules.default = { pkgs, lib, ... }: {
        imports = [ ./nix/modules/kaneo.nix ];
        services.kaneo.package.api =
          lib.mkDefault
            self.packages.${pkgs.stdenv.hostPlatform.system}.kaneo-api;
        services.kaneo.package.web =
          lib.mkDefault
            self.packages.${pkgs.stdenv.hostPlatform.system}.kaneo-web;
      };

      nixosConfigurations.kaneo-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.default
          ./nix/tests/vm.nix
        ];
      };

      checks = forAllSystems (
        system:
        lib.optionalAttrs (system == "x86_64-linux") {
          kaneo-vm-test = (pkgsFor system).testers.nixosTest (
            import ./nix/tests/vm-test.nix { inherit self; }
          );
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);
    };
}
