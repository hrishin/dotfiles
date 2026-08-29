# Debug container for `kubectl debug` — bundles common network/process
# troubleshooting tools that most application images don't ship, so pods
# without a shell (distroless/scratch) or without these tools can still be
# debugged via an attached ephemeral container. See `kdebug` in
# configs/.profile for how it's invoked.
#
# Build/publish: ./build.sh (in this directory) — see that script for
# usage. Publishes to docker.io/hriships/debug.
FROM debian:bookworm-slim

# dnsutils -> dig, sysstat -> mpstat/iostat/sar, procps -> top/ps,
# iproute2 -> ip/ss, tcpdump -> tcpdump. Runs as root (the image's
# default): tcpdump needs CAP_NET_RAW/CAP_NET_ADMIN, which an ephemeral
# debug container won't have unless it's already running as root.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        dnsutils \
        sysstat \
        procps \
        iproute2 \
        tcpdump \
    && rm -rf /var/lib/apt/lists/*

CMD ["bash"]
