# Cilium CNI + Service Mesh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Flannel with Cilium 1.20.1 in the course's kubeadm bootstrap, add a `servicemesh/` module demonstrating Cilium's built-in service mesh, and move the main app's Gateway from kgateway to Cilium.

**Architecture:** `Module1/demo.sh` bootstraps kubeadm without kube-proxy and runs `cilium install` with kube-proxy replacement, Hubble, Gateway API, WireGuard and SPIRE mutual-auth. A new `servicemesh/` folder holds one YAML per demo plus a README, following the repo's existing "folder = topic, YAML + Readme" convention. `manifests/` switches `gatewayClassName` to `cilium` and moves the Gateway into `crash-course`.

**Tech Stack:** Kubernetes 1.37.0 (kubeadm), Cilium 1.20.1, cilium-cli 0.20.0, Hubble CLI 1.19.4, Gateway API 1.6.1, kubeconform (validation), helm 3 (chart value validation only).

**Spec:** `docs/superpowers/specs/2026-09-10-cilium-service-mesh-design.md`

## Global Constraints

- Cilium `1.20.1`, cilium-cli `v0.20.0`, Hubble CLI `v1.19.4`, Gateway API CRDs `v1.6.1` — exact values, no `latest`.
- Pod CIDR stays `10.244.0.0/16`.
- Cilium helm values (verified by `helm template` against chart 1.20.1 on 2026-09-10): `kubeProxyReplacement=true k8sServiceHost=<node IP> k8sServicePort=6443 ipam.mode=kubernetes hubble.relay.enabled=true hubble.ui.enabled=true gatewayAPI.enabled=true encryption.enabled=true encryption.type=wireguard authentication.enabled=true authentication.mutual.spire.enabled=true authentication.mutual.spire.install.enabled=true`. Note `authentication.enabled=true` is mandatory — the chart's validate.yaml rejects SPIRE without it.
- Every YAML must pass `kubeconform -kubernetes-version 1.37.0 -strict` using the tool at `$SCRATCH/kubeconform` with the datree CRD catalog schema location (command in Task 3).
- Match existing repo style: 2-space YAML, README code fences with bare commands, no extra tooling.
- Commit message trailer on every commit:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JJEP5cuSZa41dzSXVyBDBU
  ```
- `$SCRATCH` = `/tmp/claude-1000/-home-nikhil-Documents-Kubernetes-crash-course-2025-Module1/84bee99a-04dd-44bb-9dcf-81624b5bb7b7/scratchpad` (holds `kubeconform`, `helm`, `cilium-1.20.1.tgz`).

---

### Task 1: Bootstrap script — kube-proxy-free kubeadm + Cilium

**Files:**
- Modify: `Module1/demo.sh:82-108` (Step 4 `kubeadm init` and Step 5 Flannel block)

**Interfaces:**
- Produces: a cluster with Cilium installed via the exact helm values in Global Constraints; the `cilium` and `hubble` CLIs in `/usr/local/bin`. Later docs assume these exist.

- [ ] **Step 1: Add `--skip-phases=addon/kube-proxy` to `kubeadm init`**

Replace the `kubeadm init` invocation (currently lines 87–93) with:

```bash
# Initialize cluster (kube-proxy is skipped: Cilium replaces it)
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --upload-certs \
  --kubernetes-version=v1.37.0 \
  --control-plane-endpoint="$(hostname)" \
  --skip-phases=addon/kube-proxy \
  --ignore-preflight-errors=all \
  --cri-socket unix:///run/containerd/containerd.sock
```

- [ ] **Step 2: Replace the Flannel block with Cilium**

Replace from `echo "Step 5: Apply Flannel Network"` through the `kubectl apply -f https://github.com/flannel-io/...` line with:

```bash
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

cilium status --wait
```

Keep the existing `# Remove control-plane taint` block and final echo after it.

- [ ] **Step 3: Verify script syntax and chart values**

Run:
```bash
bash -n Module1/demo.sh && echo OK
$SCRATCH/helm template cilium $SCRATCH/cilium-1.20.1.tgz --namespace kube-system \
  --set kubeProxyReplacement=true --set k8sServiceHost=10.0.0.5 --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes --set hubble.relay.enabled=true --set hubble.ui.enabled=true \
  --set gatewayAPI.enabled=true --set encryption.enabled=true --set encryption.type=wireguard \
  --set authentication.enabled=true --set authentication.mutual.spire.enabled=true \
  --set authentication.mutual.spire.install.enabled=true >/dev/null && echo "chart OK"
grep -oE 'https://[^ {]+' Module1/demo.sh | sort -u | while read u; do printf "%s " "$u"; curl -sL -o /dev/null -w "%{http_code}\n" "$u"; done
```
Expected: `OK`, `chart OK`, and every URL `200` (the `pkgs.k8s.io/.../deb/` directory root returns `403` — that is a directory-listing denial, not a broken link; `Release.key` under it returns 200). Also confirm `grep -c flannel Module1/demo.sh` prints `0`.

