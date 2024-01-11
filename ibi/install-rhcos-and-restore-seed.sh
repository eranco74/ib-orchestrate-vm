#!/bin/bash

set -e # Halt on error

seed_image=${1:-$SEED_IMAGE}
installation_disk=${2:-$INSTALLATION_DISK}

coreos-installer install ${installation_disk}

# We need to grow the partition. Coreos-installer leaves a small partition
growpart ${installation_disk} 4
mount ${installation_disk}4 /mnt
mount ${installation_disk}3 /mnt/boot
xfs_growfs ${installation_disk}4

# Creating shared /var/lib/containers and configuring local crio to use it
if lsattr -d /mnt/ | cut -d ' ' -f 1 | grep i; then
    chattr -i /mnt/
    mkdir -p /mnt/sysroot/containers
    chattr +i /mnt/
else
    mkdir -p /mnt/sysroot/containers
fi
mount -o bind /mnt/sysroot/containers /var/lib/containers

# Configure CRIO to use our local pull secret
mkdir -p /etc/crio/crio.conf.d
cat << EOF > /etc/crio/crio.conf.d/auth
[crio.image]
global_auth_file = "/var/tmp/pull-secret.json"
EOF

systemctl start crio

# To be changed when ibi-seed-install binary is created
/usr/local/bin/ostree-restore.sh $seed_image
