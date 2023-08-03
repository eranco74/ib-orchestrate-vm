#!/bin/bash

KUBECONFIG=${KUBECONFIG:-./bootstrap-in-place-poc/sno-workdir/auth/kubeconfig}
export KUBECONFIG
VM_NAME=${VM_NAME:-sno-test}
BASE_IMAGE_PATH_SNO=${BASE_IMAGE_PATH_SNO:-/var/lib/libvirt/images/${VM_NAME}.qcow2}

virsh shutdown ${VM_NAME}
make wait-for-shutdown
qemu-img resize ${BASE_IMAGE_PATH_SNO} +50G
qemu-nbd --connect /dev/nbd0 ${BASE_IMAGE_PATH_SNO}
sgdisk -e /dev/nbd0
echo "n_p_5____w_y"| tr _ \\n | gdisk /dev/nbd0
mkfs.xfs /dev/nbd0p5
qemu-nbd --disconnect /dev/nbd0
virsh start ${VM_NAME}
make wait-for-install-complete
oc apply -f var-lib-containers-machineconfig.yaml

mc=98-var-lib-containers
until oc get mcp master -ojson | jq -r .status.configuration.source[].name | grep -xq ${mc}; do
  echo "Waiting for ${mc} to be present in running rendered-master MachineConfig"
  sleep 15
done

oc wait --timeout=20m --for=condition=updated=true mcp master
