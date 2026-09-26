{
  lib,
}:

let
  /**
    Build a package set from the version matrix.

    Only supported release series are considered. A patch is included when its
    `pins` record holds a hash for `strategy`; a patch without that pin is
    skipped rather than making the whole set fail.

    # Inputs

    `releases`
    : The `releases` list from `versions.json`

    `strategy`
    : Pin name to build with, for example `src` or `client-amd64`

    `mkPackage`
    : `{ version, pin } -> derivation`

    # Type

    ```
    packageSet :: { releases, strategy, mkPackage } -> { <version> = derivation; }
    ```
  */
  packageSet =
    {
      releases,
      strategy,
      mkPackage,
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
      mkRelease = release: lib.optionalAttrs release.supported (lib.mergeAttrsList (map mkPatch release.patches));
    in
    lib.mergeAttrsList (map mkRelease releases);

  /**
    The highest version in a package set, or `null` when it is empty.

    # Type

    ```
    latest :: { <version> = derivation; } -> derivation | null
    ```
  */
  latest =
    set:
    let
      versions = lib.sort lib.versionOlder (builtins.attrNames set);
    in
    if versions == [ ] then null else set.${lib.last versions};

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
