{ pkgs ? import <nixpkgs> { }
, imageName ? "e2eTests"
, imageTag ? "latest"
}:
let pack = (import ../default.nix { }).justStaticEndToEnd;
in pkgs.dockerTools.buildImage {
  name = imageName;
  tag = imageTag;
  config = {
    Cmd = [ "${pack}/bin/EndToEnd" ];
  };
}
