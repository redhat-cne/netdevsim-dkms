# SPDX-License-Identifier: GPL-2.0

obj-m += nsim_ptp.o
obj-m += nsim_ptp_mock.o

nsim_ptp-y := ptp_clock.o ptp_chardev.o ptp_sysfs.o ptp_vclock.o
nsim_ptp_mock-y := ptp_mock.o

LINUXINCLUDE := -I$(DKMS_INCLUDE) $(LINUXINCLUDE)