- [ ] **Step 4: Commit**

```bash
git add Module1/demo.sh
git commit -m "demo.sh: bootstrap kube-proxy-free cluster with Cilium 1.20.1 instead of Flannel"
```

---

### Task 2: Module1 docs — CNI and kube-proxy pages for Cilium

**Files:**
- Modify: `Module1/cni.md` (append section at end)
- Modify: `Module1/kube-proxy.md` (rewrite)

**Interfaces:**
- Consumes: `cilium`, `hubble` CLIs from Task 1.

- [ ] **Step 1: Append a Cilium section to `cni.md`**

Append to the end of `Module1/cni.md`:

````markdown

## Cilium (the CNI in this course)

### Check the installation
```
cilium status
kubectl get pods -n kube-system -l k8s-app=cilium
```

### Run the built-in connectivity test (takes a few minutes, creates and deletes a `cilium-test-1` namespace)
```
cilium connectivity test
```

### Endpoints instead of bridges
Cilium does not create a Linux bridge. Each pod's veth gets eBPF programs attached and becomes a Cilium *endpoint* with a numeric security identity.
```
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg identity list
```
Find the `shared-namespace` pod in the endpoint list and note its identity; identities are derived from labels, not IPs.

### Encryption
Pod-to-pod traffic between nodes is WireGuard-encrypted (`encryption.type=wireguard` in demo.sh).
```
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
```
````

- [ ] **Step 2: Rewrite `kube-proxy.md`**

Replace the entire content of `Module1/kube-proxy.md` with:

````markdown
## Kube-Proxy (replaced by Cilium)

This cluster was bootstrapped with `kubeadm init --skip-phases=addon/kube-proxy`, so there is **no kube-proxy**. Cilium implements Services in eBPF instead (`kubeProxyReplacement=true`).

### Confirm kube-proxy is absent
```
kubectl get ds -n kube-system kube-proxy
```
Expected: `Error from server (NotFound)`.

```
cilium status | grep KubeProxyReplacement
```

### There is no KUBE-SERVICES chain
With kube-proxy this is where Service rules lived. With Cilium it is empty/absent:
```
sudo iptables -t nat -L KUBE-SERVICES -n 2>&1 | head -3
```

### Create the pod and service
Add a label if needed for the multi container pod that was created in the CNI demo.
```
kubectl label pod shared-namespace app=shared
kubectl apply -f multi-pod-service.yaml
```

### See the Service in Cilium's eBPF load balancer
As soon as the Service is created, every Cilium agent programs it into a BPF map.
```
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
```
Find the `shared-service` ClusterIP and its backend pod IP(s).

### Watch the traffic with Hubble
```
cilium hubble port-forward &
hubble observe --to-service default/shared-service
```
````

- [ ] **Step 3: Verify**

Run: `grep -c "KUBE-SVC-2JWKBRQZFJKXWXF4" Module1/kube-proxy.md` → `0`; `grep -c "cilium-dbg" Module1/cni.md Module1/kube-proxy.md` → non-zero for both.

- [ ] **Step 4: Commit**

```bash
git add Module1/cni.md Module1/kube-proxy.md
git commit -m "Module1 docs: describe Cilium endpoints and kube-proxy replacement"
```

---

### Task 3: servicemesh — demo app and L7 policy

**Files:**
- Create: `servicemesh/app.yaml`
- Create: `servicemesh/l7-policy.yaml`

**Interfaces:**
- Produces: Deployment/Service `nginx` (labels `app: nginx`) and Pod `client` (label `app: client`) in `default`. Tasks 4 and 5 reference these exact names/labels.

- [ ] **Step 1: Write `servicemesh/app.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  labels:
    app: client
spec:
  containers:
  - name: curl
    image: curlimages/curl
    command: ['sleep', '3600']
```

- [ ] **Step 2: Write `servicemesh/l7-policy.yaml`**

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: nginx-l7
spec:
  endpointSelector:
    matchLabels:
      app: nginx
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: client
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http:
        - method: GET
          path: /
