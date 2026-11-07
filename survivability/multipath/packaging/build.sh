#!/usr/bin/env bash
# Black Relay — build installable packages of the glorytun fork.
#
# Cross-compiles a fully static (musl) glorytun fork with zig, then packs:
#   dist/black-relay-glorytun_<ver>_amd64.deb    Hetzner / any Debian-Ubuntu x86_64
#   dist/black-relay-glorytun_<ver>_arm64.deb    arm64 Debian-Ubuntu (Hetzner CAX, lab VMs)
#   dist/black-relay-glorytun_<ver>_x86_64.ipk   OMR (OpenWrt x86_64) VM on the CWWK nodes
#   dist/black-relay-debug_<ver>_all.deb       capture + verify + Wireshark dissector
#   dist/black-relay-debug-<ver>.tar.gz        the same tools for a workstation
#   dist/SHA256SUMS
#
# Static binaries mean no libsodium/libc dependency on any target, so one
# binary serves Debian 11-13, Ubuntu 22.04+, and OpenWrt alike.
#
# Runs on macOS or Linux. Needs: zig (0.13+), git, curl, python3, make.
#   packaging/build.sh              # all arches
#   ARCHES=x86_64 packaging/build.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FORK="$ROOT/glorytun-fork"
WORK="${WORK:-$HERE/.build}"
DIST="${DIST:-$ROOT/dist}"
ARCHES="${ARCHES:-x86_64 aarch64}"

GT_PIN=203c5f2223d7d5146d659b51159b2f02c2480d15
GT_VERSION=0.3.4-br
PKG_VERSION=0.3.4+br5          # deb (ipk uses 0.3.4-br5)
SODIUM_VER=1.0.20
SODIUM_SHA256=ebb65ef6ca439333c2bb41a0c1990587288da07f6c7fd07cb3a18cc18d30ce19
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1761436800}"   # 2025-10-26
export ZIG_GLOBAL_CACHE_DIR="$WORK/zig-cache"
MAINTAINER="${MAINTAINER:-Black Relay <root@localhost>}"

for t in zig git curl python3 make; do
	command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
ncpu() { getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4; }

mkdir -p "$WORK" "$DIST"

# ---------------------------------------------------------------- sources
fetch() {
	local tgz="$WORK/libsodium-$SODIUM_VER.tar.gz"
	if [ ! -f "$tgz" ]; then
		echo ">> fetching libsodium $SODIUM_VER"
		curl -fsSL -o "$tgz.part" \
			"https://download.libsodium.org/libsodium/releases/libsodium-$SODIUM_VER.tar.gz"
		mv "$tgz.part" "$tgz"
	fi
	echo "$SODIUM_SHA256  $tgz" | sha256 -c - >/dev/null ||
		{ echo "libsodium checksum mismatch" >&2; exit 1; }

	local src="$WORK/glorytun"
	if [ ! -d "$src/.git" ]; then
		echo ">> cloning glorytun @ ${GT_PIN:0:7}"
		git clone -q https://github.com/ysurac/glorytun.git "$src"
	fi
	# always rebuild the tree from the pin + the fork, so local edits to the
	# patch are picked up and nothing stale survives
	git -C "$src" checkout -q -f "$GT_PIN"
	git -C "$src" clean -qfdx
	git -C "$src" submodule update -q --init --recursive --force
	git -C "$src" submodule foreach -q --recursive 'git checkout -q -f . && git clean -qfdx'
	cp "$FORK/reseq.c" "$FORK/reseq.h" "$FORK/fec.c" "$FORK/fec.h" "$src/src/"
	git -C "$src" apply "$FORK/0001-black-relay-bonding-reseq.patch"
	git -C "$src" apply "$FORK/0002-black-relay-paths-64-passive-timeout.patch"
	echo ">> fork patches applied"
}

