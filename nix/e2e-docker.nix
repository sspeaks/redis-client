{ pkgs ? import <nixpkgs> { }
, imageName ? "e2eTests"
, imageTag ? "latest"
, imageOwner ? "unowned"
}:
let pack = (import ../default.nix { }).justStaticEndToEnd;
in pkgs.dockerTools.buildImage {
  name = imageName;
  tag = imageTag;
  config = {
    Cmd = [ "${pack}/bin/EndToEnd" ];
    Labels = {
      "com.redis-client.e2e.owner" = imageOwner;
    };
  };
}
