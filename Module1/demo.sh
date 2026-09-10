#!/bin/bash
# =============================================================================
#  Single-node Kubernetes cluster with kubeadm + Cilium
# =============================================================================
#
#  What this script builds, from the bottom up:
#
#     ┌─────────────────────────────────────────────────────┐
#     │  Cilium  (CNI + kube-proxy replacement + Hubble +   │  Step 5
#     │           Gateway API + WireGuard + SPIRE mTLS)     │
#     ├─────────────────────────────────────────────────────┤
#     │  Kubernetes control plane  (kubeadm init)           │  Step 4
#     ├─────────────────────────────────────────────────────┤
#     │  containerd  (container runtime, talks CRI)         │  Step 3
#     ├─────────────────────────────────────────────────────┤
#     │  Linux prerequisites  (no swap, kernel modules,     │  Step 2
#     │                        IP forwarding)               │
#     ├─────────────────────────────────────────────────────┤
#     │  kubeadm / kubelet / kubectl packages               │  Step 1
#     └─────────────────────────────────────────────────────┘
#
#  Target: a fresh Ubuntu 22.04/24.04 VM (x86_64) with at least 2 vCPU / 4 GB.
#  Run as a normal user who can sudo:   bash demo.sh
#
#  Every version is pinned on purpose. When you bump Kubernetes, check the
#  matching Cilium / Gateway API versions in the Cilium upgrade notes.
# =============================================================================

# Abort on the first failing command. Without this, a failed step would be
# silently followed by later steps that depend on it (e.g. kubeadm init running
# with no container runtime).
set -e

# -----------------------------------------------------------------------------
# Step 1: Install the Kubernetes tooling
#
#   kubeadm  - bootstraps the cluster (generates certs, static pod manifests,
#              kubeconfigs). Used once, at setup/upgrade time.
#   kubelet  - the node agent. Runs as a systemd service on every node and
#              starts containers that the API server (or static manifests) tell
#              it to run. This is the only Kubernetes component that is NOT a pod.
#   kubectl  - the CLI you use to talk to the API server.
# -----------------------------------------------------------------------------
echo "Step 1: Install kubectl, kubeadm, and kubelet v1.37.0"

# Debian/Ubuntu keep third-party signing keys under /etc/apt/keyrings.
# 755 lets unprivileged apt helpers read the directory.
sudo mkdir -p -m 755 /etc/apt/keyrings
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# pkgs.k8s.io hosts ONE repository PER MINOR VERSION (v1.37, v1.38, ...).
# Pointing at v1.37 means `apt-get upgrade` can only ever move within 1.37.x —
# you never get a surprise minor-version jump. Minor upgrades are a deliberate
# act: change this URL, then follow the kubeadm upgrade procedure.
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Pin all three to the exact same patch release. kubelet must never be newer
# than the API server, and kubeadm must match the version it is bootstrapping.
sudo apt-get update -y
sudo apt-get install -y kubelet=1.37.0-1.1 kubeadm=1.37.0-1.1 kubectl=1.37.0-1.1 vim git curl wget

# "hold" tells apt to leave these alone during `apt-get upgrade`.
# Cluster components are upgraded with kubeadm, not with the OS.
sudo apt-mark hold kubelet kubeadm kubectl

# -----------------------------------------------------------------------------
# Step 2: Prepare the Linux host
#
# The kubelet refuses to start on a node with swap enabled (it cannot make
# memory guarantees if pages can be swapped out), and Kubernetes networking
# depends on a few kernel modules and sysctls.
# -----------------------------------------------------------------------------
echo "Step 2: Swap Off and Kernel Modules Setup"

# Comment out any swap line in /etc/fstab so swap stays off after a reboot,
# then turn it off right now.
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
sudo swapoff -a

# overlay       - the overlayfs storage driver containerd uses for image layers.
# br_netfilter  - lets iptables/nftables see traffic crossing a Linux bridge.
#                 Cilium itself does not use a bridge, but many tools and CNIs
#                 expect the module, and it is harmless to load.
sudo modprobe overlay
sudo modprobe br_netfilter

# `modprobe` only lasts until reboot. Files in /etc/modules-load.d/ are read
# by systemd at boot, so the modules come back automatically.
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

