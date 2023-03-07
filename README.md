# TLS Termination On Ingress Sidecar Selectively

This project demonstrates TLS termination on ingress sidecar using `EnvoyFilter`. This is quite similar to what can be achieved with a `Sidecar` as described in [docs](https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-sidecar-tls-termination/).

## Prerequisites

1. Create required env vars

    ```
    export CLUSTER_OWNER="kasunt"
    export PROJECT="tls-termination"
    ```

2. Provision cluster

    ```
    colima start --runtime containerd --kubernetes --kubernetes-disable-servicelb -p $PROJECT -c 4 -m 8 -d 20 --network-address --install-metallb --metallb-address-pool "192.168.106.230/29" --kubernetes-version v1.24.9+k3s2
    ```

3. Install `istioctl` version `1.17.1`.

## Setting Up Istio

```
istioctl operator init
kubectl apply -f istio-provision.yaml
```

## Deploy App and Config

```
# Generate the TLS certs
kubectl apply -f apps/httpbin/ns.yaml
./gen_tls.sh

kubectl create ns istio-config

kubectl -n httpbin apply -f config/istio-tls-sds-config.yaml

kubectl -n httpbin apply -f apps/httpbin/deploy.yaml
kubectl -n httpbin apply -f apps/curl/deploy.yaml

# Sidecar but in a different namespace
kubectl create ns trusted
kubectl -n trusted apply -f apps/curl/deploy.yaml

# Out of mesh so no sidecar
kubectl create ns untrusted
kubectl -n untrusted apply -f apps/curl/deploy.yaml

# Various configuration
kubectl apply -f config/peer-auth.yaml
kubectl apply -f config/httpbin-envoy-filter.yaml
kubectl apply -f config/httpbin-igw-vs.yaml
```

## Testing

1. From within the mesh

    ```
    export INTERNAL_CLIENT=$(kubectl -n httpbin get pod -l app=curl-client -o jsonpath={.items..metadata.name})
    kubectl -n httpbin exec "${INTERNAL_CLIENT}" -c curl-client -- curl -IsS "http://httpbin:8080/status/200"
    ```

    Resulting in,

    ```
    HTTP/1.1 200 OK
    server: envoy
    date: Tue, 28 Feb 2023 23:35:15 GMT
    content-type: text/html; charset=utf-8
    access-control-allow-origin: *
    access-control-allow-credentials: true
    content-length: 0
    x-envoy-upstream-service-time: 19
    ```

2. From outside the mesh - trusted traffic with TLS origination

    ```
    export EXTERNAL_CLIENT=$(kubectl -n trusted get pod -l app=curl-client -o jsonpath={.items..metadata.name})
    kubectl cp ._temp_client_certs/client.httpbin.svc.cluster.local.key trusted/"${EXTERNAL_CLIENT}":/tmp/client.key
    kubectl cp ._temp_client_certs/client.httpbin.svc.cluster.local.crt trusted/"${EXTERNAL_CLIENT}":/tmp/client.crt
    kubectl cp ._temp_client_certs/rootCA.crt trusted/"${EXTERNAL_CLIENT}":/tmp/ca.crt

    kubectl exec "${EXTERNAL_CLIENT}" -n trusted -c curl-client -- curl -IsS --cacert /tmp/ca.crt --key /tmp/client.key --cert /tmp/client.crt -HHost:httpbin.httbin.svc.cluster.local "https://httpbin.httpbin.svc.cluster.local:8443/status/200"
    ```

    Should result in,

    ```
    HTTP/2 200
    server: istio-envoy
    date: Tue, 28 Feb 2023 22:49:53 GMT
    content-type: text/html; charset=utf-8
    access-control-allow-origin: *
    access-control-allow-credentials: true
    content-length: 0
    x-envoy-upstream-service-time: 1
    ```

3. From outside the mesh - untrusted traffic

    ```
    export UNTRUSTED_EXTERNAL_CLIENT=$(kubectl -n untrusted get pod -l app=curl-client -o jsonpath={.items..metadata.name})
    kubectl exec "${UNTRUSTED_EXTERNAL_CLIENT}" -n untrusted -c curl-client -- curl -IsS "http://httpbin.httpbin.svc.cluster.local:8080/status/200"
    ```

    Resulting in,

    ```
    curl: (56) Recv failure: Connection reset by peer
    command terminated with exit code 56
    ```

4. Access via ingress

    ```
    export LB_IP=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    curl -kv --cacert ._temp_client_certs/rootCA.crt --cert ._temp_client_certs/client.testing.termination.internal.crt --key ._temp_client_certs/client.testing.termination.internal.key --resolve client.testing.termination.internal:10443:$LB_IP https://client.testing.termination.internal:10443/headers
    ```
    
    Which should result in,

    ```
    {
      "headers": {
        "Accept": "*/*",
        "Host": "client.testing.termination.internal:10443",
        "User-Agent": "curl/7.86.0",
        "X-Forwarded-Client-Cert": "Hash=2552f339fd26dd40d6979af021927c8fdb4fdfa48c991b1d705818433fc40a21;Subject=\"CN=client.testing.termination.internal,OU=Field Engineering,O=Solo.io,L=Boston,ST=New York,C=US\";URI=;DNS=client.testing.termination.internal"
      }
    }
    ```

5. Authorization policy to deny requests based on the authority header

    Apply the envoy filter with the authZ policy
    ```
    kubectl apply -f config/httpbin-envoy-filter-with-auth-policy.yaml
    ```

    Test with,
    ```
    export LB_IP=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    curl -kv --cacert ._temp_client_certs/rootCA.crt --cert ._temp_client_certs/client.testing.termination.internal.crt --key ._temp_client_certs/client.testing.termination.internal.key --resolve client.testing.termination.internal:10443:$LB_IP https://client.testing.termination.internal:10443/headers
    ```

    Results in,
    ```
    RBAC: access denied
    ```