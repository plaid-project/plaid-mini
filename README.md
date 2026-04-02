# plaid-mini

A nested virtualization stack for IoT testing.

```
Host (Ubuntu, /dev/kvm)
└── Firecracker microVM
    └── Alpine Linux guest (Red Green)
        └── crun container runtime
            └── Bill (Yocto Zeus x86-64 OCI image)
                └── Python 3.7 + bash
```

## Prerequisites

- Linux host with `/dev/kvm`
- Docker
- `sudo` access (for tap networking and rootfs build)
- `curl`, `jq`, `ssh-keygen`

## Quick Start

Build everything from scratch (first Yocto build takes hours; subsequent builds use sstate cache):

```bash
make build-all
```

Boot the stack and get a shell:

```bash
make up
make load-bill
make shell
```

Inside that shell, `python3 --version` prints `Python 3.7.x`.

Shut it down:

```bash
make down
```

## Build Targets

| Target | Description |
|--------|-------------|
| `make build-all` | Build everything in order |
| `make builder` | Build the Yocto builder Docker image |
| `make bill` | Build Bill OCI image with Python 3.7 |
| `make assets` | Download Firecracker binary |
| `make kernel` | Download prebuilt vmlinux kernel |
| `make rootfs` | Build Alpine ext4 rootfs + SSH keys |

## Runtime Targets

| Target | Description |
|--------|-------------|
| `make up` | Boot the Firecracker VM |
| `make down` | Shut down the VM and clean up networking |
| `make status` | Check if VM is running and SSH is reachable |
| `make load-bill` | Load Bill OCI image into the guest and start container |
| `make shell` | Open a bash shell inside Bill |

## How It Works

**Firecracker** is a lightweight VMM that boots a Linux kernel directly, configured via REST API over a Unix socket. It is not Docker — there are no container images at the VM level.

**Red Green** (the guest) is an Alpine Linux ext4 rootfs with crun, OpenSSH, and static networking (172.16.0.2/24). The host creates a tap interface (172.16.0.1/24) with NAT for outbound traffic.

**Bill** is a Yocto Zeus `core-image-minimal` with Python 3.7 and bash, built inside an Ubuntu 18.04 container and imported as a Docker/OCI image. It gets loaded into the guest via `docker save` + SSH, unpacked into an OCI bundle, and run with crun.

## License

TBD