# net.ipv4.ip_forward = 1 is the one that matters: a node must forward packets
# between pod interfaces and the outside world, i.e. act as a router.
# The two bridge-nf-call sysctls make bridged traffic go through the packet
# filter; they are needed by bridge-based CNIs and are kept for compatibility.
cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

# Load every file under /etc/sysctl.d/ now instead of waiting for a reboot.
sudo sysctl --system


# -----------------------------------------------------------------------------
# Step 3: Install and configure the container runtime (containerd)
#
# Kubernetes does not run containers itself. The kubelet talks to a runtime
# over the CRI (Container Runtime Interface) gRPC API on a Unix socket; the
# runtime pulls images and starts containers via runc. We use containerd, the
# same runtime Docker is built on, installed from Docker's apt repository.
# -----------------------------------------------------------------------------
echo "Step 3: Install and Configure Containerd"

# Some cloud images ship containerd already; do not reinstall in that case.
if ! command -v containerd &> /dev/null
then
    echo "Containerd not found, installing..."

    # Docker's repo is the most reliable source of an up-to-date containerd.io
    # package on Ubuntu. Same keyring pattern as Step 1.
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker-archive-keyring.gpg

    # $(lsb_release -cs) expands to the Ubuntu codename (jammy, noble, ...).
    echo \
    "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y

    # 👇 THIS is the important line
    # Non-interactive install that keeps any existing config files
    # (--force-confold) so the script never blocks on a dpkg prompt.
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      -o Dpkg::Options::="--force-confold" \
      --allow-downgrades --allow-change-held-packages containerd.io
else
    echo "Containerd is already installed, skipping installation."
fi

# Docker's package ships a config.toml with the CRI plugin DISABLED (Docker
# does not need it). Regenerate a full default config so the kubelet can talk
# to containerd over CRI.
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# cgroup driver: the kubelet and the runtime MUST agree on who manages
# cgroups. Modern Ubuntu boots with cgroup v2 and systemd as the cgroup
# manager, and the kubelet defaults to the systemd driver. Flip containerd to
# match; a mismatch shows up later as pods stuck in CrashLoopBackOff/OOM.
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd


# The kubelet is enabled but will crash-loop until `kubeadm init` writes its
# config in Step 4. That is expected — systemd keeps restarting it.
sudo systemctl enable kubelet

# -----------------------------------------------------------------------------
# Step 4: Bootstrap the control plane with kubeadm
#
# kubeadm init does, in order:
#   1. preflight checks (CPU, memory, ports, runtime, ...)
#   2. generates a CA and certificates for every component
#   3. writes kubeconfigs for admin, kubelet, controller-manager, scheduler
#   4. writes STATIC POD manifests to /etc/kubernetes/manifests/ —
#      etcd, kube-apiserver, kube-controller-manager, kube-scheduler.
#      The kubelet watches that directory and starts them without any API
#      server involved (there is none yet!). This is how the control plane
#      bootstraps itself.
#   5. waits for the API server, then installs add-ons: CoreDNS and (normally)
#      kube-proxy.
# -----------------------------------------------------------------------------
echo "Step 4: Pull Kubernetes images and init cluster"

# Pre-pull so the init step does not stall on slow image downloads.
# --cri-socket tells kubeadm which runtime to use (there could be several).
sudo kubeadm config images pull --cri-socket unix:///run/containerd/containerd.sock --kubernetes-version v1.37.0

# --pod-network-cidr      the range pods get IPs from. Cilium (ipam.mode=
#                         kubernetes, Step 5) hands each node a slice of it.
# --upload-certs          stores control-plane certs in a Secret so extra
#                         control-plane nodes could join later.
# --control-plane-endpoint
#                         the stable address clients use for the API server;
#                         goes into the cert SANs. On one node the hostname
#                         is fine; in HA you would put a load balancer here.
# --skip-phases=addon/kube-proxy
#                         do NOT install kube-proxy. Cilium implements
#                         Services in eBPF instead (see kube-proxy.md).
# --ignore-preflight-errors=all
#                         lets the script run on small lab VMs (e.g. <2 CPU).
#                         Do not do this in production.
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --upload-certs \
  --kubernetes-version=v1.37.0 \
  --control-plane-endpoint="$(hostname)" \
  --skip-phases=addon/kube-proxy \
  --ignore-preflight-errors=all \
  --cri-socket unix:///run/containerd/containerd.sock

