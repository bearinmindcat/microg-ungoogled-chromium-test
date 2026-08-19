#!/usr/bin/env bash
set -euo pipefail

mkdir -p "${UGC_WORK}"
cp -a "${GITHUB_WORKSPACE}/." "${UGC_WORK}/"

export CCACHE_DIR=/mnt/ccache
cd "${UGC_WORK}"

: > build-step.log
setsid ./build.sh "$@" < /dev/null >> build-step.log 2>&1 &
_pid=$!
tail --pid="$_pid" -n +1 -f build-step.log &
_tail=$!
_rc=0
wait "$_pid" || _rc=$?
sudo pkill -9 -s "$_pid" 2>/dev/null || true
wait "$_tail" 2>/dev/null || true
exit "$_rc"
