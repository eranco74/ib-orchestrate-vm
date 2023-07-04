#!/usr/bin/env bash
set -euoE pipefail ## -E option will cause functions to inherit trap

echo "Reconfiguring single node OpenShift"

mkdir -p /opt/openshift
cd /opt/openshift

function mount_config {
  echo "Mounting config iso"
  mkdir -p /mnt/config
  if ! mountpoint --quiet /mnt/config; then
      mount "/dev/$1" /mnt/config
  fi
  ls /mnt/config
}

function umount_config {
  echo "Unmounting config iso"
  umount /dev/$1
  rm -rf /mnt/config
}

CONFIGURATION_FILE=/opt/openshift/site-config.env
echo "Waiting for ${CONFIGURATION_FILE}"
while [[ ! $(lsblk -f --json | jq -r '.blockdevices[] | select(.label == "ZTC SNO") | .name') && ! -f /opt/openshift/site-config.env ]];
do
  echo "Waiting for site-config"
  sleep 5
done

DEVICE=$(lsblk -f --json | jq -r '.blockdevices[] | select(.label == "ZTC SNO") | .name')
if [[ -n ${DEVICE+x} ]]; then
  mount_config "${DEVICE}"
  cp -r /mnt/config/* $(dirname ${CONFIGURATION_FILE})
fi

if [ ! -f "${CONFIGURATION_FILE}" ]; then
  echo "Failed to find configuration file at ${CONFIGURATION_FILE}"
  exit 1
fi

echo "${CONFIGURATION_FILE} has been created"
# Replace this with a function that loads values from yaml file
set -o allexport
source "${CONFIGURATION_FILE}"
set +o allexport


if [ -z ${CLUSTER_NAME+x} ]; then
	echo "Please set CLUSTER_NAME"
	exit 1
fi

if [ -z ${BASE_DOMAIN+x} ]; then
	echo "Please set BASE_DOMAIN"
	exit 1
fi

# TODO: update IP address, machine network

if ls /opt/openshift/*.nmconnection 1> /dev/null 2>&1; then
    echo "Static network configuration exist"
    cp /opt/openshift/*.nmconnection /etc/NetworkManager/system-connections/ -f
    systemctl restart NetworkManager
    # TODO: we might need to delete the connection first
else
    echo "Static network configuration do not exist"
fi

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

wait_approve_csr() {
  local name=${1}

  echo "Waiting for ${name} CSR..."
  until oc get csr | grep -i "${name}" | grep -i "pending" &> /dev/null
  do
    echo "Waiting for ${name} CSR..."
    sleep 5
  done
  echo "CSR ${name} is ready for approval"

  echo "Approving all pending CSRs..."
  oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs oc adm certificate approve
}

# if hostname has changed
if [[ "$(oc get nodes -ojsonpath='{.items[0].metadata.name}')" != "$(hostname)" ]]
then
  wait_approve_csr "kube-apiserver-client-kubelet"
  wait_approve_csr "kubelet-serving"

  echo "Deleting previous node..."
  oc delete node "$(oc get nodes -ojsonpath='{.items[?(@.metadata.name != "'"$(hostname)"'"].metadata.name}')"
fi

# Reconfigure DNS
node_ip=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type == "InternalIP")].address}')

echo "Updating dnsmasq with new domain"
cat << EOF > /etc/dnsmasq.d/customer-domain.conf
address=/apps.${CLUSTER_NAME}.${BASE_DOMAIN}/${node_ip}
address=/api-int.${CLUSTER_NAME}.${BASE_DOMAIN}/${node_ip}
address=/api.${CLUSTER_NAME}.${BASE_DOMAIN}/${node_ip}
EOF
systemctl restart dnsmasq

create_cert(){
  local secret_name=${1}
  local domain_name=${2}
  local namespace=${3:-"openshift-config"}

  if [ ! -f $secret_name.done ]
  then
    echo "Creating new cert for $domain_name"
    openssl req -newkey rsa:2048 -new -nodes -x509 -days 3650 -keyout /tmp/key-"${secret_name}".pem -out /tmp/cert-"${secret_name}".pem \
    -subj "/CN=${domain_name}" -addext "subjectAltName = DNS:${domain_name}"
    touch "${secret_name}".done
  fi
  oc create secret tls "${secret_name}"-tls --cert=/tmp/cert-"${secret_name}".pem --key=/tmp/key-"${secret_name}".pem -n $namespace --dry-run=client -o yaml | oc apply -f -
}

wait_for_cert() {
    NEW_CERT=$(cat "${1}")
    echo "Waiting for ${2} cert to get updated"
    SERVER_CERT=$(echo | timeout 5 openssl s_client -showcerts -connect "${2}":"${3}" 2>/dev/null | openssl x509 || true)
    until [[ "${NEW_CERT}" == "${SERVER_CERT}" ]]
    do
        sleep 10
        SERVER_CERT=$(echo | timeout 5 openssl s_client -showcerts -connect "${2}":"${3}" 2>/dev/null | openssl x509 || true)
    done
    echo "${2} cert updated successfully"
}

export SITE_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"
export API_DOMAIN="api.${SITE_DOMAIN}"
export APPS_DOMAIN="apps.${SITE_DOMAIN}"
export CONSOLE_DOMAIN="console-openshift-console.${APPS_DOMAIN}"
export DOWNLOADS_DOMAIN="downloads-openshift-console.${APPS_DOMAIN}"
export OAUTH_DOMAIN="oauth-openshift.${APPS_DOMAIN}"

echo "Update API"
create_cert "api" "${API_DOMAIN}"

# Patch the apiserver
envsubst << "EOF" >> api.patch
spec:
  servingCerts:
    namedCertificates:
    - names:
      - ${API_DOMAIN}
      servingCertificate:
        name: api-tls
EOF

oc patch apiserver cluster --patch-file api.patch --type=merge

# TODO: check that API got updated
wait_for_cert /tmp/cert-api.pem "${API_DOMAIN}" 6443

create_cert "apps" "*.${APPS_DOMAIN}"
create_cert "apps" "*.${APPS_DOMAIN}" openshift-ingress

echo "Update ingress"
envsubst << "EOF" >> domain.patch
spec:
  appsDomain: ${APPS_DOMAIN}
  componentRoutes:
  - hostname: ${CONSOLE_DOMAIN}
    name: console
    namespace: openshift-console
    servingCertKeyPairSecret:
      name: apps-tls
  - hostname: ${DOWNLOADS_DOMAIN}
    name: downloads
    namespace: openshift-console
    servingCertKeyPairSecret:
      name: apps-tls
  - hostname: ${OAUTH_DOMAIN}
    name: oauth-openshift
    namespace: openshift-authentication
    servingCertKeyPairSecret:
      name: apps-tls
EOF

oc patch ingress.config.openshift.io cluster --patch-file domain.patch --type merge
wait_for_cert /tmp/cert-apps.pem "${CONSOLE_DOMAIN}" 443

echo "Re-configuring existing Routes"
# They will get delete existing routes, they will get recreated by the
oc delete routes --field-selector metadata.namespace!=openshift-console,metadata.namespace!=openshift-authentication -A

# TODO: Update ssh-key?

echo "Configure cluster registry"
# see https://docs.openshift.com/container-platform/4.12/post_installation_configuration/connected-to-disconnected.html#connected-to-disconnected-config-registry_connected-to-disconnected
# we need to do 4 things:
# Create a ConfigMap with the certificate for the registry
# Reference that ConfigMap in image.config.openshift.io/cluster (spec/additionalTrustedCA)
# Update the cluster pull-secret
# Create an ImageContentSourcePolicy
# TODO validate we have all required fields
# TODO: should we verify the pull secret is valid? how?
if [ -z ${PULL_SECRET+x} ]; then
	echo "PULL_SECRET not defined"
else
  echo 'Updating cluster-wide pull secret'
  echo "${PULL_SECRET}" > ps.json
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=ps.json
fi

if [ -z ${REGISTRY_CA+x} ]; then
	echo "REGISTRY_CA not defined"
else
  echo 'Creating ConfigMap with registry certificate'
  echo "${REGISTRY_CA}" > ps.json
  oc create configmap edge-registry-config --from-file="edge-registry-ca.crt" -n openshift-config --dry-run=client -o yaml | oc apply -f -

  echo 'Adding certificate to image.config additionalTrustedCA'
  oc patch image.config.openshift.io/cluster --patch '{"spec":{"additionalTrustedCA":{"name":"edge-registry-config"}}}' --type=merge
fi

if [ -z ${ICSP+x} ]; then
	echo "ICSP not defined"
else
  echo 'Creating ImageContentSourcePolicy'
  echo "${ICSP}" > icsp.json
  oc apply -f iscp.yaml
fi

rm -rf /opt/openshift
systemctl enable kubelet
systemctl disable installation-configuration.service
if [[ -n ${DEVICE+x} ]]; then
  umount_config "${DEVICE}"
fi
