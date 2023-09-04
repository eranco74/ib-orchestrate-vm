See https://issues.redhat.com/browse/MGMT-13669

Note that this repo is just a proof-of-concept. This repo is for debugging / experimenting with
single node OpenShift **relocation**.

Note that single node OpenShift relocation is currently unsupported.

## Prerequisites

- NMState v2.2.10 or above, this is required due to the nmstate config used in the agent-config.yaml
```bash
sudo dnf copr enable nmstate/nmstate-git
sudo dnf install nmstate
```

### Generate the image template
Install SNO cluster with bootstrap-in-place:

- Set `PULL_SECRET` environment variable to your pull secret:
```bash
make start-iso-abi
```

- Monitor the progress using `make -C bootstrap-in-place-poc/ ssh` and `journalctl -f -u bootkube.service` or `kubectl --kubeconfig ./bootstrap-in-place-poc/sno-workdir/auth/kubeconfig get clusterversion`
or execute:
```bash
make wait-for-install-complete
```

- (OPTIONAL) Now we can apply extra configurations to the node, for example, the vDU profile:
```bash
make vdu
```

- Once the installation is complete create the image template:
```bash
make bake
```

This will apply machine configs to the SNO instance (named sno-test).

- (OPTIONAL) With the cluster ready we can create an ostree backup to be imported in an existing SNO
To do so, the credentials for writing in $BACKUP_REPO must be in an environment variable called `BACKUP_SECRET`, and then run:
```bash
make ostree-backup BACKUP_REPO=quay.io/whatever/ostmagic
```

This will backup /var and /etc changes in an OCI container.

- Once the preparation is complete, we should shutdown and undefine the VM
```bash
make stop-baked-vm
```

This will shutdown the VM and remove it from the hypervisor, leaving us wih the prepaired qcow2 image in /var/lib/libvirt/images/sno-test.qcow2.

- Create the site-config iso wiht the configuration for the SNO instance at edge site:
```bash
make site-config.iso CLUSTER_NAME=new-name BASE_DOMAIN=foo.com
```
This will create the `site-config.iso` file, which will later get attached to the instance and once the instance is booted the `installation-configuration.service` will scan the attached devices,
mount the iso, read the configuration and start the reconfiguration process.

- To copy the previous VM's image into `/var/lib/libvirt/images/SNO-baked-image.qcow2` and then create a new SNO instance from it, with the `site-config.iso` attached, run:

```bash
make start-vm CLUSTER_NAME=new-name BASE_DOMAIN=foo.com
```

- In case you want to configure the new SNO with static network config add `STATIC_NETWORK=TRUE` to the above command.
- In case you want to change the SNO hostname add `HOSTNAME=foobar` to the above command.

- You can now monitor the progress using `make ssh` and `journalctl -f -u installation-configuration.service`

## Extra goodies

### Restore OSTree relocation image into existing SNO
#### Prerequisites
- A image must be created before with `make ostree-backup` (see above)
- The ssh key bootstrap-in-place-poc/ssh-key/key.pub must be authorized for the user core in the recipient SNO
- `BACKUP_SECRET` environment variable must be set as explained above
#### Procedure
Run the restore script:
```bash
make ostree-restore BACKUP_REPO=quay.io/whatever/ostmagic HOST=recipient-sno
```
And then reboot the recipient-sno host

### vDU profile
A vDU profile can be applied to the image before baking with
```bash
make vdu
```

### Use new partition for /var/lib/containers
A 5th partition can be created to store the /var/lib/containers separately
Before baking, run:
```bash
make external-container-partition
```

To keep the configuration for using an external partition /var/lib/containers, without including that partition into the final image, after baking run:
```bash
make remove-container-partition
```

### Use shared directorty for /var/lib/containers (to be used with ostree restore)
A shared directory `/sysroot/containers` can be used to mount and share /var/lib/containers when using ostree based dual boot
Before baking, run:
```bash
make ostree-shared-containers
```

This will create a `/sysroot/containers` in the system used to create the golden image, and when the golden image is restored into other cluster, it will boot using the shared /var/lib/containers directory

If the system where we want to relocate the golden image has this setup already in place, both systems will share the same directory for containers storage, and we can use it to precache images.

The use case for this is to easily precache all the images that Cluster B will use, while Cluster A is still running (see the "Precaching section" in the [ostree-restore.sh](https://github.com/eranco74/sno-relocation-poc/blob/master/ostree-restore.sh) script)

#### WARNING
It is important to note that this will only configure the golden image, but in order for the original system to also use that shared directory, the `ostree-var-lib-containers-machineconfig.yaml` manifest needs to be applied to the running SNO cluster A before relocation (and it will reboot the node). If not, nothing will break, but since that system will have its own /var/lib/containers directory, precaching cannot be done

## Examples
### Full run with vDU profile and ostree
#### Prerequisites
Let's first define a few environment variables:
```
BACKUP_REPO=quay.io/whatever/ostbackup
RECIPIENT_HOST=sno
export PULL_SECRET=$(jq -c . /path/to/my/pull-secret.json)
export BACKUP_SECRET=$(jq -c . /path/to/my/repo/credentials.json)
```
#### Creation of relocatable image
- Create new VM, apply the vDU profile, the relocation needed things, and create an ostree backup:
```
make start-iso-abi wait-for-install-complete vdu ostree-shared-containers bake ostree-backup stop-baked-vm BACKUP_REPO=$BACKUP_REPO
```
#### Installing the backup into a running SNO
- Copy the ssh key:
```
ssh-copy-id -i bootstrap-in-place-poc/ssh-key/key.pub core@$RECIPIENT_HOST
```
- Restore the backup and copy site-config:
```
make ostree-restore copy-config BACKUP_REPO=$BACKUP_REPO HOST=$RECIPIENT_HOST CLUSTER_NAME=new-name BASE_DOMAIN=foo.com
```
- Reboot the recipient host
- After host boots and finishes initialization process, copy new kubeconfig:
```
ssh -i bootstrap-in-place-poc/ssh-key/key core@$RECIPIENT_HOST sudo cat /etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/lb-ext.kubeconfig > $RECIPIENT_HOST.kubeconfig
```
- Wait until relocation operator finishes:
```
oc --kubeconfig $RECIPIENT_HOST.kubeconfig get clusterrelocation cluster -ojson | jq .status.conditions
```
