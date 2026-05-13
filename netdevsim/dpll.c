// SPDX-License-Identifier: GPL-2.0
/*
 * DPLL emulation for netdevsim
 *
 * Registers a pair of DPLL devices (PPS + EEC) that always report
 * LOCKED_HO_ACQ status, and a GNSS input pin with zero phase offset.
 * Each PF netdev gets a SyncE-type output pin associated via
 * dpll_netdev_pin_set so the linuxptp-daemon can discover the DPLL
 * through netlink.
 */

#include <dkms_compat.h>
#include <linux/dpll.h>
#include <linux/gnss.h>
#include <linux/hrtimer.h>
#include <linux/list.h>
#include <linux/netdevice.h>
#include <linux/pci.h>
#include <linux/string.h>
#include <linux/timekeeping.h>
#include <linux/workqueue.h>
#include "netdevsim.h"

#define NSIM_DPLL_CLOCK_ID	0ULL
#define NSIM_DPLL_PPS_IDX	0
#define NSIM_DPLL_EEC_IDX	1
#define NSIM_DPLL_GNSS_PIN_IDX	0

/* ---- device ops -------------------------------------------------------- */

static int nsim_dpll_mode_get(DPLL_DEVICE_CONST struct dpll_device *dpll,
			      void *priv, enum dpll_mode *mode,
			      struct netlink_ext_ack *extack)
{
	*mode = DPLL_MODE_AUTOMATIC;
	return 0;
}

#ifdef DPLL_NO_LOCK_STATUS_ERROR
static int nsim_dpll_lock_status_get(DPLL_DEVICE_CONST struct dpll_device *dpll,
				     void *priv,
				     enum dpll_lock_status *status,
				     struct netlink_ext_ack *extack)
{
	*status = DPLL_LOCK_STATUS_LOCKED_HO_ACQ;
	return 0;
}
#else
static int nsim_dpll_lock_status_get(DPLL_DEVICE_CONST struct dpll_device *dpll,
				     void *priv,
				     enum dpll_lock_status *status,
				     enum dpll_lock_status_error *status_error,
				     struct netlink_ext_ack *extack)
{
	*status = DPLL_LOCK_STATUS_LOCKED_HO_ACQ;
	*status_error = DPLL_LOCK_STATUS_ERROR_NONE;
	return 0;
}
#endif

static const struct dpll_device_ops nsim_dpll_device_ops = {
	.mode_get	  = nsim_dpll_mode_get,
	.lock_status_get  = nsim_dpll_lock_status_get,
};

/* ---- pin ops ----------------------------------------------------------- */

static int nsim_dpll_pin_frequency_get(DPLL_PIN_CONST struct dpll_pin *pin,
				       void *pin_priv,
				       DPLL_DEVICE_CONST struct dpll_device *dpll,
				       void *dpll_priv, u64 *frequency,
				       struct netlink_ext_ack *extack)
{
	struct nsim_dpll_pin *npin = pin_priv;

	*frequency = npin->frequency;
	return 0;
}

static int nsim_dpll_pin_direction_get(DPLL_PIN_CONST struct dpll_pin *pin,
				       void *pin_priv,
				       DPLL_DEVICE_CONST struct dpll_device *dpll,
				       void *dpll_priv,
				       enum dpll_pin_direction *direction,
				       struct netlink_ext_ack *extack)
{
	struct nsim_dpll_pin *npin = pin_priv;

	*direction = npin->direction;
	return 0;
}

static int nsim_dpll_pin_state_on_dpll_get(DPLL_PIN_CONST struct dpll_pin *pin,
					   void *pin_priv,
					   DPLL_DEVICE_CONST struct dpll_device *dpll,
					   void *dpll_priv,
					   enum dpll_pin_state *state,
					   struct netlink_ext_ack *extack)
{
	*state = DPLL_PIN_STATE_CONNECTED;
	return 0;
}

static int nsim_dpll_pin_phase_offset_get(DPLL_PIN_CONST struct dpll_pin *pin,
					  void *pin_priv,
					  DPLL_DEVICE_CONST struct dpll_device *dpll,
					  void *dpll_priv, s64 *phase_offset,
					  struct netlink_ext_ack *extack)
{
	*phase_offset = 0;
	return 0;
}

