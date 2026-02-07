{ pkgs ? import <nixpkgs> { } }:
let pack = (import ../default.nix { }).justStaticLibraryEndToEnd;
in pkgs.dockerTools.buildImage {
  name = "libraryE2eTests";
  tag = "latest";
  contents = [ pack pkgs.docker-client ];
  config = {
    Cmd = [ "${pack}/bin/LibraryE2E" ];
  };
}
