#!/usr/bin/env bash
set -euo pipefail

RUN="${SOURCE_RUN_ID:-$GITHUB_RUN_ID}"
API="https://api.github.com/repos/${GITHUB_REPOSITORY}"
AUTH=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

meta=$(curl -fsSL "${AUTH[@]}" "${API}/actions/runs/${RUN}/artifacts?name=build-tree-${ARCH}")
read -r AID ASIZE <<< "$(python3 -c "
import json,sys
arts=json.loads(sys.argv[1])['artifacts']
print(arts[0]['id'], arts[0]['size_in_bytes']) if arts else print('', '')" "$meta")"
if [ -z "${AID}" ]; then
    echo "FATAL: run ${RUN} has no build-tree-${ARCH} artifact to resume from"
    exit 1
fi
echo "artifact ${AID}: ${ASIZE} bytes from run ${RUN}"

dl="${GITHUB_WORKSPACE}/artifact"
mkdir -p "$dl"
zip="$dl/tree.zip"
_tar="$dl/build-tree.tar.zst"

tries=0
while :; do
    curl -fL --retry 10 --retry-delay 15 --retry-all-errors -C - \
        "${AUTH[@]}" -o "$zip" "${API}/actions/artifacts/${AID}/zip" || true
    have=$(stat -c%s "$zip" 2>/dev/null || echo 0)
    echo "downloaded ${have}/${ASIZE}"
    if [ "$have" -ge "$ASIZE" ] || [ $((tries % 3)) -eq 2 ]; then
        if unzip -o -q "$zip" -d "$dl" 2>/dev/null && zstd -t "$_tar" 2>/dev/null; then
            echo "archive verified"
            break
        fi
    fi
    tries=$((tries+1))
    if [ "$tries" -ge 20 ]; then
        echo "FATAL: could not fetch an intact build tree after ${tries} attempts (${have}/${ASIZE})"
        exit 1
    fi
    sleep 15
done
rm -f "$zip"

echo "::group::unpacking $(du -h "$_tar" | cut -f1)"
mkdir -p "${UGC_WORK}"
zstd -dc -T0 "$_tar" | tar -xf - -C "${UGC_WORK}"
rm -rf "$dl"
echo "::endgroup::"

df -h / /mnt
