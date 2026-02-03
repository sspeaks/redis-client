{ pkgs ? import <nixpkgs> { } }:
let pack = (import ./default.nix { }).justStaticClusterEndToEnd;
in pkgs.dockerTools.buildImage {
  name = "clusterE2eTests";
  tag = "latest";
  config = {
    Cmd = [ "${pack}/bin/ClusterEndToEnd" ];
  };
}
