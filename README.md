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

- Once the installation is completed we want to add a shared /var/lib/containers (see below in the Goodies section for more details)
```bash
make ostree-shared-containers
```

- With the cluster ready we can create an ostree backup to be imported in an existing SNO
To do so, the credentials for writing in $SEED_IMAGE must be in an environment variable called `BACKUP_SECRET`, and then run:
```bash
make seed-image SEED_IMAGE=quay.io/whatever/ostmagic:seed
```

This will run [ibu-imager](https://github.com/openshift-kni/lifecycle-agent/tree/main/ibu-imager) to create an OCI seed image

- Once the preparation is complete, we should shutdown and undefine the VM
```bash
make stop-baked-vm
```

This will shutdown the VM and remove it from the hypervisor

### Restore seed image into a running SNO
To restore a seed image we will use [LifeCycle Agent](https://github.com/openshift-kni/lifecycle-agent), and manage everything with the CR `ImageBasedUpgrade`

```
make lca-seed-restore SNOB_KUBECONFIG=snob_kubeconfig SEED_IMAGE=quay.io/whatever/ostmagic:seed SEED_VERSION=4.13.5
```

And then, reboot the node where we ran the upgrade

## Extra goodies

### Backup and reuse pre-baked image
At any point we can backup the VM used to generate the golden image, this allows for faster iteration and testing

To create a backup run:
```bash
make backup
```

To restore that image, just run:
```bash
make restore
```

IMPORTANT: Remember that certificates expire, so if a backed up image is old, certificates will expire and openshift wont be usable
TODO: Apply recert after restoring the image

### Restore OSTree relocation image into existing SNO
#### Prerequisites
- A image must be created before with `make ostree-backup` (see above)
- The ssh key bootstrap-in-place-poc/ssh-key/key.pub must be authorized for the user core in the recipient SNO
- `BACKUP_SECRET` environment variable must be set as explained above
#### Procedure
Run the restore script:
```bash
make ostree-restore SEED_IMAGE=quay.io/whatever/ostmagic:seed HOST=recipient-sno
```
And then reboot the recipient-sno host

### vDU profile
A vDU profile can be applied to the image before baking with
```bash
make vdu
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
SEED_IMAGE=quay.io/whatever/ostbackup:seed
SNOB_KUBECONFIG=path/to/recipient/kubeconfig
export PULL_SECRET=$(jq -c . /path/to/my/pull-secret.json)
export BACKUP_SECRET=$(jq -c . /path/to/my/repo/credentials.json)
```
#### Creation of relocatable image
- Create new VM, apply the vDU profile, the relocation needed things, and create an ostree backup:
```
make start-iso-abi wait-for-install-complete vdu ostree-shared-containers seed-image stop-baked-vm SEED_IMAGE=$SEED_IMAGE
```

#### Installing the backup into a running SNO
```
make lca-seed-restore SNOB_KUBECONFIG=$SNOB_KUBECONFIG SEED_IMAGE=$SEED_IMAGE
```
- Reboot the recipient host

## Deprecated functionality
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

### Old style bake and ostree-backup
This will use the ostree-backup.sh script to create a seed image. There are two steps needed for this:

- Prepare the cluster by running
```bash
make bake
```

This will apply machine configs to the SNO instance (named sno1).

- With the cluster ready we can create an ostree backup to be imported in an existing SNO
To do so, the credentials for writing in $SEED_IMAGE must be in an environment variable called `BACKUP_SECRET`, and then run:
```bash
make ostree-backup SEED_IMAGE=quay.io/whatever/ostmagic:seed
```

This will backup /var and /etc changes in an OCI container.
