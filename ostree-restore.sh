#!/bin/bash

set -e # Halt on error

new_osname=ibu
backup_repo=${1:-$BACKUP_REPO}
backup_tag=backup
base_tag=base
parent_tag=parent
backup_refspec=$backup_repo:$backup_tag
base_refspec=$backup_repo:$base_tag
parent_refspec=$backup_repo:$parent_tag
export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/lb-ext.kubeconfig
shared_containers_dir=/sysroot/containers
my_dir=$(dirname $(readlink -f $0))

log_it(){
    echo $@ | tr [:print:] -
    echo $@
    echo $@ | tr [:print:] -
}

build_kargs(){
    local karg
    ostree cat $backup_tag /mco-currentconfig.json \
        | jq -r '.spec.kernelArguments[]' \
        | xargs --no-run-if-empty -I% echo -n "--karg % "
}

build_catalog_regex(){
    if ostree cat $backup_tag catalogimages.list | grep -q .; then
        for i in $(ostree cat $backup_tag catalogimages.list | cut -d : -f 1 ); do
            echo $i:
            echo $i@
        done \
            | paste -sd\|
    fi
}

podman_unencapsulate(){
  local image=$1
  local ref=$2
  local credentials=$3
  if ! ostree rev-parse $ref >/dev/null 2>/dev/null; then
      podman pull --authfile $credentials $image
      ostree container unencapsulate --repo /ostree/repo ostree-unverified-image:containers-storage:$image --write-ref $ref
      podman rmi $image
  else
      echo "Ref $ref already exists, skipping unencapsulate"
  fi
}

if [[ -z "$backup_repo" ]]; then
    echo "ERROR. Backup repo is empty"
    exit 1
fi

mount /sysroot -o remount,rw

# Import OCIs
log_it "Importing backup OCI"
# Authentication is not working properly with unencapsulate
# Will be fixed with https://github.com/ostreedev/ostree-rs-ext/pull/519
# Until now, we will pull with podman and unencapsulate from local registry
# ostree container unencapsulate --authfile "$my_dir/backup-secret.json" --repo /ostree/repo ostree-unverified-registry:$backup_refspec --write-ref $backup_tag
podman_unencapsulate $backup_refspec $backup_tag "$my_dir/backup-secret.json"

# If there's a parent to that commit, import it
if [[ "$(ostree cat $backup_tag /rpm-ostree.json | jq -r '.deployments[] | select(.booted == true)| has("base-checksum")')" == "true" ]]; then
    log_it "Parent commit found for base, importing OCI"
    # ostree container unencapsulate --authfile "$my_dir/backup-secret.json" --repo /ostree/repo ostree-unverified-registry:$parent_refspec --write-ref $parent_tag
    podman_unencapsulate $parent_refspec $parent_tag "$my_dir/backup-secret.json"
fi

log_it "Initializing and deploying new stateroot"
if rpm-ostree status -v --json | jq -e '[.deployments[] | select(.osname == "ibu")] | length == 0' > /dev/null; then
    ostree admin os-init $new_osname
else
    echo "Deployment already exists, skipping os-init"
fi
ostree container image deploy --sysroot / --stateroot $new_osname $(build_kargs) --authfile "$my_dir/backup-secret.json" --imgref ostree-unverified-registry:$base_refspec
ostree_deploy=$(ostree admin status | awk /$new_osname/'{print $2}')

# Workaround to fix deploy origin URL
log_it "Restoring original osImageURL to new stateroot origin"
original_osimage=$(ostree cat backup /mco-currentconfig.json | jq -r .spec.osImageURL)
sed -e "s%docker://.*%$original_osimage%g" -i /ostree/deploy/$new_osname/deploy/$ostree_deploy.origin


log_it "Restoring /var"
ostree cat $backup_tag /var.tgz | tar xzC /ostree/deploy/$new_osname --selinux

log_it "Restoring /etc"
ostree cat $backup_tag /etc.tgz | tar xzC /ostree/deploy/$new_osname/deploy/$ostree_deploy --selinux

log_it "Removing /etc deletions"
ostree cat $backup_tag /etc.deletions | xargs --no-run-if-empty -ifile rm -f /ostree/deploy/$new_osname/deploy/$ostree_deploy/file

log_it "Waiting for API"
until oc get clusterversion 2>/dev/null >/dev/null; do
    sleep 5
done

log_it "Backing up certificates to be used by recert"
certs_dir=/ostree/deploy/$new_osname/var/opt/openshift/certs
mkdir -p $certs_dir
oc extract -n openshift-config configmap/admin-kubeconfig-client-ca --keys=ca-bundle.crt --to=- > $certs_dir/admin-kubeconfig-client-ca.crt
for key in {loadbalancer,localhost,service-network}-serving-signer; do
    oc extract -n openshift-kube-apiserver-operator secret/$key --keys=tls.key --to=- > $certs_dir/$key.key
done
ingress_cn=$(oc extract -n openshift-ingress-operator secret/router-ca --keys=tls.crt --to=- | openssl x509 -subject -noout -nameopt multiline | awk '/commonName/{print $3}')
oc extract -n openshift-ingress-operator secret/router-ca --keys=tls.key --to=- > "$certs_dir/ingresskey-$ingress_cn"

# If we have a shared container directory, precache all running images + images from ocp release
if [[ -d "$shared_containers_dir" ]]; then
    log_it "Precaching non-catalog images"
    ostree cat $backup_tag /containers.list | grep -vE $(build_catalog_regex) | xargs --no-run-if-empty --max-args 1 --max-procs 10 crictl pull

    log_it "Precaching catalog images"
    if ostree cat $backup_tag catalogimages.list | grep -q .; then
        ostree cat $backup_tag catalogimages.list | xargs --no-run-if-empty --max-args 1 --max-procs 10 crictl pull
    fi
fi

log_it "DONE. Be sure to attach the relocation site info to the host (either via ISO or make copy-config) and you can reboot the node"
