{ pkgs ? import <nixpkgs> {}, ... }:
pkgs.haskellPackages.shellFor {
  packages = hpkgs: [
    (import ./default.nix {})
  ];
  nativeBuildInputs = with (pkgs.haskellPackages); [
     haskell-language-server
     cabal-install
     stylish-haskell
  ];
}
