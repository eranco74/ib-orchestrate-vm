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

- Once the installation is complete create the image template:
```bash
make bake
```

This will apply machine configs to the SNO instance (named sno-test) and then remove it from the hypervisor, leaving us wih the prepaired qcow2 image in /var/lib/libvirt/images/sno-test.qcow2.

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
