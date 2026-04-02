# PLAID Reduced Stack — Annotated File Reference

This document walks through every file in the PLAID reduced stack, with inline
annotations explaining what each line does and why. The system has three major
subsystems:

1. **Assets** — downloading Firecracker and the kernel
2. **Guest rootfs** — building the Alpine Linux ext4 image for the Firecracker VM
3. **Bill** — building the Yocto OCI image (with GCS sstate cache)
4. **Runtime** — host networking, VM launch, SSH, and container loading

Files are presented in execution order within each subsystem.

---

## How a build flows

```
make bill
  -> bill/build.sh                  # host: launches docker compose
    -> docker compose run builder   # host: starts builder container
      -> bill/entrypoint.sh         # container (root): fix perms, drop to builder user
        -> bill/build-inner.sh      # container (builder): pull GCS, bitbake, push GCS
  -> bill/import.sh                 # host: import tarball as Docker image
```

---

## Makefile (relevant targets)

The top-level Makefile orchestrates everything. `make bill` depends on `builder`
(so the Docker image is always up-to-date), then shells into `bill/` to run the
build and import scripts.

```makefile
# bill depends on builder — if Dockerfile.builder changed, rebuild the image first
bill: builder
	cd bill && ./build.sh && ./import.sh

# Builds the Yocto builder Docker image from bill/Dockerfile.builder
# This is the "toolchain" image — it has gcc, python, bitbake deps, and gsutil
builder:
	@echo "==> Building Yocto builder image..."
	docker build -t vpanel-yocto-zeus-builder:latest -f bill/Dockerfile.builder bill/
	@echo "==> vpanel-yocto-zeus-builder:latest ready."
```

**Key point:** `make bill` always rebuilds the builder image first. This is fast
(Docker layer cache) unless Dockerfile.builder actually changed.

---

## bill/Dockerfile.builder

This builds the `vpanel-yocto-zeus-builder:latest` Docker image — an Ubuntu 18.04
environment with everything Yocto Zeus needs, plus the Google Cloud SDK for
GCS sstate sync.

```dockerfile
FROM ubuntu:18.04
# Why 18.04: Yocto Zeus (3.0) requires it. Newer Ubuntu versions break the build.

ENV DEBIAN_FRONTEND=noninteractive
# Prevents apt from asking interactive questions during docker build.

RUN apt-get update && apt-get install -y \
    gawk wget git diffstat unzip texinfo gcc build-essential chrpath \
    socat cpio python3 python3-pip python3-pexpect xz-utils debianutils \
    iputils-ping python3-git python3-jinja2 libegl1-mesa libsdl1.2-dev \
    pylint3 xterm python3-subunit mesa-common-dev zstd liblz4-tool \
    locales file python \
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
# These are Yocto's host dependencies. The list comes from the Yocto Project
# Quick Start guide for Zeus. `ca-certificates` and `curl` are for downloading
# poky and for gsutil. `python` (2.7) is still required by some Yocto scripts.

RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
# Yocto/bitbake requires a UTF-8 locale or it will fail with encoding errors.

# Install Google Cloud SDK for gsutil (sstate cache sync to GCS)
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - \
    && apt-get update && apt-get install -y google-cloud-sdk \
    && rm -rf /var/lib/apt/lists/*
# We use the apt-based install rather than the curl installer because the
# curl installer requires Python 3.8+, which Ubuntu 18.04 doesn't have.
# The apt package bundles its own Python. This gives us gsutil and gcloud
# inside the container for pulling/pushing sstate to GCS.

RUN groupadd -g 1000 builder \
    && useradd -u 1000 -g 1000 -m -s /bin/bash builder
# Yocto refuses to run as root. We create a non-root user with UID/GID 1000
# (matching the typical host user) so file ownership in bind mounts is sane.

RUN su - builder -c 'git config --global user.email "builder@plaid.local"' \
    && su - builder -c 'git config --global user.name "PLAID Builder"'
# Yocto's devtool and some recipes run git commands that fail without a
# configured identity.

RUN curl -fsSL "https://github.com/tianon/gosu/releases/download/1.16/gosu-amd64" \
        -o /usr/local/bin/gosu \
    && chmod +x /usr/local/bin/gosu \
    && gosu --version
# gosu lets the entrypoint start as root (to fix permissions) then drop
# to the builder user without the PID/signal issues that `su` causes.

RUN mkdir -p /build && chown builder:builder /build
# /build is where everything happens: poky checkout, bitbake workspace,
# conf files, and output. Owned by builder so bitbake can write freely.

COPY entrypoint.sh /build/entrypoint.sh
RUN chmod +x /build/entrypoint.sh

WORKDIR /build
ENTRYPOINT ["/build/entrypoint.sh"]
# The entrypoint runs as root, fixes volume permissions, then exec's
# the actual command as the builder user via gosu.
```

---

## bill/entrypoint.sh

Runs as root inside the container. Its only job is to fix volume ownership
(Docker volumes are created as root) and then drop to the unprivileged
builder user.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Fix ownership of mounted directories (volume mounts may be root-owned)
chown -R builder:builder /build 2>/dev/null || true
chown -R builder:builder /yocto 2>/dev/null || true
# When Docker creates a named volume for the first time, the mount point
# is owned by root. The builder user (uid 1000) can't write to it.
# /build holds the workspace; /yocto holds downloads and sstate-cache.
# The 2>/dev/null suppresses errors if /yocto doesn't exist yet (it's
# created by the volume mount).

# Drop to builder user and exec the command
exec gosu builder "$@"
# `exec` replaces the shell process so signals (SIGTERM, etc.) go
# directly to the build command, not to this wrapper script.
# gosu is like `su` but doesn't fork — it exec's directly, so PID 1
# is the actual command, not a su wrapper.
```

---

## bill/docker-compose.yml

Defines how the builder container runs. This is the glue between the host
filesystem, Docker volumes, and the container environment.

```yaml
version: "3.8"

