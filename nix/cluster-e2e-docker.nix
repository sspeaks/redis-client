{ pkgs ? import <nixpkgs> { }
, imageName ? "clusterE2eTests"
, imageTag ? "latest"
, imageOwner ? ""
}:
let pack = (import ../default.nix { }).justStaticClusterEndToEnd;
in pkgs.dockerTools.buildImage {
  name = imageName;
  tag = imageTag;
  contents = [ pack ];
  config = {
    Cmd = [ "${pack}/bin/ClusterEndToEnd" ];
    Labels = {
      "com.redis-client.e2e.owner" = imageOwner;
    };
  };
}
