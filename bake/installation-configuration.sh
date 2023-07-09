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

# Recertify
sleep 30 # TODO: wait for weird network DHCP/DNS issue to resolve
RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release:4.13.0-x86_64
ETCD_IMAGE="$(oc adm release extract --from="$RELEASE_IMAGE" --file=image-references | jq '.spec.tags[] | select(.name == "etcd").from.name' -r)"
RECERT_IMAGE="quay.io/otuchfel/recert:latest"
sudo podman run --authfile=/var/lib/kubelet/config.json --name recert_etcd --detach --rm --network=host --privileged --entrypoint etcd -v /var/lib/etcd:/store ${ETCD_IMAGE} --name editor --data-dir /store
sleep 10 # TODO: wait for etcd
sudo podman run -it --network=host --privileged -v /etc/kubernetes:/kubernetes -v /var/lib/kubelet:/kubelet -v /etc/machine-config-daemon:/machine-config-daemon ${RECERT_IMAGE} \
    --etcd-endpoint localhost:2379 \
    --static-dir /kubernetes \
    --static-dir /kubelet \
    --static-dir /machine-config-daemon \
    --cn-san-replace "api-int.$PROTO_CLUSTER_NAME.$PROTO_CLUSTER_BASE_DOMAIN api-int.$CLUSTER_NAME.$BASE_DOMAIN" \
    --cn-san-replace "api.$PROTO_CLUSTER_NAME.$PROTO_CLUSTER_BASE_DOMAIN api.$CLUSTER_NAME.$BASE_DOMAIN" \
    --cn-san-replace "*.apps.$PROTO_CLUSTER_NAME.$PROTO_CLUSTER_BASE_DOMAIN *.apps.$CLUSTER_NAME.$BASE_DOMAIN" \
    --cn-san-replace "*.apps.$PROTO_CLUSTER_NAME.$PROTO_CLUSTER_BASE_DOMAIN *.apps.$CLUSTER_NAME.$BASE_DOMAIN" \
	--cluster-rename new-name,foo.com

sudo podman kill recert_etcd

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

export SITE_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"
export API_DOMAIN="api.${SITE_DOMAIN}"
export APPS_DOMAIN="apps.${SITE_DOMAIN}"
export CONSOLE_DOMAIN="console-openshift-console.${APPS_DOMAIN}"
export DOWNLOADS_DOMAIN="downloads-openshift-console.${APPS_DOMAIN}"
export OAUTH_DOMAIN="oauth-openshift.${APPS_DOMAIN}"

echo "Update API"

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
