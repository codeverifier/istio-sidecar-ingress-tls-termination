#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

temp_dir="$DIR/.temp_$(date +%Y%m%d_%H%M%S)"
mkdir -p $temp_dir

generate_cert() {
  # Generate Private key 
  openssl genrsa -out $temp_dir/${1}.key 2048

  # Create csf conf
  cat > $temp_dir/csr.conf <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[ dn ]
C = US
ST = New York
L = Boston
O = Solo.io
OU = Field Engineering
CN = ${1}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${1}
DNS.2 = www.${1}
EOF

  # Create CSR request using private key
  openssl req -new -key $temp_dir/${1}.key -out $temp_dir/${1}.csr -config $temp_dir/csr.conf

  # Create a external config file for the certificate
  cat > $temp_dir/cert.conf <<EOF

authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${1}

EOF

  # Create SSl with self signed CA
  openssl x509 -req \
      -in $temp_dir/${1}.csr \
      -CA $temp_dir/rootCA.crt -CAkey $temp_dir/rootCA.key \
      -set_serial 1 -out $temp_dir/${1}.crt \
      -days 365 \
      -sha256 -extfile $temp_dir/cert.conf
}

# Create root CA & Private key
openssl req -x509 \
            -sha256 -days 356 \
            -nodes \
            -newkey rsa:2048 \
            -subj "/CN=example.com/C=US/L=Boston" \
            -keyout $temp_dir/rootCA.key -out $temp_dir/rootCA.crt

generate_cert "httpbin.httpbin.svc.cluster.local"
generate_cert "client.httpbin.svc.cluster.local"
generate_cert "client.testing.termination.internal"

# Destructive // TODO Handle this better
kubectl -n httpbin delete secret httpbin-mtls-termination-cacert
kubectl -n httpbin delete secret httpbin-mtls-termination

kubectl -n httpbin create secret generic httpbin-mtls-termination-cacert --from-file=ca.crt=$temp_dir/rootCA.crt
kubectl -n httpbin create secret tls httpbin-mtls-termination --cert $temp_dir/httpbin.httpbin.svc.cluster.local.crt --key $temp_dir/httpbin.httpbin.svc.cluster.local.key

# Copy client certs
client_temp_dir="$DIR/.temp_client_certs"
mkdir -p "$client_temp_dir"
cp -f $temp_dir/rootCA.* $client_temp_dir/.
cp -f $temp_dir/client.httpbin.svc.cluster.local* $client_temp_dir/.
cp -f $temp_dir/client.testing.termination.internal* $client_temp_dir/.