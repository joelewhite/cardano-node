#!/usr/bin/env bash
set -euo pipefail
cd $(git rev-parse --show-toplevel)

nix build .#pkgs.iohkNix.cabalProjectRegenerate --option substituters "https://hydra.iohk.io https://cache.nixos.org" --option trusted-substituters "" --option trusted-public-keys "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
./result/bin/cabal-project-regenerate

# Regenerate the list of the project packages:
nix eval .#pkgs.projectPackages > nix/project-packages.nix.new
mv nix/project-packages.nix.new nix/project-packages.nix
