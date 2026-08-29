# Images

Container images built and published from this repo.

## `debug` — `docker.io/hriships/debug`

A debugging container for `kubectl debug`: bundles common network/process troubleshooting tools that most application images don't ship, so pods without a shell (distroless/scratch) or without these tools can still be debugged via an attached ephemeral container.

**Tools:** `dig` (dnsutils), `sysstat` (`mpstat`/`iostat`/`sar`), `top`/`ps` (procps), `ip`/`ss` (iproute2), `tcpdump`. Runs as root — `tcpdump` needs `CAP_NET_RAW`/`CAP_NET_ADMIN`, which an ephemeral debug container won't have unless it's already running as root.

**Build/publish:**

```bash
cd images/debug
./build.sh              # multi-arch (amd64+arm64) build + push :latest
./build.sh v1            # multi-arch build + push :v1
./build.sh v1 --no-push  # host-arch-only build, skip the push
```

Requires a working `docker` (with buildx) or `podman` CLI already logged in to `docker.io` (`docker login` / `podman login`). Pushed builds are always multi-arch (`linux/amd64` + `linux/arm64`) via a manifest list, since this image is meant to run on whatever architecture the target cluster's nodes actually use — a single-arch image built on an Apple Silicon Mac and attached via `kubectl debug` to an amd64 node fails with `exec format error`. `--no-push` skips the manifest step and just builds for the local host arch, for a quick local smoke test.

**Usage:** `kdebug` in `configs/.profile` wraps `kubectl debug` to attach this image to a running pod:

```bash
kdebug mypod                # ephemeral container, own namespaces
kdebug mypod my-container    # also shares my-container's process namespace
```

Or invoke `kubectl debug` directly:

```bash
kubectl debug -it mypod --image=docker.io/hriships/debug -- bash
kubectl debug -it mypod --image=docker.io/hriships/debug --target=my-container -- bash
```
