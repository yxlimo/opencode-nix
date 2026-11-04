{
  description = "opencode CLI packaged from its npm prebuilt binaries (per-platform), self-contained and registry-agnostic";

  # 用 git+https:// 而不是 github: 简写：
  #   `github:` 靠 GitHub REST API 解析 ref，未认证时每 IP 每小时只有 60 次，
  #   一次 flake metadata 就可能撞 403。git+https: 走 git 协议，不受该限流约束。
  inputs.nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?ref=nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # 本仓只做 Linux：opencode 的 npm 平台包在 linux-x64 / linux-arm64 上都有，
      # 而我们自己的四台机器（WSL / Mac T2 / NAS / Oracle）全是 Linux。
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

      # consumer 侧最简单的用法：
      #   overlay = final: prev: { opencode = prev.callPackage "${thisFlake}/package.nix" { }; };
      # 或直接用 packages.<system>.opencode，再用 .override { registry = ...; } 换源。
      overlays.default = final: prev: {
        opencode = final.callPackage ./package.nix { };
      };

      # 不做 checks：`checks` 会被 `nix flake check` 在所有系统上构建，
      # 而 aarch64 的二进制在 x86_64 机器上根本执行不了（需要 binfmt 模拟）。
      # 两个平台的可用性交给 CI：x86_64 真构建、aarch64 求值验证。

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
