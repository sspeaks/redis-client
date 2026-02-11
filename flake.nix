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
            redis-client = hfinal.callCabal2nix "redis-client" src { };
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
