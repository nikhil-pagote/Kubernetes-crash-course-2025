## Kube-Proxy

> **Note:** kube-proxy still defaults to `iptables` mode in Kubernetes 1.37 (it logs a warning when the mode isn't set explicitly). `nftables` mode becomes the default in 1.40, at which point these `iptables` commands would need to be replaced with `nft list ruleset`. Check the mode in use with `kubectl -n kube-system get cm kube-proxy -o yaml | grep mode`.

### See the kube proxy pods
```
kubectl get pods -n kube-system
```
### Inspect the kube-services chain
```
sudo iptables -t nat -L KUBE-SERVICES -n --line-numbers

```

### Create the pod and service
As soon as the service is created, kube-proxy will create the iptables rules
Add label if needed for the multi container po that was created in the CNI demo. 
`kubectl label pod shared-namespace app=shared`

```
sudo iptables -t nat -L KUBE-SERVICES -n --line-numbers | grep 10.96.0.100

```
### See rules inside specific chain

```
sudo iptables -t nat -L KUBE-SVC-2JWKBRQZFJKXWXF4 -n --line-numbers

```
### digging deeper into the backend pod chain
```
 sudo iptables -t nat -S KUBE-SEP-XXXXXXXX

```

