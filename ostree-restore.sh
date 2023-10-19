#!/bin/bash

set -e # Halt on error

seed_image=${1:-$SEED_IMAGE}
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
    jq -r '.spec.kernelArguments[]' ${img_mnt}/mco-currentconfig.json \
        | xargs --no-run-if-empty -I% echo -n "--karg-append % "
}

build_catalog_regex(){
    if grep -q . ${img_mnt}/catalogimages.list; then
        for i in $(cat ${img_mnt}/catalogimages.list | cut -d : -f 1 ); do
            echo $i:
            echo $i@
        done \
            | paste -sd\|
    fi
}

if [[ -z "$seed_image" ]]; then
    echo "ERROR. Seed image is empty"
    exit 1
fi

mount /sysroot -o remount,rw

# Import OCIs
log_it "Pulling and mounting backup OCI"
podman pull --authfile="$my_dir/backup-secret.json" ${seed_image}
img_mnt=$(podman image mount ${seed_image})

ostree_repo=$(mktemp -d -p /var/tmp)

tar xzf $img_mnt/ostree.tgz --selinux -C $ostree_repo

# Collect seed deployment data from the backup
upg_booted_id=$(jq -r '.deployments[] | select(.booted == true) | .id' ${img_mnt}/rpm-ostree.json)
upg_booted_deployment=${upg_booted_id/*-}
upg_booted_ref=${upg_booted_deployment/\.*}

up_ver=$(jq -r '.status.desired.version' ${img_mnt}/clusterversion.json)
new_osname=rhcos_${up_ver}

log_it "Importing remote ostree"
ostree pull-local $ostree_repo
ostree admin os-init $new_osname

log_it "Creating new deployment $new_osname"
# We should create the new deploy as not-default, and after the whole process is done, be able to switch to it for the next reboot
# ostree admin deploy --os ${new_osname} $(build_kargs) --not-as-default ${upg_booted_ref}
# Until I find how to do the switch, I'll deploy as default
ostree admin deploy --os ${new_osname} $(build_kargs) ${upg_booted_ref}
ostree_deploy=$(ostree admin status | awk /$new_osname/'{print $2}')

# Restore the seed .origin file
cp ${img_mnt}/ostree-${upg_booted_deployment}.origin /ostree/deploy/$new_osname/deploy/$ostree_deploy.origin

log_it "Restoring /var"
tar xzf ${img_mnt}/var.tgz -C /ostree/deploy/$new_osname --selinux

log_it "Restoring /etc"
tar xzf ${img_mnt}/etc.tgz -C /ostree/deploy/$new_osname/deploy/$ostree_deploy --selinux

log_it "Removing /etc deletions"
ostree cat $backup_tag /etc.deletions | xargs --no-run-if-empty -ifile rm -f /ostree/deploy/$new_osname/deploy/$ostree_deploy/file

log_it "Waiting for API"
until oc get clusterversion &>/dev/null; do
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
    grep -vE $(build_catalog_regex) ${img_mnt}/containers.list | xargs --no-run-if-empty --max-args 1 --max-procs 10 crictl pull

    log_it "Precaching catalog images"
    if grep -q . ${img_mnt}/catalogimages.list; then
       cat ${img_mnt}/catalogimages.list | xargs --no-run-if-empty --max-args 1 --max-procs 10 crictl pull
    fi
fi

log_it "Unmounting and deleting backup container image"
podman image unmount ${seed_image}
podman rmi ${seed_image}
rm -fr $ostree_repo
log_it "DONE. Be sure to attach the relocation site info to the host (either via ISO or make copy-config) and you can reboot the node"
