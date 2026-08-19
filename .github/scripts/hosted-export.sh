#!/usr/bin/env bash
set -euo pipefail

_out="${GITHUB_WORKSPACE}/build-tree.tar.zst"
rm -f "$_out"

echo "::group::packing build tree"
( cd "${UGC_WORK}" && tar --format=posix -cf - --exclude='src/.git' \
      $(for d in src depot_tools ungoogled-chromium .cipd; do [ -e "$d" ] && printf '%s ' "$d"; done) ) \
  | zstd -T0 -3 -o "$_out"
ls -lh "$_out" | sed 's/^/  /'
echo "::endgroup::"

df -h / /mnt
