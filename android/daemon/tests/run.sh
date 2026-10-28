#!/usr/bin/env bash
# Host-side unit tests for the pure parts of the daemon (no device needed).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
cc -O1 -g -Wall -Wextra -fsanitize=address,undefined -Isrc -o build/jitter_test tests/jitter_test.c src/jitter.c -lpthread
build/jitter_test
