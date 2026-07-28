#!/usr/bin/env bash
set -eu -o pipefail


# Required packages are listed in README.md.

source .build_config

# Show env
pwd
whoami
echo $PATH
echo $HOME

# Argument parser from https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash/29754866#29754866
! getopt --test > /dev/null
if [[ ${PIPESTATUS[0]} -ne 4 ]]; then
    echo 'I’m sorry, `getopt --test` failed in this environment.'
    exit 1
fi

OPTIONS=dla:t:
LONGOPTS=debug,local-sdk,arch:,target:

! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@")
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    exit 2
fi
eval set -- "$PARSED"

ARCH=- TARGET=- DEBUG=n LOCAL_SDK=n

while true; do
    case "$1" in
        -d|--debug)
            DEBUG=y
            shift
            ;;
        -l|--local-sdk)
            LOCAL_SDK=y
            shift
            ;;
        -a|--arch)
            ARCH="$2"
            shift 2
            ;;
        -t|--target)
            TARGET="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Programming error"
            exit 3
            ;;
    esac
done

if [[ "$ARCH" != "arm64" ]] && [[ "$ARCH" != "arm" ]] && [[ "$ARCH" != "x86" ]]; then
    echo "Wrong architecture"
    exit 4
fi

if [[ "$TARGET" != "chrome_modern_target" ]] && [[ "$TARGET" != "trichrome_chrome_apk_target" ]] && [[ "$TARGET" != "webview_target" ]] && [[ "$TARGET" != "trichrome_webview_target" ]] && [[ "$TARGET" != "all" ]]; then
    echo "Wrong target"
    exit 5
fi

# 64-bit TriChrome
if [[ "$ARCH" == "arm64" ]]; then
  if [[ "$TARGET" == "trichrome_chrome_apk_target" ]]; then
    TARGET_EXPANDED=${trichrome_chrome_64_apk_target}
  elif [[ "$TARGET" == "trichrome_webview_target" ]]; then
    TARGET_EXPANDED=${trichrome_webview_64_target}
  else
    TARGET_EXPANDED=${!TARGET}
  fi
else
  TARGET_EXPANDED=${!TARGET}
fi

echo "arch: $ARCH, target: $TARGET, target expanded: ${TARGET_EXPANDED}, debug: $DEBUG, local sdk: $LOCAL_SDK"

path_modified=false

