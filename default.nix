{ pkgs ? import <nixpkgs> { }, ... }:
let
  src = builtins.path { path = ./.; name = "source"; };
  scriptSrc = ./scripts/azure-redis-connect.py;
  # Build hask-redis-mux: the cabal file is in hask-redis-mux/ but sources are in ../lib/
  # We give it the full repo and tell cabal2nix to look in the hask-redis-mux subdir
  hask-redis-mux = pkgs.haskell.lib.dontCheck (pkgs.haskellPackages.callCabal2nixWithOptions
    "hask-redis-mux"
    src "--subpath hask-redis-mux"
    { });
in
rec {
  fullPackage = pkgs.haskellPackages.callCabal2nix "redis-client" src { inherit hask-redis-mux; };
  e2ePackageWithFlag = pkgs.haskell.lib.enableCabalFlag
    (pkgs.haskell.lib.addBuildDepends fullPackage [
      pkgs.haskellPackages.hspec
      pkgs.haskellPackages.async
    ])
    "e2e";
  justStaticEndToEnd = pkgs.lib.pipe e2ePackageWithFlag [
    pkgs.haskell.lib.justStaticExecutables
    pkgs.haskell.lib.dontCheck
    (pkgs.lib.flip pkgs.haskell.lib.setBuildTargets [ "EndToEnd" "redis-client" ])
  ];

  justStaticClusterEndToEnd = pkgs.lib.pipe e2ePackageWithFlag [
    pkgs.haskell.lib.justStaticExecutables
    pkgs.haskell.lib.dontCheck
    (pkgs.lib.flip pkgs.haskell.lib.setBuildTargets [ "ClusterEndToEnd" "redis-client" ])
  ];

  justStaticLibraryEndToEnd = pkgs.lib.pipe e2ePackageWithFlag [
    pkgs.haskell.lib.justStaticExecutables
    pkgs.haskell.lib.dontCheck
    (pkgs.lib.flip pkgs.haskell.lib.setBuildTargets [ "LibraryE2E" ])
  ];

  justClient = pkgs.lib.pipe fullPackage [
    pkgs.haskell.lib.justStaticExecutables
    pkgs.haskell.lib.dontCheck
    (pkgs.lib.flip pkgs.haskell.lib.setBuildTargets [ "redis-client" ])
  ];

  # Wrapper package that includes both redis-client and azure-redis-connect
  fullPackageWithScripts = pkgs.stdenv.mkDerivation {
    name = "redis-client-full";

    buildInputs = [ pkgs.makeWrapper ];

    unpackPhase = "true";

    installPhase = ''
      mkdir -p $out/bin
      
      # Copy all binaries from the Haskell package
      if [ -d "${justClient}/bin" ]; then
        cp -rL ${justClient}/bin/. $out/bin/
      fi
      
      # Install the azure-redis-connect script
      cp ${scriptSrc} $out/bin/redis-connect
      chmod +x $out/bin/redis-connect
      
      # Wrap the script to ensure python3 is in PATH
      wrapProgram $out/bin/redis-connect \
        --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.python3 ]}
    '';
  };
}
