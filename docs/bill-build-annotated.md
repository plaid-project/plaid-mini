# Bill Build System — Annotated File Reference

This document walks through every file involved in building "Bill" (the Yocto
Zeus x86-64 OCI image), including the GCS sstate cache integration. Files are
presented in the order they execute during a build.

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
