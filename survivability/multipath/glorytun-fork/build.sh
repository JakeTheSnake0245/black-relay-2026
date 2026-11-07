#!/usr/bin/env bash
# Reproducible build of the Black Relay glorytun fork.
# Clones ysurac/glorytun at the pinned commit, applies the patch, builds
# against system libsodium. Linux with gcc, make, libsodium-dev, git.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PIN=203c5f2223d7d5146d659b51159b2f02c2480d15
OUT="${1:-/tmp/glorytun-br-build}"

rm -rf "$OUT"
git clone https://github.com/ysurac/glorytun.git "$OUT"
cd "$OUT"
git checkout -q "$PIN"
git submodule update --init --recursive

cp "$HERE/reseq.c" "$HERE/reseq.h" "$HERE/fec.c" "$HERE/fec.h" src/
git apply "$HERE/0001-black-relay-bonding-reseq.patch"

echo "0.3.4-br" > VERSION
gcc -std=c99 -O2 -Wall -fstack-protector-strong \
    -DPACKAGE_NAME='"glorytun"' -DPACKAGE_VERSION='"0.3.4-br"' \
    argz/argz.c mud/aegis256/aegis256.c mud/mud.c \
    src/argz.c src/bench.c src/bind.c src/common.c src/ctl.c src/fec.c \
    src/iface.c src/keygen.c src/list.c src/main.c src/path.c src/reseq.c \
    src/set.c src/show.c src/tun.c src/version.c \
    -o glorytun -lsodium

# optional: run the FEC codec self-test
cc -DFEC_TEST -Isrc src/fec.c -o /tmp/fectest && /tmp/fectest || true

echo "built: $OUT/glorytun"
./glorytun version
