{ pkgs ? import <nixpkgs> { } }:
let pack = (import ./default.nix { }).justStaticEndToEnd;
in pkgs.dockerTools.buildImage {
  name = "e2eTests";
  tag = "latest";
  config = {
    Cmd = [ "${pack}/bin/EndToEnd" ];
  };
}
