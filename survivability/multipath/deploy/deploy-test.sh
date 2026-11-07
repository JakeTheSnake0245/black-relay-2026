#!/bin/sh
# Black Relay — push the fork + lab + analysis tools to a THROWAWAY test server,
# build them, and run the self-tests. Non-destructive by design:
#   - installs nothing system-wide, writes no firewall/kernel/systemd units
#   - everything lands under ~/black-relay on the remote, runs as your user
#   - the tunnel (step: run) is a foreground process you kill with Ctrl-C
#
# This is NOT the production Hetzner box and NOT a CWWK node. Point it at a
# disposable VPS. Nothing here touches the production tunnel.
#
# Usage:
#   deploy/deploy-test.sh push  user@host     # rsync sources to ~/black-relay
#   deploy/deploy-test.sh deps  user@host     # apt-get build deps (asks sudo on remote)
#   deploy/deploy-test.sh build user@host     # clone glorytun@203c5f2, apply patch, build, self-test
#   deploy/deploy-test.sh lab   user@host     # bring up the 3-lane netns lab + tunnel (needs deps+build)
#   deploy/deploy-test.sh probe user@host     # run relay-probe end-to-end and print the reconstruction report
#   deploy/deploy-test.sh all   user@host     # push + deps + build + self-test (stops before lab)
#
# Env: REMOTE_DIR (default ~/black-relay), SSH_OPTS for extra ssh flags.
set -eu

REMOTE_DIR="${REMOTE_DIR:-black-relay}"
SSH_OPTS="${SSH_OPTS:-}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

cmd="${1:-}"; host="${2:-}"
[ -n "$cmd" ] && [ -n "$host" ] || { sed -n '1,30p' "$0"; exit 2; }

rsh() { ssh $SSH_OPTS "$host" "$@"; }

do_push() {
  echo ">> pushing sources to $host:~/$REMOTE_DIR"
  rsh "mkdir -p ~/$REMOTE_DIR"
  rsync -az --delete $SSH_OPTS_RSYNC \
    "$HERE/glorytun-fork" "$HERE/analysis" "$HERE/gt-lab" \
    "$host:~/$REMOTE_DIR/"
  echo ">> done."
}

do_deps() {
  echo ">> installing build deps on $host (will prompt for sudo on the remote)"
  rsh 'sudo apt-get update -qq && sudo apt-get install -y -qq \
        git build-essential pkg-config libsodium-dev \
        iproute2 iperf3 tcpdump python3'
}

do_build() {
  echo ">> building the fork on $host"
  rsh "cd ~/$REMOTE_DIR/glorytun-fork && sh build.sh"
}

do_lab() {
  echo ">> bringing up 3-lane netns lab + tunnel on $host (needs sudo on remote)"
  rsh "cd ~/$REMOTE_DIR/gt-lab && sudo sh lab.sh up && echo '-- lab up, now start the tunnel per gt-lab/tunnel.sh --'"
}

do_probe() {
  echo ">> running relay-probe end-to-end on $host"
  rsh "cd ~/$REMOTE_DIR && python3 analysis/relay-probe.py --help | head -20"
  echo ">> (wire the server/client endpoints per analysis/README.md, then run the probe both sides)"
}

case "$cmd" in
  push)  do_push ;;
  deps)  do_deps ;;
  build) do_build ;;
  lab)   do_lab ;;
  probe) do_probe ;;
  all)   do_push; do_deps; do_build ;;
  *) echo "unknown command: $cmd"; sed -n '1,30p' "$0"; exit 2 ;;
esac
