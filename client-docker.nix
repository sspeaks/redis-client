# docker load <$(nix-build client-docker.nix) && docker run -it --network docker-cluster_redis-cluster-net client
{ pkgs ? import <nixpkgs> { } }:
let pack = (import ./default.nix { }).justClient;
in pkgs.dockerTools.buildImage {
  name = "client";
  tag = "latest";
  contents = [ pack pkgs.bash pkgs.redis ];
  config = {
    Cmd = [ "${pkgs.bash}/bin/bash" ];
     WorkingDir = "/data";
  };
  extraCommands = ''
    mkdir -p data
    cp ${./cluster_slot_mapping.txt} data/cluster_slot_mapping.txt
  '';
 }