static const struct dpll_pin_ops nsim_dpll_gnss_pin_ops = {
	.frequency_get	    = nsim_dpll_pin_frequency_get,
	.direction_get	    = nsim_dpll_pin_direction_get,
	.state_on_dpll_get  = nsim_dpll_pin_state_on_dpll_get,
	.phase_offset_get   = nsim_dpll_pin_phase_offset_get,
};

static const struct dpll_pin_ops nsim_dpll_rclk_pin_ops = {
	.frequency_get	    = nsim_dpll_pin_frequency_get,
	.direction_get	    = nsim_dpll_pin_direction_get,
	.state_on_dpll_get  = nsim_dpll_pin_state_on_dpll_get,
	.phase_offset_get   = nsim_dpll_pin_phase_offset_get,
};

/* ---- UBX protocol simulation ------------------------------------------- */

#define UBX_SYNC1		0xB5
#define UBX_SYNC2		0x62
#define UBX_HDR_LEN		6
#define UBX_CK_LEN		2
#define UBX_OVERHEAD		(UBX_HDR_LEN + UBX_CK_LEN)

#define UBX_CLASS_NAV		0x01
#define UBX_CLASS_ACK		0x05
#define UBX_CLASS_CFG		0x06
#define UBX_CLASS_MON		0x0A

#define UBX_NAV_STATUS		0x03
#define UBX_NAV_CLOCK		0x22
#define UBX_ACK_ACK		0x01
#define UBX_CFG_MSG		0x01
#define UBX_MON_VER		0x04

#define UBX_NAV_STATUS_LEN	16
#define UBX_NAV_CLOCK_LEN	20
#define UBX_ACK_ACK_LEN	2

#define UBX_MON_VER_SW_LEN	30
#define UBX_MON_VER_HW_LEN	10
#define UBX_MON_VER_EXT_LEN	30
#define UBX_MON_VER_PAYLOAD_LEN	(UBX_MON_VER_SW_LEN + UBX_MON_VER_HW_LEN + \
				 UBX_MON_VER_EXT_LEN)

#define UBX_GPS_EPOCH_UNIX	315964800ULL
#define UBX_LEAP_SECONDS	18
#define UBX_SECS_PER_WEEK	604800

static void ubx_checksum(const u8 *data, size_t len, u8 *ck_a, u8 *ck_b)
{
	u8 a = 0, b = 0;
	size_t i;

	for (i = 0; i < len; i++) {
		a += data[i];
		b += a;
	}
	*ck_a = a;
	*ck_b = b;
}

static inline void ubx_put_le32(u8 *buf, u32 val)
{
	buf[0] = val & 0xFF;
	buf[1] = (val >> 8) & 0xFF;
	buf[2] = (val >> 16) & 0xFF;
	buf[3] = (val >> 24) & 0xFF;
}

static int ubx_build_frame(u8 *buf, size_t bufsz, u8 cls, u8 id,
			   const u8 *payload, u16 payload_len)
{
	int total = UBX_OVERHEAD + payload_len;
	u8 ck_a, ck_b;

	if ((int)bufsz < total)
		return -ENOSPC;

	buf[0] = UBX_SYNC1;
	buf[1] = UBX_SYNC2;
	buf[2] = cls;
	buf[3] = id;
	buf[4] = payload_len & 0xFF;
	buf[5] = (payload_len >> 8) & 0xFF;

	if (payload_len > 0 && payload)
		memcpy(buf + UBX_HDR_LEN, payload, payload_len);

	ubx_checksum(buf + 2, 4 + payload_len, &ck_a, &ck_b);
	buf[UBX_HDR_LEN + payload_len] = ck_a;
	buf[UBX_HDR_LEN + payload_len + 1] = ck_b;

	return total;
}

static u32 ubx_get_itow(void)
{
	struct timespec64 ts;
	u64 gps_secs;
	u32 secs_in_week;

	ktime_get_real_ts64(&ts);
	gps_secs = (u64)ts.tv_sec + UBX_LEAP_SECONDS - UBX_GPS_EPOCH_UNIX;
	secs_in_week = do_div(gps_secs, UBX_SECS_PER_WEEK);

	return secs_in_week * 1000 + (u32)(ts.tv_nsec / 1000000);
}

