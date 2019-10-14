#!/bin/bash

set -u # unset variables are errors

cd "${0%/*}"

export ANDROID_HOME=${ANDROID_HOME:-$HOME/Android/Sdk}
TOOLS=$ANDROID_HOME/build-tools
ADB=$ANDROID_HOME/platform-tools/adb
KEYSTORE=$HOME/.android/release.keystore
METADATA=$PWD/metadata
IMPLANT=$HOME/.implant
TMP=$IMPLANT/tmp
DOWNLOADS=$IMPLANT/downloads
SRC=$IMPLANT/src
OUT=$IMPLANT/output
LOG=$IMPLANT/build.log
VERBOSE=${VERBOSE:-0}
INSTALL=0
REINSTALL=0
DEFAULT_GRADLE_PROPS="org.gradle.jvmargs=-Xmx2048m -XX:MaxPermSize=2048m -XX:+HeapDumpOnOutOfMemoryError"

source ./functions.sh

load_config() {
  PACKAGE=$(get_package "$PACKAGE")
  CONFIG="$METADATA/$PACKAGE.yml"

  if [ ! -f "$CONFIG" ]; then
    puts "Invalid package: $PACKAGE"
    exit 1
  fi

  if ! yq r "$CONFIG" >/dev/null 2>&1; then
    puts "Invalid yml file: $CONFIG"
    exit 1
  fi

  puts
  puts "***** $PACKAGE $(date) *****"
  NAME=$(get_config name)
  PROJECT=$(get_config project app)
  TARGET=$(get_config target release)
  FLAVOR=$(get_config flavor)
  NDK=$(get_config ndk)
  PREBUILD=$(get_config prebuild)
  BUILD=$(get_config build)
  DEPS=$(get_config deps)
  GRADLE_VERSION=$(get_config gradle)
  GIT_URL=$(get_config git.url)
  GIT_SHA=$(get_config git.sha)
  GIT_TAGS=$(get_config git.tags)
  VERSION=$(get_config version)
  GRADLEPROPS=$(get_config gradle_props "$DEFAULT_GRADLE_PROPS")
  puts
}

update_apps() {
  if [ ! -t 0 ] && [ "$#" -eq 0 ]; then
    readarray STDIN_ARGS </dev/stdin
    set -- "${STDIN_ARGS[@]}"
  fi
  for PACKAGE in "$@"; do
    PACKAGE=$(get_package "$PACKAGE")
    put "updating $PACKAGE..."
    if (update_app); then
      green "OK"
    else
      red "ERROR"
    fi
  done
}

