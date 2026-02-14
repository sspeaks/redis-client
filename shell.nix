{ pkgs ? import <nixpkgs> { }, ... }:
pkgs.haskellPackages.shellFor {
  packages = hpkgs: [
    (import ./default.nix { }).justStaticEndToEnd
  ];
  nativeBuildInputs = with (pkgs.haskellPackages); [
    haskell-language-server
    cabal-install
    stylish-haskell
    pkgs.zlib
  ];
  shellHook = ''
    git config core.hooksPath .githooks
  '';
}
