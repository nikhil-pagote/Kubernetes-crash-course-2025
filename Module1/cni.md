## CNI in action 

```
kubectl apply -f multi.yaml

```
### See the ip 
```
ip link show
```

After po creation there will be veth pair created 

```
ip link show
```
### Check network namespace
```
ip netns list 
ip netns exec <namespace> ip link 
```

### Exec into the pod and see that within a pod they share same namespace and are able to communicate over localhost 

```
kubectl exec -it shared-namespace -- sh
wget -qO- http://localhost
```
Also check 
`ip a`

### chaeck namespace for paus econtainer 

```
lsns | grep nginx 
lsns -p 
lsns | grep sleep
```

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
