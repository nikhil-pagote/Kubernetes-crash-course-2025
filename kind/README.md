## Local 3-node cluster with kind

`Module1/demo.sh` builds a real single-node cluster on a VM. For a multi-node cluster on your laptop use kind: every node is a container running kubeadm-bootstrapped Kubernetes 1.37.0.

### Prerequisites
- Docker, or **rootful** Podman (see below)
- kind v0.33.0 — https://kind.sigs.k8s.io/docs/user/quick-start/#installation (Arch: `sudo pacman -S kind`)
- `kubectl`, `cilium` and `hubble` CLIs (`Module1/demo.sh` Steps 1 and 5 show how; Arch: `sudo pacman -S kubectl cilium-cli`)
- WireGuard kernel module on the host: `sudo modprobe wireguard`. kind nodes are containers, so they share your machine's kernel and cannot load modules themselves; the Cilium agent's `encryption.type=wireguard` needs the module already present (`lsmod | grep wireguard`). Skip this if you drop the two `encryption.*` values.

#### Podman must be rootful
Cilium mounts the BPF filesystem and loads eBPF programs into the host kernel. A rootless container is not allowed to do that, so with rootless Podman the `cilium` agent pods stay in `Init:CrashLoopBackOff` and the `mount-bpf-fs` init container logs `mount: /sys/fs/bpf: permission denied`. Run kind as root so the node containers are rootful:
```
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster --config kind-config.yaml --kubeconfig ~/.kube/config
sudo chown $USER ~/.kube/config
```
`--kubeconfig` writes the credentials to your own kubeconfig instead of root's, so `kubectl`, `cilium` and `hubble` work without sudo. Only `kind` itself needs `sudo KIND_EXPERIMENTAL_PROVIDER=podman` from then on (`kind get clusters`, `kind delete cluster`, ...), because the cluster lives in root's Podman.

With Docker none of this applies — its daemon is already rootful.

### Create the cluster
```
kind create cluster --config kind-config.yaml        # Docker
kubectl get nodes
```
All three nodes are `NotReady`: the config disables kind's default CNI and kube-proxy, so — exactly like the VM after `kubeadm init` — there is no pod network yet.

### Install Cilium
Same values as `Module1/demo.sh`. The only difference is how we find the API server address: on kind it is the control-plane container's IP.
```
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

API_SERVER_IP=$(kubectl get node cilium-lab-control-plane -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
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

cilium status --wait
kubectl get nodes
```
Nodes turn `Ready` as soon as the Cilium agent runs on them. No taint removal is needed here: the control plane keeps its `NoSchedule` taint and workloads land on the two workers.

### What is different from the VM
- `kubectl get nodes -o wide` shows three nodes with different IPs; `scheduler/` demos (nodeSelector, affinity, topology spread, taints) now have real nodes to work with. Node names are `cilium-lab-control-plane`, `cilium-lab-worker`, `cilium-lab-worker2`.
- Node-level commands from `Module1/cni.md` and `Module1/kube-proxy.md` (`ip link`, `lsns`, `iptables`) run inside a node container: `docker exec -it cilium-lab-worker bash`.
- There is no LoadBalancer. For the Gateway demos in `servicemesh/` use a port-forward instead of a NodePort:
  `kubectl port-forward svc/cilium-gateway-nginx-gateway 8080:80` then `curl http://localhost:8080`.
- WireGuard encryption uses the host kernel's module; if `cilium status` reports encryption errors, re-run the install without the two `encryption.*` values.

### Delete the cluster
```
kind delete cluster --name cilium-lab                                    # Docker
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name cilium-lab   # rootful Podman
```
