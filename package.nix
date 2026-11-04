# opencode —— 从 npm 拉上游预编译二进制（与官方安装脚本同一个产物）。
#
# 这个包只做三件事：下载平台 tarball、解出 bin/opencode、把它 patch 成能在
# NixOS 上跑。版本与哈希都在 sources.json（由 bin/update-sources.sh 维护）。
#
# 为什么必须 autoPatchelfHook：上游二进制是动态链接的 ELF（PT_INTERP 指
# /lib64/ld-linux-x86-64.so.2），不 patch 的话在 NixOS 上根本起不来
# —— 只能在 FHS 发行版上用。这是很多第三方 flake 漏掉的一步。
#
# registry 是参数而不是常量，目的：仓库本身面向全球（默认官方 npm），
# 国内机器由 consumer 传镜像地址。换源哈希照样成立 —— 镜像与官方是同一份
# tarball（两边 registry 的 dist.shasum 一致，bin/update-sources.sh 每次都会校验）。
{ lib
, stdenv
, fetchurl
, autoPatchelfHook
, libgcc
, registry ? "https://registry.npmjs.org"
, sourcesFile ? ./sources.json
}:

let
  sources = lib.importJSON sourcesFile;
  system = stdenv.hostPlatform.system;
  platform =
    sources.platforms.${system}
      or (throw "opencode: unsupported system '${system}'; supported: ${lib.concatStringsSep ", " (lib.attrNames sources.platforms)}");
in
stdenv.mkDerivation {
  pname = "opencode";
  version = sources.version;

  src = fetchurl {
    url = "${registry}/${platform.package}/-/${platform.tarball}-${platform.version}.tgz";
    hash = platform.hash;
  };

  # npm tarball 的顶层目录固定是 package/
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
    description = "AI coding agent built for the terminal (upstream prebuilt npm binary)";
    homepage = "https://github.com/anomalyco/opencode";
    changelog = "https://github.com/anomalyco/opencode/releases";
    license = lib.licenses.mit;
    mainProgram = "opencode";
    platforms = lib.attrNames sources.platforms;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
