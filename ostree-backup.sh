#!/bin/bash

backup_repo=${1:-$BACKUP_REPO}
backup_tag=backup
base_tag=base
parent_tag=parent
backup_refspec=$backup_repo:$backup_tag
base_refspec=$backup_repo:$base_tag
parent_refspec=$backup_repo:$parent_tag

log_it(){
    echo $@ | tr [:print:] -
    echo $@
    echo $@ | tr [:print:] -
}

if [[ -z "$backup_repo" ]]; then
    echo "ERROR. Backup repo is empty"
    exit 1
fi

crictl ps -o json| jq -r '.containers[] | .imageRef' > /var/tmp/containers.list

log_it Stopping kubelet
systemctl stop kubelet
log_it Stopping containers
crictl ps -q | xargs --no-run-if-empty crictl stop --timeout 5
log_it Waiting for containers to stop
while crictl ps -q | grep -q .; do sleep 1; done
log_it Stopping crio
systemctl stop crio

log_it Creating backup datadir
mkdir /var/tmp/backup
mv /var/tmp/containers.list /var/tmp/backup/containers.list
tar czf /var/tmp/backup/var.tgz \
    --exclude='/var/tmp/*' \
    --exclude='/var/lib/log/*' \
    --exclude='/var/log/*' \
    --exclude='/var/lib/containers/*' \
    --exclude='/var/lib/kubelet/pods/*' \
    --exclude='/var/lib/cni/bin/*' \
    --selinux \
    /var
ostree admin config-diff | awk '{print "/etc/" $2}' | xargs tar czf /var/tmp/backup/etc.tgz --selinux
rpm-ostree status -v --json > /var/tmp/backup/rpm-ostree.json
cp /etc/machine-config-daemon/currentconfig /var/tmp/backup/mco-currentconfig.json
ostree commit --branch $backup_tag /var/tmp/backup

# Create credentials for pushing the generated image
mkdir /root/.docker
cp backup-secret.json /root/.docker/config.json

log_it Encapsulating and pushing backup OCI
ostree container encapsulate $backup_tag registry:$backup_refspec --repo /ostree/repo --label ostree.bootable=true

log_it Encapsulating and pushing base OCI
base_commit=$(rpm-ostree status -v --json | jq -r '.deployments[] | select(.booted == true).checksum')
ostree container encapsulate $base_commit registry:$base_refspec --repo /ostree/repo --label ostree.bootable=true

# If there's a parent to that commit, also encapsulate it
if [[ "$(rpm-ostree status -v --json | jq -r '.deployments[] | select(.booted == true)| has("base-checksum")')" == "true" ]]; then
    log_it Parent commit found for base, encapsulating and pushing OCI
    parent_commit=$(rpm-ostree status -v --json | jq -r '.deployments[] | select(.booted == true)."base-checksum"')
    ostree container encapsulate $parent_commit registry:$parent_refspec --repo /ostree/repo --label ostree.bootable=true
fi
