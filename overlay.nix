# Add the package sets to any nixpkgs:
#
#   nixpkgs.overlays = [ (import ./overlay.nix) ];
#   pkgs.kubernetes4nix.latest
#
# The sets are built against the package set the overlay is applied to, so an
# overlay on a channel builds for that channel.
final: _prev:
{
  kubernetes4nix = (import ./default.nix { pkgs = final; }).outputs;
}
