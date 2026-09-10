## Core DNS
### CoreDNS pods
```
kubectl get pods -n kube-system -l k8s-app=kube-dns
```
### Core NS config map
```
kubectl -n kube-system get configmap coredns -o yaml
```

### Deploy nginx and service
```
kubectl apply -f nginx.yaml

```
`nginx.yaml` is written in KYAML — the strict, brace-delimited YAML subset that kubectl can emit since 1.34. Any object can be printed that way:
```
kubectl get pod nginx -o kyaml
```
### DNS test pod 
```
kubectl run -it --rm busybox --image=busybox --restart=Never -- sh
nslookup nginx-service

```