static int ubx_build_mon_ver(u8 *buf, size_t bufsz)
{
	u8 payload[UBX_MON_VER_PAYLOAD_LEN] = {};

	strscpy(payload, "SIM 1.00 (000000)", UBX_MON_VER_SW_LEN);
	strscpy(payload + UBX_MON_VER_SW_LEN, "00190000",
		UBX_MON_VER_HW_LEN);
	strscpy(payload + UBX_MON_VER_SW_LEN + UBX_MON_VER_HW_LEN,
		"PROTVER=29.20", UBX_MON_VER_EXT_LEN);

	return ubx_build_frame(buf, bufsz, UBX_CLASS_MON, UBX_MON_VER,
			       payload, UBX_MON_VER_PAYLOAD_LEN);
}

static int ubx_build_ack(u8 *buf, size_t bufsz, u8 acked_cls, u8 acked_id)
{
	u8 payload[UBX_ACK_ACK_LEN] = { acked_cls, acked_id };

	return ubx_build_frame(buf, bufsz, UBX_CLASS_ACK, UBX_ACK_ACK,
			       payload, UBX_ACK_ACK_LEN);
}

static int ubx_build_nav_status(u8 *buf, size_t bufsz, u8 gps_fix)
{
	u8 payload[UBX_NAV_STATUS_LEN] = {};

	ubx_put_le32(payload, ubx_get_itow());
	payload[4] = gps_fix;
	payload[5] = (gps_fix >= 2) ? 0x0D : 0x00;
	payload[6] = 0x00;	/* fixStat */
	payload[7] = 0x08;	/* flags2: psmState = acquisition */
	ubx_put_le32(payload + 8, 1000);	/* ttff (ms) */
	ubx_put_le32(payload + 12, 60000);	/* msss (ms) */

	return ubx_build_frame(buf, bufsz, UBX_CLASS_NAV, UBX_NAV_STATUS,
			       payload, UBX_NAV_STATUS_LEN);
}

static int ubx_build_nav_clock(u8 *buf, size_t bufsz, u8 gps_fix)
{
	u8 payload[UBX_NAV_CLOCK_LEN] = {};
	u32 t_acc = (gps_fix >= 2) ? 10 : 999999;

	ubx_put_le32(payload, ubx_get_itow());
	ubx_put_le32(payload + 4, 0);		/* clkB: clock bias (ns) */
	ubx_put_le32(payload + 8, 0);		/* clkD: clock drift (ns/s) */
	ubx_put_le32(payload + 12, t_acc);	/* tAcc: time accuracy (ns) */
	ubx_put_le32(payload + 16, 10);		/* fAcc: freq accuracy (ps/s) */

	return ubx_build_frame(buf, bufsz, UBX_CLASS_NAV, UBX_NAV_CLOCK,
			       payload, UBX_NAV_CLOCK_LEN);
}

static void nsim_dpll_ntf_work(struct work_struct *work)
{
	struct nsim_dpll *ndpll = container_of(work, struct nsim_dpll, ntf_work);

	dpll_device_change_ntf(ndpll->pps_dpll);
	dpll_device_change_ntf(ndpll->eec_dpll);
	dpll_pin_change_ntf(ndpll->gnss_pin);
}

static enum hrtimer_restart nsim_dpll_ntf_timer_cb(struct hrtimer *timer)
{
	struct nsim_dpll *ndpll = container_of(timer, struct nsim_dpll,
					       ntf_timer);

	schedule_work(&ndpll->ntf_work);
	hrtimer_forward_now(timer, ns_to_ktime(NSEC_PER_SEC));
	return HRTIMER_RESTART;
}

static void nsim_ubx_insert_locked(struct nsim_dpll *ndpll,
				   const u8 *buf, int len)
{
	unsigned long flags;

	spin_lock_irqsave(&ndpll->gnss_lock, flags);
	gnss_insert_raw(ndpll->gnss_dev, buf, len);
	spin_unlock_irqrestore(&ndpll->gnss_lock, flags);
}

