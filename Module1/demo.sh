#!/bin/bash
set -e

echo "Step 1: Install kubectl, kubeadm, and kubelet v1.37.0"

# Prepare keyrings
sudo mkdir -p -m 755 /etc/apt/keyrings
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Kubernetes repo
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Update and install Kubernetes components
sudo apt-get update -y
sudo apt-get install -y kubelet=1.37.0-1.1 kubeadm=1.37.0-1.1 kubectl=1.37.0-1.1 vim git curl wget
sudo apt-mark hold kubelet kubeadm kubectl

echo "Step 2: Swap Off and Kernel Modules Setup"
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
sudo swapoff -a
sudo modprobe overlay
sudo modprobe br_netfilter

# Persist kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

# Kernel parameters for Kubernetes networking
cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

# Apply sysctl params
sudo sysctl --system


echo "Step 3: Install and Configure Containerd"

# Check if containerd is already installed
if ! command -v containerd &> /dev/null
then
    echo "Containerd not found, installing..."

    # Add Docker repo key and repository
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker-archive-keyring.gpg

    echo \
    "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y

    # 👇 THIS is the important line
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      -o Dpkg::Options::="--force-confold" \
      --allow-downgrades --allow-change-held-packages containerd.io
else
    echo "Containerd is already installed, skipping installation."
fi

# Always configure containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# Modify config.toml to use SystemdCgroup
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd


# Enable kubelet
sudo systemctl enable kubelet

echo "Step 4: Pull Kubernetes images and init cluster"

# Pull Kubernetes images
sudo kubeadm config images pull --cri-socket unix:///run/containerd/containerd.sock --kubernetes-version v1.37.0

# Initialize cluster (kube-proxy is skipped: Cilium replaces it)
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --upload-certs \
  --kubernetes-version=v1.37.0 \
  --control-plane-endpoint="$(hostname)" \
  --skip-phases=addon/kube-proxy \
  --ignore-preflight-errors=all \
  --cri-socket unix:///run/containerd/containerd.sock

# Setup kubeconfig for user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=$HOME/.kube/config

echo "Step 5: Install Cilium (CNI + kube-proxy replacement + service mesh)"

# Gateway API CRDs (Cilium 1.20 requires v1.6.1)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

# cilium CLI
CILIUM_CLI_VERSION=v0.20.0
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz{,.sha256sum}

# hubble CLI
HUBBLE_VERSION=v1.19.4
curl -L --fail --remote-name-all https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check hubble-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC hubble-linux-amd64.tar.gz /usr/local/bin
rm hubble-linux-amd64.tar.gz{,.sha256sum}

# Install Cilium. Without kube-proxy, Cilium needs the API server address explicitly.
API_SERVER_IP=$(hostname -I | awk '{print $1}')
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

# Remove control-plane taint so pods can be scheduled (Hubble relay/UI and
# SPIRE server are regular Deployments and need a schedulable node)
kubectl taint nodes $(hostname) node-role.kubernetes.io/control-plane:NoSchedule-

cilium status --wait

echo "Kubernetes cluster setup is complete!"
