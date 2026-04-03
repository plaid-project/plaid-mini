SHELL := /bin/bash
.PHONY: up down status bill load-bill shell assets rootfs kernel builder build-all help

SSH_KEY := keys/rg_key
GUEST_IP := 172.16.0.2
SSH_OPTS := -i $(SSH_KEY) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR

help:
	@echo "PLAID Reduced Stack"
	@echo ""
	@echo "From-scratch build:"
	@echo "  make build-all  - Build everything (builder, bill, assets, rootfs)"
	@echo ""
	@echo "Individual build targets:"
	@echo "  make builder    - Build the Yocto builder Docker image"
	@echo "  make bill       - Build Bill (Yocto) OCI image with Python 3.7"
	@echo "  make assets     - Download Firecracker binary"
	@echo "  make kernel     - Download (or build) vmlinux kernel"
	@echo "  make rootfs     - Build Alpine rootfs for Firecracker guest"
	@echo ""
	@echo "Runtime targets:"
	@echo "  make up         - Boot the Firecracker VM"
	@echo "  make down       - Shut down the Firecracker VM"
	@echo "  make status     - Check if VM is running and SSH reachable"
	@echo "  make load-bill  - Load Bill OCI image into the guest and start container"
	@echo "  make shell      - Open a bash shell inside Bill"
	@echo ""
	@echo "Full from-scratch: make build-all && make up && make load-bill && make shell"

# === Build targets ===

build-all: builder bill assets kernel rootfs
	@echo "==> All build targets complete."

builder:
	@echo "==> Building Yocto builder image..."
	docker build -t vpanel-yocto-zeus-builder:latest -f bill/Dockerfile.builder bill/
	@echo "==> vpanel-yocto-zeus-builder:latest ready."

assets: assets/firecracker

kernel: assets/vmlinux

rootfs: assets/alpine-rootfs.ext4

bill: builder
	cd bill && ./build.sh && ./import.sh

# === Runtime targets ===

up: assets/firecracker assets/vmlinux assets/alpine-rootfs.ext4 $(SSH_KEY)
	./setup-host.sh
	./launch.sh
	./wait-for-ssh.sh

down:
	./stop.sh
	./teardown-host.sh

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

BILL_TARBALL ?= sources/meta-bill/build-output/bill-image-bill-x86-64.tar.bz2

load-bill:
	@echo "==> Preparing OCI bundle on guest..."
	ssh $(SSH_OPTS) root@$(GUEST_IP) \
		'crun delete -f bill 2>/dev/null || true; rm -rf /var/lib/oci/bill; mkdir -p /var/lib/oci/bill/rootfs'
	@echo "==> Streaming $(BILL_TARBALL) to guest..."
	cat $(BILL_TARBALL) | ssh $(SSH_OPTS) root@$(GUEST_IP) 'bzcat | tar xf - -C /var/lib/oci/bill/rootfs'
	@echo "==> Writing OCI config..."
	ssh $(SSH_OPTS) root@$(GUEST_IP) \
		'printf "%s\n" '"'"'{"ociVersion":"1.0.0","process":{"terminal":false,"user":{"uid":0,"gid":0},"args":["/bin/sh","-c","sleep infinity"],"env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin","HOME=/root","TERM=xterm"],"cwd":"/"},"root":{"path":"rootfs","readonly":false},"mounts":[{"destination":"/proc","type":"proc","source":"proc"},{"destination":"/dev","type":"tmpfs","source":"tmpfs","options":["nosuid","strictatime","mode=755","size=65536k"]},{"destination":"/dev/pts","type":"devpts","source":"devpts","options":["nosuid","noexec","newinstance","ptmxmode=0666","mode=0620"]},{"destination":"/sys","type":"sysfs","source":"sysfs","options":["nosuid","noexec","nodev","ro"]},{"destination":"/tmp","type":"tmpfs","source":"tmpfs","options":["nosuid","nodev"]}],"linux":{"namespaces":[{"type":"pid"},{"type":"mount"}]}}'"'"' > /var/lib/oci/bill/config.json'
	@echo "==> Starting Bill container..."
	ssh $(SSH_OPTS) root@$(GUEST_IP) \
		'cd /var/lib/oci/bill && crun run -d bill </dev/null >/dev/null 2>&1'
	@echo "==> Bill is running."

shell:
	@echo "==> Entering Bill container..."
	ssh -t $(SSH_OPTS) root@$(GUEST_IP) 'crun exec -t bill /bin/bash'

# === File prerequisites ===

assets/firecracker:
	./get-firecracker.sh

# Kernel: download prebuilt for now; replace this rule when building from source
assets/vmlinux:
	./get-firecracker.sh

assets/alpine-rootfs.ext4:
	./build-rootfs/build.sh

$(SSH_KEY):
	@echo "ERROR: SSH key not found. Run 'make rootfs' first."
	@exit 1