static enum hrtimer_restart nsim_ubx_timer_cb(struct hrtimer *timer)
{
	struct nsim_dpll *ndpll = container_of(timer, struct nsim_dpll,
					       ubx_timer);
	u8 buf[UBX_OVERHEAD + UBX_NAV_CLOCK_LEN];
	unsigned long flags;
	int len;

	if (!ndpll->ubx_nav_enabled || !ndpll->gnss_dev)
		return HRTIMER_NORESTART;

	spin_lock_irqsave(&ndpll->gnss_lock, flags);

	len = ubx_build_nav_status(buf, sizeof(buf), ndpll->gnss_gps_fix);
	if (len > 0)
		gnss_insert_raw(ndpll->gnss_dev, buf, len);

	len = ubx_build_nav_clock(buf, sizeof(buf), ndpll->gnss_gps_fix);
	if (len > 0)
		gnss_insert_raw(ndpll->gnss_dev, buf, len);

	spin_unlock_irqrestore(&ndpll->gnss_lock, flags);

	hrtimer_forward_now(timer, ns_to_ktime(NSEC_PER_SEC));
	return HRTIMER_RESTART;
}

/* ---- NMEA GGA parsing -------------------------------------------------- */

/*
 * Map GGA fix quality (field 6) to UBX gpsFix value:
 *   GGA 0 (invalid)  -> gpsFix 0 (NoFix)
 *   GGA 1 (GPS fix)  -> gpsFix 3 (3D)
 *   GGA 2 (DGPS)     -> gpsFix 3 (3D)
 *   GGA 6 (estimated)-> gpsFix 1 (Dead Reckoning)
 *   Others            -> gpsFix 3 (3D)
 */
static u8 nsim_gga_quality_to_gps_fix(u8 gga_quality)
{
	switch (gga_quality) {
	case 0:
		return 0x00;
	case 6:
		return 0x01;
	default:
		return 0x03;
	}
}

/*
 * Scan buf for a GGA sentence (e.g. $GNGGA or $GPGGA) and extract
 * the fix quality from field 6.  The buffer may contain multiple
 * concatenated NMEA sentences from a single write() call, so we
 * search for '$' start markers rather than only checking buf[0].
 */
static void nsim_parse_gga_fix(struct nsim_dpll *ndpll,
			       const unsigned char *buf, size_t count)
{
	size_t p;

	for (p = 0; p + 10 < count; p++) {
		int commas = 0;
		size_t i;

		if (buf[p] != '$')
			continue;
		if (p + 7 > count)
			break;
		if (memcmp(buf + p + 3, "GGA,", 4) != 0)
			continue;

		for (i = p + 7; i < count; i++) {
			if (buf[i] == '*' || buf[i] == '$')
				break;
			if (buf[i] == ',') {
				commas++;
				if (commas == 5) {
					if (i + 1 < count &&
					    buf[i + 1] >= '0' &&
					    buf[i + 1] <= '9') {
						ndpll->gnss_gps_fix =
							nsim_gga_quality_to_gps_fix(
								buf[i + 1] - '0');
					}
					return;
				}
			}
		}
		return;
	}
}

/* ---- GNSS ops ---------------------------------------------------------- */

static int nsim_gnss_open(struct gnss_device *gdev)
{
	return 0;
}

static void nsim_gnss_close(struct gnss_device *gdev)
{
	struct nsim_dpll *ndpll = gnss_get_drvdata(gdev);

	if (ndpll) {
		ndpll->ubx_nav_enabled = false;
		hrtimer_cancel(&ndpll->ubx_timer);
	}
}

