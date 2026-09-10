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