services:
  builder:
    image: vpanel-yocto-zeus-builder:latest
    # The image built by Dockerfile.builder above.

    volumes:
      - yocto-downloads:/yocto/downloads
      # Named Docker volume for Yocto's download cache (fetched source
      # tarballs). Persists across builds so sources aren't re-downloaded.

      - yocto-sstate:/yocto/sstate-cache
      # Named Docker volume for Yocto's shared state cache. This is the
      # big one — it stores compiled artifacts so tasks don't re-run.
      # On a cold start this is empty; GCS sync populates it.

      - ./conf:/build/conf
      # Bind-mounts local.conf and bblayers.conf into the container.
      # These control what Yocto builds (machine, packages, layers).

      - ./build-output:/build/build-output
      # Bind-mount where the final rootfs tarball lands. The host's
      # import.sh reads from here.

      - ./build-inner.sh:/build/build-inner.sh
      # Bind-mount the build script so we can edit it without rebuilding
      # the Docker image.

      - ${HOME}/.config/gcloud:/home/builder/.config/gcloud:ro
      # Mounts the host's gcloud credentials into the container (read-only).
      # This is how gsutil inside the container authenticates to GCS.
      # The host user runs `gcloud auth login` once; the container reuses
      # those credentials. :ro prevents the container from modifying them.

    environment:
      - SSTATE_GCS_BUCKET=${SSTATE_GCS_BUCKET:-}
      # Pass the GCS bucket name into the container. If the host env var
      # is unset, this resolves to an empty string, and build-inner.sh
      # skips the GCS sync entirely. This makes GCS opt-in:
      #   SSTATE_GCS_BUCKET=vpanel-sstate make bill   # with GCS
      #   make bill                                     # without GCS

    working_dir: /build
    command: bash -c "/build/build-inner.sh"
    # The entrypoint (entrypoint.sh) wraps this: it fixes perms, drops
    # to the builder user, then exec's this command.

volumes:
  yocto-downloads:
    external: true
    name: vpanel-base-x86_yocto-downloads
  yocto-sstate:
    external: true
    name: vpanel-base-x86_yocto-sstate
  # `external: true` means docker compose won't create these volumes —
  # they must already exist. The Makefile or the user creates them with
  # `docker volume create`. The fixed names ensure multiple runs share
  # the same cache even if the compose project name changes.
```

---

## bill/build-inner.sh

This is the main build script. It runs inside the container as the `builder`
user. It handles the full lifecycle: GCS pull, Yocto setup, bitbake, output
copy, and GCS push.

```bash
#!/usr/bin/env bash
set -eo pipefail
# Note: -u (nounset) is intentionally omitted because Yocto's
# oe-init-build-env sets variables that would trigger unbound errors.

cd /build

# GitHub killed git:// protocol — redirect to https
git config --global url."https://".insteadOf git://
# Many Yocto recipes and layers use git:// URLs for GitHub repos.
# GitHub dropped the git:// protocol entirely. This global git config
# rewrites all git:// URLs to https:// transparently.

# Pull sstate cache from GCS if bucket is configured
if [ -n "${SSTATE_GCS_BUCKET:-}" ]; then
    echo "==> Pulling sstate cache from gs://${SSTATE_GCS_BUCKET}/sstate-cache/ ..."
    gsutil -m rsync -r "gs://${SSTATE_GCS_BUCKET}/sstate-cache/" /yocto/sstate-cache/ || \
        echo "    Warning: GCS pull failed (bucket may be empty on first run), continuing..."
fi
# -m enables multi-threaded transfer (much faster for thousands of small files).
# rsync -r does a recursive sync: only downloads files that don't exist locally
# or differ from the remote. On a truly cold build (empty volume), this pulls
# the entire cache (~3.3 GiB, ~5200 files). On subsequent builds, it's a no-op
# or a small delta.
#
# The || echo fallback means the build continues even if GCS pull fails (e.g.,
# empty bucket on very first build, or no network). The build will just be slow.

# Clone poky if not already present (pinned to match sstate cache)
if [ ! -d poky ]; then
    git clone -b yocto-3.0.3 https://git.yoctoproject.org/poky.git poky
fi
# Poky is the Yocto reference distribution. yocto-3.0.3 is the Zeus release.
# The tag is pinned so the sstate cache stays valid — if you change the poky
# version, the entire sstate cache becomes useless and everything rebuilds.
# The if/fi guard means poky persists in the Docker volume between runs.

# The git:// protocol is dead on GitHub — git config insteadOf handles that.
# Do NOT blindly replace branch=master with branch=main; most repos still use master.

# Copy conf files into the build directory
mkdir -p /build/build/conf
cp /build/conf/local.conf /build/build/conf/local.conf
cp /build/conf/bblayers.conf /build/build/conf/bblayers.conf
# Yocto expects conf files in the build directory. We bind-mount our conf/
# directory and copy them into place. This way, edits to local.conf on the
# host take effect on the next build without needing to rebuild the Docker image.

# Source the oe-init-build-env (this changes directory to /build/build)
source /build/poky/oe-init-build-env /build/build
# This is the Yocto environment setup script. It:
#   - Adds bitbake to PATH
#   - Sets BUILDDIR to /build/build
#   - cd's into the build directory
# After this line, we're in /build/build and bitbake is available.

# Build
bitbake core-image-minimal
# This is the actual Yocto build. core-image-minimal is a small Linux image.
# With a populated sstate cache, this takes minutes (just re-packaging).
# Without sstate, it takes hours (compiles gcc, glibc, kernel, everything).

# Copy the output rootfs tarball
mkdir -p /build/build-output
cp /build/build/tmp/deploy/images/qemux86-64/core-image-minimal-qemux86-64.tar.bz2 \
   /build/build-output/ 2>/dev/null || \
cp /build/build/tmp/deploy/images/qemux86-64/core-image-minimal-qemux86-64.rootfs.tar.bz2 \
   /build/build-output/ 2>/dev/null || true
# Yocto names the output differently depending on version/config. We try
# both common names. The tarball lands in build-output/ which is bind-mounted
# to the host, so import.sh can find it.

# Also copy any tar.gz variant
cp /build/build/tmp/deploy/images/qemux86-64/core-image-minimal-qemux86-64.tar.gz \
   /build/build-output/ 2>/dev/null || true

# Push sstate cache to GCS if bucket is configured
if [ -n "${SSTATE_GCS_BUCKET:-}" ]; then
    echo "==> Pushing sstate cache to gs://${SSTATE_GCS_BUCKET}/sstate-cache/ ..."
    gsutil -m rsync -r /yocto/sstate-cache/ "gs://${SSTATE_GCS_BUCKET}/sstate-cache/" || \
        echo "    Warning: GCS push failed, continuing..."
fi
# After a successful build, push any new sstate artifacts back to GCS.
# rsync only uploads files that are new or changed, so this is fast after
# the initial seed. This keeps the GCS cache up to date for the next person
# who clones the repo.
#
# Note the direction: local -> GCS (opposite of the pull above).
# The || echo fallback means a push failure doesn't fail the build.

echo "Build complete. Output in /build/build-output/"
ls -la /build/build-output/
```

---

## bill/conf/local.conf

Yocto's main configuration file. Controls what machine to build for,
what packages to include, and where caches live.

```conf
MACHINE ??= "qemux86-64"
# Build for QEMU x86-64. This matches the Firecracker VM architecture.
# ??= is Yocto's "set if not already set anywhere" operator.

DISTRO ?= "poky"
# Use the Poky reference distribution (default Yocto).

PACKAGE_CLASSES ?= "package_ipk"
# Use IPK packaging (lightweight, good for embedded).

