{
  description = "opencode packaged for Nix from its published npm prebuilt binaries (Linux)";

  # Use git+https:// rather than the `github:` shorthand: the shorthand
  # resolves refs through the GitHub REST API, which is rate limited to 60
  # requests per hour per unauthenticated IP — a single `nix flake metadata` can
  # hit 403. git+https speaks the git protocol and is not subject to that limit.
  inputs.nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?ref=nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # Linux only: the npm platform packages exist for linux-x64 and
      # linux-arm64, and that is what consumers here run.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system: {
        opencode = nixpkgs.legacyPackages.${system}.callPackage ./package.nix { };
        default = self.packages.${system}.opencode;
      });

      # For consumers that prefer `pkgs.opencode` over a flake attribute. The
      # registry stays overridable: `pkgs.opencode.override { registry = …; }`
      # works because the package is a callPackage function.
      overlays.default = final: prev: {
        opencode = final.callPackage ./package.nix { };
      };

      # No `checks`: `nix flake check` would build them on every system, and an
      # aarch64 binary cannot execute on an x86_64 host without binfmt
      # emulation. CI covers both instead — a real build on x86_64, evaluation
      # on aarch64.

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
