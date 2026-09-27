{
  description = "Build every supported Kubernetes version and patch with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-2605.url = "github:NixOS/nixpkgs/nixos-26.05";
    # The channel's own immutable link, so the input never changes under the
    # lock when the channel advances.
    cyberus-2605.url = "tarball+https://channels.cyberus-linux.com/permanent/ctrlos-247c37c59474f7821f1ca9ea787305a03b150e74.tar.xz";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = function: lib.genAttrs systems function;

      # The nixpkgs each package set is built against. The key is the name the
      # CI matrix and `legacyPackages` use.
      channels = {
        nixos-unstable = nixpkgs;
        "nixos-26.05" = inputs.nixos-2605;
        "cyberus-linux-26.05" = inputs.cyberus-2605;
      };

      outputsFor =
        system: channel:
        (import ./default.nix {
          pkgs = channels.${channel}.legacyPackages.${system};
        }).outputs;

      channelsFor = system: lib.mapAttrs (channel: _: outputsFor system channel) channels;
    in
    {
      # The plain names stay on nixos-unstable; the others live under
      # legacyPackages.<system>.<channel>.
      packages = forAllSystems (
        system:
        let
          primary = outputsFor system "nixos-unstable";
        in
        primary.packages // { default = primary.default; }
      );

      legacyPackages = forAllSystems channelsFor;

      overlays.default = import ./overlay.nix;

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              (pkgs.python3.withPackages (packages: [ packages.anyio ]))
              pkgs.git
              pkgs.yq-go
            ];
          };
        }
      );
    };
}
