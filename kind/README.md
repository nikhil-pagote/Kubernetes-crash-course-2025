## Local 3-node cluster with kind + Cilium

One control plane and two workers, each a container sharing your machine's kernel, running kubeadm-bootstrapped Kubernetes 1.37.0. kind's default CNI and kube-proxy are disabled in `kind-config.yaml`; Cilium provides both, installed with the values in `cilium-values.yaml`.

Verified on: Arch/CachyOS, kernel 7.2, rootful Podman 6.1, kind 0.33.0, Cilium 1.21.0-pre.2.

### Prerequisites
```
sudo pacman -S kind kubectl cilium-cli
```
`hubble` CLI (not packaged) — see `Module1/demo.sh` Step 5.

Cilium needs rootful containers (it mounts bpffs and loads eBPF into the kernel), so every `kind` and `podman` command below runs with `sudo`. `kubectl`, `cilium` and `hubble` do not.

### 1. Podman network and firewall (one-time)
```
sudo podman network create kind
sudo podman network inspect kind --format '{{.NetworkInterface}}'   # e.g. podman1
sudo ufw allow in on podman1
sudo ufw route allow in on podman1
```
The two ufw rules let the node containers reach the host (DNS) and the internet (image pulls). They accept traffic only from your own containers on that bridge. Skip them if ufw is inactive (`sudo ufw status`).

### 2. Create the cluster
```
cd kind
sudo modprobe wireguard
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster --config kind-config.yaml --kubeconfig ~/.kube/config
sudo chown $USER ~/.kube/config
kubectl get nodes
```
All three nodes are `NotReady` and CoreDNS is `Pending` — there is no CNI yet. This is the same state as the VM right after `kubeadm init`.

### 3. Install Cilium
Gateway API CRDs first (Cilium's Gateway controller needs them at startup), then Cilium itself — either with the `cilium` CLI or with Helm. Both produce the same Helm release; pick one.
```
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
API_SERVER_IP=$(kubectl get node cilium-lab-control-plane -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
```

**Option A — cilium CLI.** Detects kind and fills in the cluster name, operator replica count and tunnel mode by itself:
```
cilium install --version 1.21.0-pre.2 -f cilium-values.yaml --set k8sServiceHost=${API_SERVER_IP}
```

**Option B — Helm** (`sudo pacman -S helm`). Same chart from Cilium's OCI registry; the four values the CLI would auto-detect are passed explicitly:
```
helm install cilium oci://quay.io/cilium/charts/cilium --version 1.21.0-pre.2 \
  --namespace kube-system \
  -f cilium-values.yaml \
  --set k8sServiceHost=${API_SERVER_IP} \
  --set cluster.name=kind-cilium-lab \
  --set operator.replicas=1 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan
```

Then, for either option:
```
cilium status --wait
kubectl get nodes
```
Takes a few minutes on first run (image pulls). Ends with `Cilium: OK`, three `Ready` nodes, and in `cilium-spire` a `2/2` server plus three `1/1` agents.

Later changes go through the same tool you installed with: `cilium upgrade --version <ver> -f cilium-values.yaml --set ...` or `helm upgrade cilium oci://quay.io/cilium/charts/cilium --version <ver> -n kube-system -f cilium-values.yaml --set ...` (repeat the `--set` values; Helm does not remember them across upgrades unless you pass `--reuse-values`). `helm -n kube-system get values cilium` shows what is currently applied, whichever tool did it.

Version note: `1.21.0-pre.2` is required on host kernel 7.2 or newer ([cilium/cilium#48016](https://github.com/cilium/cilium/issues/48016)). On kernel 7.1 or older use `1.20.1`, the same version as `Module1/demo.sh`.

### Hubble UI
```
cilium hubble ui
```
Port-forwards the UI to http://localhost:12000 and opens it; keep the terminal open. It shows a service map per namespace built from observed flows, so generate traffic first (e.g. `servicemesh/README.md` step 1). CLI equivalent: `cilium hubble port-forward &` then `hubble observe --follow`.

### Using the cluster
- Node names: `cilium-lab-control-plane`, `cilium-lab-worker`, `cilium-lab-worker2`. The control plane keeps its `NoSchedule` taint; workloads land on the workers.
- Node-level commands from `Module1/cni.md` and `Module1/kube-proxy.md` run inside a node: `sudo podman exec -it cilium-lab-worker bash`.
- No LoadBalancer. For the Gateway demos in `servicemesh/` use `kubectl port-forward svc/cilium-gateway-nginx-gateway 8080:80` and `curl http://localhost:8080`.

### Delete the cluster
```
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name cilium-lab
```

### If something fails
| Symptom | Cause | Fix |
|---|---|---|
| `kind create cluster` fails at "Joining worker nodes", `lookup cilium-lab-control-plane ... i/o timeout` | ufw drops container → host DNS | `sudo ufw allow in on podman1` |
| Pods stuck in `ErrImagePull` / `DeadlineExceeded` | ufw drops container → internet | `sudo ufw route allow in on podman1` |
| `cilium` pods `Init:CrashLoopBackOff`, `mount: /sys/fs/bpf: permission denied` | kind running under rootless Podman | delete the cluster, recreate with `sudo` as in step 2 |
| `cilium` pods `CrashLoopBackOff`, `bpf_set_retval ... R1 is not a scalar` | host kernel ≥ 7.2 with Cilium ≤ 1.20.1 | `cilium upgrade --version 1.21.0-pre.2` |
| `cilium status` shows `Cannot connect to SPIRE server`, `spire-server-0` never ready | socket directory owned by root, server runs as uid 1000 | already handled by the init container in `cilium-values.yaml` |
| Pods in `ImagePullBackOff` long after the fix | kubelet retry backoff | `kubectl -n kube-system delete pods -l k8s-app=cilium` |

Docker instead of Podman: drop `sudo` and `KIND_EXPERIMENTAL_PROVIDER=podman` everywhere, and skip step 1 — Docker's daemon is already rootful and manages its own firewall rules.