static int nsim_gnss_write_raw(struct gnss_device *gdev,
			       const unsigned char *buf, size_t count)
{
	struct nsim_dpll *ndpll = gnss_get_drvdata(gdev);
	u8 resp[UBX_OVERHEAD + UBX_MON_VER_PAYLOAD_LEN];
	int len;
	u8 cls, id;

	if (!ndpll || count == 0)
		return count;

	/* NMEA sentence: parse GGA fix quality, then echo to read side */
	if (buf[0] == '$') {
		nsim_parse_gga_fix(ndpll, buf, count);
		nsim_ubx_insert_locked(ndpll, buf, count);
		return count;
	}

	/* UBX frame: sync(2) + class(1) + id(1) + len(2) minimum */
	if (count < UBX_HDR_LEN || buf[0] != UBX_SYNC1 || buf[1] != UBX_SYNC2)
		return count;

	cls = buf[2];
	id = buf[3];

	switch (cls) {
	case UBX_CLASS_MON:
		if (id == UBX_MON_VER) {
			len = ubx_build_mon_ver(resp, sizeof(resp));
			if (len > 0)
				nsim_ubx_insert_locked(ndpll, resp, len);
		}
		break;
	case UBX_CLASS_CFG:
		if (id == UBX_CFG_MSG && count >= UBX_HDR_LEN + 3) {
			u8 msg_cls = buf[UBX_HDR_LEN];
			u8 msg_id = buf[UBX_HDR_LEN + 1];

			if (msg_cls == UBX_CLASS_NAV &&
			    (msg_id == UBX_NAV_STATUS ||
			     msg_id == UBX_NAV_CLOCK)) {
				if (!ndpll->ubx_nav_enabled) {
					ndpll->ubx_nav_enabled = true;
					hrtimer_start(&ndpll->ubx_timer,
						      ns_to_ktime(NSEC_PER_SEC),
						      HRTIMER_MODE_REL);
				}
			}

			len = ubx_build_ack(resp, sizeof(resp), cls, id);
			if (len > 0)
				nsim_ubx_insert_locked(ndpll, resp, len);
		}
		break;
	default:
		len = ubx_build_ack(resp, sizeof(resp), cls, id);
		if (len > 0)
			nsim_ubx_insert_locked(ndpll, resp, len);
		break;
	}

	return count;
}

static const struct gnss_operations nsim_gnss_ops = {
	.open		= nsim_gnss_open,
	.close		= nsim_gnss_close,
	.write_raw	= nsim_gnss_write_raw,
};

/* ---- pin properties ---------------------------------------------------- */

static struct dpll_pin_frequency nsim_dpll_gnss_freq[] = {
	DPLL_PIN_FREQUENCY_1PPS,
};

static struct dpll_pin_properties nsim_dpll_gnss_pin_props = {
	.board_label	   = "GNSS-1PPS",
	.type		   = DPLL_PIN_TYPE_GNSS,
	.capabilities	   = 0,
	.freq_supported	   = nsim_dpll_gnss_freq,
	.freq_supported_num = ARRAY_SIZE(nsim_dpll_gnss_freq),
};

/* ---- helpers ----------------------------------------------------------- */

static void nsim_dpll_cleanup_port_pins(struct nsim_dpll *ndpll);

/* ---- init/exit --------------------------------------------------------- */

