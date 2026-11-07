# Black Relay "Multithread" hub/tunnel image: the glorytun fork + tunnel
# helpers + wstunnel (sites reach the hub through HTTPS 443), run by
# br-supervise instead of systemd. Userspace only: no kernel modules, no MPTCP
# kernel, no host firewall changes. Tunnel devices, forwarding and NAT all live
# in the container's own network namespace.
#
# Build context is prepared by build.sh (rootfs/ = files from the .deb).
FROM alpine:3.22.2

RUN apk add --no-cache iproute2 nftables tini python3 \
 && mkdir -p /etc/black-relay /usr/share/black-relay/defaults

COPY rootfs/ /
COPY br-supervise /usr/sbin/br-supervise

RUN chmod 0755 /usr/sbin/br-supervise /usr/sbin/black-relay-hub /usr/sbin/black-relay-keygen \
        /usr/lib/black-relay/tunnel /usr/lib/black-relay/glorytun \
 && mv /etc/black-relay/black-relay.env /usr/share/black-relay/defaults/black-relay.env \
 && /usr/lib/black-relay/glorytun version \
 && /usr/bin/wstunnel --version

LABEL org.opencontainers.image.title="black-relay" \
      org.opencontainers.image.description="Black Relay glorytun fork: multipath bonded UDP tunnel hub (userspace)"

VOLUME ["/etc/black-relay"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD ["/usr/sbin/br-supervise", "health"]
ENTRYPOINT ["/sbin/tini", "--", "/usr/sbin/br-supervise"]
