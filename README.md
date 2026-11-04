# opencode-nix

`opencode` packaged for Nix from its published npm prebuilt binaries. No
TypeScript build, no source checkout — the tarball is whatever upstream
published, already compiled.

Linux only: `x86_64-linux`, `aarch64-linux`.

## Usage

Add the flake as an input:

```nix
{
  inputs.opencode-nix.url = "github:yxlimo/opencode-nix";

  # Optional, but avoids pulling a second copy of nixpkgs.
  inputs.opencode-nix.inputs.nixpkgs.follows = "nixpkgs";
}
```

Install it — NixOS, Home Manager and a devShell all use the same attribute path:

```nix
environment.systemPackages = [ inputs.opencode-nix.packages.${pkgs.system}.opencode ];
# or: home.packages = [ inputs.opencode-nix.packages.${pkgs.system}.opencode ];
```

Try it without installing anything:

```bash
nix run github:yxlimo/opencode-nix
```

If you would rather have `pkgs.opencode` than a flake attribute, use the
overlay:

```nix
nixpkgs.overlays = [ inputs.opencode-nix.overlays.default ];

environment.systemPackages = [ pkgs.opencode ];
```

### Pinning a version

Every update publishes a `v<version>` tag and a GitHub release, so you can pin a
readable version instead of a commit revision:

```nix
# Track upstream (recommended; flake.lock pins the exact revision anyway).
inputs.opencode-nix.url = "github:yxlimo/opencode-nix";

# Freeze one opencode version.
inputs.opencode-nix.url = "github:yxlimo/opencode-nix/v2.2.5";
```

With a `git+https://` URL the ref must be written in full — `?ref=v2.2.5` is
looked up as a **branch** and fails with
`couldn't find remote ref refs/heads/v2.2.5`:

```nix
inputs.opencode-nix.url = "git+https://github.com/yxlimo/opencode-nix?ref=refs/tags/v2.2.5";
```

### Choosing a registry

The registry is a `callPackage` argument, not a constant. The default is the
official npm registry — this repository is meant to be used worldwide — and a
mirror is opt-in at the consumer:

```nix
opencode = (inputs.opencode-nix.packages.${pkgs.system}.opencode).override {
  registry = "https://registry.npmmirror.com";
};
```

Switching registries does not change the hashes: a mirror serves the same
tarball, byte for byte. The update script verifies that on every run by
comparing `dist.shasum` from both registries before writing anything, and a
mismatch fails the build instead of silently installing different code.

## How updates happen

`sources.json` is the single source of truth for the version and the per-platform
hashes. It is maintained by `bin/update-sources.sh`:

```
1. ask the registry for @opencode/cli@latest           -> version
2. read its optionalDependencies for per-platform versions
3. cross-check: official and mirror dist.shasum must match
4. nix-prefetch-url each platform tarball              -> write sources.json
```

Triggering is **event driven; there is no cron**:

- `repository_dispatch` (type `upstream-release`): sent by an external relay
  after upstream publishes a release;
- `workflow_dispatch`: manual catch-up (`gh workflow run update.yml`).

GitHub only delivers `release` events for releases of the repository itself, so
a repository that packages someone else's software needs a relay to poll
upstream and dispatch. The relay is not part of this repository (it runs as a
systemd timer on the consumer's server); see the consumer's docs.

On a successful update the workflow commits `sources.json`, tags `v<version>`
and publishes a GitHub release listing both platform hashes.

## Notes

- The npm tarball contains dynamic ELF binaries whose `PT_INTERP` pointed at
  `/lib64/ld-linux-x86-64.so.2`. `package.nix` runs `autoPatchelfHook` (plus
  `libgcc`), which repoints the interpreter at the nix glibc. Without that step
  the binary builds fine and then fails on NixOS with
  `cannot execute: required file not found` — it only ever worked on FHS
  distributions.
- Only the `v2` line is packaged. Upstream still publishes `v1` (`opencode-ai`
  1.x); its tags are not picked up.
- The version of a platform package can differ from the root package, so it is
  read from `optionalDependencies` rather than assumed equal.

## Layout

| Path | What it is |
|---|---|
| `flake.nix` | flake outputs: `packages`, `overlays.default` |
| `package.nix` | the derivation; `registry` and `sourcesFile` are arguments |
| `sources.json` | version and per-platform hashes, maintained by CI |
| `bin/update-sources.sh` | regenerate `sources.json` from the registry |
| `.github/workflows/update.yml` | update (dispatch-driven) and build (push/PR) jobs |

## Credits

The structure follows
[mikael-lindstrom/opencode-flake](https://github.com/mikael-lindstrom/opencode-flake),
which packages the same binaries on a daily schedule in a single file. This
repository differs in that the data lives in `sources.json` instead of a regex
rewrite of `flake.nix`, the CI cross-checks registries, `autoPatchelfHook` is
present, and the `v1` line is dropped.