IMAGE_INSTALL_append = " python3 python3-modules bash"
# Add Python 3.7 and bash to the image. The leading space before "python3"
# is CRITICAL — IMAGE_INSTALL_append concatenates directly, so without
# the space you'd get "...lastpackagepython3" which breaks.

EXTRA_IMAGE_FEATURES ?= "debug-tweaks"
# Allows root login without password, useful for development.

DL_DIR ?= "/yocto/downloads"
# Where bitbake stores downloaded source tarballs. Mapped to a Docker
# volume so downloads persist across container runs.

SSTATE_DIR ?= "/yocto/sstate-cache"
# Where bitbake stores shared state (compiled artifacts). This is the
# directory that GCS sync populates/uploads. Mapped to a Docker volume.

BB_NUMBER_THREADS ?= "${@oe.utils.cpu_count()}"
PARALLEL_MAKE ?= "-j ${@oe.utils.cpu_count()}"
# Use all available CPU cores for both bitbake task scheduling and make.
# ${@...} is Yocto's inline Python syntax.
```

---

## bill/conf/bblayers.conf

Tells Yocto which layers (collections of recipes) to include.

```conf
POKY_BBLAYERS_CONF_VERSION = "2"
# Config version for the Poky layer manager. Must be "2" for Zeus.

BBPATH = "${TOPDIR}"
BBFILES ?= ""

BBLAYERS ?= " \
  /build/poky/meta \
  /build/poky/meta-poky \
  /build/poky/meta-yocto-bsp \
  "
# Three layers from the Poky checkout:
#   meta           — OpenEmbedded core recipes (gcc, glibc, busybox, etc.)
#   meta-poky      — Poky distribution config
#   meta-yocto-bsp — Board support packages for QEMU and reference hardware
# Paths are absolute inside the container (poky is cloned to /build/poky).
```

---

## bill/build.sh

Host-side wrapper that kicks off the Docker Compose build.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# cd into bill/ regardless of where the script was invoked from.
# docker compose needs to find docker-compose.yml in the current directory.

echo "==> Building Bill (Yocto Zeus core-image-minimal with Python 3.7)..."
echo "    This uses sstate cache, so rebuilds should be fast."

# Copy build-inner.sh into the context so the container can run it
docker compose run --rm builder
# `docker compose run` starts the builder service defined in docker-compose.yml.
# --rm removes the container after it exits (we only care about the volumes
# and bind-mounted output, not the container itself).
# This triggers: entrypoint.sh -> build-inner.sh inside the container.

echo "==> Build complete."
echo "    Run ./import.sh to import as vpanel-bill:latest"
```

---

## bill/import.sh

Host-side script that takes the Yocto build output and imports it as a
Docker image. This Docker image is what gets loaded into the Firecracker VM.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Find the rootfs tarball
TARBALL=""
for f in build-output/core-image-minimal-qemux86-64.tar.bz2 \
         build-output/core-image-minimal-qemux86-64.rootfs.tar.bz2 \
         build-output/core-image-minimal-qemux86-64.tar.gz; do
    if [ -f "$f" ]; then
        TARBALL="$f"
        break
    fi
done
# Try multiple possible output names. Yocto naming varies.

if [ -z "$TARBALL" ]; then
    echo "ERROR: No rootfs tarball found in build-output/"
    echo "       Run ./build.sh first."
    exit 1
fi

echo "==> Importing $TARBALL as vpanel-bill:latest..."

# Remove old image if it exists
docker rmi vpanel-bill:latest 2>/dev/null || true

# Import
docker import "$TARBALL" vpanel-bill:latest
# `docker import` creates a Docker image from a rootfs tarball.
# This is NOT a normal Dockerfile build — it takes a flat filesystem
# archive and wraps it as a single-layer Docker image. The result is
# a minimal image containing exactly what Yocto built.

echo "==> Verifying python3..."
docker run --rm vpanel-bill:latest /usr/bin/python3 --version
# Smoke test: make sure Python 3 is actually in the image.
# If this fails, IMAGE_INSTALL_append in local.conf is probably wrong.

echo "==> Done. vpanel-bill:latest is ready."
```

---

## test-gcs-sstate.sh

End-to-end test that verifies a completely cold build can pull sstate from
GCS and succeed. Simulates what a new developer cloning the repo would experience.

```bash
#!/usr/bin/env bash
# Test: verify a cold build can pull sstate from GCS and succeed.
set -euo pipefail

BUCKET="${SSTATE_GCS_BUCKET:-vpanel-sstate}"
VOLUME="vpanel-base-x86_yocto-sstate"
# Defaults to the vpanel-sstate bucket. Override with env var if needed.

echo "=== GCS sstate pull test ==="
echo "    Bucket: gs://${BUCKET}/sstate-cache/"
echo "    Volume: ${VOLUME}"

# Step 1: Nuke the local sstate volume to simulate a fresh clone
echo "==> Step 1: Removing local sstate volume to simulate cold start..."
docker volume rm "${VOLUME}" 2>/dev/null || true
docker volume create "${VOLUME}"
echo "    Created empty volume ${VOLUME}"
# This destroys the local cache entirely, forcing the build to rely
# on GCS. This is the closest simulation of `git clone && make bill`
# on a fresh machine.

# Verify it's empty
FILE_COUNT=$(docker run --rm -v "${VOLUME}:/sstate" alpine sh -c 'find /sstate -type f | wc -l')
echo "    Files in volume before pull: ${FILE_COUNT}"
if [ "${FILE_COUNT}" -ne 0 ]; then
    echo "FAIL: Volume should be empty but has ${FILE_COUNT} files"
    exit 1
fi

# Step 2: Run the build with GCS pull enabled
echo "==> Step 2: Running make bill with SSTATE_GCS_BUCKET=${BUCKET}..."
SSTATE_GCS_BUCKET="${BUCKET}" make bill
# This triggers the full pipeline: builder image check, docker compose,
# GCS pull, bitbake, GCS push, import. If the sstate pull works, bitbake
# will reuse cached artifacts and finish in minutes instead of hours.

# Step 3: Verify sstate was pulled (volume is no longer empty)
echo "==> Step 3: Verifying sstate cache was populated from GCS..."
FILE_COUNT=$(docker run --rm -v "${VOLUME}:/sstate" alpine sh -c 'find /sstate -type f | wc -l')
echo "    Files in sstate volume after build: ${FILE_COUNT}"
if [ "${FILE_COUNT}" -lt 100 ]; then
    echo "FAIL: Expected sstate volume to have many files, got ${FILE_COUNT}"
    exit 1
fi
echo "    OK: sstate volume has ${FILE_COUNT} files"
# After a successful pull, the volume should have ~5000+ files.
# We check for at least 100 as a conservative threshold.

