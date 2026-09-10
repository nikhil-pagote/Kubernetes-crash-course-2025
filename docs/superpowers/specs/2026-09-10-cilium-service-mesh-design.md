# Cilium CNI + Service Mesh — design

**Date:** 2026-09-10 · **Branch:** `cilium` · **Base:** `main` @ 572bf8a2 (Kubernetes v1.37)

## Goal

Replace Flannel with Cilium 1.20.1 as the course CNI and add a hands-on
service-mesh module using Cilium's built-in, sidecar-less mesh
(kube-proxy replacement, embedded Envoy L7, WireGuard encryption, SPIRE
mutual auth, Hubble, Gateway API). The main app's ingress moves from
kgateway to Cilium's Gateway API implementation.

## Non-goals

LB-IPAM / L2 announcements, BGP, cluster mesh, Istio/Linkerd, replacing
the `services/Ingress` ingress-nginx demo, changes to app code.

## Versions (verified 2026-09-10)

| Component | Version | Source |
|---|---|---|
| Cilium | 1.20.1 | github.com/cilium/cilium latest release |
| cilium-cli | 0.20.0 | github.com/cilium/cilium-cli latest release |
| Gateway API CRDs | 1.6.1 | required by Cilium ≥ 1.19 (upgrade notes) |
| Kubernetes | 1.37.0 | unchanged from `main` |

## Components

### 1. `Module1/demo.sh` (modified)
- Step 4: `kubeadm init … --skip-phases=addon/kube-proxy`. Pod CIDR stays `10.244.0.0/16`.
- Step 5 (was Flannel): install Gateway API 1.6.1 standard CRDs
  (`standard-install.yaml`, same URL as `main`); install cilium-cli 0.20.0
  from the GitHub release tarball; `cilium install --version 1.20.1` with
  ```
  kubeProxyReplacement=true
  k8sServiceHost=<control-plane hostname>   k8sServicePort=6443
  ipam.mode=kubernetes
  hubble.relay.enabled=true  hubble.ui.enabled=true
  gatewayAPI.enabled=true
  encryption.enabled=true  encryption.type=wireguard
  authentication.mutual.spire.enabled=true
  authentication.mutual.spire.install.enabled=true
  ```
  then `cilium status --wait`.
- Taint removal unchanged.
- Preflight: `--ignore-preflight-errors=all` unchanged.

### 2. Module1 docs (modified)
- `cni.md`: keep the namespace/veth exploration; add `cilium status`,
  `cilium connectivity test`, `cilium-dbg endpoint list` (run inside the
  cilium agent pod), and a note that Cilium attaches eBPF programs to the
  veth instead of bridging.
- `kube-proxy.md`: rewrite. There is no `KUBE-SERVICES` iptables chain in a
  kube-proxy-free cluster; show `kubectl -n kube-system get ds kube-proxy`
  (not found), `cilium-dbg service list`, `cilium-dbg bpf lb list`.
- `Coredns.md`: unchanged.

### 3. `servicemesh/` (new)
| File | Purpose |
|---|---|
| `README.md` | walk-through of the four demos below |
| `app.yaml` | `nginx` Deployment+Service (`app: nginx`) and a `client` busybox-style pod (uses `curlimages/curl`) — the demo target |
| `l7-policy.yaml` | `CiliumNetworkPolicy` on `app: nginx`: ingress from `app: client` allowed only for `GET /` on port 80 |
| `mtls-policy.yaml` | same rule plus `authentication.mode: required` |
| `gateway.yaml` | `Gateway` `gatewayClassName: cilium`, HTTP listener :80 |
| `httproute.yaml` | `HTTPRoute` → `nginx` Service |

README sections: (a) deploy app, observe with `hubble observe`;
(b) apply L7 policy, `GET /` succeeds, `POST /` → 403 from Envoy,
`hubble observe --verdict DROPPED` / `--protocol http`; (c) apply mTLS
policy, `cilium-dbg` shows SPIFFE identities, traffic still flows;
(d) Gateway: `kubectl get gateway` shows the LoadBalancer Service; on the
kubeadm VM (no cloud LB) reach it via the Service's NodePort on the node IP;
(e) Hubble UI via `cilium hubble ui`.

### 4. Main app (modified)
- `manifests/gateway.yaml`: `gatewayClassName: cilium`, `namespace: crash-course`.
- `manifests/httproute.yaml`, `manifests/httpredirect.yaml`,
  `manifests/cluster-issuer.yaml`: `parentRefs` namespace → `crash-course`.
- `README.md` step 4: remove kgateway installs. Add: on Exoscale SKS create
  the cluster with `--cni cilium` (or `cilium install` as in demo.sh for a
  kubeadm cluster), apply Gateway API 1.6.1 CRDs, enable
  `gatewayAPI.enabled=true`. cert-manager unchanged.

### 5. `services/README.md` (modified)
"Nodeport check via iptables" → `cilium-dbg service list` / `bpf lb list`.

## Verification
- `bash -n Module1/demo.sh`
- `helm template` Cilium chart 1.20.1 with the exact `--set` values from demo.sh
  (proves every value key exists).
- `kubeconform -kubernetes-version 1.37.0 -strict` on all YAML, with the
  Cilium and Gateway API CRD schemas from the datree CRD catalog.
- `curl` every URL introduced.
- A real cluster run is not possible in this environment; the summary must
  say so.
