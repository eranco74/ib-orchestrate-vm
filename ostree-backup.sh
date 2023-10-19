#!/bin/bash

set -e # Halt on error

seed_image=${1:-$SEED_IMAGE}
my_dir=$(dirname $(readlink -f $0))

# Collect info about the booted deployment
booted_osname=$(rpm-ostree status -v --json | jq -r '.deployments[] | select(.booted == true) | .osname')
booted_id=$(rpm-ostree status -v --json | jq -r '.deployments[] | select(.booted == true) | .id')

# rpm-ostree status returns the id of a deployment in the form staterootname-id
# since we just want the id itself, we get the string at the right of the last - character
# Example:
# booted_id=rhcos-1.2.3-7750be6eca55a9a8cfd324b1099361c656dd8996cbe7938bcd51156520699db0.0
# booted_deployment=7750be6eca55a9a8cfd324b1099361c656dd8996cbe7938bcd51156520699db0.0
booted_deployment=${booted_id/*-}

export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/lb-ext.kubeconfig

log_it(){
    echo "$@" | tr "[:print:]" -
    echo "$@"
    echo "$@" | tr "[:print:]" -
}

if [[ -z "$seed_image" ]]; then
    echo "ERROR. Seed image is empty"
    exit 1
fi

log_it "Saving list of running containers and clusterversion"
if [[ ! -f /tmp/container_list.done ]]; then
    mkdir -p /var/tmp/backup
    crictl images -o json | jq -r '.images[] | .repoDigests[], .repoTags[]' > /var/tmp/backup/containers.list
    oc get catalogsource -A -ojson | jq -r .items[].spec.image > /var/tmp/backup/catalogimages.list
    oc get clusterversion version -ojson > /var/tmp/backup/clusterversion.json
    touch /tmp/container_list.done
else
    echo "Container list already exists"
fi

log_it "Stopping kubelet"
systemctl stop kubelet

log_it "Stopping containers"
if systemctl is-active --quiet crio; then
    while crictl ps -q | grep -q .; do 
        crictl ps -q | xargs --no-run-if-empty --max-args 1 --max-procs 10 crictl stop --timeout 5 || true
    done
    log_it "Stopping crio"
    systemctl stop crio
else
    echo "CRI-O already not running"
fi

log_it "Creating backup datadir"
if [[ ! -f /var/tmp/backup/var.tgz ]]; then
    tar czf /var/tmp/backup/var.tgz \
        --exclude='/var/tmp/*' \
        --exclude='/var/lib/log/*' \
        --exclude='/var/log/*' \
        --exclude='/var/lib/containers/*' \
        --exclude='/var/lib/kubelet/pods/*' \
        --exclude='/var/lib/cni/bin/*' \
        --selinux \
        /var
else
    echo "Skipping var backup as it already exists"
fi

if [[ ! -f /var/tmp/backup/etc.tgz ]]; then
    ostree admin config-diff | awk '/^D/ {print "/etc/" $2}' > /var/tmp/backup/etc.deletions
    ostree admin config-diff | awk '!/^D/ {print "/etc/" $2}' | xargs tar czf /var/tmp/backup/etc.tgz --selinux
else
    echo "Skipping etc backup as it already exists"
fi

if [[ ! -f /var/tmp/backup/ostree.tgz ]]; then
    tar czf /var/tmp/backup/ostree.tgz --selinux -C /ostree/repo .
else
    echo "Skipping ostree backup as it already exists"
fi

if [[ ! -f /var/tmp/backup/rpm-ostree.json ]]; then
    rpm-ostree status -v --json > /var/tmp/backup/rpm-ostree.json
else
    echo "Skipping rpm-ostree backup as it already exists"
fi

if [[ ! -f /var/tmp/backup/mco-currentconfig.json ]]; then
    cp /etc/machine-config-daemon/currentconfig /var/tmp/backup/mco-currentconfig.json
else
    echo "Skipping currentconfig backup as it already exists"
fi

if [[ ! -f /var/tmp/backup/ostree-${booted_deployment}.origin ]]; then
    cp /ostree/deploy/${booted_osname}/deploy/${booted_deployment}.origin /var/tmp/backup/ostree-${booted_deployment}.origin
else
    echo "Skipping ostree deployment origin backup as it already exists"
fi

log_it "Creating backup container image"
# Build the single image (note: We could include --squash-all option, as well)
cat <<EOF | podman build -f - -t ${seed_image} /var/tmp/backup
FROM scratch
COPY . /
EOF

log_it "Pushing backup container image to remote registry"
podman push --authfile "$my_dir/backup-secret.json" ${seed_image}