# Step 4: Verify the build output exists
echo "==> Step 4: Verifying build output..."
if ls bill/build-output/core-image-minimal-qemux86-64.tar.bz2 >/dev/null 2>&1; then
    echo "    OK: core-image-minimal-qemux86-64.tar.bz2 exists"
elif ls bill/build-output/core-image-minimal-qemux86-64.rootfs.tar.bz2 >/dev/null 2>&1; then
    echo "    OK: core-image-minimal-qemux86-64.rootfs.tar.bz2 exists"
else
    echo "FAIL: No build output tarball found"
    exit 1
fi

# Step 5: Verify Docker image was imported
echo "==> Step 5: Verifying vpanel-bill:latest Docker image..."
if docker image inspect vpanel-bill:latest >/dev/null 2>&1; then
    echo "    OK: vpanel-bill:latest exists"
else
    echo "FAIL: vpanel-bill:latest not found"
    exit 1
fi

echo ""
echo "=== ALL TESTS PASSED ==="
echo "    GCS sstate pull works for cold builds."
```

---

## GCS sstate cache — how the pieces fit together

```
First build (seed the cache):
  1. Developer runs `gcloud auth login` on host
  2. SSTATE_GCS_BUCKET=vpanel-sstate make bill
  3. build-inner.sh tries to pull from GCS — bucket is empty, continues
  4. bitbake runs cold build (hours) — populates local sstate volume
  5. build-inner.sh pushes local sstate to GCS (~3.3 GiB, ~5200 files)

Subsequent builds (same machine):
  1. SSTATE_GCS_BUCKET=vpanel-sstate make bill
  2. GCS pull: rsync finds local already matches remote — no-op
  3. bitbake: sstate is local, instant reuse
  4. GCS push: rsync finds remote already matches local — no-op

New clone (different machine):
  1. Developer runs `gcloud auth login` on host
  2. SSTATE_GCS_BUCKET=vpanel-sstate make bill
  3. GCS pull: rsync downloads entire cache into empty volume (~3.3 GiB)
  4. bitbake: finds sstate, reuses everything — minutes instead of hours
  5. GCS push: rsync pushes any new artifacts (small delta)

Without GCS (opt-out):
  1. make bill  (no env var)
  2. GCS sync blocks are skipped entirely
  3. Build uses only local Docker volume (cold if empty)
```

**Bucket:** `gs://vpanel-sstate/sstate-cache/` in GCP project `vpanel-sstate`

**Auth:** Host user's gcloud credentials are mounted read-only into the container
at `/home/builder/.config/gcloud`. No service account key files needed for
development. For CI, use a service account with `GOOGLE_APPLICATION_CREDENTIALS`.

---
---

# Part 1: Assets — Firecracker and Kernel

These are downloaded (not built) and placed in `assets/`. Everything here is a
prerequisite for booting the VM.

## get-firecracker.sh

Downloads both the Firecracker VMM binary and a prebuilt Linux kernel. Called
by `make assets` and `make kernel`.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$SCRIPT_DIR/assets"
FC_VERSION="v1.15.0"
ARCH="x86_64"
# Pin the Firecracker version. Changing this may require kernel and rootfs
# updates too — Firecracker's virtio interface can change between versions.

mkdir -p "$ASSETS_DIR"

# Download Firecracker binary
FC_URL="https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${ARCH}.tgz"

if [ ! -f "$ASSETS_DIR/firecracker" ]; then
    echo "==> Downloading Firecracker ${FC_VERSION}..."
    curl -fSL "$FC_URL" -o "/tmp/firecracker.tgz"
    tar -xzf /tmp/firecracker.tgz -C /tmp/
    cp "/tmp/release-${FC_VERSION}-${ARCH}/firecracker-${FC_VERSION}-${ARCH}" "$ASSETS_DIR/firecracker"
    chmod +x "$ASSETS_DIR/firecracker"
    rm -rf /tmp/firecracker.tgz "/tmp/release-${FC_VERSION}-${ARCH}"
    echo "    Firecracker installed: $ASSETS_DIR/firecracker"
else
    echo "==> Firecracker already present."
fi
# The tarball contains the release directory with versioned binary names.
# We extract the specific binary and rename it to just `firecracker`.
# The if/fi guard makes this idempotent — safe to run repeatedly.

# Download prebuilt vmlinux kernel (stopgap until custom kernel build)
# Firecracker publishes CI kernels in their S3 bucket
KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.15/${ARCH}/vmlinux-5.10.245"

if [ ! -f "$ASSETS_DIR/vmlinux" ]; then
    echo "==> Downloading prebuilt vmlinux kernel..."
    curl -fSL "$KERNEL_URL" -o "$ASSETS_DIR/vmlinux"
    echo "    Kernel installed: $ASSETS_DIR/vmlinux"
else
    echo "==> Kernel already present."
fi
# This is a prebuilt kernel from Firecracker's CI. It's a bare vmlinux
# (not bzImage) — Firecracker boots vmlinux directly, no bootloader.
# Kernel 5.10 is matched to Firecracker v1.15. The kernel/ directory is
# reserved for a future custom kernel build with additional drivers.
```

---
---

# Part 2: Guest Rootfs — Alpine Linux for Firecracker

The Firecracker VM boots from an ext4 disk image containing Alpine Linux.
This is the "Red Green" guest — the intermediate layer between the host
and the Bill container.

## build-rootfs/Dockerfile.rootfs

Defines the Alpine Linux guest image. This is built as a Docker image first,
then exported into an ext4 filesystem. It's NOT run as a Docker container —
Docker is just used as a convenient rootfs builder.

```dockerfile
FROM alpine:3.19
# Alpine is tiny (~5MB base) which keeps the VM image small and boot fast.
# 3.19 is recent enough to have crun and modern OpenRC.

# Install packages needed in the Firecracker guest
RUN apk add --no-cache \
    openssh-server \
    bash \
    jq \
    crun \
    curl \
    tar \
    openrc \
    e2fsprogs \
    util-linux
# openssh-server: for SSH access from host into VM (how we interact with it)
# bash: for scripting inside the guest
# jq: for parsing JSON (used in load-bill for Docker image manifest parsing)
# crun: OCI container runtime (runs Bill inside the VM)
# curl/tar: for moving files around
# openrc: init system (Firecracker boots with init=/sbin/init)
# e2fsprogs: filesystem utilities
# util-linux: mount, etc.

# Configure OpenRC for VM use (not Docker container)
RUN mkdir -p /run/openrc && touch /run/openrc/softlevel
# OpenRC detects when it's inside a Docker container and disables itself.
# Creating the softlevel file tricks it into running normally.

# Override OpenRC's Docker auto-detection so networking and other services start
RUN echo 'rc_sys=""' >> /etc/rc.conf
# Without this, OpenRC detects cgroups/namespaces and thinks it's in a
# container, skipping service startup. rc_sys="" forces it to behave as
# if it's running on bare metal.

