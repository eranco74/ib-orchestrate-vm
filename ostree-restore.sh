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
ostree container unencapsulate --repo /ostree/repo ostree-unverified-registry:$backup_refspec | tee /tmp/unencapsulate.backup
ostree refs --create backup $(cut -d ' ' -f 2 < /tmp/unencapsulate.backup)

# Get base_container from rpm-ostree status of donor
base_container=$(ostree cat backup /rpm-ostree.status | awk '/ostree-unverified-registry/{print $NF}')

log_it Importing base OCI
cp pull-secret.json /etc/ostree/auth.json
ostree container unencapsulate --repo /ostree/repo $base_container | tee /tmp/unencapsulate.base
ostree refs --create base $(cut -d ' ' -f 2 < /tmp/unencapsulate.base)

ostree admin os-init $new_osname
log_it Deploying new stateroot
ostree admin deploy --retain --os $new_osname base
ostree_deploy=$(ostree admin status |awk /$new_osname/'{print $2}')
log_it Restoring /var
ostree cat backup /var.tgz | tar xzC /ostree/deploy/$new_osname --selinux

log_it Restoring /etc
ostree cat backup /etc.tgz | tar xzC /ostree/deploy/$new_osname/deploy/$ostree_deploy

log_it Changing grub configuration
mount -o remount,rw /boot
boot_hash=$(ls -d /ostree/boot.1/$new_osname/* | xargs basename)
kernel_dir=$new_osname-$boot_hash
base_modules_dir=/ostree/deploy/$new_osname/deploy/$ostree_deploy/usr/lib/modules
kernel_version=$(ls $base_modules_dir)
base_kernel_dir=$base_modules_dir/$kernel_version

kernel=vmlinuz-$kernel_version
initrd=initramfs-$kernel_version.img

mkdir -p /boot/ostree/$kernel_dir
cp $base_kernel_dir/vmlinuz /boot/ostree/$kernel_dir/$kernel
cp $base_kernel_dir/initramfs.img /boot/ostree/$kernel_dir/$initrd

new_ostree=$(ls -d /ostree/boot.1/$new_osname/$boot_hash/*)
sed -ie 's%ostree=.* %ostree='$new_ostree' %g' /boot/loader/entries/ostree-1-rhcos.conf
sed -ie 's%^linux .*%linux '/ostree/$kernel_dir/$kernel'%g' /boot/loader/entries/ostree-1-rhcos.conf
sed -ie 's%^initrd .*%initrd '/ostree/$kernel_dir/$initrd'%g' /boot/loader/entries/ostree-1-rhcos.conf

log_it DONE. You can reboot into the restored system
