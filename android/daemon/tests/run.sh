#!/usr/bin/env bash
# Host-side unit tests for the pure parts of the daemon (no device needed).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
cc -O1 -g -Wall -Wextra -fsanitize=address,undefined -Isrc -o build/jitter_test tests/jitter_test.c src/jitter.c -lpthread
build/jitter_test
cc -O1 -g -Wall -Wextra -fsanitize=address,undefined -Isrc -o build/mic_state_test tests/mic_state_test.c src/mic_state.c
build/mic_state_test
cc -O1 -g -Wall -Wextra -fsanitize=address,undefined -Isrc -o build/tones_test tests/tones_test.c src/tones.c -lpthread
build/tones_test
cc -O1 -g -Wall -Wextra -fsanitize=address,undefined -Isrc -o build/wifi_test tests/wifi_test.c src/wifi.c src/run.c
build/wifi_test
cc -O1 -g -Wall -Wextra -fsanitize=address,undefined -Isrc -o build/sms_test tests/sms_test.c src/sms.c src/run.c
build/sms_test