# Enable serial console on ttyS0 for Firecracker
RUN sed -i 's|^#ttyS0.*|ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100|' /etc/inittab || true
# Firecracker exposes a serial console on ttyS0. This enables a login
# prompt on it. The kernel boot_args include "console=ttyS0" to match.

# Configure networking: static IP 172.16.0.2/24
RUN mkdir -p /etc/network
RUN printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet static\n    address 172.16.0.2\n    netmask 255.255.255.0\n    gateway 172.16.0.1\n' > /etc/network/interfaces
# Static networking — no DHCP. The host tap0 is at 172.16.0.1, the guest
# eth0 is at 172.16.0.2. Gateway points to the host for outbound NAT.
# This matches setup-host.sh which configures the host side.

# DNS - resolv.conf is managed by Docker during build, written post-export in build.sh
# Docker overwrites /etc/resolv.conf during image build, so we can't set
# it here. build-rootfs/build.sh writes it after exporting the filesystem.

# Configure sshd
RUN ssh-keygen -A
# Generate host keys (ed25519, rsa, ecdsa). These are baked into the image
# so the guest always has the same host keys (no "host key changed" warnings).

RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh
RUN sed -i 's/^#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
RUN sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
RUN sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
# SSH config: root can log in with a key, but not a password.
# The authorized_keys file is injected by build.sh after export.

# Add cgroup2 mount at boot (needed for crun)
RUN echo 'cgroup2 /sys/fs/cgroup cgroup2 defaults 0 0' >> /etc/fstab
# crun needs cgroups to manage container resource limits. cgroup2 is the
# modern unified hierarchy. This fstab entry mounts it automatically at boot.

# Enable services at boot
RUN rc-update add sshd default
RUN rc-update add networking boot
RUN rc-update add devfs sysinit
RUN rc-update add dmesg sysinit
RUN rc-update add hwclock boot || true
RUN rc-update add modules boot || true
RUN rc-update add sysctl boot || true
RUN rc-update add hostname boot || true
RUN rc-update add bootmisc boot || true
# OpenRC runlevels: sysinit -> boot -> default
# sysinit: devfs (populate /dev), dmesg
# boot: networking (brings up eth0), hwclock, modules, hostname
# default: sshd (accept SSH connections)
# The || true on some prevents failure if the service doesn't exist.

# Set hostname
RUN echo "redgreen" > /etc/hostname
# The VM is called "Red Green" in the PLAID architecture.

# Create directories for OCI container images
RUN mkdir -p /var/lib/oci /var/run/oci
# These are where Bill's OCI bundle gets unpacked and where crun
# stores container runtime state.

# Set root password (disabled - pubkey only)
RUN echo 'root:*' | chpasswd -e
# '*' as a password hash means "locked" — no password login possible.
# SSH pubkey is the only way in.
```

---

## build-rootfs/build.sh

Host-side script that converts the Docker image into a Firecracker-bootable
ext4 disk image. This is the trickiest build step because it involves
mounting a loopback device, which requires sudo.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ROOTFS_IMG="$PROJECT_DIR/assets/alpine-rootfs.ext4"
KEYS_DIR="$PROJECT_DIR/keys"
ROOTFS_SIZE_MB=512
MOUNT_DIR="/tmp/alpine-rootfs-mount"
# 512MB ext4 image. Alpine itself is tiny, but we need room for Bill's
# OCI image (the Yocto rootfs tarball is ~20MB, unpacked is larger)
# plus runtime scratch space.

echo "==> Building Alpine rootfs for Firecracker guest (Red Green)..."

# Step 1: Generate SSH keypair if not present
mkdir -p "$KEYS_DIR"
if [ ! -f "$KEYS_DIR/rg_key" ]; then
    echo "    Generating SSH keypair..."
    ssh-keygen -t ed25519 -f "$KEYS_DIR/rg_key" -N "" -C "plaid-redgreen"
    chmod 600 "$KEYS_DIR/rg_key"
    chmod 644 "$KEYS_DIR/rg_key.pub"
else
    echo "    SSH keypair already exists."
fi
# ed25519 key with no passphrase. The private key stays on the host
# (keys/rg_key), the public key gets baked into the guest rootfs.
# The keypair is generated once and reused across rootfs rebuilds so
# you don't have to update known_hosts every time.

# Step 2: Build the Docker image
echo "    Building Docker image..."
docker build -t alpine-rootfs-builder -f "$SCRIPT_DIR/Dockerfile.rootfs" "$SCRIPT_DIR"
# Builds Dockerfile.rootfs into a Docker image. We're only using Docker
# as a filesystem builder — this image is never run as a container.

# Step 3: Create ext4 image
echo "    Creating ${ROOTFS_SIZE_MB}MB ext4 image..."
mkdir -p "$PROJECT_DIR/assets"
dd if=/dev/zero of="$ROOTFS_IMG" bs=1M count=$ROOTFS_SIZE_MB status=progress
mkfs.ext4 -F "$ROOTFS_IMG"
# Create a blank file, format it as ext4. This becomes the VM's root disk.
# dd creates the raw file, mkfs.ext4 writes the filesystem structures.
# -F forces mkfs to format a regular file (not a block device).

# Step 4: Mount and populate
echo "    Mounting and populating rootfs (needs sudo)..."
sudo mkdir -p "$MOUNT_DIR"
sudo mount -o loop "$ROOTFS_IMG" "$MOUNT_DIR"
# Loop-mount the ext4 file so we can write files into it as if it were
# a regular directory. Requires sudo because mount is privileged.

# Export the Docker image filesystem
CONTAINER_ID=$(docker create alpine-rootfs-builder)
docker export "$CONTAINER_ID" | sudo tar -xf - -C "$MOUNT_DIR"
docker rm "$CONTAINER_ID" > /dev/null
# docker create + docker export extracts the full filesystem of the image
# as a tar stream. We pipe it directly into tar to unpack into the mounted
# ext4. This is how the Alpine rootfs (with all installed packages and
# config) gets transferred from the Docker image to the disk image.

# Write resolv.conf (can't do this in Dockerfile - Docker mounts it)
sudo bash -c "echo 'nameserver 8.8.8.8' > '$MOUNT_DIR/etc/resolv.conf'"
# Docker bind-mounts its own resolv.conf during builds, overwriting
# anything we set in the Dockerfile. We write the real one here.

# Inject SSH public key
sudo mkdir -p "$MOUNT_DIR/root/.ssh"
sudo chmod 700 "$MOUNT_DIR/root/.ssh"
sudo cp "$KEYS_DIR/rg_key.pub" "$MOUNT_DIR/root/.ssh/authorized_keys"
sudo chmod 600 "$MOUNT_DIR/root/.ssh/authorized_keys"
# Install the public key so the host can SSH in as root.
# The private key is at keys/rg_key on the host.

# Create device nodes needed for boot
sudo mknod -m 622 "$MOUNT_DIR/dev/console" c 5 1 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_DIR/dev/null"    c 1 3 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_DIR/dev/zero"    c 1 5 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_DIR/dev/tty"     c 5 0 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_DIR/dev/ttyS0"   c 4 64 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_DIR/dev/random"  c 1 8 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_DIR/dev/urandom" c 1 9 2>/dev/null || true
# Linux needs these device nodes to boot. In a normal system, devtmpfs
# creates them automatically, but Firecracker's minimal environment may
# not mount devtmpfs early enough. Creating them statically in the rootfs
# ensures they exist at init time.
#
# console (5,1): kernel console output
# null (1,3): /dev/null
# zero (1,5): /dev/zero
# tty (5,0): current terminal
# ttyS0 (4,64): serial port (Firecracker console)
# random/urandom (1,8/1,9): entropy sources

# Create init symlink if needed (OpenRC)
if [ ! -f "$MOUNT_DIR/sbin/init" ]; then
    sudo ln -sf /sbin/openrc-init "$MOUNT_DIR/sbin/init" 2>/dev/null || true
fi
# The kernel boot_args specify init=/sbin/init. Alpine's OpenRC provides
# openrc-init. If the symlink doesn't exist, create it.

# Ensure /etc/init.d/networking uses OpenRC properly
# Write a simple rcS init script as fallback
sudo tee "$MOUNT_DIR/etc/init.d/rcS.local" > /dev/null << 'INITEOF'
#!/bin/sh
# Bring up networking if OpenRC hasn't
if ! ip addr show eth0 | grep -q "172.16.0.2"; then
    ip addr add 172.16.0.2/24 dev eth0
    ip link set eth0 up
    ip route add default via 172.16.0.1
fi
# Start sshd if not running
if ! pgrep sshd > /dev/null; then
    /usr/sbin/sshd
fi
INITEOF
sudo chmod +x "$MOUNT_DIR/etc/init.d/rcS.local"
# Belt-and-suspenders: if OpenRC's networking service fails for any reason,
# this fallback script manually configures eth0 and starts sshd. Without
# networking and sshd, the VM is unreachable.

# Unmount
sudo umount "$MOUNT_DIR"
sudo rmdir "$MOUNT_DIR"
# Clean up the loop mount. The ext4 file is now a complete, bootable
# rootfs ready for Firecracker.

echo "==> Alpine rootfs created: $ROOTFS_IMG"
echo "    SSH key: $KEYS_DIR/rg_key"
```