int nsim_dpll_init(struct nsim_dev *nsim_dev)
{
	struct nsim_dpll *ndpll;
	int err;

	ndpll = kzalloc(sizeof(*ndpll), GFP_KERNEL);
	if (!ndpll)
		return -ENOMEM;

	ndpll->clock_id = NSIM_DPLL_CLOCK_ID;
	INIT_LIST_HEAD(&ndpll->port_pins);

	/* PPS DPLL */
	ndpll->pps_dpll = dpll_device_get(ndpll->clock_id,
					  NSIM_DPLL_PPS_IDX, THIS_MODULE);
	if (IS_ERR(ndpll->pps_dpll)) {
		err = PTR_ERR(ndpll->pps_dpll);
		goto err_free;
	}

	err = dpll_device_register(ndpll->pps_dpll, DPLL_TYPE_PPS,
				   &nsim_dpll_device_ops, ndpll);
	if (err)
		goto err_pps_put;

	/* EEC DPLL */
	ndpll->eec_dpll = dpll_device_get(ndpll->clock_id,
					  NSIM_DPLL_EEC_IDX, THIS_MODULE);
	if (IS_ERR(ndpll->eec_dpll)) {
		err = PTR_ERR(ndpll->eec_dpll);
		goto err_pps_unreg;
	}

	err = dpll_device_register(ndpll->eec_dpll, DPLL_TYPE_EEC,
				   &nsim_dpll_device_ops, ndpll);
	if (err)
		goto err_eec_put;

	/* GNSS input pin on PPS DPLL */
	ndpll->gnss_pin_priv.direction = DPLL_PIN_DIRECTION_INPUT;
	ndpll->gnss_pin_priv.frequency = DPLL_PIN_FREQUENCY_1_HZ;

	ndpll->gnss_pin = dpll_pin_get(ndpll->clock_id,
				       NSIM_DPLL_GNSS_PIN_IDX, THIS_MODULE,
				       &nsim_dpll_gnss_pin_props);
	if (IS_ERR(ndpll->gnss_pin)) {
		err = PTR_ERR(ndpll->gnss_pin);
		goto err_eec_unreg;
	}

	err = dpll_pin_register(ndpll->pps_dpll, ndpll->gnss_pin,
				&nsim_dpll_gnss_pin_ops,
				&ndpll->gnss_pin_priv);
	if (err)
		goto err_gnss_put;

	/*
	 * Start a 1 Hz timer that re-emits DPLL device/pin change
	 * notifications so that late-joining userspace consumers
	 * (e.g. linuxptp-daemon) receive the GNSS pin's phase-offset
	 * data without needing an initial DumpPinGet.
	 */
	INIT_WORK(&ndpll->ntf_work, nsim_dpll_ntf_work);
	hrtimer_init(&ndpll->ntf_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
	ndpll->ntf_timer.function = nsim_dpll_ntf_timer_cb;
	hrtimer_start(&ndpll->ntf_timer, ns_to_ktime(NSEC_PER_SEC),
		      HRTIMER_MODE_REL);

	nsim_dev->dpll = ndpll;

	/* Associate per-port output pins with netdevs */
	{
		struct nsim_dev_port *nsim_dev_port;
		int pin_idx = NSIM_DPLL_GNSS_PIN_IDX + 1;

		list_for_each_entry(nsim_dev_port, &nsim_dev->port_list, list) {
			struct netdevsim *ns = nsim_dev_port->ns;
			struct dpll_pin_properties props = {};
			struct dpll_pin_frequency rclk_freq[] = {
				DPLL_PIN_FREQUENCY(DPLL_PIN_FREQUENCY_10_MHZ),
			};
			struct nsim_dpll_pin *npin;
			struct dpll_pin *pin;

			if (!nsim_dev_port_is_pf(nsim_dev_port))
				continue;

			npin = kzalloc(sizeof(*npin), GFP_KERNEL);
			if (!npin) {
				err = -ENOMEM;
				goto err_ports_cleanup;
			}
			npin->direction = DPLL_PIN_DIRECTION_OUTPUT;
			npin->frequency = DPLL_PIN_FREQUENCY_10_MHZ;
			npin->ns = ns;

			props.board_label = ns->netdev->name;
			props.type = DPLL_PIN_TYPE_SYNCE_ETH_PORT;
			props.capabilities = 0;
			props.freq_supported = rclk_freq;
			props.freq_supported_num = 1;

			pin = dpll_pin_get(ndpll->clock_id, pin_idx,
					   THIS_MODULE, &props);
			if (IS_ERR(pin)) {
				kfree(npin);
				err = PTR_ERR(pin);
				goto err_ports_cleanup;
			}

			err = dpll_pin_register(ndpll->pps_dpll, pin,
						&nsim_dpll_rclk_pin_ops, npin);
			if (err) {
				dpll_pin_put(pin);
				kfree(npin);
				goto err_ports_cleanup;
			}

			dpll_netdev_pin_set(ns->netdev, pin);

			npin->pin = pin;
			list_add_tail(&npin->list, &ndpll->port_pins);
			pin_idx++;
		}
	}

	/* Virtual GNSS device for NMEA passthrough */
	{
		struct gnss_device *gdev;
		struct device *parent;

		if (nsim_dev->fake_pci_dev)
			parent = &nsim_dev->fake_pci_dev->dev;
		else
			parent = &nsim_dev->nsim_bus_dev->dev;

		gdev = gnss_allocate_device(parent);
		if (!gdev) {
			err = -ENOMEM;
			goto err_ports_cleanup;
		}

		gdev->type = GNSS_TYPE_NMEA;
		gdev->ops = &nsim_gnss_ops;

		err = gnss_register_device(gdev);
		if (err) {
			gnss_put_device(gdev);
			goto err_ports_cleanup;
		}

		gnss_set_drvdata(gdev, ndpll);
		ndpll->gnss_dev = gdev;
		spin_lock_init(&ndpll->gnss_lock);
		hrtimer_init(&ndpll->ubx_timer, CLOCK_MONOTONIC,
			     HRTIMER_MODE_REL);
		ndpll->ubx_timer.function = nsim_ubx_timer_cb;
		ndpll->ubx_nav_enabled = false;
		ndpll->gnss_gps_fix = 0x03;
		pr_info("netdevsim: GNSS device registered (gnss%d)\n",
			gdev->id);
	}

	/*
	 * Emit change notifications so that userspace consumers (e.g.
	 * linuxptp-daemon) that subscribe to DPLL multicast before we
	 * register will receive the initial pin state including the
	 * phase offset.
	 */
	dpll_device_change_ntf(ndpll->pps_dpll);
	dpll_device_change_ntf(ndpll->eec_dpll);
	dpll_pin_change_ntf(ndpll->gnss_pin);
	{
		struct nsim_dpll_pin *npin;

		list_for_each_entry(npin, &ndpll->port_pins, list)
			dpll_pin_change_ntf(npin->pin);
	}

	pr_info("netdevsim: DPLL emulation initialized (clock_id=%llu)\n",
		ndpll->clock_id);
	return 0;

err_ports_cleanup:
	hrtimer_cancel(&ndpll->ntf_timer);
	cancel_work_sync(&ndpll->ntf_work);
	nsim_dpll_cleanup_port_pins(ndpll);
	dpll_pin_unregister(ndpll->pps_dpll, ndpll->gnss_pin,
			    &nsim_dpll_gnss_pin_ops, &ndpll->gnss_pin_priv);
err_gnss_put:
	dpll_pin_put(ndpll->gnss_pin);
err_eec_unreg:
	dpll_device_unregister(ndpll->eec_dpll, &nsim_dpll_device_ops, ndpll);
err_eec_put:
	dpll_device_put(ndpll->eec_dpll);
err_pps_unreg:
	dpll_device_unregister(ndpll->pps_dpll, &nsim_dpll_device_ops, ndpll);
err_pps_put:
	dpll_device_put(ndpll->pps_dpll);
err_free:
	kfree(ndpll);
	return err;
}

static void nsim_dpll_cleanup_port_pins(struct nsim_dpll *ndpll)
{
	struct nsim_dpll_pin *npin, *tmp;

	list_for_each_entry_safe(npin, tmp, &ndpll->port_pins, list) {
		dpll_netdev_pin_clear(npin->ns->netdev);
		dpll_pin_unregister(ndpll->pps_dpll, npin->pin,
				    &nsim_dpll_rclk_pin_ops, npin);
		dpll_pin_put(npin->pin);
		list_del(&npin->list);
		kfree(npin);
	}
}

void nsim_dpll_exit(struct nsim_dev *nsim_dev)
{
	struct nsim_dpll *ndpll = nsim_dev->dpll;

	if (!ndpll)
		return;

	hrtimer_cancel(&ndpll->ntf_timer);
	cancel_work_sync(&ndpll->ntf_work);

	if (ndpll->gnss_dev) {
		ndpll->ubx_nav_enabled = false;
		hrtimer_cancel(&ndpll->ubx_timer);
		gnss_deregister_device(ndpll->gnss_dev);
		gnss_put_device(ndpll->gnss_dev);
	}

	nsim_dpll_cleanup_port_pins(ndpll);

	dpll_pin_unregister(ndpll->pps_dpll, ndpll->gnss_pin,
			    &nsim_dpll_gnss_pin_ops, &ndpll->gnss_pin_priv);
	dpll_pin_put(ndpll->gnss_pin);

	dpll_device_unregister(ndpll->eec_dpll, &nsim_dpll_device_ops, ndpll);
	dpll_device_put(ndpll->eec_dpll);

	dpll_device_unregister(ndpll->pps_dpll, &nsim_dpll_device_ops, ndpll);
	dpll_device_put(ndpll->pps_dpll);

	kfree(ndpll);
	nsim_dev->dpll = NULL;

	pr_info("netdevsim: DPLL emulation removed\n");
}