function prepare_repos {
  declare -a arr=("depot_tools" "src" "ungoogled-chromium" ".cipd")
  for dname in "${arr[@]}"
  do
    if [[ -d "$dname" ]]
    then
      echo "Removing $dname"
      rm -rf "$dname"
    fi
  done

  path_modified=false

  ## Clone ungoogled-chromium repo
  git clone https://github.com/ungoogled-software/ungoogled-chromium.git -b ${ungoogled_chromium_version}-${ungoogled_chromium_revision} \
   || return $?

  ## Clone chromium repo
  git clone --depth 1 --no-tags https://chromium.googlesource.com/chromium/src.git -b ${chromium_version} || return $?

  ## Fetch depot-tools
  depot_tools_commit=$(grep 'depot_tools.git' src/DEPS | cut -d\' -f8)
  mkdir -p depot_tools
  pushd depot_tools
  git init
  git remote add origin https://chromium.googlesource.com/chromium/tools/depot_tools.git
  git fetch --depth 1 --no-tags origin "${depot_tools_commit}" || return $?
  git reset --hard FETCH_HEAD
  popd
  OLD_PATH=$PATH
  export PATH="$(pwd -P)/depot_tools:$PATH"
  export PYTHONPATH="$(pwd -P)/depot_tools${PYTHONPATH:+:$PYTHONPATH}"
  path_modified=true
  pushd src/third_party
  ln -s ../../depot_tools
  popd

  ## Sync files (SDK/NDK/JDK/node/aapt2/bundletool arrive here via CIPD)
  gclient.py sync --nohooks --no-history --shallow --revision=${chromium_version} || return $?


  # node_modules for WebUI build
  ( src/third_party/node/update_npm_deps ) || return $?
  # devtools' node_modules lacks rollup's native binary; fetch it directly
  # from the public registry (devtools' .npmrc points at a mirror without it).
  ROLLUP_VER=$(grep '"version"' src/third_party/devtools-frontend/src/node_modules/rollup/package.json | head -1 | cut -d'"' -f4)
  _rollup_dest="src/third_party/devtools-frontend/src/node_modules/@rollup/rollup-linux-x64-gnu"
  if [ ! -f "${_rollup_dest}/rollup.linux-x64-gnu.node" ]; then
    curl -sL "https://registry.npmjs.org/@rollup/rollup-linux-x64-gnu/-/rollup-linux-x64-gnu-${ROLLUP_VER}.tgz" -o /tmp/rollup-native.tgz || return $?
    rm -rf "${_rollup_dest}"; mkdir -p "${_rollup_dest}"
    tar xzf /tmp/rollup-native.tgz -C "${_rollup_dest}" --strip-components=1 || return $?
  fi
  [ -f "${_rollup_dest}/rollup.linux-x64-gnu.node" ] || { echo "FATAL: rollup native module missing"; return 1; }

  ## Hooks (subset of src/DEPS hooks)
  python3 src/build/util/lastchange.py -o src/build/util/LASTCHANGE
  python3 src/tools/download_optimization_profile.py --newest_state=src/chrome/android/profiles/newest.txt --local_state=src/chrome/android/profiles/local.txt --output_name=src/chrome/android/profiles/afdo.prof --gs_url_base=chromeos-prebuilt/afdo-job/llvm || return $?
  python3 src/tools/download_optimization_profile.py --newest_state=src/chrome/android/profiles/arm.newest.txt --local_state=src/chrome/android/profiles/arm.local.txt --output_name=src/chrome/android/profiles/arm.afdo.prof --gs_url_base=chromeos-prebuilt/afdo-job/llvm || return $?
  python3 src/build/util/lastchange.py -m GPU_LISTS_VERSION --revision-id-only --header src/gpu/config/gpu_lists_version.h
  python3 src/build/util/lastchange.py -m SKIA_COMMIT_HASH -s src/third_party/skia --header src/skia/ext/skia_commit_hash.h
  python3 src/build/util/lastchange.py -m DAWN_COMMIT_HASH -s src/third_party/dawn --revision src/gpu/webgpu/DAWN_VERSION --header src/gpu/webgpu/dawn_commit_hash.h
  # Prebuilt clang + sysroots
  python3 src/tools/clang/scripts/update.py
  python3 src/build/linux/sysroot_scripts/install-sysroot.py --arch=amd64
  # i386 sysroot required by the clang_x86 secondary toolchain on Android builds
  python3 src/build/linux/sysroot_scripts/install-sysroot.py --arch=i386
  # V8 builtins PGO profiles are consumed when is_official_build=true.
  python3 src/v8/tools/builtins-pgo/download_profiles.py download --depot-tools "$(pwd -P)/depot_tools" --check-v8-revision --quiet || return $?
  # Needed for an ad-block list used in webview
  cp misc/UnindexedRules src/third_party/subresource-filter-ruleset/data
}


function reverse_change {
  if [ "$path_modified" = true ] ; then
    export PATH=$OLD_PATH
    path_modified=false
  fi
}

# Run preparation
for i in $(seq 1 10); do prepare_repos && s=0 && break || s=$? && reverse_change && sleep 120; done; (exit $s)

## Run ungoogled-chromium scripts
# Patch prune list and GN flags for the Android build
patch -p1 --ignore-whitespace -i patches/Other/ungoogled-main-repo-fix.patch --no-backup-if-mismatch
# Remove the cache file if exists
cache_file="domsubcache.tar.gz"
if [[ -f ${cache_file} ]] ; then
    rm ${cache_file}
fi

# Ignore the pruning error
python3 ungoogled-chromium/utils/prune_binaries.py src ungoogled-chromium/pruning.list --keep-contingent-paths || true
python3 ungoogled-chromium/utils/patches.py apply src ungoogled-chromium/patches
python3 ungoogled-chromium/utils/domain_substitution.py apply -r ungoogled-chromium/domain_regex.list -f ungoogled-chromium/domain_substitution.list -c ${cache_file} src


# Additional Source Patches
## Extra fixes for Chromium source
python3 ungoogled-chromium/utils/patches.py apply src patches
## Second pruning list
pruning_list_2="pruning_2.list"
python3 ungoogled-chromium/utils/prune_binaries.py src ${pruning_list_2} --keep-contingent-paths || true
## Second domain substitution list
substitution_list_2="domain_sub_2.list"
# Remove the cache file if exists
cache_file="domsubcache.tar.gz"
if [[ -f ${cache_file} ]] ; then
    rm ${cache_file}
fi
python3 ungoogled-chromium/utils/domain_substitution.py apply -r ungoogled-chromium/domain_regex.list -f ${substitution_list_2} -c ${cache_file} src

## Empty attestations file: pruned, but android_assets still bundles it.
psa_dat="src/components/privacy_sandbox/privacy_sandbox_attestations/preload/privacy-sandbox-attestations.dat"
[[ -f ${psa_dat} ]] || : > ${psa_dat}

## Restore prefs sources still compiled at 150 after pruning.
( cd src && git checkout HEAD -- \
    components/signin/public/base/signin_pref_names.h \
    components/signin/public/base/signin_pref_names.cc \
    components/safe_browsing/core/common/safe_browsing_prefs.h \
    components/safe_browsing/core/common/safe_browsing_prefs.cc 2>/dev/null ) || true


## Configure output folder
export PATH=$OLD_PATH  # remove depot_tools from PATH
pushd src
output_folder="out/Default"
mkdir -p "${output_folder}"
if [ "$DEBUG" = n ] ; then
    cat ../ungoogled-chromium/flags.gn ../android_flags.gn ../android_flags.release.gn > "${output_folder}"/args.gn
    # Release keystore if present, else gn's default debug keystore.
    if [ -f ../../uc_keystore/keystore.gn ]; then
        cat ../../uc_keystore/keystore.gn >> "${output_folder}"/args.gn
    fi
else
    cat ../android_flags.gn ../android_flags.debug.gn > "${output_folder}"/args.gn
fi
printf '\ntarget_cpu="'"$ARCH"'"\n' >> "${output_folder}"/args.gn
# Trichrome doesn't forward version_name to base in bundle
printf '\nandroid_override_version_name="'"${chromium_version}"'"\n' >> "${output_folder}"/args.gn

gn gen "${output_folder}" --fail-on-unused-args
popd


## Set compiler flags
export AR=${AR:=llvm-ar}
export NM=${NM:=llvm-nm}
export CC=${CC:=clang}
export CXX=${CXX:=clang++}
export CCACHE_CPP2=yes
export CCACHE_SLOPPINESS=time_macros

## Build
apk_out_folder="apk_out"
mkdir -p "${apk_out_folder}"
pushd src
if [[ "$TARGET" != "all" ]]; then
  ninja -C "${output_folder}" "${TARGET_EXPANDED}"
  if [[ "$TARGET" == "trichrome_chrome_bundle_target" ]] || [[ "$TARGET" == "chrome_modern_target" ]] || [[ "$TARGET" == "trichrome_chrome_apk_target" ]] || [[ "$TARGET" == "trichrome_webview_target" ]]; then
    ../bundle_generate_apk.sh -o "${output_folder}" -a "${ARCH}" -t "${TARGET_EXPANDED}"
  fi
  if [[ "$TARGET" != "webview_target" ]]; then
    find ${output_folder}/apks/release -iname "*.apk" -exec cp -f {} ../"${apk_out_folder}" \;
  else
    find ${output_folder}/apks -iname "*.apk" -exec cp -f {} ../"${apk_out_folder}" \;
  fi
else
  ninja -C out/Default "$chrome_modern_target"
  ../bundle_generate_apk.sh -o "${output_folder}" -a "${ARCH}" -t "$chrome_modern_target"
  ninja -C out/Default "$webview_target"
  ninja -C out/Default "$trichrome_webview_target"
  find ${output_folder}/apks/release -iname "*.apk" -exec cp -f {} ../"${apk_out_folder}" \;

  # arm64+TriChrome needs to be run separately, otherwise it will fail
  if [[ "$ARCH" != "arm64" ]]; then
    ninja -C "${output_folder}" "$trichrome_chrome_apk_target"
    find ${output_folder}/apks/release -iname "*.apk" -exec cp -f {} ../"${apk_out_folder}" \;
  fi
fi
popd
