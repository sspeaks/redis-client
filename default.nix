{ pkgs ? import <nixpkgs> { }, ... }:
let 
  src = builtins.path { path = ./.; name = "source"; };
  scriptSrc = ./azure-redis-connect.py;
in 
rec {
  fullPackage = pkgs.haskellPackages.callCabal2nix "redis-client" src { };
  justStaticEndToEnd = pkgs.lib.pipe fullPackage [
    pkgs.haskell.lib.justStaticExecutables
    pkgs.haskell.lib.dontCheck
    (pkgs.lib.flip pkgs.haskell.lib.setBuildTargets [ "EndToEnd" "redis-client" ])
  ];
  
  # Wrapper package that includes both redis-client and azure-redis-connect
  fullPackageWithScripts = pkgs.symlinkJoin {
    name = "redis-client-with-scripts";
    paths = [ fullPackage ];
    buildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      # Install the azure-redis-connect script
      mkdir -p $out/bin
      cp ${scriptSrc} $out/bin/azure-redis-connect
      chmod +x $out/bin/azure-redis-connect
      
      # Wrap the script to ensure python3 is in PATH
      wrapProgram $out/bin/azure-redis-connect \
        --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.python3 ]}
    '';
  };
}
