{ pkgs ? import <nixpkgs> {}, ... }:
pkgs.haskellPackages.callCabal2nix "redis-client" ./. {}
