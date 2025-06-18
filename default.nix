{ pkgs ? import <nixpkgs> { }, ... }:
let src = builtins.path { path = ./.; name = "source"; };
in 
rec {
  fullPackage = pkgs.haskellPackages.callCabal2nix "redis-client" src { };
  justStaticEndToEnd = pkgs.lib.pipe fullPackage [
    pkgs.haskell.lib.justStaticExecutables
    pkgs.haskell.lib.dontCheck
    (pkgs.lib.flip pkgs.haskell.lib.setBuildTargets [ "EndToEnd" ])
  ];
}