```

- [ ] **Step 3: Validate**

Run:
```bash
$SCRATCH/kubeconform -kubernetes-version 1.37.0 -strict -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  servicemesh/app.yaml servicemesh/l7-policy.yaml
```
Expected: `Valid: 4, Invalid: 0, Errors: 0, Skipped: 0`.

- [ ] **Step 4: Commit**

```bash
git add servicemesh/app.yaml servicemesh/l7-policy.yaml
git commit -m "servicemesh: demo app and L7 CiliumNetworkPolicy"
```

---

### Task 4: servicemesh — mutual auth policy and Cilium Gateway

**Files:**
- Create: `servicemesh/mtls-policy.yaml`
- Create: `servicemesh/gateway.yaml`
- Create: `servicemesh/httproute.yaml`

**Interfaces:**
- Consumes: Service `nginx` :80 and labels from Task 3.
- Produces: Gateway `nginx-gateway` (default ns). Cilium creates Service `cilium-gateway-nginx-gateway` (type LoadBalancer) for it — Task 5 README references that name.

- [ ] **Step 1: Write `servicemesh/mtls-policy.yaml`**

Same policy as L7 with `authentication.mode: required` and a different name (so both can coexist for comparison):

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: nginx-mtls
spec:
  endpointSelector:
    matchLabels:
      app: nginx
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: client
    authentication:
      mode: required
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http:
        - method: GET
          path: /
```

- [ ] **Step 2: Write `servicemesh/gateway.yaml`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: nginx-gateway
spec:
  gatewayClassName: cilium
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
```

- [ ] **Step 3: Write `servicemesh/httproute.yaml`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nginx-route
spec:
  parentRefs:
  - name: nginx-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: nginx
      port: 80
```

- [ ] **Step 4: Validate**

Run the kubeconform command from Task 3 Step 3 against `servicemesh/*.yaml`.
Expected: `Valid: 7, Invalid: 0, Errors: 0, Skipped: 0`.

- [ ] **Step 5: Commit**

```bash
git add servicemesh/mtls-policy.yaml servicemesh/gateway.yaml servicemesh/httproute.yaml
git commit -m "servicemesh: mutual-auth policy and Cilium Gateway API demo"
```

---

### Task 5: servicemesh README

**Files:**
- Create: `servicemesh/README.md`

**Interfaces:**
- Consumes: all names from Tasks 3–4; CLIs from Task 1.

- [ ] **Step 1: Write `servicemesh/README.md`**

````markdown
## Cilium Service Mesh

Cilium's service mesh is sidecar-less: L7 handling happens in an Envoy proxy embedded in the Cilium agent, and mTLS identities come from SPIRE. Everything here was enabled by `Module1/demo.sh`.

### 1. Deploy the demo app and watch traffic
```
kubectl apply -f app.yaml
kubectl wait --for=condition=Ready pod -l app=nginx --timeout=120s
cilium hubble port-forward &
hubble observe --to-pod default/nginx --follow
```
In another terminal:
```
kubectl exec client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx
```
Hubble shows L3/L4 flows only (`TCP` verdict `FORWARDED`).

### 2. L7 policy: allow only `GET /`
```
kubectl apply -f l7-policy.yaml
kubectl exec client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx           # 200
kubectl exec client -- curl -s -o /dev/null -w "%{http_code}\n" -X POST http://nginx   # 403
kubectl exec client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx/admin     # 403
```
The 403 is returned by Envoy, not nginx. Hubble now shows HTTP-level flows:
```
hubble observe --to-pod default/nginx --protocol http
hubble observe --to-pod default/nginx --verdict DROPPED
```
Traffic from any pod *without* `app=client` is dropped at L3 before ever reaching Envoy:
```
kubectl run other --image=curlimages/curl --rm -it --restart=Never -- curl -s -m 3 http://nginx || echo "blocked"
```

### 3. Mutual authentication (mTLS identities from SPIRE)
```
kubectl delete -f l7-policy.yaml
kubectl apply -f mtls-policy.yaml
kubectl exec client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx           # 200 (after a short handshake)
```
See the SPIFFE identities Cilium registered for the pods:
```
kubectl -n cilium-spire exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show
```
Hubble shows the handshake:
```
hubble observe --to-pod default/nginx --type policy-verdict
```

### 4. Gateway API with Cilium
No separate gateway controller — the Cilium operator reconciles `Gateway` objects of class `cilium` and the Cilium agent's Envoy serves them.
```
kubectl get gatewayclass
kubectl apply -f gateway.yaml -f httproute.yaml
kubectl get gateway nginx-gateway
kubectl get svc cilium-gateway-nginx-gateway
```
On a cloud cluster the Service gets an external IP. On the kubeadm VM there is no LoadBalancer, so use the NodePort:
```
NODE_PORT=$(kubectl get svc cilium-gateway-nginx-gateway -o jsonpath='{.spec.ports[0].nodePort}')
curl -s http://$(hostname -I | awk '{print $1}'):$NODE_PORT | head -5
```

### 5. Hubble UI
```
cilium hubble ui
```
Opens a service map in the browser (port-forward to localhost:12000). Select the `default` namespace to see `client → nginx` and the gateway flows.

### Cleanup
```
kubectl delete -f httproute.yaml -f gateway.yaml -f mtls-policy.yaml -f app.yaml --ignore-not-found
```
````

- [ ] **Step 2: Verify every file referenced exists**