---
---

# Part 3: Runtime — Host Networking, VM Launch, and Bill

These scripts handle the lifecycle of the running system: setting up the
network, starting/stopping the VM, and loading Bill into it.

## The runtime flow

```
make up
  -> setup-host.sh      # create tap0, iptables NAT (sudo)
  -> launch.sh           # start Firecracker, configure via REST API
  -> wait-for-ssh.sh     # poll until guest SSH responds

make load-bill           # docker save | ssh | unpack OCI bundle, crun run
make shell               # ssh into guest, crun exec into Bill container

make down
  -> stop.sh             # kill Firecracker process
  -> teardown-host.sh    # remove tap0, iptables rules (sudo)
```

---

## setup-host.sh

Creates the host-side network plumbing so the Firecracker VM can communicate
with the host and the internet.

```bash
#!/usr/bin/env bash
set -euo pipefail

TAP_DEV="tap0"
TAP_IP="172.16.0.1"
TAP_MASK="24"
HOST_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
# Auto-detect the host's default network interface (e.g., eth0, ens5).
# This is needed for the NAT rule — traffic from the VM gets masqueraded
# out through this interface.

echo "==> Setting up host networking..."

# Create tap device
if ! ip link show "$TAP_DEV" &>/dev/null; then
    sudo ip tuntap add dev "$TAP_DEV" mode tap
    echo "    Created $TAP_DEV"
else
    echo "    $TAP_DEV already exists"
fi
# A TAP device is a virtual network interface that Firecracker attaches
# to. Packets the VM sends out its eth0 appear on tap0, and vice versa.
# This is how Firecracker does networking — it's not Docker networking,
# there's no bridge, no veth pair. Just a direct tap device.

sudo ip addr replace "${TAP_IP}/${TAP_MASK}" dev "$TAP_DEV"
sudo ip link set "$TAP_DEV" up
# Assign 172.16.0.1/24 to tap0. The guest is 172.16.0.2/24.
# `ip addr replace` is idempotent — safe to run repeatedly.

# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
# The host needs to forward packets between tap0 and the real interface.
# Without this, the VM can reach the host but not the internet.

# NAT for guest outbound traffic
if ! sudo iptables -t nat -C POSTROUTING -o "$HOST_IFACE" -s 172.16.0.0/24 -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -s 172.16.0.0/24 -j MASQUERADE
    echo "    Added MASQUERADE rule for 172.16.0.0/24 via $HOST_IFACE"
else
    echo "    MASQUERADE rule already exists"
fi
# MASQUERADE rewrites the source IP of outbound packets from 172.16.0.x
# to the host's real IP, so return traffic finds its way back. This is
# the same NAT technique Docker uses for container networking.
# -C checks if the rule exists first (idempotent).

# Allow forwarding
if ! sudo iptables -C FORWARD -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT 2>/dev/null; then
    sudo iptables -A FORWARD -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT
    sudo iptables -A FORWARD -i "$HOST_IFACE" -o "$TAP_DEV" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi
# Two rules:
# 1. Allow NEW packets from tap0 -> host interface (VM initiating connections)
# 2. Allow ESTABLISHED/RELATED packets back from host interface -> tap0
#    (return traffic for connections the VM initiated)
# Without these, the default FORWARD policy would drop inter-interface traffic.

echo "==> Host networking ready. Guest will be at 172.16.0.2"
```

---

## launch.sh

Starts the Firecracker VMM process and configures it entirely via its REST API
over a Unix socket. This is the core of how Firecracker works — there's no
config file, no CLI flags for the VM. Everything is a PUT request.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCKET_PATH="/tmp/firecracker.sock"
FC_BIN="$SCRIPT_DIR/assets/firecracker"
KERNEL_PATH="$SCRIPT_DIR/assets/vmlinux"
ROOTFS_PATH="$SCRIPT_DIR/assets/alpine-rootfs.ext4"
FC_PID_FILE="/tmp/firecracker.pid"
# All paths are absolute. The socket and PID file go in /tmp for simplicity.

# Validate assets
for f in "$FC_BIN" "$KERNEL_PATH" "$ROOTFS_PATH"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Missing $f"
        exit 1
    fi
done
# Fail fast if any required file is missing. Common cause: forgot to
# run `make assets` or `make rootfs`.

