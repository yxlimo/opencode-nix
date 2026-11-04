#!/usr/bin/env bash
# Maintain sources.json: query upstream's latest version, cross-check the
# mirror, hash every platform tarball, write the file back.
#
#   ./bin/update-sources.sh                  # default registry (official npm)
#   REGISTRY=https://registry.npmmirror.com ./bin/update-sources.sh
#   ./bin/update-sources.sh --check          # report only, do not write
#
# The default is the official registry: this repository is meant to be usable
# worldwide, and a mirror is a regional acceleration, not a default.
#
# The cross-check runs on every update. A stale or tampered mirror would produce
# a hash that only builds on one side, so the script refuses to write anything
# unless both registries report the same dist.shasum for each tarball.
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCES="sources.json"
REGISTRY="${REGISTRY:-https://registry.npmjs.org}"
OFFICIAL="https://registry.npmjs.org"
ROOT_PKG="@opencode/cli"

# system -> platform package suffix. npm ships these as
# @opencode/cli-linux-x64 / @opencode/cli-linux-arm64.
PLATFORMS=(
  "x86_64-linux:linux-x64"
  "aarch64-linux:linux-arm64"
)

check_only=false
if [[ "${1:-}" == "--check" ]]; then
  check_only=true
fi

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# npm scoped package names need the slash escaped in a URL path
url_pkg() {
  local pkg=$1
  printf '%s' "${pkg/\//%2f}"
}

for tool in curl jq nix-prefetch-url; do
  command -v "$tool" >/dev/null || die "missing dependency: $tool"
done

printf 'Fetching %s metadata from %s ...\n' "$ROOT_PKG" "$REGISTRY"
metadata=$(curl -fsS --retry 3 "$REGISTRY/$(url_pkg "$ROOT_PKG")/latest") || die "cannot fetch metadata for $ROOT_PKG"
version=$(jq -er '.version' <<<"$metadata") || die "metadata has no version"
current=$(jq -r '.version' "$SOURCES")

printf 'upstream: %s   current: %s\n' "$version" "$current"

if [[ "$version" == "$current" ]] && $check_only; then
  printf 'up to date\n'
  exit 0
fi

platform_entries=()
for entry in "${PLATFORMS[@]}"; do
  system=${entry%%:*}
  arch=${entry##*:}
  pkg="@opencode/cli-${arch}"
  tarball="cli-${arch}"

  # The platform package version comes from the root package's
  # optionalDependencies; platforms may lag behind or run ahead.
  platform_version=$(jq -er --arg p "$pkg" '.optionalDependencies[$p]' <<<"$metadata") \
    || die "$ROOT_PKG has no optionalDependencies entry for $pkg"

  official_sum=$(curl -fsS --retry 3 "$OFFICIAL/$(url_pkg "$pkg")/${platform_version}" | jq -r '.dist.shasum')
  mirror_sum=$(curl -fsS --retry 3 "https://registry.npmmirror.com/$(url_pkg "$pkg")/${platform_version}" | jq -r '.dist.shasum')
  if [[ -z "$official_sum" || "$official_sum" == "null" ]]; then
    die "$pkg@$platform_version has no dist.shasum on the official registry"
  fi
  if [[ "$official_sum" != "$mirror_sum" ]]; then
    die "$pkg@$platform_version differs between registries (official=${official_sum} mirror=${mirror_sum}) — refusing to write"
  fi

  if $check_only; then
    printf '%s@%s: shasum ok (%s)\n' "$pkg" "$platform_version" "$official_sum"
    platform_entries+=("placeholder")
    continue
  fi

  printf 'hashing %s@%s ... ' "$pkg" "$platform_version"
  base32=$(nix-prefetch-url --type sha256 "$REGISTRY/${pkg}/-/${tarball}-${platform_version}.tgz" 2>/dev/null) \
    || die "download or hash failed: $pkg@$platform_version"
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
  # Reached only when the version moved: report and signal "not up to date".
  exit 1
fi

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
