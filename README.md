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

- Once the installation is complete create the image template:
```
```bash
make bake
```

This will apply machine configs to the SNO instance and then shut it down

- To copy the previous VM's image into `/var/lib/libvirt/images/SNO-baked-image.qcow2` and then create a new SNO instance from it, with a `site-config.iso` containing custom site config attached, run:

```bash
make start-vm CLUSTER_NAME=new-name BASE_DOMAIN=foo.com
```

- You can now monitor the progress using `make ssh` and `journalctl -f -u installation-configuration.service`