# Clean up stale socket
rm -f "$SOCKET_PATH"
# Firecracker won't start if the socket file exists from a previous run.

echo "==> Starting Firecracker..."

# Start Firecracker in background
"$FC_BIN" --api-sock "$SOCKET_PATH" &
FC_PID=$!
echo $FC_PID > "$FC_PID_FILE"
# Firecracker starts as a process listening on a Unix socket.
# At this point, the VMM is running but no VM exists yet.
# We save the PID so stop.sh can kill it later.

# Wait for API socket to appear
for i in $(seq 1 20); do
    if [ -e "$SOCKET_PATH" ]; then
        break
    fi
    sleep 0.1
done

if [ ! -e "$SOCKET_PATH" ]; then
    echo "ERROR: Firecracker API socket did not appear"
    kill $FC_PID 2>/dev/null || true
    exit 1
fi
# Poll up to 2 seconds for the socket to appear. If it doesn't,
# Firecracker failed to start (check stderr for why).

echo "    Firecracker PID: $FC_PID"

# Configure boot source
echo "    Setting boot source..."
curl -s --unix-socket "$SOCKET_PATH" -X PUT "http://localhost/boot-source" \
    -H "Content-Type: application/json" \
    -d "{
        \"kernel_image_path\": \"$KERNEL_PATH\",
        \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw init=/sbin/init\"
    }"
# Tell Firecracker which kernel to boot and what kernel command line to use.
# boot_args breakdown:
#   console=ttyS0    — kernel output goes to serial (Firecracker's console)
#   reboot=k         — use keyboard controller for reboot (Firecracker convention)
#   panic=1          — reboot 1 second after kernel panic
#   pci=off          — Firecracker has no PCI bus, skip PCI probing
#   root=/dev/vda    — root filesystem is the first virtio block device
#   rw               — mount root read-write
#   init=/sbin/init  — run OpenRC init (symlinked to openrc-init in rootfs)

# Configure rootfs drive
echo "    Setting rootfs drive..."
curl -s --unix-socket "$SOCKET_PATH" -X PUT "http://localhost/drives/rootfs" \
    -H "Content-Type: application/json" \
    -d "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"$ROOTFS_PATH\",
        \"is_root_device\": true,
        \"is_read_only\": false
    }"
# Attach the Alpine ext4 image as the root block device. Firecracker
# exposes it to the guest as /dev/vda (virtio block). is_read_only=false
# because the guest needs to write (logs, container state, etc.).

# Configure network interface
echo "    Setting network interface..."
curl -s --unix-socket "$SOCKET_PATH" -X PUT "http://localhost/network-interfaces/eth0" \
    -H "Content-Type: application/json" \
    -d '{
        "iface_id": "eth0",
        "guest_mac": "AA:FC:00:00:00:01",
        "host_dev_name": "tap0"
    }'
# Connect the VM's eth0 to the host's tap0 device. The MAC address is
# arbitrary but deterministic (starts with AA:FC for "Firecracker").
# host_dev_name must match the TAP device created by setup-host.sh.

# Configure machine
echo "    Setting machine config..."
curl -s --unix-socket "$SOCKET_PATH" -X PUT "http://localhost/machine-config" \
    -H "Content-Type: application/json" \
    -d '{
        "vcpu_count": 2,
        "mem_size_mib": 512
    }'
# 2 vCPUs, 512MB RAM. This is enough for Alpine + crun + Bill.
# Firecracker VMs are lightweight — 512MB is generous. The vCPUs are
# backed by host KVM, so they're near-native performance.

# Start the VM
echo "    Starting VM..."
curl -s --unix-socket "$SOCKET_PATH" -X PUT "http://localhost/actions" \
    -H "Content-Type: application/json" \
    -d '{"action_type": "InstanceStart"}'
# This is the "press the power button" moment. After this PUT returns,
# the kernel is booting. The VM goes from configured to running.
# Boot takes ~1-2 seconds to reach a login prompt.

echo "==> Firecracker VM started (PID: $FC_PID)"
echo "    Guest IP: 172.16.0.2"
```

---

## wait-for-ssh.sh

Polls the guest until SSH responds. Used by `make up` to block until the
VM is actually usable.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUEST_IP="172.16.0.2"
SSH_KEY="$SCRIPT_DIR/keys/rg_key"
MAX_WAIT=60
INTERVAL=2
# Wait up to 60 seconds, checking every 2 seconds. The VM typically
# boots in 2-5 seconds, but first boot with OpenRC service init can
# take longer.

echo "==> Waiting for SSH on $GUEST_IP (up to ${MAX_WAIT}s)..."

elapsed=0
while [ $elapsed -lt $MAX_WAIT ]; do
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o ConnectTimeout=2 -o BatchMode=yes \
       root@"$GUEST_IP" "echo ok" 2>/dev/null; then
        echo "==> SSH is ready."
        exit 0
    fi
    sleep $INTERVAL
    elapsed=$((elapsed + INTERVAL))
    echo "    Waiting... (${elapsed}s)"
done
# SSH options:
#   -o StrictHostKeyChecking=no  — don't prompt about unknown host keys
#   -o UserKnownHostsFile=/dev/null — don't save host keys (they change
#                                      each time the rootfs is rebuilt)
#   -o ConnectTimeout=2 — don't wait long if sshd isn't up yet
#   -o BatchMode=yes — never prompt for anything (fail instead)
# The "echo ok" command is a minimal probe — if it succeeds, sshd is
# running and accepting our key.

echo "ERROR: SSH did not become available within ${MAX_WAIT}s"
exit 1
```

---

## stop.sh

Gracefully stops the Firecracker VM by killing the process.

```bash
#!/usr/bin/env bash
set -euo pipefail

FC_PID_FILE="/tmp/firecracker.pid"
SOCKET_PATH="/tmp/firecracker.sock"

echo "==> Stopping Firecracker..."

if [ -f "$FC_PID_FILE" ]; then
    FC_PID=$(cat "$FC_PID_FILE")
    if kill -0 "$FC_PID" 2>/dev/null; then
        kill "$FC_PID"
        # Wait for it to exit
        for i in $(seq 1 30); do
            if ! kill -0 "$FC_PID" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        # Force kill if still running
        if kill -0 "$FC_PID" 2>/dev/null; then
            kill -9 "$FC_PID" 2>/dev/null || true
        fi
        echo "    Firecracker (PID $FC_PID) stopped."
    else
        echo "    Firecracker (PID $FC_PID) not running."
    fi
    rm -f "$FC_PID_FILE"
else
    # Try to find and kill any firecracker process
    pkill -f "firecracker --api-sock" 2>/dev/null || true
    echo "    No PID file found, sent kill to any firecracker process."
fi
# First tries SIGTERM (graceful shutdown), waits up to 3 seconds,
# then SIGKILL if it's still alive. Fallback pkill handles the case
# where the PID file is missing (e.g., manual cleanup).

rm -f "$SOCKET_PATH"
echo "==> Firecracker stopped."
# Clean up the API socket so the next launch.sh doesn't find a stale one.
```

