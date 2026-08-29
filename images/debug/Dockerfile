# Debug container for `kubectl debug` — bundles common network/process
# troubleshooting tools that most application images don't ship, so pods
# without a shell (distroless/scratch) or without these tools can still be
# debugged via an attached ephemeral container. See `kdebug` in
# configs/.profile for how it's invoked.
#
# Build/publish: ./build.sh (in this directory) — see that script for
# usage. Publishes to docker.io/hriships/debug.
FROM debian:bookworm-slim

# dnsutils -> dig/host/nslookup, sysstat -> mpstat/iostat/sar,
# procps -> top/ps/free/vmstat, iproute2 -> ip/ss, curl/wget -> HTTP
# checks, iputils-ping -> ping, netcat-openbsd -> nc (port checks),
# traceroute -> path tracing, net-tools -> netstat/ifconfig (still
# common muscle memory alongside ip/ss), lsof -> open files/sockets,
# strace -> syscall tracing, openssl -> TLS/cert inspection,
# jq -> parsing curl'd JSON, less/vim-tiny -> paging and editing files,
# ca-certificates -> trust store for curl/wget against HTTPS.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        dnsutils \
        sysstat \
        procps \
        iproute2 \
        curl \
        wget \
        iputils-ping \
        netcat-openbsd \
        traceroute \
        net-tools \
        lsof \
        strace \
        openssl \
        jq \
        less \
        vim-tiny \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

CMD ["bash"]
