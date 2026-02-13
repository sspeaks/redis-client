{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { nixpkgs, flake-utils, ... }:
    let
      src = builtins.path { path = ./.; name = "source"; };

      # Overlay that adds redis-client to haskellPackages.
      # Apply this in your own flake to use redis-client as a library:
      #   nixpkgs.overlays = [ redis-client.overlays.default ];
      overlay = final: prev: {
        haskellPackages = prev.haskellPackages.override {
          overrides = hfinal: hprev: {
            hask-redis-mux = hfinal.callCabal2nixWithOptions
              "hask-redis-mux" src "--subpath hask-redis-mux" { };
            redis-client = hfinal.callCabal2nix "redis-client" src {
              inherit (hfinal) hask-redis-mux;
            };
          };
        };
      };
    in
    {
      overlays.default = overlay;
    } // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };
      in
      {
        defaultPackage = (import ./default.nix { inherit pkgs; }).fullPackageWithScripts;
        devShell = import ./shell.nix { inherit pkgs; };
        formatter = pkgs.nixpkgs-fmt;
      });
}
