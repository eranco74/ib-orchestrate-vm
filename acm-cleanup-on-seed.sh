#!/bin/bash
#

# 1. Drop site-config
#    Is it sufficient to delete the managedcluster from the hub? Would it potentially get reimported?
#    Or do we drop everything via gitops?
#    This will delete the open-cluster-management-agent and open-cluster-management-agent-addon namespaces,
#    but there are other resources remaining that can also be cleaned up. In the case of the assisted-installer
#    namespace and the observability feature, this includes hub-signed certs that are not supported by the
#    recert tool and must be cleaned up before generating the seed image.
#
# oc --kubeconfig ${HUB_KUBECONFIG} delete managedcluster cnfde8

# 2. Clean up ACM resources remaining on seed SNO

oc delete ns assisted-installer

oc delete ClusterRole                         klusterlet
oc delete ClusterRole                         klusterlet-bootstrap-kubeconfig
oc delete ClusterRole                         open-cluster-management:klusterlet-admin-aggregate-clusterrole
oc delete ClusterRoleBinding                  klusterlet

oc delete crd \
    clusterclaims.cluster.open-cluster-management.io \
    appliedmanifestworks.work.open-cluster-management.io \
    configurationpolicies.policy.open-cluster-management.io \
    observabilityaddons.observability.open-cluster-management.io \
    policies.policy.open-cluster-management.io

# 3. Cleanup pods
oc delete pod --field-selector=status.phase==Succeeded --all-namespaces
oc delete pod --field-selector=status.phase==Failed --all-namespaces

# 4. Delete observablity namespace and secret, if configured
oc delete ns open-cluster-management-addon-observability
oc delete secret -n openshift-monitoring observability-alertmanager-accessor

