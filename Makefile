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

.PHONY: all clean modules_install tarball rpm rpm-container test-utm

all:
	$(MAKE) -C $(KDIR) M=$(PWD)/ptp DKMS_INCLUDE=$(DKMS_INCLUDE) modules
	$(MAKE) -C $(KDIR) M=$(PWD)/dpll DKMS_INCLUDE=$(DKMS_INCLUDE) modules
	$(MAKE) -C $(KDIR) M=$(PWD)/netdevsim DKMS_INCLUDE=$(DKMS_INCLUDE) \
		KBUILD_EXTRA_SYMBOLS="$(PWD)/ptp/Module.symvers $(PWD)/dpll/Module.symvers" \
		modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD)/ptp clean
	$(MAKE) -C $(KDIR) M=$(PWD)/dpll clean
	$(MAKE) -C $(KDIR) M=$(PWD)/netdevsim clean
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

test-utm: rpm-container
	./scripts/test-utm.sh \
		--rpm $$(ls rpmbuild/RPMS/noarch/$(NAME)-dkms-*.noarch.rpm | head -1) \
		--cleanup
