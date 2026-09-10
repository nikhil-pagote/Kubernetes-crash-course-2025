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
