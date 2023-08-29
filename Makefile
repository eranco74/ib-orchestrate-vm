# Disable built-in rules
MAKEFLAGS += --no-builtin-rules

IMAGE_BASED_DIR = .
SNO_DIR = ./bootstrap-in-place-poc
CONFIG_DIR = ./config-dir

########################

default: help

checkenv:
ifndef PULL_SECRET
	$(error PULL_SECRET must be defined)
endif

LIBVIRT_IMAGE_PATH := $(or ${LIBVIRT_IMAGE_PATH},/var/lib/libvirt/images)
BASE_IMAGE_PATH_SNO = $(LIBVIRT_IMAGE_PATH)/sno-test.qcow2
IMAGE_PATH_SNO_IN_LIBVIRT = $(LIBVIRT_IMAGE_PATH)/SNO-baked-image.qcow2
SITE_CONFIG_PATH_IN_LIBVIRT = $(LIBVIRT_IMAGE_PATH)/site-config.iso
CLUSTER_RELOCATION_TEMPLATE = ./edge_configs/05_cluster-relocation.json
PULL_SECRET_TEMPLATE = ./edge_configs/03_pullsecret.json
NAMESPACE_TEMPLATE = ./edge_configs/00_namespace.json
MACHINE_NETWORK ?= 192.168.127.0/24
CPU_CORE ?= 16
RAM_MB ?= 32768

NET_CONFIG_TEMPLATE = $(IMAGE_BASED_DIR)/template-net.xml
NET_CONFIG = $(IMAGE_BASED_DIR)/net.xml


NET_NAME = test-net-2
VM_NAME = sno-test-2
VOL_NAME = $(VM_NAME).qcow2

SSH_KEY_DIR = $(SNO_DIR)/ssh-key
SSH_KEY_PUB_PATH = $(SSH_KEY_DIR)/key.pub
SSH_KEY_PRIV_PATH = $(SSH_KEY_DIR)/key

SSH_FLAGS = -o IdentityFile=$(SSH_KEY_PRIV_PATH) \
 			-o UserKnownHostsFile=/dev/null \
 			-o StrictHostKeyChecking=no

HOST_IP = 192.168.128.10
SSH_HOST = core@$(HOST_IP)

SNO_KUBECONFIG = $(SNO_DIR)/sno-workdir/auth/kubeconfig
oc = oc --kubeconfig $(SNO_KUBECONFIG)

# Relocation config
CLUSTER_NAME ?= new-name
BASE_DOMAIN ?= relocated.com
HOSTNAME ?= master1
MIRROR_URL ?= mirror-registry.local
MIRROR_PORT ?= 5000
NEW_REGISTRY_CERT = $(shell cat edge_configs/registry.crt)
NEW_SSH_KEY = $(shell cat ${SSH_KEY_PUB_PATH})
export NEW_REGISTRY_CERT
export NEW_SSH_KEY

$(SSH_KEY_DIR):
	@echo Creating SSH key dir
	mkdir $@

$(SSH_KEY_PRIV_PATH): $(SSH_KEY_DIR)
	@echo "No private key $@ found, generating a private-public pair"
	# -N "" means no password
	ssh-keygen -f $@ -N ""
	chmod 400 $@

$(SSH_KEY_PUB_PATH): $(SSH_KEY_PRIV_PATH)

.PHONY: gather checkenv clean destroy-libvirt start-vm network ssh bake wait-for-install-complete $(IMAGE_PATH_SNO_IN_LIBVIRT) $(NET_CONFIG) $(CONFIG_DIR) help vdu external-container-partition remove-container-partition ostree-backup ostree-restore create-config copy-config

.SILENT: destroy-libvirt

### Install SNO from ISO
start-iso: bootstrap-in-place-poc
	make -C $(SNO_DIR) $@