# ---------------------------------------------------------------- compile
build_arch() {
	local arch=$1 target="$1-linux-musl"
	local pfx="$WORK/sysroot-$arch" sod="$WORK/libsodium-$arch"
	local CC="zig cc -target $target"

	if [ ! -f "$pfx/lib/libsodium.a" ]; then
		echo ">> [$arch] libsodium $SODIUM_VER (static)"
		rm -rf "$sod" && mkdir -p "$sod"
		tar xzf "$WORK/libsodium-$SODIUM_VER.tar.gz" -C "$sod" --strip-components 1
		(cd "$sod" &&
		 ./configure -q --host="$target" --prefix="$pfx" \
			--disable-shared --enable-static --disable-pie \
			CC="$CC" AR="zig ar" RANLIB="zig ranlib" >/dev/null 2>&1 &&
		 make -s -j"$(ncpu)" install >/dev/null 2>"$WORK/libsodium-$arch.log")
	fi

	echo ">> [$arch] glorytun fork (static)"
	local src="$WORK/glorytun"
	(cd "$src" &&
	 $CC -static -std=c99 -O2 -Wall -fstack-protector-strong -s \
		-DPACKAGE_NAME='"glorytun"' -DPACKAGE_VERSION="\"$GT_VERSION\"" \
		-I"$pfx/include" \
		argz/argz.c mud/aegis256/aegis256.c mud/mud.c \
		src/argz.c src/bench.c src/bind.c src/common.c src/ctl.c src/fec.c \
		src/iface.c src/keygen.c src/list.c src/main.c src/path.c src/reseq.c \
		src/set.c src/show.c src/tun.c src/version.c \
		-L"$pfx/lib" -lsodium -o "$WORK/glorytun-$arch" 2>"$WORK/glorytun-$arch.log") ||
		{ cat "$WORK/glorytun-$arch.log" >&2; exit 1; }
}

fec_selftest() {
	echo ">> FEC codec self-test (host)"
	local t="$WORK/fectest"
	zig cc -DFEC_TEST -I"$WORK/glorytun/src" "$WORK/glorytun/src/fec.c" -o "$t" 2>/dev/null
	"$t"
}

# ---------------------------------------------------------------- staging
stage_common() {
	local arch=$1 r=$2
	install -d "$r/usr/lib/black-relay" "$r/usr/sbin" "$r/etc/black-relay" \
		"$r/usr/share/black-relay/analysis"
	install -m 0755 "$WORK/glorytun-$arch" "$r/usr/lib/black-relay/glorytun"
	install -m 0755 "$HERE/files/glorytun-br" "$HERE/files/black-relay-switch" \
		"$HERE/files/black-relay-keygen" "$r/usr/sbin/"
	install -m 0644 "$HERE/files/black-relay.env" "$r/etc/black-relay/"
	install -m 0755 "$ROOT/analysis/relay-probe.py" "$ROOT/analysis/lane-stats.py" \
		"$r/usr/share/black-relay/analysis/"
	install -m 0644 "$ROOT/analysis/README.md" "$r/usr/share/black-relay/analysis/"
}

deb_arch() { case $1 in x86_64) echo amd64 ;; aarch64) echo arm64 ;; esac; }

pack_deb() {
	local arch=$1 darch r c
	darch=$(deb_arch "$arch")
	r="$WORK/stage-deb-$darch/root" c="$WORK/stage-deb-$darch/DEBIAN"
	rm -rf "$WORK/stage-deb-$darch" && mkdir -p "$r" "$c"
	stage_common "$arch" "$r"

	install -d "$r/usr/lib/systemd/system" "$r/usr/share/black-relay/lab" \
		"$r/usr/share/black-relay/examples" "$r/usr/share/doc/black-relay-glorytun"
	install -m 0755 "$HERE/files/tunnel" "$r/usr/lib/black-relay/tunnel"
	install -m 0755 "$HERE/files/black-relay-lab" "$HERE/files/black-relay-setup" "$HERE/files/black-relay-hub" "$r/usr/sbin/"
	install -m 0644 "$HERE/files/black-relay@.service" "$HERE/files/black-relay-watch@.service" \
		"$r/usr/lib/systemd/system/"
	install -m 0644 "$HERE/files/server.conf.example" "$HERE/files/client.conf.example" \
		"$r/usr/share/black-relay/examples/"
	install -m 0755 "$ROOT/gt-lab/"*.sh "$ROOT/gt-lab/"*.py "$r/usr/share/black-relay/lab/"
	install -m 0644 "$HERE/README.md" "$FORK/SECURITY.md" "$HERE/files/copyright" \
		"$r/usr/share/doc/black-relay-glorytun/"
	install -m 0644 "$FORK/README.md" "$r/usr/share/doc/black-relay-glorytun/FORK.md"

	cat >"$c/control" <<EOF
Package: black-relay-glorytun
Version: $PKG_VERSION
Architecture: $darch
Maintainer: $MAINTAINER
Section: net
Priority: optional
Depends: iproute2
Recommends: python3
Suggests: iperf3, tcpdump
Homepage: https://github.com/angt/glorytun
Description: Black Relay glorytun fork - bonded multipath tunnel with reconstruction
 Glorytun (ysurac@203c5f2) plus the Black Relay patch: in-AEAD sequence
 numbers, scatter/arrival schedulers, receive-side resequencer, XOR FEC,
 header protection, monotonic nonce and anti-replay. Static binary.
 Installs alongside stock glorytun; black-relay-switch swaps it in/out.
EOF
	echo "/etc/black-relay/black-relay.env" >"$c/conffiles"
	install -m 0755 "$HERE/debian/postinst" "$HERE/debian/prerm" "$c/"

	python3 "$HERE/mkpkg.py" deb "$r" "$c" \
		"$DIST/black-relay-glorytun_${PKG_VERSION}_${darch}.deb"
}

