#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p module/bin/arm64-v8a module/bin/x86_64

ANDROID_API="${ANDROID_API:-23}"

find_ndk_bin() {
  if [[ -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" ]]; then
    find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -maxdepth 2 -type d -name bin | sort -V | tail -n 1
    return
  fi

  local sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "$sdk_root" ]]; then
    echo "ANDROID_HOME/ANDROID_SDK_ROOT is not set" >&2
    exit 1
  fi
  find "$sdk_root/ndk" -path "*/toolchains/llvm/prebuilt/*/bin" -type d | sort -V | tail -n 1
}

NDK_BIN="$(find_ndk_bin)"
if [[ -z "$NDK_BIN" ]]; then
  echo "Android NDK clang bin was not found" >&2
  exit 1
fi

clang_for() {
  local triple="$1"
  local exact="$NDK_BIN/${triple}-linux-android${ANDROID_API}-clang"
  if [[ -x "$exact" ]]; then
    echo "$exact"
    return
  fi
  find "$NDK_BIN" -name "${triple}-linux-android*-clang" -type f | sort -V | tail -n 1
}

ARM64_CC="$(clang_for aarch64)"
X64_CC="$(clang_for x86_64)"

CC="$ARM64_CC" CGO_ENABLED=1 GOOS=android GOARCH=arm64 go build -trimpath -tags "netgo,osusergo" -ldflags "-s -w" \
  -o module/bin/arm64-v8a/magic-fetch ./tools/magic-fetch

CC="$X64_CC" CGO_ENABLED=1 GOOS=android GOARCH=amd64 go build -trimpath -tags "netgo,osusergo" -ldflags "-s -w" \
  -o module/bin/x86_64/magic-fetch ./tools/magic-fetch

BUILD_DIR="$ROOT/build/applist"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/classes" "$BUILD_DIR/dex"

javac --release 8 -encoding UTF-8 -d "$BUILD_DIR/classes" module/tools/applist/AppList.java

D8_BIN="${D8_BIN:-$(command -v d8 || true)}"
if [[ -z "$D8_BIN" ]]; then
  SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "$SDK_ROOT" ]]; then
    echo "ANDROID_HOME/ANDROID_SDK_ROOT is not set and d8 is not on PATH" >&2
    exit 1
  fi
  D8_BIN="$(find "$SDK_ROOT/build-tools" -name d8 -type f | sort -V | tail -n 1)"
fi

"$D8_BIN" --min-api 33 --output "$BUILD_DIR/dex" "$BUILD_DIR/classes/AppList.class"
cp "$BUILD_DIR/dex/classes.dex" module/bin/applist.dex

echo "built helper binaries and applist.dex"
