#!/bin/bash
echo "Reconfiguring single node OpenShift"
CONFIGURATION_FILE=/opt/install-config.yaml
echo "Waiting for ${CONFIGURATION_FILE}"
while [ ! -e ${CONFIGURATION_FILE} ]
do
  sleep 5
done

echo "${CONFIGURATION_FILE} has been created"

echo "Starting kubelet"
systemctl enable kubelet

#TODO: add DNS configuration here