---

## teardown-host.sh

Reverse of setup-host.sh — removes the tap device and iptables rules.

```bash
#!/usr/bin/env bash
set -euo pipefail

TAP_DEV="tap0"
HOST_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)

echo "==> Tearing down host networking..."

# Remove iptables rules
sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -s 172.16.0.0/24 -j MASQUERADE 2>/dev/null || true
sudo iptables -D FORWARD -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -i "$HOST_IFACE" -o "$TAP_DEV" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
# -D deletes the exact rule. || true because the rules may not exist
# (e.g., if setup-host.sh wasn't run or was already torn down).
# Order doesn't matter for deletion.

# Remove tap device
if ip link show "$TAP_DEV" &>/dev/null; then
    sudo ip link set "$TAP_DEV" down
    sudo ip tuntap del dev "$TAP_DEV" mode tap
    echo "    Removed $TAP_DEV"
else
    echo "    $TAP_DEV not found"
fi

echo "==> Host networking cleaned up."
```

---

## Makefile — runtime targets

The runtime portion of the Makefile ties the scripts together.

```makefile
SSH_KEY := keys/rg_key
GUEST_IP := 172.16.0.2
SSH_OPTS := -i $(SSH_KEY) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
# Shared SSH options used by all targets that talk to the guest.
# LogLevel=ERROR suppresses the "Warning: Permanently added..." messages.

# Boot the VM: requires all assets to be built first
up: assets/firecracker assets/vmlinux assets/alpine-rootfs.ext4 $(SSH_KEY)
	./setup-host.sh
	./launch.sh
	./wait-for-ssh.sh
# Three steps in sequence: network, VM start, wait for SSH.
# The prerequisites ensure you can't boot without building first.

# Shut down: stop VM, tear down networking
down:
	./stop.sh
	./teardown-host.sh

# Check if VM is running and reachable
status:
	@if [ -f /tmp/firecracker.pid ] && kill -0 $$(cat /tmp/firecracker.pid) 2>/dev/null; then \
		echo "Firecracker: running (PID $$(cat /tmp/firecracker.pid))"; \
	else \
		echo "Firecracker: not running"; \
	fi
	@if ssh $(SSH_OPTS) -o ConnectTimeout=2 -o BatchMode=yes root@$(GUEST_IP) "echo ok" 2>/dev/null; then \
		echo "SSH: reachable at $(GUEST_IP)"; \
	else \
		echo "SSH: not reachable"; \
	fi

# Load Bill into the running VM
load-bill:
	@echo "==> Loading Bill OCI image into guest..."
	docker save vpanel-bill:latest | ssh $(SSH_OPTS) root@$(GUEST_IP) \
		'cat > /tmp/bill.tar'
	# Stream the Docker image from host to guest via SSH pipe.
	# docker save produces a tar of the image layers and metadata.

	@echo "==> Creating OCI bundle from Docker image..."
	ssh $(SSH_OPTS) root@$(GUEST_IP) 'set -e; \
		rm -rf /var/lib/oci/bill; \
		mkdir -p /var/lib/oci/bill/rootfs; \
		cd /tmp && tar xf bill.tar; \
		LAYER=$$(jq -r ".[0].Layers[0]" /tmp/manifest.json); \
		tar xf "/tmp/$$LAYER" -C /var/lib/oci/bill/rootfs; \
		rm -rf /tmp/blobs /tmp/manifest.json /tmp/index.json /tmp/oci-layout /tmp/repositories /tmp/bill.tar'
	# Unpack the Docker image into an OCI bundle:
	#   1. Extract the docker save tar
	#   2. Read manifest.json to find the filesystem layer
	#   3. Extract that layer into the rootfs directory
	# This converts Docker's image format to OCI's expected layout.

	@echo "==> Writing OCI config..."
	ssh $(SSH_OPTS) root@$(GUEST_IP) \
		'printf "%s\n" '"'"'{"ociVersion":"1.0.0",...}'"'"' > /var/lib/oci/bill/config.json'
	# Write the OCI runtime spec (config.json). This tells crun:
	#   - Run /bin/sh -c "sleep infinity" as the init process
	#   - Mount /proc, /dev, /dev/pts, /sys, /tmp
	#   - Use PID and mount namespaces
	#   - Root filesystem at ./rootfs
	# sleep infinity keeps the container alive; we exec into it with crun exec.

	@echo "==> Starting Bill container..."
	ssh $(SSH_OPTS) root@$(GUEST_IP) \
		'crun delete -f bill 2>/dev/null || true; cd /var/lib/oci/bill && crun run -d bill </dev/null >/dev/null 2>&1'
	# Kill any existing Bill container, then start a new one detached (-d).
	# crun is a lightweight OCI runtime (alternative to runc).

	@echo "==> Bill is running."

# Open a shell inside Bill
shell:
	@echo "==> Entering Bill container..."
	ssh -t $(SSH_OPTS) root@$(GUEST_IP) 'crun exec -t bill /bin/bash'
	# SSH into the VM, then crun exec into the running Bill container.
	# -t allocates a TTY for interactive use. This gives you a bash prompt
	# inside the Yocto-built environment with Python 3.7.
```

---
---

# Full system diagram

```
Host machine (Ubuntu, /dev/kvm)
│
├── make build-all
│   ├── make builder     → Dockerfile.builder → vpanel-yocto-zeus-builder:latest
│   ├── make bill        → build.sh → docker compose → build-inner.sh (GCS ↔ bitbake)
│   │                    → import.sh → vpanel-bill:latest (Docker image)
│   ├── make assets      → get-firecracker.sh → assets/firecracker
│   ├── make kernel      → get-firecracker.sh → assets/vmlinux
│   └── make rootfs      → build-rootfs/build.sh → assets/alpine-rootfs.ext4
│                          + keys/rg_key, keys/rg_key.pub
│
├── make up
│   ├── setup-host.sh    → tap0 (172.16.0.1/24) + iptables NAT
│   ├── launch.sh        → Firecracker process + REST API config
│   └── wait-for-ssh.sh  → polls 172.16.0.2:22
│
├── make load-bill       → docker save | ssh → OCI bundle → crun run
├── make shell           → ssh → crun exec → bash inside Bill
│
└── make down
    ├── stop.sh          → kill Firecracker
    └── teardown-host.sh → remove tap0 + iptables rules

Network:
  Host tap0: 172.16.0.1/24 ──── Guest eth0: 172.16.0.2/24
  NAT via iptables MASQUERADE on host's default interface

Nesting:
  Host → Firecracker VM (Alpine "Red Green") → crun container (Bill/Yocto)
```
