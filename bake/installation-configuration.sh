#!/usr/bin/env bash
set -euoE pipefail ## -E option will cause functions to inherit trap

echo "Reconfiguring single node OpenShift"

mkdir -p /opt/openshift
cd /opt/openshift

function mount_config {
  echo "Mounting config iso"
  mkdir -p /mnt/config
  if ! mountpoint --quiet /var/mnt/config; then
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
  cp /mnt/config/site-config.env ${CONFIGURATION_FILE}
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
}

SITE_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"
API_DOMAIN="api.${SITE_DOMAIN}"
APPS_DOMAIN="apps.${SITE_DOMAIN}"
CONSOLE_DOMAIN="console-openshift-console.${APPS_DOMAIN}"
DOWNLOADS_DOMAIN="downloads-openshift-console.${APPS_DOMAIN}"
OAUTH_DOMAIN="oauth-openshift.${APPS_DOMAIN}"

echo "Update API"
create_cert "api" "${API_DOMAIN}"

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
wait_for_cert "${APPS_CERT_FILE_PATH}" "${CONSOLE_DOMAIN}" 443

echo "Re-configuring existing Routes"
# They will get delete existing routes, they will get recreated by the
oc delete routes --field-selector metadata.namespace!=openshift-console,metadata.namespace!=openshift-authentication -A

# TODO: Update ssh-key?

# TODO: should we verify the pull secret is valid? how?
if [ -z ${PULL_SECRET+x} ]; then
	echo "PULL_SECRET not defined"
else
  echo "Overriding PULL_SECRET"
  echo "$PULL_SECRET" > ps.json
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=ps.json
fi
# If we want to create additional pull secret
# oc create secret -n openshift-config generic foo-secret --type=kubernetes.io/dockerconfigjson -from-file=.dockerconfigjson=ps.json


# TODO: Update ssh-key
# TODO: update ICSP(s)

rm -rf /opt/openshift
systemctl enable kubelet
systemctl disable installation-configuration.service
if [[ -n ${DEVICE+x} ]]; then
  umount_config "${DEVICE}"
fi
