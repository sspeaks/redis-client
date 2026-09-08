{ pkgs ? import <nixpkgs> { }
, imageName ? "directTlsE2eTests"
, imageTag ? "latest"
, imageOwner ? ""
}:
let pack = (import ../default.nix { }).justStaticDirectTLSEndToEnd;
in pkgs.dockerTools.buildImage {
  name = imageName;
  tag = imageTag;
  contents = [ pack pkgs.cacert ];
  config = {
    Cmd = [ "${pack}/bin/DirectTLSEndToEnd" ];
    Env = [
      "SSL_CERT_FILE=/certs/redis-ca.crt"
      "SYSTEM_CERTIFICATE_PATH=/certs/redis-ca.crt"
    ];
    Labels = {
      "com.redis-client.e2e.owner" = imageOwner;
    };
  };
}