Run: `for f in app.yaml l7-policy.yaml mtls-policy.yaml gateway.yaml httproute.yaml; do test -f servicemesh/$f && echo "ok $f"; done`
Expected: five `ok` lines.

- [ ] **Step 3: Commit**

```bash
git add servicemesh/README.md
git commit -m "servicemesh: README walkthrough"
```

---

### Task 6: Main app — kgateway → Cilium Gateway, README and services doc

**Files:**
- Modify: `manifests/gateway.yaml` (namespace, gatewayClassName, drop file comment)
- Modify: `manifests/httproute.yaml:8-10` (parentRefs namespace)
- Modify: `manifests/httpredirect.yaml:7-10` (parentRefs namespace)
- Modify: `manifests/cluster-issuer.yaml:13-16` (parentRefs namespace)
- Modify: `README.md:66-97` (step 4)
- Modify: `README.md:112-117` (repository structure list)
- Modify: `services/README.md:71-75` ("Nodeport check via iptables")

**Interfaces:**
- Consumes: nothing from earlier tasks (independent).

- [ ] **Step 1: `manifests/gateway.yaml`**

Replace the file with:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: crash-course-gateway
  namespace: crash-course
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "k8s2025.kubesimplify.com"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: course-kubesimplify-com-tls
      allowedRoutes:
        namespaces:
          from: Same
```

- [ ] **Step 2: parentRefs namespace in three files**

`sed -i 's/namespace: kgateway-system/namespace: crash-course/' manifests/httproute.yaml manifests/httpredirect.yaml manifests/cluster-issuer.yaml`

- [ ] **Step 3: README step 4**

Replace the block from `4. **Secure with HTTPS & Gateway API**` up to (not including) `5. **Monitor with kube-prometheus-stack**` with:

````markdown
4. **Secure with HTTPS & Gateway API**  
   - Cilium is the CNI *and* the Gateway API implementation — no separate gateway controller
   - Install `cert-manager` and enable its Gateway API support
   - Create `Gateway`, `ClusterIssuer`, and `HTTPRoute`

Cilium: on Exoscale SKS create the cluster with `--cni cilium`; on a kubeadm cluster `Module1/demo.sh` installs it. Either way Gateway API must be on:
```
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
cilium upgrade --version 1.20.1 --set gatewayAPI.enabled=true
kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl get gatewayclass cilium
```
Cert Manager 
```
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.1/cert-manager.yaml
```
Edit deployment and add enable gateway API 

```
kubectl edit deploy cert-manager -n cert-manager
```
add `- --enable-gateway-api`
Restart cert-manager
```
kubectl rollout restart deployment cert-manager -n cert-manager
```
Apply manifests 

```
kubectl apply -f manifests/cluster-issuer.yaml
kubectl apply -f manifests/gateway.yaml
kubectl apply -f manifests/httproute.yaml
kubectl apply -f manifests/httpredirect.yaml
kubectl -n crash-course get svc cilium-gateway-crash-course-gateway
```
Point the `k8s2025.kubesimplify.com` DNS record at that Service's external IP.
````

- [ ] **Step 4: README repository structure**

In the `## 📁 Repository Structure` list, after the `scheduler` line add:

```markdown
- `servicemesh`: Cilium service mesh demos (L7 policy, mTLS, Gateway API, Hubble)
```

- [ ] **Step 5: services/README.md NodePort section**

Replace:
````markdown
## Nodeport check via iptables
```
sudo iptables -t nat -L -n -v | grep -e NodePort -e KUBE
sudo iptables -t nat -L -n -v | grep 31188
```
````
with:
````markdown
## Nodeport check via Cilium
There is no kube-proxy in this cluster, so NodePorts live in Cilium's eBPF maps instead of iptables:
```
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list | grep NodePort
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list | grep 31188
```
````

- [ ] **Step 6: Validate**

Run:
```bash
$SCRATCH/kubeconform -kubernetes-version 1.37.0 -strict -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  manifests/*.yaml servicemesh/*.yaml
grep -rn "kgateway" --include="*.md" --include="*.yaml" . | grep -v docs/superpowers
```
Expected: all valid; the grep prints nothing.

- [ ] **Step 7: Commit**

```bash
git add manifests README.md services/README.md
git commit -m "Main app: serve Gateway with Cilium instead of kgateway"
```

---

## Final verification (after all tasks)

```bash
bash -n Module1/demo.sh
$SCRATCH/kubeconform -kubernetes-version 1.37.0 -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  Module1/*.yaml servicemesh/*.yaml manifests/*.yaml
grep -rn -i "flannel\|kgateway" --include="*.md" --include="*.yaml" --include="*.sh" . | grep -v docs/superpowers   # expect nothing
git log --oneline main..cilium
```

Not verifiable here: an actual `demo.sh` run on an Ubuntu VM. The final summary must state this.
