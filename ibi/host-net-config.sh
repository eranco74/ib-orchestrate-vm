#!/bin/bash

set -euxo pipefail

tmpfile=$(mktemp)
_cleanup(){
    rm -f $tmpfile
}
trap _cleanup exit

# Update libvirt dhcp configuration
if sudo virsh net-dumpxml $NET_NAME | grep -q "mac='$HOST_MAC'" ; then
    action=modify
else
    action=add-last
fi
sudo virsh net-update $NET_NAME $action ip-dhcp-host '<host mac="'$HOST_MAC'" name="'$HOST_NAME'" ip="'$HOST_IP'"/>' --live --parent-index 0

# Update dnsmasq configuration
IBI_DNSMASQ_CONF=/etc/NetworkManager/dnsmasq.d/ibi.conf
if test -f $IBI_DNSMASQ_CONF ; then
  # copy existing dnsmasq conf to temp file, exclude the cluster api DNS
  grep -vx address=/api.${CLUSTER_NAME}.${BASE_DOMAIN}/${HOST_IP} $IBI_DNSMASQ_CONF > $tmpfile || touch $tmpfile
fi
echo address=/api.${CLUSTER_NAME}.${BASE_DOMAIN}/${HOST_IP} >> $tmpfile
cat $tmpfile | sudo tee $IBI_DNSMASQ_CONF
sudo systemctl reload NetworkManager.service
