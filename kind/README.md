## Local 3-node cluster with kind

`Module1/demo.sh` builds a real single-node cluster on a VM. For a multi-node cluster on your laptop use kind: every node is a container running kubeadm-bootstrapped Kubernetes 1.37.0.

### Prerequisites
- Docker, or **rootful** Podman (see below)
- kind v0.33.0 — https://kind.sigs.k8s.io/docs/user/quick-start/#installation (Arch: `sudo pacman -S kind`)
- `kubectl`, `cilium` and `hubble` CLIs (`Module1/demo.sh` Steps 1 and 5 show how; Arch: `sudo pacman -S kubectl cilium-cli`)
- WireGuard kernel module on the host: `sudo modprobe wireguard`. kind nodes are containers, so they share your machine's kernel and cannot load modules themselves; the Cilium agent's `encryption.type=wireguard` needs the module already present (`lsmod | grep wireguard`). Skip this if you drop the two `encryption.*` values.

#### Podman must be rootful
Cilium mounts the BPF filesystem and loads eBPF programs into the host kernel. A rootless container is not allowed to do that, so with rootless Podman the `cilium` agent pods stay in `Init:CrashLoopBackOff` and the `mount-bpf-fs` init container logs `mount: /sys/fs/bpf: permission denied`. Run kind as root so the node containers are rootful. One-time setup:

1. Create the Podman network kind will use, so its bridge interface exists:
   ```
   sudo podman network create kind
   sudo podman network inspect kind --format '{{.NetworkInterface}}'   # prints e.g. podman1
   ```
2. If a host firewall is active (`sudo ufw status`), allow traffic arriving on that bridge. Without this the worker nodes cannot resolve the control plane's name — Podman's DNS (aardvark-dns) listens on the bridge gateway, and the firewall silently drops the queries, so `kind create cluster` fails at "Joining worker nodes" with `lookup cilium-lab-control-plane ... i/o timeout`:
   ```
   sudo ufw allow in on podman1          # containers -> host (DNS)
   sudo ufw route allow in on podman1    # containers -> internet (image pulls)
   ```
   The first rule lets containers reach services on the host (ufw's INPUT chain); the second lets their traffic be forwarded out to the internet (FORWARD chain, which ufw also drops by default — without it every image pull fails with `ErrImagePull`/`DeadlineExceeded`). Neither opens anything to the LAN. Remove them later with `sudo ufw delete allow in on podman1` and `sudo ufw delete route allow in on podman1`.
3. Create the cluster as root, but keep the credentials in your own kubeconfig:
   ```
   sudo KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster --config kind-config.yaml --kubeconfig ~/.kube/config
   sudo chown $USER ~/.kube/config
   ```
   Only `kind` needs `sudo KIND_EXPERIMENTAL_PROVIDER=podman` from then on (`kind get clusters`, `kind delete cluster`, ...) because the cluster lives in root's Podman; `kubectl`, `cilium` and `hubble` work without sudo.

With Docker none of this applies — its daemon is already rootful and manages its own firewall rules.

### Create the cluster
```
kind create cluster --config kind-config.yaml        # Docker
kubectl get nodes
```
All three nodes are `NotReady`: the config disables kind's default CNI and kube-proxy, so — exactly like the VM after `kubeadm init` — there is no pod network yet.

### Install Cilium
Same settings as `Module1/demo.sh`, kept in `cilium-values.yaml` (plus one fix, explained in that file). The only per-cluster value is the API server address — on kind it is the control-plane container's IP.
```
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

API_SERVER_IP=$(kubectl get node cilium-lab-control-plane -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
cilium install --version 1.20.1 -f cilium-values.yaml --set k8sServiceHost=${API_SERVER_IP}

cilium status --wait
kubectl get nodes
```
Nodes turn `Ready` as soon as the Cilium agent runs on them. No taint removal is needed here: the control plane keeps its `NoSchedule` taint and workloads land on the two workers.

#### Host kernel 7.2 or newer: use Cilium 1.21.0-pre.2
kind nodes share your kernel, and kernel 7.2 (August 2026) rejects the feature probe every released Cilium runs at startup ([cilium/cilium#48016](https://github.com/cilium/cilium/issues/48016)). The agents crash-loop with `failed to probe helper ... bpf_set_retval ... R1 is not a scalar`. The fix is in `1.21.0-pre.2` and will be in 1.20.2 once released. Check with `uname -r`; if you are on 7.2+, use `--version 1.21.0-pre.2` in the command above (or `cilium upgrade --version 1.21.0-pre.2` on an existing install).

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
