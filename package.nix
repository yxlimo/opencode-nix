# opencode, from the npm prebuilt binaries upstream publishes — the same
# artifact the official install script downloads.
#
# The derivation does three things: fetch the platform tarball, install
# bin/opencode, and patch it so it runs on NixOS. Version and per-platform
# hashes live in sources.json, maintained by bin/update-sources.sh.
#
# autoPatchelfHook is not optional here: the binaries are dynamically linked
# ELF with PT_INTERP pointing at /lib64/ld-linux-x86-64.so.2. Without repointing
# that at the nix glibc they only run on FHS distributions.
#
# `registry` is an argument rather than a constant on purpose: the repository
# targets the official npm registry by default, and consumers in regions where
# that is slow pass a mirror. Hashes survive the switch because both registries
# serve the same tarball — bin/update-sources.sh verifies that on every run.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  libgcc,
  registry ? "https://registry.npmjs.org",
  sourcesFile ? ./sources.json,
}:

let
  sources = lib.importJSON sourcesFile;
  system = stdenv.hostPlatform.system;
  platform =
    sources.platforms.${system}
      or (throw "opencode: unsupported system '${system}'; supported: ${lib.concatStringsSep ", " (lib.attrNames sources.platforms)}");

  # Strip a possible trailing slash, otherwise the URL gets a double slash.
  reg = lib.removeSuffix "/" registry;
in
stdenv.mkDerivation {
  pname = "opencode";
  version = sources.version;

  src = fetchurl {
    url = "${reg}/${platform.package}/-/${platform.tarball}-${platform.version}.tgz";
    hash = platform.hash;
  };

  # An npm tarball always unpacks into a top-level package/ directory.
  sourceRoot = "package";

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ libgcc ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 bin/opencode $out/bin/opencode
    runHook postInstall
  '';

  meta = {
    description = "AI coding agent built for the terminal (upstream npm prebuilt binary)";
    homepage = "https://github.com/anomalyco/opencode";
    changelog = "https://github.com/anomalyco/opencode/releases";
    license = lib.licenses.mit;
    mainProgram = "opencode";
    platforms = lib.attrNames sources.platforms;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
