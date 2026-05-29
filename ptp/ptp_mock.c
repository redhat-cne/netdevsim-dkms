// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright 2023 NXP
 *
 * Mock-up PTP Hardware Clock driver for virtual network devices
 *
 * Create a PTP clock which offers PTP time manipulation operations
 * using a timecounter/cyclecounter on top of CLOCK_MONOTONIC_RAW.
 *
 * Two PTP pins are exposed so PTP_PIN_SETFUNC2 with pin index 1 (typical for
 * 1PPS input on Intel-style devices) succeeds; both may map EXTTS to channel 0.
 */

#include <dkms_compat.h>
#include <linux/ptp_mock.h>
#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/timecounter.h>
#include <linux/ktime.h>

/* Clamp scaled_ppm between -32,768,000,000 and 32,768,000,000,
 * and thus "adj" between -1,073,741,824 and 1,073,741,824
 */
#define MOCK_PHC_MAX_ADJ_PPB		500000000
/* Timestamps from ktime_get_raw() have 1 ns resolution, so the scale factor
 * (MULT >> SHIFT) needs to be 1. Pick SHIFT as 31 bits, which translates
 * MULT(freq 0) into 0x80000000.
 */
#define MOCK_PHC_CC_SHIFT		31
#define MOCK_PHC_CC_MULT		(1 << MOCK_PHC_CC_SHIFT)
#define MOCK_PHC_FADJ_SHIFT		9
#define MOCK_PHC_FADJ_DENOMINATOR	15625ULL

/* The largest cycle_delta that timecounter_read_delta() can handle without a
 * 64-bit overflow during the multiplication with cc->mult, given the max "adj"
 * we permit, is ~5.7 seconds. Make sure readouts are more frequent than that.
 */
#define MOCK_PHC_REFRESH_INTERVAL	(HZ * 3)

#define info_to_phc(d) container_of((d), struct mock_phc, info)

struct ptp_clock_info *mock_phc_get_ptp_info(struct mock_phc *phc)
{
	return &phc->info;
}
EXPORT_SYMBOL_GPL(mock_phc_get_ptp_info);

static u64 mock_phc_cc_read(CYCLECOUNTER_READ_CONST struct cyclecounter *cc)
{
	return ktime_get_raw_ns();
}

static int mock_phc_adjfine(struct ptp_clock_info *info, long scaled_ppm)
{
	struct mock_phc *phc = info_to_phc(info);
	unsigned long flags;
	s64 adj;

	adj = (s64)scaled_ppm << MOCK_PHC_FADJ_SHIFT;
	adj = div_s64(adj, MOCK_PHC_FADJ_DENOMINATOR);

	spin_lock_irqsave(&phc->lock, flags);
	timecounter_read(&phc->tc);
	phc->cc.mult = MOCK_PHC_CC_MULT + adj;
	spin_unlock_irqrestore(&phc->lock, flags);

	return 0;
}

static int mock_phc_adjtime(struct ptp_clock_info *info, s64 delta)
{
	struct mock_phc *phc = info_to_phc(info);
	unsigned long flags;

	spin_lock_irqsave(&phc->lock, flags);
	timecounter_adjtime(&phc->tc, delta);
	spin_unlock_irqrestore(&phc->lock, flags);

	return 0;
}

static int mock_phc_settime64(struct ptp_clock_info *info,
			      const struct timespec64 *ts)
{
	struct mock_phc *phc = info_to_phc(info);
	u64 ns = timespec64_to_ns(ts);
	unsigned long flags;

	spin_lock_irqsave(&phc->lock, flags);
	timecounter_init(&phc->tc, &phc->cc, ns);
	spin_unlock_irqrestore(&phc->lock, flags);

	return 0;
}

static int mock_phc_gettime64(struct ptp_clock_info *info, struct timespec64 *ts)
{
	struct mock_phc *phc = info_to_phc(info);
	unsigned long flags;
	u64 ns;

	spin_lock_irqsave(&phc->lock, flags);
	ns = timecounter_read(&phc->tc);
	spin_unlock_irqrestore(&phc->lock, flags);

	*ts = ns_to_timespec64(ns);

	return 0;
}

static long mock_phc_refresh(struct ptp_clock_info *info)
{
	struct timespec64 ts;

	mock_phc_gettime64(info, &ts);

	return MOCK_PHC_REFRESH_INTERVAL;
}

static enum hrtimer_restart mock_phc_extts_timer(struct hrtimer *timer)
{
	struct mock_phc *phc = container_of(timer, struct mock_phc, extts_timer);
	struct ptp_clock_event event;

	/*
	 * Report the TAI second boundary as the EXTTS timestamp.  ts2phc
	 * converts NMEA (UTC) to TAI via its leap-second file, so the
	 * EXTTS timestamp must also be in TAI for offset ≈ 0.
	 */
	event.type = PTP_CLOCK_EXTTS;
	event.index = phc->extts_channel;
	event.timestamp = div64_u64(ktime_get_clocktai_ns(),
				    NSEC_PER_SEC) * NSEC_PER_SEC;
	ptp_clock_event(phc->clock, &event);

