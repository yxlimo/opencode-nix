# opencode-nix

把 [opencode](https://github.com/anomalyco/opencode) 的 **npm 预编译二进制**包成 Nix 包。
只做 Linux（`x86_64-linux` / `aarch64-linux`）。

## 为什么有这个仓

opencode 两三天发一版，版本跟 nixpkgs 的节奏对不上；而自己在下游仓里维护
`version` + `sha256` 又会踩两个坑：

1. 包管理工具（`nix-update` 等）通常只重算**当前这台机器的平台**的哈希，
   另一个平台的哈希会悄悄过期，直到有人在那台机器上构建才发现；
2. npm 的 registry 可能被换成镜像，而多数自动更新工具把 registry 写死成官方域名。

所以版本与每平台哈希集中放在 `sources.json`，由一个脚本一次性更新全部平台，
并由 CI 在写回前交叉校验官方与镜像的 tarball 是同一份文件。

## 用法

### 作为 flake input

```nix
{
  inputs.opencode-nix.url = "git+https://github.com/yxlimo/opencode-nix?ref=main";
  # 让它的 nixpkgs 与你的一致，避免闭包里出现两份 nixpkgs
  inputs.opencode-nix.inputs.nixpkgs.follows = "nixpkgs";
}
```

**锁版本**：每次 `sources.json` 变化都会打一个 `v<version>` 的 tag 并发 release，
所以可以按可读版本号锁，而不是只能锁 commit rev：

```nix
# 跟上游最新（推荐，flake.lock 自己会钉住具体 rev）
inputs.opencode-nix.url = "git+https://github.com/yxlimo/opencode-nix?ref=main";

# 锁死某个 opencode 版本（不会随上游推进）
inputs.opencode-nix.url = "git+https://github.com/yxlimo/opencode-nix?ref=v2.2.5";
```

然后二选一：

```nix
# A. 直接用它的包
opencode = opencode-nix.packages.${system}.opencode;

# B. 用它的 overlay（callPackage 形式，于是 .override 可用）
opencode = (opencode-nix.overlays.default final prev).opencode;
```

### 换 registry（例如国内用镜像）

默认是官方 `https://registry.npmjs.org`。镜像不是默认值 —— 本仓面向全球。
国内机器可以这样换，**不用改本仓**：

```nix
opencode = (opencode-nix.packages.${system}.opencode).override {
  registry = "https://registry.npmmirror.com";
};
```

换源后哈希仍然成立：镜像与官方是逐字节相同的 tarball
（`bin/update-sources.sh` 每次都会比对两边的 `dist.shasum`）。
万一某个源给了不同内容，哈希失配会直接让构建失败，不会静默装进坏包。

## 更新机制

`sources.json` 由 `bin/update-sources.sh` 维护：

```
1. 向 registry 查 @opencode/cli 的 latest            → 版本号
2. 该包的 optionalDependencies 给出各平台包的版本    → 平台版本
3. 交叉校验：官方与镜像的 dist.shasum 必须一致       → 防止镜像滞后/被改
4. nix-prefetch-url 取每个平台 tarball 的 sha256     → 写回 sources.json
```

触发方式是 **事件驱动，没有 cron**：

- `repository_dispatch`（type=`upstream-release`）：由外部中继在上游发版后触发；
- `workflow_dispatch`：手动补跑（`gh workflow run update.yml`）。

更新成功后 CI 会：提交 `sources.json` → 打 `v<version>` tag → 发 GitHub release（附每平台哈希）。

GitHub 不会把「别人仓库发 release」的事件投递给本仓，所以需要一个探测中继
（定时查上游 release 列表 → 发现新版本就 dispatch）。中继不在本仓，
详见使用方仓库的文档。

## 关于 patchelf

上游的二进制是动态链接 ELF，`PT_INTERP` 指向 `/lib64/ld-linux-x86-64.so.2`。
在 NixOS 上必须 `autoPatchelfHook` + `libgcc` 才能运行 —— 本仓的 `package.nix`
已经处理。没有这一步的打包在 FHS 发行版上能跑，在 NixOS 上会直接报
"cannot execute: required file not found"。

## 致谢

结构参考 [mikael-lindstrom/opencode-nix](https://github.com/mikael-lindstrom/opencode-nix)
（它把同一件事做成了每日 cron + 单文件 `flake.nix`）。本仓的实现是独立编写的：
数据放 `sources.json`、CI 校验镜像一致性、补上 `autoPatchelfHook`、
去掉冗余的 v1 线（`opencode-ai` 1.x）。
