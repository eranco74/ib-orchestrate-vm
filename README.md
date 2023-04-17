See https://issues.redhat.com/browse/MGMT-13669

Note that this repo is just a proof-of-concept. This repo is for debugging / experimenting with
single-node *image-based* installation.

image-based installation is currently unsupported.

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

- Create a new SNO instance from the SNO-baked-image:
```bash
make start-vm
```