start-iso-abi: bootstrap-in-place-poc machineConfigs/internal-ip.yaml ## Install SNO cluster with ABI
	@echo "Add the internal-ip machine config - this is required until https://github.com/openshift/machine-config-operator/pull/3774 is merged"
	cp machineConfigs/internal-ip.yaml $(SNO_DIR)/manifests/
	@echo "Replace the bootstrap-in-place agent-config.yaml with the config from this repo"
	cp agent-config.yaml $(SNO_DIR)
	make -C $(SNO_DIR) $@ \
		MACHINE_NETWORK=${MACHINE_NETWORK} \
		CPU_CORE=$(CPU_CORE) \
		RAM_MB=$(RAM_MB)

bootstrap-in-place-poc:
	rm -rf $(SNO_DIR)
	git clone https://github.com/eranco74/bootstrap-in-place-poc

wait-for-install-complete: ## Wait for start-iso-abi to complete
	echo "Waiting for installation to complete"
	until [ "$$($(oc) get clusterversion -o jsonpath='{.items[*].status.conditions[?(@.type=="Available")].status}')" == "True" ]; do \
			echo "Still waiting for installation to complete ..."; \
			sleep 10; \
	done

### Bake the image template

bake: machineConfigs ## Add changes into image template
	$(oc) apply -f ./relocation-operator.yaml
	$(oc) apply -f ./machineConfigs/installation-configuration.yaml
	$(oc) apply -f ./machineConfigs/dnsmasq.yaml
	echo "Wait for mcp to update, the node will reboot in the process"
	for mc in 50-master-dnsmasq-configuration 99-master-installation-configuration; do \
		echo "Waiting for $$mc to be present in running rendered-master MachineConfig"; \
		until $(oc) get mcp master -ojson | jq -r .status.configuration.source[].name | grep -xq $$mc; do \
			echo -n .;\
			sleep 30; \
		done; echo; \
	done
	$(oc) wait --timeout=20m --for=condition=updated=true mcp master
	# TODO: add this once we have the bootstrap script
	make -C $(SNO_DIR) ssh CMD="sudo systemctl disable kubelet"

stop-baked-vm: ## Shutdown and undefine sno-test
	sudo virsh shutdown sno-test
	make wait-for-shutdown
	sudo virsh undefine sno-test

credentials/backup-secret.json:
	@test '$(BACKUP_SECRET)' || { echo "BACKUP_SECRET must be defined"; exit 1; }
	mkdir -p credentials
	echo '$(BACKUP_SECRET)' > credentials/backup-secret.json

ostree-backup: credentials/backup-secret.json ## Backup sno-test into ostree container		make ostree-backup BACKUP_REPO=quay.io/whatever/ostmagic
	scp $(SSH_FLAGS) ostree-backup.sh credentials/backup-secret.json core@sno-test:/tmp
	ssh $(SSH_FLAGS) core@sno-test sudo /tmp/ostree-backup.sh $(BACKUP_REPO)

