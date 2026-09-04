{ pkgs ? import <nixpkgs> { } }:
let pack = (import ../default.nix { }).justStaticAuthenticatedClusterEndToEnd;
in pkgs.dockerTools.buildImage {
  name = "authenticatedClusterE2eTests";
  tag = "latest";
  contents = [ pack ];
  config = {
    Cmd = [ "${pack}/bin/AuthenticatedClusterEndToEnd" ];
  };
}