update_app() {
  set -eu # unset variables are errors & non-zero return values exit the whole script

  setup_logging

  load_config

  clone_and_cd "$GIT_URL" "$SRC/$PACKAGE" "$GIT_SHA"

  SHA=$(get_latest_tag)
  if [ "$SHA" == "$GIT_SHA" ]; then
    puts "up to date [$SHA]"
    exit 0
  fi

  puts "updating $PACKAGE to $SHA"
  OUT_DIR=$OUT/$PACKAGE
  if (build_app); then
    yq w -i "$CONFIG" git.sha "\"$SHA\""
    for apk in "$OUT_DIR"/*.apk; do
      APK_VERSION=$(get_apk_version_code "$apk")
      if [ -z "$APK_VERSION" ]; then
        puts "Error parsing apk version"
        exit 1
      fi
      if [ "$APK_VERSION" == "1" ]; then
        APK_VERSION=$(("$VERSION" + 1))
      fi
      yq w -i "$CONFIG" version "\"$APK_VERSION\""
    done
  else
    exit 1
  fi
}

build_apps() {
  if [ ! -t 0 ] && [ "$#" -eq 0 ]; then
    readarray STDIN_ARGS </dev/stdin
    set -- "${STDIN_ARGS[@]}"
  fi
  for PACKAGE in "$@"; do
    PACKAGE=$(get_package "$PACKAGE")
    OUT_DIR=$OUT/$PACKAGE
    if [ "$INSTALL" -eq 1 ] && [ "$REINSTALL" -eq 0 ] && up_to_date "$PACKAGE"; then
      puts "$PACKAGE up to date"
      continue
    fi
    put "building $PACKAGE..."
    if (build_app); then
      green "OK"
    else
      red "FAILED"
      continue
    fi

    if [ "$INSTALL" -eq 1 ]; then
      for apk in "$OUT_DIR"/*.apk; do
        adb install "$apk" 1>&2
      done
    fi
  done
}

build_app() {
  set -eu # unset variables are errors & non-zero return values exit the whole script

  setup_logging

  load_config

  mkdir -p "$OUT_DIR" "$DOWNLOADS" "$TMP"
  rm -fv "$OUT_DIR"/*.apk

  setup_ndk

  install_deps

  clone_and_cd "$GIT_URL" "$SRC/$PACKAGE" "$GIT_SHA"

  download_gradle

  setup_gradle_properties

  sed -i 's/.*signingConfig .*//g' "$PWD/$PROJECT"/build.gradle*

  prebuild

  build

  find "./$PROJECT" -regex '.*\.apk$' -exec cp -v {} "$OUT_DIR" \; >>"$LOG"

  if [ ! -f "$KEYSTORE" ]; then
    puts "Cannot sign APK: $KEYSTORE found"
    return "$INSTALL"
  fi

  for apk in "$OUT_DIR"/*.apk; do
    zipalign_and_sign "$apk"
  done
}

zipalign_and_sign() {
  UNSIGNED=$1
  SIGNED=$(echo "$UNSIGNED" | sed 's/[-]unsigned//g;s/\.apk$/-signed\.apk/')
  zipalign "$UNSIGNED" "$SIGNED" && rm -v "$UNSIGNED" && sign "$SIGNED"
}

if [ "$#" -eq 0 ]; then
  puts "missing arguments"
  # TODO: print usage
  exit 1
fi

type yq >/dev/null 2>&1 || {
  # TODO: download automatically
  echo >&2 "yq must be in your PATH, please download from https://github.com/mikefarah/yq/releases"
  exit 1
}

case $1 in
  adb)
    shift
    adb "$@"
    ;;
  i | install)
    shift
    INSTALL=1
    if [ "${1:-}" == "--reinstall" ]; then
      shift
      REINSTALL=1
    fi
    build_apps "$@"
    ;;
  b | build)
    shift
    build_apps "$@"
    ;;
  u | update)
    shift
    update_apps "$@"
    ;;
  l | list)
    shift
    apps=()
    if [ -z "${1:-}" ]; then
      PACKAGES=(metadata/*.yml)
    elif [ "$1" == "--installed" ]; then
      get_installed_packages
    else
      puts "invalid option $1"
      exit 1
    fi
    for PACKAGE in "${PACKAGES[@]}"; do
      PACKAGE=$(get_package "$PACKAGE")
      CONFIG="$METADATA/$PACKAGE.yml"
      NAME=$(get_config name 2>/dev/null)
      apps+=("$NAME - $PACKAGE")
    done
    IFS=$'\n' sorted=($(sort -f <<<"${apps[*]}"))
    unset IFS
    printf "%s\n" "${sorted[@]}" | less
    ;;
  keygen)
    if [ ! -f "$OUT/adbkey" ] && [ ! -f "$OUT/adbkey.pub" ]; then
      puts "Generating adbkey and adbkey.pub"
      $ADB start-server >>"$LOG" 2>&1
      cp -v "$HOME/.android/adbkey" "$HOME/.android/adbkey.pub" "$OUT"
    fi
    if [ ! -f "$OUT/debug.keystore" ]; then
      puts "Generating $OUT/debug.keystore"
      keytool -genkey -v -keystore "$OUT/debug.keystore" -storepass android -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 -validity 10000 -dname "C=US, O=Android, CN=Android Debug" >>"$LOG" 2>&1
    fi
    if [ ! -f "$OUT/release.keystore" ]; then
      puts "Generating $OUT/release.keystore (requires 'docker run --interactive --tty')"
      keytool -genkey -v -keystore "$OUT/release.keystore" -alias implant -keyalg RSA -keysize 2048 -validity 10000
    fi
    ;;
  -h | --help | h | help)
    puts "not implemented"
    # TODO: print usage
    exit 1
    ;;
  *)
    puts "unknown command: $1"
    exit 1
    ;;
esac
