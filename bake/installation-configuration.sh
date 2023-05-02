#!/usr/bin/env bash
set -euoE pipefail ## -E option will cause functions to inherit trap

echo "Reconfiguring single node OpenShift"

CONFIGURATION_FILE=/opt/openshift/site-config.env
echo "Waiting for ${CONFIGURATION_FILE}"
while [ ! -e ${CONFIGURATION_FILE} ]
do
  sleep 5
done

echo "${CONFIGURATION_FILE} has been created"

set -o allexport
source ${CONFIGURATION_FILE}
set +o allexport


if [ -z ${CLUSTER_NAME+x} ]; then
	echo "Please set CLUSTER_NAME"
	exit 1
fi

if [ -z ${BASE_DOMAIN+x} ]; then
	echo "Please set BASE_DOMAIN"
	exit 1
fi

# TODO: Update hostname
# TODO: update IP address, machine network
# TODO: Regenerate/update certificates

echo "Starting kubelet"
systemctl start kubelet

#TODO: we need to add kubeconfig to the node for the configuration stage
export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig
function wait_for_api {
  echo "Waiting for api ..."
  until oc get clusterversion &> /dev/null
  do
    echo "Waiting for api ..."
    sleep 5
  done
  echo "api is available"
}

wait_for_api

# Reconfigure DNS

create_cert(){
  if [ ! -f $1.done ]
  then
    openssl req -newkey rsa:2048 -new -nodes -x509 -days 3650 -keyout key-$1.pem -out cert-$1.pem \
    -subj "/CN=$2" -addext "subjectAltName = DNS:$2"

    oc create secret tls $1-tls --cert=cert-$1.pem --key=key-$1.pem -n openshift-config
    touch $1.done
  fi
}

create_cert "console" "console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
create_cert "oauth" "oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
create_cert "api" "api.${CLUSTER_NAME}.${BASE_DOMAIN}"

echo "Update ingress"
envsubst << "EOF" >> domain.patch
spec:
  componentRoutes:
  - hostname: console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
    name: console
    namespace: openshift-console
    servingCertKeyPairSecret:
      name: console-tls
  - hostname: oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
    name: oauth-openshift
    namespace: openshift-authentication
    servingCertKeyPairSecret:
      name: oauth-tls
  domain: apps.${CLUSTER_NAME}.${BASE_DOMAIN}
EOF

oc patch ingress.config.openshift.io cluster --patch-file domain.patch --type merge

# TODO: check that curl to the new DNS works
# TODO: change all routes already created with the default domain

echo "Update API"
# Patch the apiserver
envsubst << "EOF" >> api.patch
spec:
  servingCerts:
    namedCertificates:
    - names:
      - api.${CLUSTER_NAME}.${BASE_DOMAIN}
      servingCertificate:
        name: api-tls
EOF

oc patch apiserver cluster --patch-file api.patch --type=merge

# TODO: check that API got updated
# TODO: Update pullSecret
# TODO: Update ssh-key
# TODO: update ICSP(s)

rm -rf /opt/openshift
systemctl disable image-base-configuration.service
systemctl enable kubelet
