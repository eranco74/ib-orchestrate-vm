#!/bin/bash

set -e # Halt on error
set -x

do_clean(){
    rm -fr "$workdir"
}

trap do_clean EXIT

cert_subject=$1

workdir=$(mktemp -d)
oc extract -n openshift-kube-apiserver-operator secret/loadbalancer-serving-signer --to=$workdir >&2
openssl genpkey -algorithm RSA -out $workdir/new_key.pem

cat > $workdir/san.conf << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $cert_subject

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $cert_subject
EOF

openssl req -config $workdir/san.conf -new -key $workdir/new_key.pem -out $workdir/csr.pem
openssl x509 -req -days 3650 -in $workdir/csr.pem -CA $workdir/tls.crt -CAkey $workdir/tls.key -extensions v3_req -extfile $workdir/san.conf -set_serial 01 -out $workdir/new_cert.pem
oc create secret tls --key $workdir/new_key.pem --cert $workdir/new_cert.pem -n relocation new-api-certs --dry-run -ojson
