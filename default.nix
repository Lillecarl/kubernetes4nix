{ pkgs ? import <nixpkgs> { } }:

let
  inherit (pkgs) lib;

  data = builtins.fromJSON (builtins.readFile ./versions.json);
  helpers = import ./lib { inherit lib; };

  # Kubernetes release archives are named for the Go architecture, so aarch64
  # asks for arm64 pins and finds none until the updater has fetched them.
  arch = pkgs.go.GOARCH;

  mkSource =
    { version, pin }:
    pkgs.callPackage ./pkgs/kubernetes-source.nix {
      inherit version;
      hash = pin;
    };

  mkBinary =
    flavor:
    { version, pin }:
    pkgs.callPackage ./pkgs/kubernetes-binary.nix {
      inherit version arch flavor;
      hash = pin;
    };

  set =
    strategy: mkPackage:
    helpers.packageSet {
      releases = data.releases;
      inherit strategy mkPackage;
    };

  source = set "src" mkSource;
  client = set "client-${arch}" (mkBinary "client");
  server = set "server-${arch}" (mkBinary "server");
  node = set "node-${arch}" (mkBinary "node");

  packages =
    (helpers.flat "kubernetes" source)
    // (helpers.flat "kubernetes-client" client)
    // (helpers.flat "kubernetes-server" server)
    // (helpers.flat "kubernetes-node" node);

  latestSource = helpers.latest source;
  latestClient = helpers.latest client;
in
{
  outputs = {
    inherit
      client
      node
      packages
      server
      source
      ;

    inherit (data) generated releases sources strategies;

    default = latestSource;
    latest = latestSource;
  }
  // lib.optionalAttrs (latestClient != null) {
    kubectl = latestClient;
  };
}
