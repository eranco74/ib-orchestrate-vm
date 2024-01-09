#!/bin/bash

set -e # Halt on error

SKIP_PRECACHE="${SKIP_PRECACHE:-no}"

seed_image=${1:-$SEED_IMAGE}
my_dir=$(dirname $(readlink -f $0))

log_it(){
    echo $@ | tr [:print:] -
    echo $@
    echo $@ | tr [:print:] -
}

build_kargs(){
    local karg
    jq -r '.spec.kernelArguments[]' ${img_mnt}/mco-currentconfig.json \
        | while IFS= read -r line; do
            echo -n "--karg-append $line "
        done
}

shared_container_storage(){
    shared_containers_dir=/sysroot/containers
    if [ -d "${shared_containers_dir}" ]; then
        # Container storage is shared via bind-mount method
        return 0
    elif [ "$(stat -c %d /sysroot)" != "$(stat -c %d /var/lib/containers)" ]; then
        # Container storage is on a separate partition from /sysroot
        return 0
    fi

    return 1
}

if [[ -z "$seed_image" ]]; then
    echo "ERROR. Seed image is empty"
    exit 1
fi

# mount /sysroot -o remount,rw

# Import OCIs
log_it "Pulling and mounting backup OCI"
podman pull --authfile="/var/tmp/backup-secret.json" ${seed_image}
img_mnt=$(podman image mount ${seed_image})

# Collect seed deployment data from the backup
upg_booted_id=$(jq -r '.deployments[] | select(.booted == true) | .id' ${img_mnt}/rpm-ostree.json)
upg_booted_deployment=${upg_booted_id/*-}
upg_booted_ref=${upg_booted_deployment/\.*}

up_ver=$(jq -r '.version' ${img_mnt}/manifest.json)
new_osname=rhcos_${up_ver}

ostree_repo=$(mktemp -d -p /mnt/ostree/deploy/rhcos/var/tmp)

tar xzf $img_mnt/ostree.tgz --selinux -C $ostree_repo

# We need to adjust to the mounted disk ostree repo path
log_it "Importing remote ostree"
ostree pull-local --repo /mnt/ostree/repo $ostree_repo
ostree admin os-init --sysroot /mnt $new_osname

log_it "Creating new deployment $new_osname"
# We should create the new deploy as not-default, and after the whole process is done, be able to switch to it for the next reboot
# ostree admin deploy --os ${new_osname} $(build_kargs) --not-as-default ${upg_booted_ref}
# Until I find how to do the switch, I'll deploy as default

ostree admin deploy --sysroot /mnt --os ${new_osname} $(build_kargs) ${upg_booted_ref}
ostree_deploy=$(ostree admin status --sysroot /mnt | awk /$new_osname/'{print $2}')

# Restore the seed .origin file
cp ${img_mnt}/ostree-${upg_booted_deployment}.origin /mnt/ostree/deploy/$new_osname/deploy/$ostree_deploy.origin

log_it "Restoring /var"
tar xzf ${img_mnt}/var.tgz -C /mnt/ostree/deploy/$new_osname --selinux

log_it "Restoring /etc"
tar xzf ${img_mnt}/etc.tgz -C /mnt/ostree/deploy/$new_osname/deploy/$ostree_deploy --selinux

log_it "Removing /etc deletions"
cat ${img_mnt}/etc.deletions | xargs --no-run-if-empty -ifile rm -f /mnt/ostree/deploy/$new_osname/deploy/$ostree_deploy/file

log_it "Precaching container images"
xargs --no-run-if-empty --max-args 1 --max-procs 10 crictl pull < ${img_mnt}/containers.list

# log_it "Unpacking certificates to be used by recert"
# certs_dir=/mnt/ostree/deploy/$new_osname/var/opt/openshift/certs
# mkdir -p $certs_dir
# tar xpvzf /tmp/certs.tgz -C $certs_dir

log_it "Unmounting and deleting backup container image"
# umount /mnt
podman image unmount ${seed_image}
podman rmi ${seed_image}
rm -fr $ostree_repo
log_it "DONE. Be sure to attach the relocation site info to the host and you can reboot the node"