pack_ipk() {
	local arch=$1 r c
	r="$WORK/stage-ipk-$arch/root" c="$WORK/stage-ipk-$arch/CONTROL"
	rm -rf "$WORK/stage-ipk-$arch" && mkdir -p "$r" "$c"
	stage_common "$arch" "$r"

	sed -i.bak 's/^#GT_ROLE=$/GT_ROLE=client/' "$r/etc/black-relay/black-relay.env" && rm -f "$r/etc/black-relay/black-relay.env.bak"

	local v="${PKG_VERSION/+br/-br}"
	cat >"$c/control" <<EOF
Package: black-relay-glorytun
Version: $v
Architecture: $arch
Maintainer: $MAINTAINER
Section: net
License: BSD-2-Clause
Description: Black Relay glorytun fork (static). Installs beside OMR's
 glorytun-udp; black-relay-switch swaps it in and out.
EOF
	echo "/etc/black-relay/black-relay.env" >"$c/conffiles"
	install -m 0755 "$HERE/openwrt/postinst" "$HERE/openwrt/prerm" "$c/"

	python3 "$HERE/mkpkg.py" ipk "$r" "$c" \
		"$DIST/black-relay-glorytun_${v}_${arch}.ipk"
}

# separate test/debug package: per-interface capture, verification, and the
# Wireshark dissector. Architecture-independent (shell + python + lua).
pack_debug() {
	local r="$WORK/stage-debug/root" c="$WORK/stage-debug/DEBIAN"
	rm -rf "$WORK/stage-debug" && mkdir -p "$r" "$c"
	install -d "$r/usr/sbin" "$r/usr/bin" "$r/usr/share/black-relay-debug" \
		"$r/usr/share/doc/black-relay-debug"
	install -m 0755 "$HERE/debug/br-capture" "$r/usr/sbin/"
	install -m 0755 "$HERE/debug/br-verify" "$r/usr/bin/"
	install -m 0644 "$HERE/debug/black-relay.lua" "$r/usr/share/black-relay-debug/"
	install -m 0644 "$HERE/debug/README.md" "$HERE/files/copyright" "$r/usr/share/doc/black-relay-debug/"
	cat >"$c/control" <<EOF
Package: black-relay-debug
Version: $PKG_VERSION
Architecture: all
Maintainer: $MAINTAINER
Section: net
Priority: optional
Depends: tcpdump, python3
Suggests: black-relay-glorytun, tshark
Description: Black Relay test and debug tools
 br-capture records every uplink and the tunnel device independently;
 br-verify checks each packet left through the right uplink, matches lanes
 and inner packets end to end, and writes an annotated pcapng for Wireshark.
 Includes a Wireshark Lua dissector for the outer tunnel packets.
EOF
	python3 "$HERE/mkpkg.py" deb "$r" "$c" "$DIST/black-relay-debug_${PKG_VERSION}_all.deb"

	# the same tools for a workstation (macOS/Windows/Linux with Wireshark)
	local t="$WORK/stage-debug/black-relay-debug-$PKG_VERSION"
	mkdir -p "$t"
	cp "$HERE/debug/br-verify" "$HERE/debug/br-capture" "$HERE/debug/black-relay.lua" \
		"$HERE/debug/README.md" "$t/"
	tar -C "$WORK/stage-debug" -czf "$DIST/black-relay-debug-$PKG_VERSION.tar.gz" \
		--uid 0 --gid 0 "black-relay-debug-$PKG_VERSION" 2>/dev/null ||
		tar -C "$WORK/stage-debug" -czf "$DIST/black-relay-debug-$PKG_VERSION.tar.gz" \
			"black-relay-debug-$PKG_VERSION"
	echo "wrote $DIST/black-relay-debug-$PKG_VERSION.tar.gz"
}

# ---------------------------------------------------------------- main
fetch
fec_selftest
rm -f "$DIST"/black-relay-glorytun_* "$DIST"/black-relay-debug* "$DIST/SHA256SUMS"
for a in $ARCHES; do
	build_arch "$a"
	pack_deb "$a"
	[ "$a" = x86_64 ] && pack_ipk "$a"
done
pack_debug
(cd "$DIST" && sha256 black-relay-glorytun_* black-relay-debug* >SHA256SUMS)
echo ">> done:"
ls -l "$DIST"
