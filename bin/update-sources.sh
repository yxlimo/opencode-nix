#!/usr/bin/env bash
# 维护 sources.json：查上游最新版本 → 交叉校验镜像 → 算每平台哈希 → 写回。
#
#   ./bin/update-sources.sh                  # 用默认 registry（官方 npm）查版本
#   REGISTRY=https://registry.npmmirror.com ./bin/update-sources.sh
#   ./bin/update-sources.sh --check          # 只报告是否有新版，不写文件（退出码 0/1）
#
# 为什么默认官方 npm：本仓面向全球使用，镜像只是国内消费者的加速选项。
#
# 为什么每次都要做交叉校验：镜像滞后或被篡改时，哈希会与官方不一致，
# 那种情况下宁可直接失败，也不要写进一个「只有我们这边能构建成功」的哈希。
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCES="sources.json"
REGISTRY="${REGISTRY:-https://registry.npmjs.org}"
OFFICIAL="https://registry.npmjs.org"
ROOT_PKG="@opencode/cli"

# system → 平台包的包名后缀 / tarball 名后缀
PLATFORMS=(
  "x86_64-linux:x64"
  "aarch64-linux:arm64"
)

check_only=false
if [[ "${1:-}" == "--check" ]]; then
  check_only=true
fi

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# npm 的 scoped 包名在 URL 里要转义斜杠
url_pkg() {
  local pkg=$1
  printf '%s' "${pkg/\//%2f}"
}

for tool in curl jq nix-prefetch-url; do
  command -v "$tool" >/dev/null || die "缺少依赖：$tool"
done

printf 'Fetching %s metadata from %s ...\n' "$ROOT_PKG" "$REGISTRY"
metadata=$(curl -fsS --retry 3 "$REGISTRY/$(url_pkg "$ROOT_PKG")/latest") || die "取不到 $ROOT_PKG 的 metadata"
version=$(jq -er '.version' <<<"$metadata") || die "metadata 里没有 version"
current=$(jq -r '.version' "$SOURCES")

printf 'upstream: %s   current: %s\n' "$version" "$current"

if [[ "$version" == "$current" ]]; then
  if $check_only; then
    printf 'up to date\n'
    exit 0
  fi
fi

platform_entries=()
for entry in "${PLATFORMS[@]}"; do
  system=${entry%%:*}
  arch=${entry##*:}
  pkg="@opencode/cli-${arch}"
  tarball="cli-${arch}"

  # 平台包版本取自 root 包的 optionalDependencies（各平台可以不同版本）
  platform_version=$(jq -er --arg p "$pkg" '.optionalDependencies[$p]' <<<"$metadata") \
    || die "$ROOT_PKG 的 optionalDependencies 里没有 $pkg"

  # 交叉校验：官方与镜像必须给出同一个 dist.shasum
  official_sum=$(curl -fsS --retry 3 "$OFFICIAL/$(url_pkg "$pkg")/${platform_version}" | jq -r '.dist.shasum')
  mirror_sum=$(curl -fsS --retry 3 "https://registry.npmmirror.com/$(url_pkg "$pkg")/${platform_version}" | jq -r '.dist.shasum')
  if [[ -z "$official_sum" || "$official_sum" == "null" ]]; then
    die "$pkg@$platform_version 在官方 registry 上没有 dist.shasum"
  fi
  if [[ "$official_sum" != "$mirror_sum" ]]; then
    die "$pkg@$platform_version 的 tarball 在两个 registry 不一致（official=${official_sum} mirror=${mirror_sum}）—— 镜像滞后或被改过，拒绝写入"
  fi

  if $check_only; then
    printf '%s@%s: shasum ok (%s)\n' "$pkg" "$platform_version" "$official_sum"
    platform_entries+=("placeholder")
    continue
  fi

  printf 'hashing %s@%s ... ' "$pkg" "$platform_version"
  base32=$(nix-prefetch-url --type sha256 "$REGISTRY/${pkg}/-/${tarball}-${platform_version}.tgz" 2>/dev/null) \
    || die "下载/计算哈希失败：$pkg@$platform_version"
  sri=$(nix hash convert --hash-algo sha256 --to sri "$base32")
  printf '%s\n' "$sri"

  platform_entries+=("$(jq -nc \
    --arg package "$pkg" \
    --arg tarball "$tarball" \
    --arg version "$platform_version" \
    --arg hash "$sri" \
    '{package:$package, tarball:$tarball, version:$version, hash:$hash}')")
done

if $check_only; then
  exit 1
fi

# 按系统名把上面的条目拼成对象
new_json=$(jq -n --arg version "$version" '{
  version: $version,
  platforms: {}
}')

idx=0
for entry in "${PLATFORMS[@]}"; do
  system=${entry%%:*}
  new_json=$(jq -c --arg system "$system" --argjson value "${platform_entries[$idx]}" \
    '.platforms[$system] = $value' <<<"$new_json")
  idx=$((idx + 1))
done

printf '%s\n' "$new_json" | jq . > "$SOURCES.tmp"
mv "$SOURCES.tmp" "$SOURCES"

printf 'wrote %s (opencode %s)\n' "$SOURCES" "$version"
