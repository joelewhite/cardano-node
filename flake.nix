{
  description = "Cardano Node";

  inputs = {
    # IMPORTANT: report any change to nixpkgs channel in nix/default.nix:
    nixpkgs.follows = "haskellNix/nixpkgs-2105";
    haskellNix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    utils.url = "github:numtide/flake-utils";
    iohkNix = {
      url = "github:input-output-hk/iohk-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-compat = {
      url = "github:input-output-hk/flake-compat/fixes";
      flake = false;
    };
    membench = {
      url = "github:input-output-hk/cardano-memory-benchmark";
      inputs.cardano-node-measured.follows = "/";
      inputs.cardano-node-process.follows = "/";
      inputs.cardano-node-snapshot.url = "github:input-output-hk/cardano-node/7f00e3ea5a61609e19eeeee4af35241571efdf5c";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Custom user config (default: empty), eg.:
    # { outputs = {...}: {
    #   # Cutomize listeming port of node scripts:
    #   nixosModules.cardano-node = {
    #     services.cardano-node.port = 3002;
    #   };
    # };
    customConfig.url = "github:input-output-hk/empty-flake";
    plutus-example = {
      url = "github:input-output-hk/cardano-node/1.33.0";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, utils, haskellNix, iohkNix, customConfig, membench, plutus-example, flake-compat }:
    let
      inherit (nixpkgs) lib;
      inherit (lib) head systems mapAttrs recursiveUpdate mkDefault
        getAttrs optionalAttrs nameValuePair attrNames;
      inherit (utils.lib) eachSystem mkApp flattenTree;
      inherit (iohkNix.lib) prefixNamesWith;
      removeRecurse = lib.filterAttrsRecursive (n: _: n != "recurseForDerivations");
      flatten = attrs: lib.foldl' (acc: a: if (lib.isAttrs a) then acc // (removeAttrs a [ "recurseForDerivations" ]) else acc) { } (lib.attrValues attrs);

      supportedSystems = import ./nix/supported-systems.nix;
      defaultSystem = head supportedSystems;

      overlays = [
        haskellNix.overlay
        iohkNix.overlays.haskell-nix-extra
        iohkNix.overlays.crypto
        iohkNix.overlays.cardano-lib
        iohkNix.overlays.utils
        (final: prev: {
          customConfig = recursiveUpdate
            (import ./nix/custom-config.nix final.customConfig)
            customConfig;
          gitrev = self.rev or "0000000000000000000000000000000000000000";
          commonLib = lib
            // iohkNix.lib
            // final.cardanoLib
            // import ./nix/svclib.nix { inherit (final) pkgs; };
          inherit ((import plutus-example {
            inherit (final) system;
            gitrev = plutus-example.rev;
          }).haskellPackages.plutus-example.components.exes) plutus-example;
        })
        (import ./nix/pkgs.nix)
      ];
      flake = eachSystem supportedSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system overlays;
            inherit (haskellNix) config;
          };
          inherit (pkgs.haskell-nix) haskellLib;
          inherit (haskellLib) collectChecks' collectComponents';
          inherit (pkgs.commonLib) eachEnv environments mkSupervisordCluster;

          project = pkgs.cardanoNodeProject;
          projectPackages = haskellLib.selectProjectPackages project.hsPkgs;

          shell = import ./shell.nix { inherit pkgs; };
          devShells = {
            inherit (shell) devops;
            cluster = shell;
            profiled = pkgs.cardanoNodeProfiledProject.shell;
          };

          devShell = shell.dev;

          checks = flattenTree (collectChecks' projectPackages) //
            # Linux only checks:
            (optionalAttrs (system == "x86_64-linux") (
              prefixNamesWith "nixosTests/" (mapAttrs (_: v: v.${system} or v) pkgs.nixosTests)
            ))
            # checks run on default system only;
            // (optionalAttrs (system == defaultSystem) {
            hlint = pkgs.callPackage pkgs.hlintCheck {
              inherit (project.args) src;
            };
          });

          projectExes = flatten (collectComponents' "exes" projectPackages);
          exes = projectExes // {
            inherit (pkgs)  db-analyser cardano-ping db-converter bech32;
          } // lib.optionalAttrs (pkgs.stdenv.hostPlatform.isLinux) {
            inherit (pkgs) cardano-node-asserted cardano-node-eventlogged cardano-node-profiled tx-generator-profiled plutus-scripts;
          } // flattenTree (pkgs.scripts // {
            # `tests` are the test suites which have been built.
            tests = collectComponents' "tests" projectPackages;
            # `benchmarks` (only built, not run).
            benchmarks = collectComponents' "benchmarks" projectPackages;
          });

          packages = exes
            # Linux only packages:
            // optionalAttrs (system == "x86_64-linux") {
            "dockerImage/node" = pkgs.dockerImage;
            "dockerImage/submit-api" = pkgs.submitApiDockerImage;
            membenches = membench.outputs.packages.x86_64-linux.batch-report;
            snapshot = membench.outputs.packages.x86_64-linux.snapshot;
          }
            # Add checks to be able to build them individually
            // (prefixNamesWith "checks/" checks);

          apps = lib.mapAttrs (n: p: { type = "app"; program = p.exePath or "${p}/bin/${p.name or n}"; }) exes;

        in
        {

          inherit environments packages checks apps;

          legacyPackages = pkgs;

          # Built by `nix build .`
          defaultPackage = packages.cardano-node;

          # Run by `nix run .`
          defaultApp = apps.cardano-node;

          # This is used by `nix develop .` to open a devShell
          inherit devShell devShells;

          systemHydraJobs = optionalAttrs (system == "x86_64-linux")
            {
              linux = {
                native = packages // {
                  shells = devShells // {
                    default = devShell;
                  };
                  internal = {
                    roots.project = project.roots;
                    plan-nix.project = project.plan-nix;
                  };
                };
                musl =
                  let
                    muslProject = project.projectCross.musl64;
                    projectPackages = haskellLib.selectProjectPackages muslProject.hsPkgs;
                    projectExes = flatten (collectComponents' "exes" projectPackages);
                  in
                  projectExes // {
                    cardano-node-linux = import ./nix/binary-release.nix {
                      inherit pkgs;
                      inherit (exes.cardano-node.identifier) version;
                      platform = "linux";
                      exes = lib.attrValues projectExes;
                    };
                    internal.roots.project = muslProject.roots;
                  };
                windows =
                  let
                    windowsProject = project.projectCross.mingwW64;
                    projectPackages = haskellLib.selectProjectPackages windowsProject.hsPkgs;
                    projectExes = flatten (collectComponents' "exes" projectPackages);
                  in
                  projectExes
                    // (removeRecurse {
                    checks = collectChecks' projectPackages;
                    tests = collectComponents' "tests" projectPackages;
                    benchmarks = collectComponents' "benchmarks" projectPackages;
                    cardano-node-win64 = import ./nix/binary-release.nix {
                      inherit pkgs;
                      inherit (exes.cardano-node.identifier) version;
                      platform = "win64";
                      exes = lib.attrValues projectExes;
                    };
                    internal.roots.project = windowsProject.roots;
                  });
              };
            } // optionalAttrs (system == "x86_64-darwin") {
            macos = packages // {
              cardano-node-macos = import ./nix/binary-release.nix {
                inherit pkgs;
                inherit (exes.cardano-node.identifier) version;
                platform = "macos";
                exes = lib.attrValues projectExes;
              };
              shells = devShells // {
                default = devShell;
              };
              internal = {
                roots.project = project.roots;
                plan-nix.project = project.plan-nix;
              };
            };
          };
        }
      );
    in
    builtins.removeAttrs flake [ "systemHydraJobs" ] // {
      hydraJobs =
        let
          jobs = lib.foldl' lib.mergeAttrs { } (lib.attrValues flake.systemHydraJobs);
          nonRequiredPaths = map lib.hasPrefix [ ];
        in
        jobs // {
          required = self.legacyPackages.${defaultSystem}.pkgs.releaseTools.aggregate {
            name = "github-required";
            meta.description = "All jobs required to pass CI";
            constituents = lib.collect lib.isDerivation (lib.mapAttrsRecursiveCond (v: !(lib.isDerivation v))
              (path: value:
                let stringPath = lib.concatStringsSep "." path; in if (lib.any (p: p stringPath) nonRequiredPaths) then { } else value)
              jobs);
          };
        };
      overlay = import ./overlay.nix self;
      nixosModules = {
        cardano-node = { pkgs, lib, ... }: {
          imports = [ ./nix/nixos/cardano-node-service.nix ];
          services.cardano-node.cardanoNodePkgs = lib.mkDefault self.legacyPackages.${pkgs.system};
        };
        cardano-submit-api = { pkgs, lib, ... }: {
          imports = [ ./nix/nixos/cardano-submit-api-service.nix ];
          services.cardano-submit-api.cardanoNodePkgs = lib.mkDefault self.legacyPackages.${pkgs.system};
        };
      };
    };
}
