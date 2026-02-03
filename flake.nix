{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        defaultPackage = (import ./default.nix { inherit pkgs; }).fullPackageWithScripts;
        devShell = import ./shell.nix { inherit pkgs; };
        formatter = pkgs.nixpkgs-fmt;
      });
}