	hrtimer_forward_now(timer, ns_to_ktime(NSEC_PER_SEC));
	return HRTIMER_RESTART;
}

static int mock_phc_verify(struct ptp_clock_info *info, unsigned int pin,
			   enum ptp_pin_function func, unsigned int chan)
{
	return 0;
}

static int mock_phc_enable(struct ptp_clock_info *info,
			   struct ptp_clock_request *rq, int on)
{
	struct mock_phc *phc = info_to_phc(info);

	switch (rq->type) {
	case PTP_CLK_REQ_EXTTS: {
		u64 now_ns, ns_to_next;

		if (rq->extts.index >= info->n_ext_ts)
			return -EINVAL;
		if (on) {
			phc->extts_channel = rq->extts.index;
			phc->extts_enabled = true;
			now_ns = ktime_get_real_ns();
			ns_to_next = NSEC_PER_SEC -
				     do_div(now_ns, NSEC_PER_SEC);
			hrtimer_start(&phc->extts_timer,
				      ns_to_ktime(ns_to_next),
				      HRTIMER_MODE_REL);
		} else {
			phc->extts_enabled = false;
			hrtimer_cancel(&phc->extts_timer);
		}
		return 0;
	}
	default:
		return -EOPNOTSUPP;
	}
}

int mock_phc_index(struct mock_phc *phc)
{
	return ptp_clock_index(phc->clock);
}
EXPORT_SYMBOL_GPL(mock_phc_index);

int mock_phc_logical_clk_id(struct mock_phc *phc)
{
	return phc->logical_clk_id;
}
EXPORT_SYMBOL_GPL(mock_phc_logical_clk_id);

struct mock_phc *mock_phc_create(struct device *dev, int logical_clk_id)
{
	struct mock_phc *phc;
	int err;

	phc = kzalloc(sizeof(*phc), GFP_KERNEL);
	if (!phc) {
		err = -ENOMEM;
		goto out;
	}

	strscpy(phc->pins[0].name, "NONE", sizeof(phc->pins[0].name));
	phc->pins[0].index = 0;
	phc->pins[0].func = PTP_PF_NONE;
	phc->pins[0].chan = 0;

	strscpy(phc->pins[1].name, "GNSS1PPS", sizeof(phc->pins[1].name));
	phc->pins[1].index = 1;
	phc->pins[1].func = PTP_PF_NONE;
	phc->pins[1].chan = 0;

	phc->info = (struct ptp_clock_info) {
		.owner		= THIS_MODULE,
		.name		= "Mock-up PTP clock",
		.max_adj	= MOCK_PHC_MAX_ADJ_PPB,
		.n_ext_ts	= 1,
		.n_pins		= ARRAY_SIZE(phc->pins),
		.pin_config	= phc->pins,
		.adjfine	= mock_phc_adjfine,
		.adjtime	= mock_phc_adjtime,
		.gettime64	= mock_phc_gettime64,
		.settime64	= mock_phc_settime64,
		.do_aux_work	= mock_phc_refresh,
		.enable		= mock_phc_enable,
		.verify		= mock_phc_verify,
	};

	phc->logical_clk_id = logical_clk_id;

	phc->cc = (struct cyclecounter) {
		.read	= mock_phc_cc_read,
		.mask	= CYCLECOUNTER_MASK(64),
		.mult	= MOCK_PHC_CC_MULT,
		.shift	= MOCK_PHC_CC_SHIFT,
	};

	spin_lock_init(&phc->lock);
	kref_init(&phc->ref);

	hrtimer_init(&phc->extts_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
	phc->extts_timer.function = mock_phc_extts_timer;

	timecounter_init(&phc->tc, &phc->cc, ktime_get_clocktai_ns());

	phc->clock = ptp_clock_register(&phc->info, dev);
	if (IS_ERR(phc->clock)) {
		err = PTR_ERR(phc->clock);
		goto out_free_phc;
	}

	ptp_schedule_worker(phc->clock, MOCK_PHC_REFRESH_INTERVAL);

	return phc;

out_free_phc:
	kfree(phc);
out:
	return ERR_PTR(err);
}
EXPORT_SYMBOL_GPL(mock_phc_create);

static void mock_phc_destroy(struct kref *ref)
{
	struct mock_phc *phc = container_of(ref, struct mock_phc, ref);

	hrtimer_cancel(&phc->extts_timer);
	ptp_clock_unregister(phc->clock);
	kfree(phc);
}

void mock_phc_release(struct mock_phc *phc)
{
	pr_info("Releasing mock phc. Current ref count before kref_put: %u\n", kref_read(&phc->ref));

	kref_put(&phc->ref, mock_phc_destroy);
}
EXPORT_SYMBOL_GPL(mock_phc_release);


MODULE_DESCRIPTION("Mock-up PTP Hardware Clock driver");
MODULE_LICENSE("GPL");
