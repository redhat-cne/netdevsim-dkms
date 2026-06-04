# SPDX-License-Identifier: GPL-2.0
#
# Top-level Makefile for netdevsim DKMS package.
#
# Build order matters: ptp exports symbols consumed by ptp_mock and netdevsim,
# dpll exports symbols consumed by netdevsim, so build ptp/ first, then dpll/,
# then netdevsim/.
#
# All exported symbols are prefixed with nsim_ (via include/nsim_rename.h) so
# our modules never collide with the kernel's built-in PTP / DPLL.  This means
# we always build all four modules regardless of kernel config.
#
# DKMS passes KERNELRELEASE via the environment or command line.

KVER  ?= $(shell uname -r)
KDIR  ?= /lib/modules/$(KVER)/build
DKMS_INCLUDE := $(shell pwd)/include

PWD := $(shell pwd)

NAME    := netdevsim
VERSION := 6.9.5

CONTAINER_IMAGE ?= fedora:39
CONTAINER_CMD   ?= podman

.PHONY: all clean modules_install tarball rpm rpm-container test-utm test-dpll dkms-install dkms-uninstall

all:
	$(MAKE) -C $(KDIR) M=$(PWD)/ptp DKMS_INCLUDE=$(DKMS_INCLUDE) modules
	$(MAKE) -C $(KDIR) M=$(PWD)/dpll DKMS_INCLUDE=$(DKMS_INCLUDE) modules
	$(MAKE) -C $(KDIR) M=$(PWD)/netdevsim DKMS_INCLUDE=$(DKMS_INCLUDE) \
		KBUILD_EXTRA_SYMBOLS="$(PWD)/ptp/Module.symvers $(PWD)/dpll/Module.symvers" \
		modules

clean:
	find $(PWD)/ptp $(PWD)/dpll $(PWD)/netdevsim \
		\( -name '*.o' -o -name '*.ko' -o -name '*.ko.*' \
		-o -name '*.mod' -o -name '*.mod.c' -o -name '*.mod.o' \
		-o -name '.*.cmd' -o -name 'modules.order' \
		-o -name 'Module.symvers' -o -name '.tmp_versions' \) \
		-exec rm -rf {} + 2>/dev/null || true
	rm -rf $(PWD)/rpmbuild $(PWD)/$(NAME)-$(VERSION).tar.gz

tarball:
	rm -rf $(NAME)-$(VERSION).tar.gz $(NAME)-$(VERSION)
	mkdir -p $(NAME)-$(VERSION)
	cp -a Makefile dkms.conf install-udev-rule.sh 99-nsim-ptp.rules include netdevsim ptp dpll $(NAME)-$(VERSION)/
	find $(NAME)-$(VERSION) -name '._*' -delete
	find $(NAME)-$(VERSION) -name '.DS_Store' -delete
	COPYFILE_DISABLE=1 tar czf $(NAME)-$(VERSION).tar.gz $(NAME)-$(VERSION)
	rm -rf $(NAME)-$(VERSION)

rpm: tarball
	rm -rf rpmbuild
	mkdir -p rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	cp $(NAME)-$(VERSION).tar.gz rpmbuild/SOURCES/
	rpmbuild -bb \
		--define "_topdir $(PWD)/rpmbuild" \
		$(NAME)-dkms.spec
	@echo "RPMs written to rpmbuild/RPMS/"

rpm-container: tarball
	rm -rf rpmbuild
	mkdir -p rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	cp $(NAME)-$(VERSION).tar.gz rpmbuild/SOURCES/
	$(CONTAINER_CMD) run --rm \
		-v $(PWD):/src:Z \
		-w /src \
		$(CONTAINER_IMAGE) \
		bash -c "dnf install -y rpm-build && rpmbuild -bb --define '_topdir /src/rpmbuild' $(NAME)-dkms.spec"
	@echo "RPMs written to rpmbuild/RPMS/"

DKMS_SRC := /usr/src/$(NAME)-$(VERSION)

dkms-install: ## Install DKMS modules (requires root)
	sudo mkdir -p $(DKMS_SRC)
	sudo cp -a Makefile dkms.conf install-udev-rule.sh 99-nsim-ptp.rules \
		include ptp dpll netdevsim $(DKMS_SRC)/
	sudo dkms add $(NAME)/$(VERSION) 2>/dev/null || true
	sudo dkms build $(NAME)/$(VERSION)
	sudo dkms install --force $(NAME)/$(VERSION)
	sudo cp $(DKMS_SRC)/99-nsim-ptp.rules /etc/udev/rules.d/
	sudo udevadm control --reload-rules
	@echo "Installed $(NAME)/$(VERSION) via DKMS"

dkms-uninstall: ## Uninstall DKMS modules (requires root)
	-sudo rmmod netdevsim nsim_dpll nsim_ptp_mock nsim_ptp 2>/dev/null
	-sudo dkms remove $(NAME)/$(VERSION) --all 2>/dev/null
	-sudo rm -rf $(DKMS_SRC)
	-sudo rm -f /etc/udev/rules.d/99-nsim-ptp.rules
	-sudo udevadm control --reload-rules
	@echo "Uninstalled $(NAME)/$(VERSION)"

test-dpll: ## Run DPLL unit tests (requires root, modules loaded)
	sudo ./scripts/test-dpll.sh

test-utm: rpm-container
	./scripts/test-utm.sh \
		--rpm $$(ls rpmbuild/RPMS/noarch/$(NAME)-dkms-*.noarch.rpm | head -1) \
		--cleanup
