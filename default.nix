{ pkgs ? import <nixpkgs> { }, ... }:
let
  src = builtins.path { path = ./.; name = "source"; };
  scriptSrc = ./scripts/azure-redis-connect.py;
  # Build hask-redis-mux: sources are self-contained in hask-redis-mux/
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

  justStaticAuthenticatedClusterEndToEnd = pkgs.lib.pipe e2ePackageWithFlag [
    pkgs.haskell.lib.justStaticExecutables
    pkgs.haskell.lib.dontCheck
    (pkgs.lib.flip pkgs.haskell.lib.setBuildTargets [ "AuthenticatedClusterEndToEnd" ])
  ];

  justStaticDirectTLSEndToEnd = pkgs.lib.pipe e2ePackageWithFlag [
    pkgs.haskell.lib.justStaticExecutables
    pkgs.haskell.lib.dontCheck
    (pkgs.lib.flip pkgs.haskell.lib.setBuildTargets [ "DirectTLSEndToEnd" ])
  ];

  justStaticLibraryEndToEnd = pkgs.lib.pipe e2ePackageWithFlag [
    pkgs.haskell.lib.justStaticExecutables
    pkgs.haskell.lib.dontCheck
    (pkgs.lib.flip pkgs.haskell.lib.setBuildTargets [ "LibraryE2E" ])
  ];

  justClient = pkgs.lib.pipe fullPackage [
    pkgs.haskell.lib.justStaticExecutables
    pkgs.haskell.lib.dontCheck
    (pkgs.lib.flip pkgs.haskell.lib.setBuildTargets [ "redis-client" "redis-client-benchmark" ])
  ];

  dockerImage = pkgs.dockerTools.buildLayeredImage {
    name = "ghcr.io/sspeaks/redis-client";
    tag = "latest";
    contents = [ justClient pkgs.cacert pkgs.jq pkgs.curl pkgs.bash pkgs.coreutils ];
    config = {
      Entrypoint = [ "/bin/redis-client" ];
    };
  };

  # Wrapper package that includes redis-client and the Azure helper.
  fullPackageWithScripts = pkgs.stdenv.mkDerivation {
    name = "redis-client-full";

    unpackPhase = "true";

    installPhase = ''
      mkdir -p $out/bin
      
      # Copy all binaries from the Haskell package
      if [ -d "${justClient}/bin" ]; then
        cp -rL ${justClient}/bin/. $out/bin/
      fi
      
      # Install the canonical Azure helper command.
      cp ${scriptSrc} $out/bin/azure-redis-connect
      chmod +x $out/bin/azure-redis-connect
      substituteInPlace $out/bin/azure-redis-connect \
        --replace-fail '#!/usr/bin/env python3' '#!${pkgs.python3}/bin/python3'

      # Preserve the previously shipped short name as a compatibility alias.
      ln -s azure-redis-connect $out/bin/redis-connect
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      $out/bin/azure-redis-connect --help >/dev/null
      $out/bin/redis-connect --help >/dev/null
    '';
  };
}
