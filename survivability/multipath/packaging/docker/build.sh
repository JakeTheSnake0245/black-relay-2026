#!/bin/sh
# Build the black-relay container image from the amd64 .deb in ../../dist.
#
#   packaging/docker/build.sh                 # -> image black-relay:<ver>, dist/black-relay-image_<ver>_amd64.tar.gz
#   NO_SAVE=1 packaging/docker/build.sh       # skip the docker-save tarball
#
# Needs docker, ar (binutils) and tar. The binary is the static one already
# in the .deb, so the image runs the exact build the lab tested.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
VER=${VER:-0.3.4+br5}            # glorytun fork .deb the binary comes from
TAG=${TAG:-0.3.5-mt3}              # image tag (fork + scripts + wstunnel)
# wstunnel (HTTPS transport for sites, "Multithread" over 443): pinned release,
# checked against the sha256 published in the release's checksums.txt
WSTUNNEL_VER=11.1.0
WSTUNNEL_SHA256=512edf4e7bb64fc133522220123514868fae75b5bae4124b53e396787276aa23
WSTUNNEL_TGZ=${WSTUNNEL_TGZ:-$ROOT/dist/wstunnel_${WSTUNNEL_VER}_linux_amd64.tar.gz}
DEB="$ROOT/dist/black-relay-glorytun_${VER}_amd64.deb"
[ -r "$DEB" ] || { echo "missing $DEB (run packaging/build.sh)" >&2; exit 1; }
[ -r "$WSTUNNEL_TGZ" ] || { echo "missing $WSTUNNEL_TGZ (gh release download v$WSTUNNEL_VER -R erebe/wstunnel)" >&2; exit 1; }
echo "$WSTUNNEL_SHA256  $WSTUNNEL_TGZ" | sha256sum -c - >/dev/null || { echo "wstunnel sha256 mismatch" >&2; exit 1; }

CTX=$(mktemp -d)
trap 'rm -rf "$CTX"' EXIT
mkdir -p "$CTX/rootfs"
( cd "$CTX" && ar x "$DEB" data.tar.gz && tar -xzf data.tar.gz -C rootfs \
	./usr/lib/black-relay/glorytun ./usr/lib/black-relay/tunnel \
	./usr/sbin/black-relay-keygen ./etc/black-relay/black-relay.env \
	./usr/share/black-relay/analysis )
# scripts from the tree (the hub script gained container support after br4)
install -m 0755 "$ROOT/packaging/files/black-relay-hub" "$CTX/rootfs/usr/sbin/black-relay-hub"
install -m 0755 "$ROOT/packaging/files/tunnel" "$CTX/rootfs/usr/lib/black-relay/tunnel"
install -d "$CTX/rootfs/usr/bin"
tar -xzf "$WSTUNNEL_TGZ" -C "$CTX/rootfs/usr/bin" wstunnel
chmod 0755 "$CTX/rootfs/usr/bin/wstunnel"
cp "$HERE/Dockerfile" "$HERE/br-supervise" "$CTX/"

docker build --platform linux/amd64 -t "black-relay:$TAG" "$CTX"
if [ -z "${NO_SAVE:-}" ]; then
	out="$ROOT/dist/black-relay-image_${TAG}_amd64.tar.gz"
	docker save "black-relay:$TAG" | gzip -9 >"$out"
	( cd "$ROOT/dist" && sha256sum "$(basename "$out")" )
	echo "wrote $out"
fi
