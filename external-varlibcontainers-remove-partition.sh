#!/bin/bash

VM_NAME=${VM_NAME:-sno-test}
BASE_IMAGE_PATH_SNO=${BASE_IMAGE_PATH_SNO:-/var/lib/libvirt/images/${VM_NAME}.qcow2}

qemu-nbd --connect /dev/nbd0 ${BASE_IMAGE_PATH_SNO}
echo "d_5_w_y"| tr _ \\n | gdisk /dev/nbd0
qemu-nbd --disconnect /dev/nbd0
qemu-img resize --shrink ${BASE_IMAGE_PATH_SNO} -50G
qemu-nbd --connect /dev/nbd0 ${BASE_IMAGE_PATH_SNO}
sgdisk -e /dev/nbd0
qemu-nbd --disconnect /dev/nbd0
