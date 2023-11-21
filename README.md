# SNO seed image creation and restoration using Image Base Upgrade (IBU)
Note that this repo is just a proof-of-concept. This repo is for debugging / experimenting with
single node OpenShift **

Note that single node OpenShift relocation is currently unsupported.

## Prerequisites

- NMState v2.2.10 or above, this is required due to the nmstate config used in the agent-config.yaml
```bash
sudo dnf copr enable nmstate/nmstate-git
sudo dnf install nmstate
- Set `PULL_SECRET` environment variable to the contents of your cluster pull secret
- Set `BACKUP_SECRET` environment variable with the credentials needed to push/pull the seed image, in standard pull-secret format
```

- virt-install

```bash
sudo dnf install virt-install
```

## Fedora prerequisites

### If using systemd-resolved as a system DNS resolver

<details>
  <summary>Show more info</summary>


Add the `NetworkManager` dnsmasq instance as a DNS server for resolved:

```bash
sudo mkdir /etc/systemd/resolved.conf.d
```

Then create `/etc/systemd/resolved.conf.d/dns_servers.conf` with:

```
[Resolve]
DNS=127.0.0.1
Domains=~.
```

And finally restart systemd-resolved:

```bash
sudo systemctl restart systemd-resolved
```

</details>

### If using authselect as nsswitch manager

<details>
  <summary>Show more info</summary>

#### Install libvirt-nss
```bash
sudo dnf install libvirt-nss
```

#### Add authselect libvirt feature

```bash
sudo authselect enable-feature with-libvirt
```

</details>

This makes it so that libvirt guest names resolve to IP addresses

## Procedure
### Generate the seed image template
To generate a seed image we want to:
- Provision a VM and install SNO in it
```bash
make seed-vm-create wait-for-seed
```

- (OPTIONAL) Modify that installation to suit the use-case that we want to have in the seed image. In this example we install the components of a vDU profile
```bash
make vdu
```

- Prepare the seed cluster to have a couple of needed extras
```bash
make dnsmasq-workaround ostree-shared-containers
```

- Create a seed image from that SNO cluster
```bash
make seed-image-create SEED_IMAGE=quay.io/whatever/repo:tag
```
This will run [ibu-imager](https://github.com/openshift-kni/lifecycle-agent/tree/main/ibu-imager) to create an OCI seed image

### Restore seed image
To restore a seed image we will use [LifeCycle Agent](https://github.com/openshift-kni/lifecycle-agent), and manage everything with the CR `ImageBasedUpgrade`

The steps will be as follow:

- Provision a VM and install SNO in it
```bash
make recipient-vm-create wait-for-recipient
```

- Prepare the recipient cluster to use /var/lib/containers in a directory that can be shared among different deployments
```bash
make ostree-shared-containers CLUSTER=recipient
```

- Restore the seed image
```bash
make seed-image-restore SEED_IMAGE=quay.io/whatever/repo:tag
```

- Reboot into the new deployment
```bash
virsh reboot recipient
```

## Extra goodies

### Backup and reuse VM qcow2 files
To be able to reuse the VMs, we can backup the qcow2 files of both seed and recipient VM
This will allow us to skip the initial provision, allowing for faster iterations when testing
To create a backup run:
```bash
make seed-vm-backup
```
or
```bash
make recipient-vm-backup
```

To restore an image, we run the complementary `restore` command
```bash
make seed-vm-restore
```
or
```bash
make recipient-vm-restore
```

IMPORTANT: Remember that certificates expire, so if a backed up image is old, certificates will expire and openshift wont be usable
TODO: Apply recert after restoring the image

### vDU profile
A vDU profile can be applied to the image before baking with
```bash
make vdu
```

### Use shared directorty for /var/lib/containers
A shared directory `/sysroot/containers` can be used to mount and share /var/lib/containers when using ostree based dual boot
Before baking, run:
```bash
make ostree-shared-containers
```
or
```bash
make ostree-shared-containers CLUSTER=recipient
```

This will create a `/sysroot/containers` in the SNO (when not specifying the cluster with the CLUSTER variable, it defaults to the seed image) to be mounted in /var/lib/containers
The use case for this is to easily precache all the images that the cluster in the seed image will need, while original recipient cluster is still running

#### WARNING
It is important to note that for precaching to work, this change must be applied both in seed image and recipient cluster

## Examples
### Full run with vDU profile
#### Prerequisites
Let's first define a few environment variables:
```
SEED_IMAGE=quay.io/whatever/ostbackup:seed
export PULL_SECRET=$(jq -c . /path/to/my/pull-secret.json)
export BACKUP_SECRET=$(jq -c . /path/to/my/repo/credentials.json)
```
#### Creation of relocatable image
- Create seed VM and image
```
make seed-vm-create wait-for-seed vdu dnsmasq-workaround ostree-shared-containers seed-image-create SEED_IMAGE=$SEED_IMAGE
```
- Create recipient SNO and restore seed image
```
make recipient-vm-create wait-for-recipient ostree-shared-containers seed-image-restore SEED_IMAGE=$SEED_IMAGE
virsh reboot recipient
```

### Installing the backup into some running SNO
```
make seed-image-restore SNO_KUBECONFIG=path/to/recipient/sno/kubeconfig SEED_IMAGE=$SEED_IMAGE
```
- Reboot the recipient host
