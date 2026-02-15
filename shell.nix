{ pkgs ? import <nixpkgs> { }, ... }:
let
  src = builtins.path { path = ./.; name = "source"; };
  hask-redis-mux = pkgs.haskellPackages.callCabal2nixWithOptions
    "hask-redis-mux"
    src "--subpath hask-redis-mux"
    { };
  redis-client = pkgs.haskellPackages.callCabal2nix "redis-client" src { inherit hask-redis-mux; };
in
pkgs.haskellPackages.shellFor {
  packages = hpkgs: [ redis-client hask-redis-mux ];
  nativeBuildInputs = with (pkgs.haskellPackages); [
    haskell-language-server
    cabal-install
    stylish-haskell
    pkgs.zlib
    pkgs.dotnet-sdk_8
    (pkgs.python3.withPackages (ps: [ ps.markdown ps.pygments ]))
  ];
  shellHook = ''
    git config core.hooksPath .githooks
  '';
}
