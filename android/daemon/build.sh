#!/usr/bin/env bash
# Builds cellbridge_audiod for arm64 Android with the NDK. tinyalsa is the pinned submodule (v2.0.0).
set -euo pipefail
cd "$(dirname "$0")"

NDK="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"
CC="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android30-clang"
TS=third_party/tinyalsa

mkdir -p build
"$CC" -O2 -Wall -Wextra -o build/cellbridge_audiod \
  -I"$TS/include" -I"$TS/src" -Isrc \
  src/*.c "$TS"/src/*.c -ldl
"$CC" -O2 -Wall -Wextra -o build/udp_probe tools/udp_probe.c -lm
echo "built build/cellbridge_audiod build/udp_probe"
