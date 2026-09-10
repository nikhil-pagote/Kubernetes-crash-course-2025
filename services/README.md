

## Services 

```
kubectl run nginx --image=nginx
kubectl run nginx2 --image=nginx
kubectl label pod nginx2 run=nginx --overwrite

kubectl expose pod nginx --port 80 --dry-run=client -oyaml
kubectl expose pod nginx --port 80  
kubectl get endpointslices

```
Note: the `Endpoints` API (`kubectl get ep`) is deprecated since Kubernetes 1.33; EndpointSlices are the replacement.

## Headless Service
```
kubectl create -f statefulset.yaml
kubectl apply -f svc.yaml
```
Check 
`kubectl exec -it postgres-0 -- psql -U postgres`

## ExternalName
Create database and app namespaces 
```
kubectl create ns database-ns
kubectl create ns application-ns
```
Create the databas pod and service
```
kubectl apply -f db.yaml
kubectl apply -f db_svc.yaml
```
Create ExternalName service
```
kubectl apply -f externam-db_svc.yaml
```
Create Application to access the service
Docker build
`docker build --no-cache --platform=linux/amd64 -t ttl.sh/saiyamdemo:1h . `

Docker push 
`docker push ttl.sh/saiyamdemo:1h`

`kubectl apply -f apppod.yaml`

Check the pod logs to see if the connection was successful 

`kubectl logs my-application -n application-ns`



## Ingres controller
> **Note:** the ingress-nginx project was retired and archived in March 2026 — `controller-v1.15.1` is its final release and it receives no further security fixes. It still works for this demo, but for anything real use Gateway API instead (see `manifests/` and `servicemesh/` for the Cilium-based setup).
```
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/cloud/deploy.yaml
```
Deploy all in Ingress folder after creating below config map 

`kubectl create configmap nginx-config --from-file=nginx.conf`

ssh onto the node where the pod is deployed and the change the /etc/hosts file.



## Nodeport check via Cilium
There is no kube-proxy in this cluster, so NodePorts live in Cilium's eBPF maps instead of iptables:
```
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list | grep NodePort
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list | grep 31188
```