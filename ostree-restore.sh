#!/bin/bash

new_osname=javipolo
backup_repo=${BACKUP_REPO:-quay.io/jpolo/ostmagic}
backup_tag=backup
backup_refspec=$backup_repo:$backup_tag

log_it(){
    echo $@ | tr [:print:] -
    echo $@
    echo $@ | tr [:print:] -
}

mount /sysroot -o remount,rw

# Import OCIs
log_it Importing backup OCI
cp backup-secret.json /etc/ostree/auth.json
ostree container unencapsulate --repo /ostree/repo ostree-unverified-registry:$backup_refspec --write-ref backup

# Get base_container from rpm-ostree status of donor
base_container=$(ostree cat backup /rpm-ostree.status | awk '/ostree-unverified-registry/{print $NF}')

log_it Importing base OCI
cp pull-secret.json /etc/ostree/auth.json
ostree container unencapsulate --repo /ostree/repo $base_container --write-ref base

ostree admin os-init $new_osname
log_it Deploying new stateroot
ostree admin deploy --retain --os $new_osname base
ostree_deploy=$(ostree admin status |awk /$new_osname/'{print $2}')

log_it Restoring /var
ostree cat backup /var.tgz | tar xzC /ostree/deploy/$new_osname --selinux

log_it Restoring /etc
ostree cat backup /etc.tgz | tar xzC /ostree/deploy/$new_osname/deploy/$ostree_deploy

log_it DONE. You can reboot into the restored system
