See https://issues.redhat.com/browse/MGMT-13669

Note that this repo is just a proof-of-concept. This repo is for debugging / experimenting with
single node OpenShift **relocation**.

Note that single node OpenShift relocation is currently unsupported.

### Generate the image template
Install SNO cluster with bootstrap-in-place:

- Set `PULL_SECRET` environment variable to your pull secret:
    ```bash
    make start-iso
    ```

    monitor the progress using `make -C bootstrap-in-place-poc/ ssh` and `journalctl -f -u bootkube.service` or `kubectl --kubeconfig ./bootstrap-in-place-poc/sno-workdir/auth/kubeconfig get clusterversion`.

- Once the installation is complete create the image template:
    ```bash
    make bake
    ```

This will apply machine configs to the SNO instance and then shut it down.

- Create the `site-config.iso` with the configuration for the SNO instance at edge site:
    ```bash
    make site-config CLUSTER_NAME=new-name BASE_DOMAIN=foo.com
    ```
    This will create the `site-config.iso` file, which will later get attached to the instance and once the instance is booted the `installation-configuration.service` will scan the attached devices,
    mount the iso, read the configuration and start the reconfiguration process.

- To copy the previous VM's image into `/var/lib/libvirt/images/SNO-baked-image.qcow2` and then create a new SNO instance from it, with the `site-config.iso` attached, run:

    ```bash
    make start-vm
    ```

- You can now monitor the progress using `make ssh` and `journalctl -f -u installation-configuration.service`
