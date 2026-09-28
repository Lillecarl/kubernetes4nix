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

  # A series is built when it is supported, or still in development with
  # release candidates and no final release yet.
  included = release: release.supported || release.development;
  stable = release: release.supported;

  set =
    {
      strategy,
      mkPackage,
      include ? stable,
    }:
    helpers.packageSet {
      releases = data.releases;
      inherit strategy mkPackage include;
    };

  source = set {
    strategy = "src";
    mkPackage = mkSource;
    include = included;
  };
  client = set {
    strategy = "client-${arch}";
    mkPackage = mkBinary "client";
    include = included;
  };
  server = set {
    strategy = "server-${arch}";
    mkPackage = mkBinary "server";
    include = included;
  };
  node = set {
    strategy = "node-${arch}";
    mkPackage = mkBinary "node";
    include = included;
  };

  packages =
    (helpers.flat "kubernetes" source)
    // (helpers.flat "kubernetes-client" client)
    // (helpers.flat "kubernetes-server" server)
    // (helpers.flat "kubernetes-node" node);

  # Convenience aliases point at the latest released version; helpers.latest
  # ignores release candidates.
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
