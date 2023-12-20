#!/bin/bash

set -e # Halt on error

machineconfigs="50-performance-openshift-node-performance-profile 99-master-generated-kubelet"
subscriptions="
openshift-local-storage/local-storage-operator
openshift-logging/cluster-logging
openshift-ptp/ptp-operator-subscription
openshift-sriov-network-operator/sriov-network-operator-subscription
"

# Node tuning causes downtime so we begin with just it
# and wait for everything to stabilize before continuing, otherwise
# the rest of the VDU configuration could run into errors with OLM jobs
oc apply -f ./vdu/01-node-tuning.yaml

# Wait for generated machineconfig to have performanceprofile and tuned baked in
for mc in ${machineconfigs}; do
  echo "Waiting for ${mc} to be present in running rendered-master MachineConfig"
  until oc get mcp master -ojson | jq -r .status.configuration.source[].name | grep -xq "${mc}"; do
    echo -n .
    sleep 30
  done; echo
done

# Wait for generated machineconfig to be applied
oc wait --timeout=20m --for=condition=updated=true mcp master

# Now that the node tuning is applied, we can apply the rest of the VDU
# configuration and since there is no downtime, it should go smoothly
oc apply -f ./vdu/02-namespaces.yaml
oc apply -f ./vdu/03-subscriptions.yaml
oc apply -f ./vdu/04-configurations.yaml

for subscription in ${subscriptions}; do
  namespace=${subscription%/*}
  name=${subscription#*/}
  oc wait subscription --timeout=20m --for=jsonpath='{.status.state}'=AtLatestKnown -n "${namespace}" "${name}"
done
