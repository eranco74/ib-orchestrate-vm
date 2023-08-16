#!/bin/bash

backup_repo=${BACKUP_REPO:-quay.io/jpolo/ostmagic}
backup_tag=backup
backup_refspec=$backup_repo:$backup_tag

log_it(){
    echo $@ | tr [:print:] -
    echo $@
    echo $@ | tr [:print:] -
}

sudo crictl ps -o json| jq -r '.containers[] | .imageRef' > /var/tmp/containers.list

log_it Stopping kubelet and crio
systemctl stop kubelet
crictl ps -q | xargs crictl stop
systemctl stop crio

log_it Cleaning /var
# Clean journal
journalctl --flush --rotate --vacuum-time=1s
journalctl --user --flush --rotate --vacuum-time=1s
rm -fr /var/log/pods/*
for i in $(find /var/log -type f -name "*.log"); do > $i; done

log_it Creating backup datadir
mkdir /var/tmp/backup
mv /var/tmp/containers.list /var/tmp/backup/containers.list
tar czf /var/tmp/backup/var.tgz \
    --exclude='/var/tmp/*' \
    --exclude='/var/lib/log/*' \
    --exclude='/var/lib/containers/*' \
    --exclude='/var/lib/kubelet/pods/*' \
    --exclude='/var/lib/cni/bin/*' \
    --selinux \
    /var
ostree admin config-diff | awk '{print "/etc/" $2}' | xargs tar czf /var/tmp/backup/etc.tgz
rpm-ostree status > /var/tmp/backup/rpm-ostree.status
ostree commit --branch backup /var/tmp/backup

# Create credentials for pushing the generated image
mkdir /root/.docker
cp backup-secret.json /root/.docker/config.json

log_it Encapsulating and pushing backup OCI
ostree container encapsulate backup registry:$backup_refspec --repo /ostree/repo --label ostree.bootable=true
