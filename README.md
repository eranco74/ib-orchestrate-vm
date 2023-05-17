See https://issues.redhat.com/browse/MGMT-13669

Note that this repo is just a proof-of-concept. This repo is for debugging / experimenting with
single node OpenShift **relocation**.

Note that single node OpenShift relocation is currently unsupported.

### Generate the image template
Install SNO cluster with bootstrap-in-place:
- Set PULL_SECRET environment variable to your pull secret

```
```bash
make start-iso
```
monitor the progress using make ssh and journalctl -f -u bootkube.service or kubectl --kubeconfig ./sno-workdir/auth/kubeconfig get clusterversion.
The kubeconfig file can be found in `.bootstrap-in-place/sno-workdir/auth/kubeconfig`

Once the installation is complete create the image template:
```
```bash
make bake
```
This will apply machine configs to the SNO instance, shut it down and copy the image to:
```
/var/lib/libvirt/images/SNO-baked-image.qcow2
```

- Create the site-config iso wiht the configuration for the SNO instance at edge site:
```bash
make site-config.iso CLUSTER_NAME=new-name BASE_DOMAIN=foo.com
```
This will create the site-config.iso file, this iso will get attached to the instance and once the instance is booted the installation-configuration.service will scan the attached devices, 
mount the iso, read the configuration and start the reconfiguration process.

- Create a new SNO instance from the SNO-baked-image:
```bash
make start-vm
```

- You can now monitor the progress using `make ssh` and `journalctl -f -u installation-configuration.service`