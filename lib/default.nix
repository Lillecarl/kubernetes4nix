{
  lib,
}:

let
  /**
    Build a package set from the version matrix.

    A release series is considered when `include` accepts it; supported
    series by default. A patch of a considered series is included when its
    `pins` record holds a hash for `strategy`; a patch without that pin is
    skipped rather than making the whole set fail.

    # Inputs

    `releases`
    : The `releases` list from `versions.json`

    `strategy`
    : Pin name to build with, for example `src` or `client-amd64`

    `mkPackage`
    : `{ version, pin } -> derivation`

    `include`
    : `release -> Bool`, which series to include. Defaults to
      `release: release.supported`

    # Type

    ```
    packageSet :: { releases, strategy, mkPackage, include ? ... } -> { <version> = derivation; }
    ```
  */
  packageSet =
    {
      releases,
      strategy,
      mkPackage,
      include ? (release: release.supported),
    }:
    let
      mkPatch =
        patch:
        let
          pin = patch.pins.${strategy} or null;
        in
        lib.optionalAttrs (pin != null) {
          ${patch.version} = mkPackage {
            inherit (patch) version;
            inherit pin;
          };
        };
      mkRelease = release: lib.optionalAttrs (include release) (lib.mergeAttrsList (map mkPatch release.patches));
    in
    lib.mergeAttrsList (map mkRelease releases);

  /**
    The highest released version in a package set, or `null` when it holds no
    release. Prereleases are ignored: Nix orders `1.37.0-rc.1` above `1.37.0`,
    so without the filter a candidate could win.

    # Type

    ```
    latest :: { <version> = derivation; } -> derivation | null
    ```
  */
  latest =
    set:
    let
      releases = lib.filter (version: !(lib.hasInfix "-" version)) (builtins.attrNames set);
      sorted = lib.sort lib.versionOlder releases;
    in
    if sorted == [ ] then null else set.${lib.last sorted};

  /**
    Rename a package set for a flat, flake-friendly namespace.

    # Type

    ```
    flat :: String -> { <version> = derivation; } -> { "<prefix>-<version>" = derivation; }
    ```
  */
  flat =
    prefix: set:
    lib.mapAttrs' (version: package: lib.nameValuePair "${prefix}-${version}" package) set;
in
{
  inherit flat latest packageSet;
}
