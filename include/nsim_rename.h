/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Symbol renaming for netdevsim DKMS package.
 *
 * The kernel may have PTP, PTP-mock, and DPLL built-in (=y) or as
 * modules (=m).  To guarantee our DKMS modules never collide with the
 * in-kernel versions we prefix every exported (and potentially
 * link-visible) symbol with nsim_.  The C source files remain
 * unchanged; all renaming happens via the macros below.
 *
 * Include order: dkms_compat.h pulls this header before anything else.
 */

#ifndef _NSIM_RENAME_H_
#define _NSIM_RENAME_H_

/* ---- PTP core (ptp_clock.c) -------------------------------------------- */
#define ptp_class			nsim_ptp_class
#define ptp_clock_register		nsim_ptp_clock_register
#define ptp_clock_unregister		nsim_ptp_clock_unregister
#define ptp_clock_event			nsim_ptp_clock_event
#define ptp_clock_index			nsim_ptp_clock_index
#define get_ptp_clock_info		nsim_get_ptp_clock_info
#define ptp_find_pin			nsim_ptp_find_pin
#define ptp_find_pin_unlocked		nsim_ptp_find_pin_unlocked
#define ptp_schedule_worker		nsim_ptp_schedule_worker
#define ptp_cancel_worker_sync		nsim_ptp_cancel_worker_sync

/* ---- PTP vclock (ptp_vclock.c) ----------------------------------------- */
#define ptp_get_vclocks_index		nsim_ptp_get_vclocks_index
#define ptp_convert_timestamp		nsim_ptp_convert_timestamp

/* ---- PTP internal (ptp_private.h / ptp_*.c) ---------------------------- */
#define ptp_groups			nsim_ptp_groups
#define ptp_set_pinfunc			nsim_ptp_set_pinfunc
#define ptp_ioctl			nsim_ptp_ioctl
#define ptp_open			nsim_ptp_open
#define ptp_release			nsim_ptp_release
#define ptp_read			nsim_ptp_read
#define ptp_poll			nsim_ptp_poll
#define ptp_populate_pin_groups		nsim_ptp_populate_pin_groups
#define ptp_cleanup_pin_groups		nsim_ptp_cleanup_pin_groups
#define ptp_vclock_register		nsim_ptp_vclock_register
#define ptp_vclock_unregister		nsim_ptp_vclock_unregister
#define ptp_vclock_in_use		nsim_ptp_vclock_in_use
#define ptp_clock_freerun		nsim_ptp_clock_freerun

/* ---- PTP mock (ptp_mock.c) --------------------------------------------- */
#define mock_phc_create			nsim_mock_phc_create
#define mock_phc_release		nsim_mock_phc_release
#define mock_phc_index			nsim_mock_phc_index
#define mock_phc_logical_clk_id		nsim_mock_phc_logical_clk_id
#define mock_phc_get_ptp_info		nsim_mock_phc_get_ptp_info

/* ---- DPLL core (dpll_core.c) ------------------------------------------- */
#define dpll_device_get			nsim_dpll_device_get
#define dpll_device_put			nsim_dpll_device_put
#define dpll_device_register		nsim_dpll_device_register
#define dpll_device_unregister		nsim_dpll_device_unregister
#define dpll_netdev_pin_set		nsim_dpll_netdev_pin_set
#define dpll_netdev_pin_clear		nsim_dpll_netdev_pin_clear
#define dpll_pin_get			nsim_dpll_pin_get
#define dpll_pin_put			nsim_dpll_pin_put
#define dpll_pin_register		nsim_dpll_pin_register
#define dpll_pin_unregister		nsim_dpll_pin_unregister
#define dpll_pin_on_pin_register	nsim_dpll_pin_on_pin_register
#define dpll_pin_on_pin_unregister	nsim_dpll_pin_on_pin_unregister

/* ---- DPLL netlink (dpll_netlink.c) ------------------------------------- */
#define dpll_device_change_ntf		nsim_dpll_device_change_ntf
#define dpll_pin_change_ntf		nsim_dpll_pin_change_ntf
#define __dpll_device_change_ntf	nsim_dpll_device_change_ntf_internal
#define __dpll_pin_change_ntf		nsim_dpll_pin_change_ntf_internal

/* ---- DPLL internal (dpll_core.h / dpll_*.c) ---------------------------- */
#define dpll_nl_family			nsim_dpll_nl_family
#define dpll_priv			nsim_dpll_priv
#define dpll_pin_on_dpll_priv		nsim_dpll_pin_on_dpll_priv
#define dpll_pin_on_pin_priv		nsim_dpll_pin_on_pin_priv
#define dpll_device_get_by_id		nsim_dpll_device_get_by_id
#define dpll_xa_ref_dpll_first		nsim_dpll_xa_ref_dpll_first
#define dpll_device_xa			nsim_dpll_device_xa
#define dpll_pin_xa			nsim_dpll_pin_xa
#define dpll_lock			nsim_dpll_lock
#define dpll_device_create_ntf		nsim_dpll_device_create_ntf
#define dpll_device_delete_ntf		nsim_dpll_device_delete_ntf
#define dpll_pin_create_ntf		nsim_dpll_pin_create_ntf
#define dpll_pin_delete_ntf		nsim_dpll_pin_delete_ntf

#endif /* _NSIM_RENAME_H_ */