# kubeadm wrote the cluster-admin kubeconfig as root. Copy it to the normal
# user so plain `kubectl` works without sudo. This file contains an admin
# client certificate — treat it like a password.
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=$HOME/.kube/config

# -----------------------------------------------------------------------------
# Step 5: Install Cilium
#
# At this point the node is NotReady and CoreDNS is Pending: the kubelet has no
# CNI plugin, so it cannot give pods a network. Cilium provides that, and
# because we skipped kube-proxy it also has to implement Services. Everything
# below is one Helm chart driven by the cilium CLI.
# -----------------------------------------------------------------------------
echo "Step 5: Install Cilium (CNI + kube-proxy replacement + service mesh)"

# Gateway API is not part of core Kubernetes; it ships as CRDs. Cilium 1.20's
# Gateway controller expects exactly this version. Install the CRDs BEFORE
# Cilium so the operator sees them at startup.
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

# cilium CLI: installs/upgrades Cilium (wrapping Helm) and gives you
# `cilium status` and `cilium connectivity test`.
# The {,.sha256sum} brace expansion downloads the tarball AND its checksum;
# sha256sum --check verifies the download before we untar it into PATH.
CILIUM_CLI_VERSION=v0.20.0
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz{,.sha256sum}

# hubble CLI: the observability client. `hubble observe` streams every flow
# (and its policy verdict) that the eBPF datapath sees. Same download pattern.
HUBBLE_VERSION=v1.19.4
curl -L --fail --remote-name-all https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check hubble-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC hubble-linux-amd64.tar.gz /usr/local/bin
rm hubble-linux-amd64.tar.gz{,.sha256sum}

# Chicken-and-egg: the Cilium agent normally reaches the API server through the
# `kubernetes` ClusterIP Service — but Services are implemented by... Cilium
# (there is no kube-proxy). So we give it the node's real IP directly.
API_SERVER_IP=$(hostname -I | awk '{print $1}')

# One install, several features — each --set maps to a topic in this course:
#
#   kubeProxyReplacement=true   Services (ClusterIP/NodePort/LoadBalancer) are
#                               done in eBPF on the socket/XDP path. No iptables
#                               chains.                          -> kube-proxy.md
#   k8sServiceHost / Port       see the note above.
#   ipam.mode=kubernetes        use the per-node PodCIDR that kube-controller-
#                               manager carves out of --pod-network-cidr.
#   hubble.relay / hubble.ui    cluster-wide flow visibility + service map.
#                                                                -> servicemesh/
#   gatewayAPI.enabled=true     Cilium's operator reconciles Gateway/HTTPRoute
#                               and its embedded Envoy serves them. No separate
#                               ingress controller.              -> servicemesh/
#   encryption.type=wireguard   transparent node-to-node pod traffic encryption
#                               using the kernel's WireGuard.    -> cni.md
#   authentication.*            SPIRE issues SPIFFE identities to pods; policies
#                               with `authentication.mode: required` enforce
#                               mutual TLS handshakes.           -> servicemesh/
cilium install --version 1.20.1 \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=${API_SERVER_IP} \
  --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set gatewayAPI.enabled=true \
  --set encryption.enabled=true \
  --set encryption.type=wireguard \
  --set authentication.enabled=true \
  --set authentication.mutual.spire.enabled=true \
  --set authentication.mutual.spire.install.enabled=true

# kubeadm taints control-plane nodes NoSchedule so ordinary workloads stay off
# them. On a single-node lab cluster that would leave nothing to run on.
# The Cilium agent/operator tolerate the taint, but Hubble relay/UI and the
# SPIRE server are regular Deployments and need a schedulable node — so remove
# the taint BEFORE waiting for Cilium to become healthy.
# (The trailing "-" on the taint means "remove".)
kubectl taint nodes $(hostname) node-role.kubernetes.io/control-plane:NoSchedule-

# Block until every Cilium component reports OK. Takes a few minutes on first
# run while ~10 images are pulled. If this times out, `cilium status` and
# `kubectl -n kube-system get pods` show what is stuck.
cilium status --wait

echo "Kubernetes cluster setup is complete!"