ostree-restore: credentials/backup-secret.json ## Restore SNO from ostree OCI			make ostree-restore BACKUP_REPO=quay.io/whatever/ostmagic HOST=recipient-sno
	@test "$(HOST)" || { echo "HOST must be defined"; exit 1; }
	scp $(SSH_FLAGS) ostree-restore.sh credentials/*-secret.json core@$(HOST):/tmp
	ssh $(SSH_FLAGS) core@$(HOST) sudo /tmp/ostree-restore.sh $(BACKUP_REPO)

machineConfigs: machineConfigs/installation-configuration.yaml machineConfigs/dnsmasq.yaml

# Generate installation-configuration machine config that will create the service that reconfigure the node.
machineConfigs/installation-configuration.yaml: bake/installation-configuration.sh butane-installation-configuration.yaml
	podman run -i -v ./bake:/scripts/:rw,Z  --rm quay.io/coreos/butane:release --pretty --strict -d /scripts < butane-installation-configuration.yaml > $@ || (rm $@ && false)

machineConfigs/dnsmasq.yaml: bake/dnsmasq.conf bake/force-dns-script bake/unmanaged-resolv.conf butane-dnsmasq.yaml
	podman run -i -v ./bake:/scripts/:rw,Z  --rm quay.io/coreos/butane:release --pretty --strict -d /scripts < butane-dnsmasq.yaml > $@ || (rm $@ && false)

machineConfigs/internal-ip.yaml: bake/dispatcher-pre-up-internal-ip.sh bake/crio-nodenet.conf bake/kubelet-nodenet.conf
	podman run -i -v ./bake:/scripts/:rw,Z  --rm quay.io/coreos/butane:release --pretty --strict -d /scripts < butane-internal-ip.yaml > $@ || (rm $@ && false)


wait-for-shutdown:
	until sudo virsh domstate sno-test | grep shut; do \
  		echo " sno-test still running"; \
  		sleep 10; \
    done

### Create new image from template
create-image-template: $(IMAGE_PATH_SNO_IN_LIBVIRT)

$(IMAGE_PATH_SNO_IN_LIBVIRT): $(BASE_IMAGE_PATH_SNO)
	sudo mv $< $@
	sudo chown qemu:qemu $@

### Create a new SNO from the image template

# Render the libvirt net config file with the network name and host IP
$(NET_CONFIG): $(NET_CONFIG_TEMPLATE)
	sed -e 's/REPLACE_NET_NAME/$(NET_NAME)/' \
		-e 's/REPLACE_HOST_IP/$(HOST_IP)/' \
		-e 's|DOMAIN|$(CLUSTER_NAME).$(BASE_DOMAIN)|' \
		-e 's|REPLACE_HOSTNAME|$(HOSTNAME)|' \
	    $(NET_CONFIG_TEMPLATE) > $@
	@if [ "$(STATIC_NETWORK)" = "TRUE" ]; then \
		sed -i "/dhcp/,/\/dhcp/d" $@; \
	fi

network: destroy-libvirt $(NET_CONFIG)
	NET_XML=$(NET_CONFIG) \
	HOST_IP=$(HOST_IP) \
	CLUSTER_NAME=$(CLUSTER_NAME) \
	BASE_DOMAIN=$(BASE_DOMAIN) \
	$(SNO_DIR)/virt-create-net.sh

# Destroy previously created VMs/Networks and create a VM/Network with the pre-baked image
start-vm: checkenv $(IMAGE_PATH_SNO_IN_LIBVIRT) network $(SITE_CONFIG_PATH_IN_LIBVIRT) ## Copy sno-image.qcow2 and create new instance	make start-vm CLUSTER_NAME=new-name BASE_DOMAIN=foo.com
	IMAGE=$(IMAGE_PATH_SNO_IN_LIBVIRT) \
	VM_NAME=$(VM_NAME) \
	NET_NAME=$(NET_NAME) \
	SITE_CONFIG=$(SITE_CONFIG_PATH_IN_LIBVIRT) \
	CPU_CORE=$(CPU_CORE) \
	RAM_MB=$(RAM_MB) \
	$(IMAGE_BASED_DIR)/virt-install-sno.sh


# Set the network name to static and call start-vm
start-vm-static-network: STATIC_NETWORK = "TRUE"
start-vm-static-network: start-vm

ssh: $(SSH_KEY_PRIV_PATH)
	ssh $(SSH_FLAGS) $(SSH_HOST)

$(CONFIG_DIR):
	rm -rf $@
	mkdir -p $@

# Set the network name to static and call start-vm
$(CONFIG_DIR)/cluster-configuration: PULL_SECRET_ENCODED=$(shell echo '$(PULL_SECRET)' | json_reformat | base64 -w 0)
$(CONFIG_DIR)/cluster-configuration: $(CONFIG_DIR) $(CLUSTER_RELOCATION_TEMPLATE) checkenv
	mkdir $@
	sed -e 's/REPLACE_DOMAIN/$(CLUSTER_NAME).$(BASE_DOMAIN)/' \
		-e 's/REPLACE_PULL_SECRET_ENCODED/"$(PULL_SECRET_ENCODED)"/' \
		-e 's/REPLACE_MIRROR_URL/$(MIRROR_URL)/' \
		-e 's/REPLACE_MIRROR_PORT/$(MIRROR_PORT)/' \
		-e 's|REPLACE_SSH_KEY|"$(NEW_SSH_KEY)"|' \
		-e 's|REPLACE_REGISTRY_CERT|"$(NEW_REGISTRY_CERT)"|' \
		$(CLUSTER_RELOCATION_TEMPLATE) > $@/$(notdir $(CLUSTER_RELOCATION_TEMPLATE))
	sed -e 's/REPLACE_PULL_SECRET_ENCODED/"$(PULL_SECRET_ENCODED)"/' \
		$(PULL_SECRET_TEMPLATE) > $@/$(notdir $(PULL_SECRET_TEMPLATE))
	cp $(NAMESPACE_TEMPLATE) $@/$(notdir $(NAMESPACE_TEMPLATE))

create-config: $(CONFIG_DIR)/cluster-configuration edge_configs/static_network.cfg edge_configs/extra-manifests
	@if [ "$(STATIC_NETWORK)" = "TRUE" ]; then \
		echo "Adding static network configuration to ISO"; \
		mkdir $(CONFIG_DIR)/network-configuration; \
		cp edge_configs/static_network.cfg $(CONFIG_DIR)/network-configuration/enp1s0.nmconnection; \
	fi
	cp -r edge_configs/extra-manifests $(CONFIG_DIR)

site-config.iso: create-config ## Create site-config.iso				make site-config.iso CLUSTER_NAME=new-name BASE_DOMAIN=foo.com
	mkisofs -o site-config.iso -R -V "relocation-config" $(CONFIG_DIR)

copy-config: create-config ## Copy site-config to HOST				make copy-config CLUSTER_NAME=new-name BASE_DOMAIN=foo.com HOST=recipient-sno
	@test "$(HOST)" || { echo "HOST must be defined"; exit 1; }
	echo "Copying site-config to $(HOST)"
	ssh $(SSH_FLAGS) core@$(HOST) sudo mkdir -p /sysroot/ostree/deploy/ingrade/var/opt/openshift
	tar czC $(CONFIG_DIR) . | ssh $(SSH_FLAGS) core@$(HOST) sudo tar xvzC /sysroot/ostree/deploy/ingrade/var/opt/openshift --no-same-owner

$(SITE_CONFIG_PATH_IN_LIBVIRT): site-config.iso
	sudo cp site-config.iso $(LIBVIRT_IMAGE_PATH)
	sudo chown qemu:qemu $(LIBVIRT_IMAGE_PATH)/site-config.iso
	sudo restorecon $(LIBVIRT_IMAGE_PATH)/site-config.iso

update_script:
	cat bake/installation-configuration.sh | ssh $(SSH_FLAGS) $(SSH_HOST) "sudo tee /usr/local/bin/installation-configuration.sh"
	ssh $(SSH_FLAGS) $(SSH_HOST) "sudo systemctl daemon-reload"
	ssh $(SSH_FLAGS) $(SSH_HOST) "sudo systemctl restart installation-configuration.service --no-block"

vdu: ## Apply VDU profile to sno-test
	KUBECONFIG=$(SNO_KUBECONFIG) \
	$(IMAGE_BASED_DIR)/vdu-profile.sh

external-container-partition: ## Configure sno-test to use external /var/lib/containers
	VM_NAME=sno-test \
	BASE_IMAGE_PATH_SNO=$(BASE_IMAGE_PATH_SNO) \
	KUBECONFIG=$(SNO_KUBECONFIG) \
	$(IMAGE_BASED_DIR)/external-varlibcontainers-create.sh

remove-container-partition: ## Remove extra /var/lib/containers partition from baked image
	BASE_IMAGE_PATH_SNO=$(BASE_IMAGE_PATH_SNO) \
	$(IMAGE_BASED_DIR)/external-varlibcontainers-remove-partition.sh

### Cleanup

destroy-libvirt:
	echo "Destroying previous libvirt resources"
	NET_NAME=$(NET_NAME) \
        VM_NAME=$(VM_NAME) \
        VOL_NAME=$(VOL_NAME) \
	$(SNO_DIR)/virt-delete-sno.sh || true

help:   ## Shows this message.
		@grep -E '^[a-zA-Z_\.\-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
