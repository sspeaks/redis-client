{ pkgs ? import <nixpkgs> { }, ... }:
rec {
  fullPackage = pkgs.haskellPackages.callCabal2nix "redis-client" ./. { };
  justStaticEndToEnd = pkgs.lib.pipe fullPackage [
    pkgs.haskell.lib.justStaticExecutables
    pkgs.haskell.lib.dontCheck
    (pkgs.lib.flip pkgs.haskell.lib.setBuildTargets [ "EndToEnd" ])
  ];
}
