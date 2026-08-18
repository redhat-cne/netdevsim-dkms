/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Kernel version compatibility layer for netdevsim DKMS package.
 *
 * The DKMS sources originate from Linux 6.9.5.  This header provides
 * shims so the same source tree compiles against 6.8.x (Ubuntu 22.04),
 * 6.17.x (Ubuntu 24.04.4 HWE), and 7.0.x (Ubuntu 24.04.5 HWE) kernels.
 *
 * Each compat block is guarded by LINUX_VERSION_CODE so the module
 * builds cleanly on the native 6.9.x tree as well.
 */

#ifndef _DKMS_COMPAT_H_
#define _DKMS_COMPAT_H_

#include "nsim_rename.h"
#include <linux/version.h>

/*
 * ---- posix_clock_context (PTP chardev) ------------------------------------
 *
 * struct posix_clock_context was introduced in v6.8 to carry per-fd
 * private data through the posix-clock file operations.  Kernels < 6.8
 * pass a bare struct posix_clock * to open/read/ioctl/poll/release.
 *
 * We define a pair of accessor macros so ptp_chardev.c can be written
 * once and compiled for both worlds.  The actual function signatures are
 * selected via #if in ptp_private.h and ptp_chardev.c.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 8, 0)
  #define HAVE_POSIX_CLOCK_CONTEXT	1
#endif

/*
 * ---- PTP_CLOCK_EXTOFF -----------------------------------------------------
 *
 * PTP_CLOCK_EXTOFF (external-timestamp-as-offset) was added in v6.9.
 * Guard any code that handles this event type.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 9, 0)
  #define HAVE_PTP_CLOCK_EXTOFF		1
#endif

/*
 * ---- PTP_EXTTS_EVENT_VALID / PTP_EXT_OFFSET flags -------------------------
 *
 * These flags on struct ptp_extts_event were added together with EXTOFF
 * in v6.9.  On 6.8.x they don't exist in the kernel headers so we
 * define them to 0 (no-ops).  On 6.9+ (including 6.17) the kernel's
 * uapi/linux/ptp_clock.h already defines them, so we must not redefine.
 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 9, 0)
  #define PTP_EXTTS_EVENT_VALID		0
  #define PTP_EXT_OFFSET		0
#endif

/*
 * ---- DPLL const-qualified device/pin ops ----------------------------------
 *
 * Starting with v6.8 the DPLL device-ops and pin-ops callbacks receive
 * const-qualified pointers to struct dpll_device / struct dpll_pin.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 8, 0)
  #define DPLL_DEVICE_CONST	const
  #define DPLL_PIN_CONST	const
#else
  #define DPLL_DEVICE_CONST
  #define DPLL_PIN_CONST
#endif

/*
 * ---- dpll_lock_status_error -----------------------------------------------
 *
 * The status_error out-param in lock_status_get was added in v6.9.
 * On 6.8.x, the callback has no status_error parameter and the enum
 * does not exist.
 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 9, 0)
  #define DPLL_NO_LOCK_STATUS_ERROR	1
  #ifndef DPLL_LOCK_STATUS_ERROR_NONE
    enum dpll_lock_status_error {
	DPLL_LOCK_STATUS_ERROR_NONE = 0,
	DPLL_LOCK_STATUS_ERROR_UNDEFINED,
    };
  #endif
#endif

/*
 * ---- genlmsg_multicast_allns compat ---------------------------------------
 *
 * The signature has changed across kernel versions:
 *   < 6.9:   (family, skb, portid, flags)            — no group
 *   6.9-6.11: (family, skb, portid, group, flags)    — our 6.9.5 source
 *   >= 6.12:  (family, skb, portid, group)            — flags removed
 *
 * Our source uses the 5-arg form.  Map it to the right kernel signature.
 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 9, 0)
#include <net/genetlink.h>
#define genlmsg_multicast_allns(family, skb, portid, group, flags) \
	(genlmsg_multicast_allns)(family, skb, portid, flags)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 12, 0)
#include <net/genetlink.h>
#define genlmsg_multicast_allns(family, skb, portid, group, flags) \
	(genlmsg_multicast_allns)(family, skb, portid, group)
#endif

/*
 * ---- nla_put_sint ---------------------------------------------------------
 *
 * nla_put_sint() was added in v6.7 (net-next).  Provide a simple
 * fallback for kernels that lack it.
 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 7, 0)
#include <net/netlink.h>
static inline int nla_put_sint(struct sk_buff *msg, int attrtype, s64 value)
{
	if (value >= S32_MIN && value <= S32_MAX)
		return nla_put_s32(msg, attrtype, (s32)value);
	return nla_put_64bit(msg, attrtype, sizeof(value),
			     &value, attrtype + 1);
}
#endif

/*
 * ---- hrtimer_init removal -------------------------------------------------
 *
 * hrtimer_init() was removed in v6.15 in favour of hrtimer_setup()
 * which combines initialisation and callback assignment.  Our 6.9.5
 * source still uses the old two-step pattern:
 *   hrtimer_init(&t, clock, mode);
 *   t.function = callback;
 *
 * On >= 6.15, provide an inline shim that maps hrtimer_init() to
 * hrtimer_setup() with a dummy callback; the real callback assignment
 * on the next line will overwrite it.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 15, 0)
#include <linux/hrtimer.h>
static enum hrtimer_restart __maybe_unused
__dkms_hrtimer_dummy(struct hrtimer *t)
{
	return HRTIMER_NORESTART;
}
#define hrtimer_init(timer, which_clock, mode) \
	hrtimer_setup(timer, __dkms_hrtimer_dummy, which_clock, mode)
#endif

/*
 * ---- cyclecounter const qualifier -----------------------------------------
 *
 * Commit e78f70bad29c ("time/timecounter: Fix the lie that struct
 * cyclecounter is const"), merged in v6.14, removed the const from
 * the cyclecounter.read callback and from container_of users.
 * Needed for ubuntu-22.04 whose kernel (6.8.x) still has const.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0)
  #define CYCLECOUNTER_READ_CONST
#else
  #define CYCLECOUNTER_READ_CONST	const
#endif

/*
 * ---- no_llseek removal ----------------------------------------------------
 *
 * no_llseek was removed from <linux/fs.h> in v6.12.  Our fib.c still
 * references it.  Map to noop_llseek which is equivalent and still exists.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 12, 0)
  #define no_llseek noop_llseek
#endif

/*
 * ---- debugfs_real_fops removal / debugfs_get_aux --------------------------
 *
 * debugfs_real_fops() was removed in v6.16 as part of the debugfs proxy
 * refactor.  The replacement pattern uses debugfs_get_aux() with
 * debugfs_create_file_aux() and struct debugfs_short_fops (added in v6.13).
 *
 * hwstats.c uses #ifdef HAVE_DEBUGFS_GET_AUX to select the right API.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 16, 0)
  #define HAVE_DEBUGFS_GET_AUX	1
#endif

/*
 * ---- xfrmdev_ops signature change -----------------------------------------
 *
 * The xdo_dev_state_add/delete/free callbacks gained an explicit
 * struct net_device * first parameter in v6.16.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 16, 0)
  #define HAVE_XFRMDEV_OPS_DEV_PARAM	1
#endif

/*
 * ---- UDP_TUNNEL_NIC_INFO_MAY_SLEEP removal --------------------------------
 *
 * The flag was removed in v6.17 when the UDP tunnel NIC infrastructure
 * switched from rtnl_lock to a dedicated mutex.  Define it as 0 so
 * existing code that sets the flag becomes a harmless no-op.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)
  #define UDP_TUNNEL_NIC_INFO_MAY_SLEEP	0
#endif

/*
 * ---- devl_health_reporter_create signature --------------------------------
 *
 * Commit d2b007374551 ("devlink: Move graceful period parameter to
 * reporter ops"), merged in v6.18, dropped the graceful_period argument.
 * The period now lives in ops->default_graceful_period (0 when unset).
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)
  #define HAVE_DEVLINK_HEALTH_REPORTER_OPS_PERIOD	1
#endif

/*
 * ---- kernel_ethtool_ts_info -----------------------------------------------
 *
 * struct kernel_ethtool_ts_info was introduced in v6.11 as a kernel-only
 * replacement for struct ethtool_ts_info in the get_ts_info() callback.
 * Our 6.9.5 source uses the old struct name.  Provide a typedef so the
 * function signature matches whichever kernel we build against.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 11, 0)
  #define NSIM_ETHTOOL_TS_INFO struct kernel_ethtool_ts_info
#else
  #define NSIM_ETHTOOL_TS_INFO struct ethtool_ts_info
#endif

/*
 * ---- ptp_clock_freerun ----------------------------------------------------
 *
 * Older kernels (< 6.9) do not expose ptp_clock_freerun() or the
 * has_cycles field.  The concept of preventing settime on a clock whose
 * vclocks are active is still present, but spelled differently.
 * For DKMS purposes we simply allow settime when the helper is missing
 * because mock clocks have no real vclock users.
 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 9, 0)
  #ifndef ptp_clock_freerun
    /* Forward-declare; the implementation lives in ptp_private.h which
     * includes this header indirectly.  If the kernel already provides it
     * this define will be harmless. */
  #endif
#endif

#endif /* _DKMS_COMPAT_H_ */
