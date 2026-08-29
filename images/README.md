# Images

Container images built and published from this repo.

## `debug` — `docker.io/hriships/debug`

A debugging container for `kubectl debug`: bundles common network/process troubleshooting tools that most application images don't ship, so pods without a shell (distroless/scratch) or without these tools can still be debugged via an attached ephemeral container.

**Tools:** `dig`/`host`/`nslookup` (dnsutils), `sysstat` (`mpstat`/`iostat`/`sar`), `top`/`ps`/`free`/`vmstat` (procps), `ip`/`ss` (iproute2), `curl`, `wget`, `ping` (iputils-ping), `nc` (netcat-openbsd), `traceroute`, `netstat`/`ifconfig` (net-tools), `lsof`, `strace`, `openssl`, `jq`, `less`, `vi` (vim-tiny), plus a CA trust store (ca-certificates) so `curl`/`wget` work against HTTPS. See `images/debug/Dockerfile` for the authoritative, exact package list.

**Build/publish:**

```bash
cd images/debug
./build.sh              # multi-arch (amd64+arm64) build + push :latest
./build.sh v1            # multi-arch build + push :v1
./build.sh v1 --no-push  # host-arch-only build, skip the push
```

Requires a working `docker` (with buildx) or `podman` CLI already logged in to `docker.io` (`docker login` / `podman login`). Pushed builds are always multi-arch (`linux/amd64` + `linux/arm64`) via a manifest list, since this image is meant to run on whatever architecture the target cluster's nodes actually use — a single-arch image built on an Apple Silicon Mac and attached via `kubectl debug` to an amd64 node fails with `exec format error`. `--no-push` skips the manifest step and just builds for the local host arch, for a quick local smoke test.

**CI:** `.github/workflows/debug-image.yml` builds and pushes the same multi-arch image automatically (via `docker/build-push-action` + QEMU, not `build.sh`) on every push to `master` that touches `images/debug/**`, tagging `:latest` and the short commit SHA. It also runs (build-only, no push) on pull requests touching that path, to catch a broken Dockerfile before merge, and supports manual runs via `workflow_dispatch` with an optional extra tag. Needs two repo secrets — Settings → Secrets and variables → Actions:

- `DOCKERHUB_USERNAME` — the `hriships` Docker Hub account
- `DOCKERHUB_TOKEN` — an [access token](https://hub.docker.com/settings/security) for that account (not the account password), scoped to Read & Write

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
