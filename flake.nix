{
  description = "Build every supported Kubernetes version and patch with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = function: nixpkgs.lib.genAttrs systems function;

      outputsFor =
        system:
        (import ./default.nix {
          pkgs = nixpkgs.legacyPackages.${system};
        }).outputs;
    in
    {
      packages = forAllSystems (
        system:
        let
          outputs = outputsFor system;
        in
        outputs.packages // { default = outputs.default; }
      );

      legacyPackages = forAllSystems outputsFor;

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              (pkgs.python3.withPackages (ps: [ ps.anyio ]))
              pkgs.git
              pkgs.yq
            ];
          };
        }
      );
    };
}
