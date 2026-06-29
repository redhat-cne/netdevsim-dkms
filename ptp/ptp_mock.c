// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright 2023 NXP
 *
 * Mock-up PTP Hardware Clock driver for virtual network devices
 *
 * The PHC time is derived from CLOCK_MONOTONIC plus an accumulated offset.
 * CLOCK_MONOTONIC never steps (immune to phc2sys stepping CLOCK_REALTIME/TAI)
 * and its rate is NTP-adjusted so freq_ppb stays near zero.  adjfine()
 * applies a frequency correction on top of this base so the PTP servo
 * feedback loop operates normally.
 *
 * Two PTP pins are exposed so PTP_PIN_SETFUNC2 with pin index 1 (typical for
 * 1PPS input on Intel-style devices) succeeds; both may map EXTTS to channel 0.
 */

#include <dkms_compat.h>
#include <linux/ptp_mock.h>
#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/ktime.h>

#include "ptp_private.h"

#define MOCK_PHC_MAX_ADJ_PPB	500000000

#define info_to_phc(d) container_of((d), struct mock_phc, info)

struct ptp_clock_info *mock_phc_get_ptp_info(struct mock_phc *phc)
{
	return &phc->info;
}
EXPORT_SYMBOL_GPL(mock_phc_get_ptp_info);

/*
 * Advance the internal bookkeeping: accumulate the frequency-induced
 * drift since the last update and snapshot the monotonic time.
 * Returns the PHC time = monotonic + accumulated offset.
 * Must be called with phc->lock held.
 */
static u64 mock_phc_read_locked(struct mock_phc *phc)
{
	u64 raw = ktime_get_ns();
	s64 elapsed = (s64)(raw - phc->last_mono_ns);
	s64 drift;

	if (elapsed > 0 && phc->freq_ppb != 0) {
		drift = div_s64(elapsed * phc->freq_ppb, 1000000000LL);
		phc->offset_ns += drift;
	}
	phc->last_mono_ns = raw;

	return (u64)((s64)raw + phc->offset_ns);
}

static int mock_phc_adjfine(struct ptp_clock_info *info, long scaled_ppm)
{
	struct mock_phc *phc = info_to_phc(info);
	unsigned long flags;

	spin_lock_irqsave(&phc->lock, flags);
	mock_phc_read_locked(phc);
	phc->freq_ppb = div_s64((s64)scaled_ppm * 1000LL, 65536LL);
	spin_unlock_irqrestore(&phc->lock, flags);

	return 0;
}

static int mock_phc_adjtime(struct ptp_clock_info *info, s64 delta)
{
	struct mock_phc *phc = info_to_phc(info);
	unsigned long flags;

	spin_lock_irqsave(&phc->lock, flags);
	mock_phc_read_locked(phc);
	phc->offset_ns += delta;
	spin_unlock_irqrestore(&phc->lock, flags);

	return 0;
}

static int mock_phc_settime64(struct ptp_clock_info *info,
			      const struct timespec64 *ts)
{
	struct mock_phc *phc = info_to_phc(info);
	unsigned long flags;
	u64 raw;

	spin_lock_irqsave(&phc->lock, flags);
	raw = ktime_get_ns();
	phc->last_mono_ns = raw;
	phc->offset_ns = (s64)(timespec64_to_ns(ts)) - (s64)raw;
	phc->freq_ppb = 0;
	spin_unlock_irqrestore(&phc->lock, flags);

	return 0;
}

static int mock_phc_gettime64(struct ptp_clock_info *info,
			      struct timespec64 *ts)
{
	struct mock_phc *phc = info_to_phc(info);
	unsigned long flags;
	u64 ns;

	spin_lock_irqsave(&phc->lock, flags);
	ns = mock_phc_read_locked(phc);
	spin_unlock_irqrestore(&phc->lock, flags);

	*ts = ns_to_timespec64(ns);

	return 0;
}

/*
 * Poll the PHC time at a high rate and emit one EXTTS event each time
 * the PHC second counter increments.  The event timestamp is always
 * the exact PHC second boundary (sec * 1e9).
 *
 * Why polling?  Computing the exact monotonic instant of the next PHC
 * second requires arithmetic involving freq_ppb that is fragile under
 * large offsets or frequency swings.  Polling at 100 ms is cheap and
 * bulletproof: hrtimer_forward_now + HRTIMER_RESTART never stops, and
 * the last_extts_sec dedup means exactly one event per PHC second.
 */
#define EXTTS_POLL_NS	(NSEC_PER_SEC / 10)	/* 100 ms */

static enum hrtimer_restart mock_phc_extts_timer(struct hrtimer *timer)
{
	struct mock_phc *phc = container_of(timer, struct mock_phc, extts_timer);
	struct ptp_clock_event event;
	unsigned long flags;
	u64 phc_ns;
	u64 sec;

	if (!READ_ONCE(phc->extts_enabled))
		goto reschedule;

	spin_lock_irqsave(&phc->lock, flags);
	phc_ns = mock_phc_read_locked(phc);
	spin_unlock_irqrestore(&phc->lock, flags);

	sec = div_u64(phc_ns, NSEC_PER_SEC);

	if (sec != phc->last_extts_sec) {
		phc->last_extts_sec = sec;

		event.timestamp = sec * NSEC_PER_SEC;
		event.type = PTP_CLOCK_EXTTS;
		event.index = phc->extts_channel;
		ptp_clock_event(phc->clock, &event);
	}

reschedule:
	hrtimer_forward_now(timer, ns_to_ktime(EXTTS_POLL_NS));
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
		if (rq->extts.index >= info->n_ext_ts)
			return -EINVAL;
		if (on) {
			phc->extts_channel = rq->extts.index;
			phc->last_extts_sec = 0;
			/* Barrier ensures channel/sec are visible before flag */
			smp_wmb();
			WRITE_ONCE(phc->extts_enabled, true);
		} else {
			WRITE_ONCE(phc->extts_enabled, false);
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

struct kobject *mock_phc_dev_kobj(struct mock_phc *phc)
{
	return &phc->clock->dev.kobj;
}
EXPORT_SYMBOL_GPL(mock_phc_dev_kobj);

struct mock_phc *mock_phc_create(struct device *dev, int logical_clk_id)
{
	struct mock_phc *phc;
	int err;

	phc = kzalloc(sizeof(*phc), GFP_KERNEL);
	if (!phc) {
		err = -ENOMEM;
		goto out;
	}

	strscpy(phc->pins[0].name, "GNSS-1PPS", sizeof(phc->pins[0].name));
	phc->pins[0].index = 0;
	phc->pins[0].func = PTP_PF_EXTTS;
	phc->pins[0].chan = 0;

	strscpy(phc->pins[1].name, "SMA1", sizeof(phc->pins[1].name));
	phc->pins[1].index = 1;
	phc->pins[1].func = PTP_PF_NONE;
	phc->pins[1].chan = 0;

	strscpy(phc->pins[2].name, "SMA2", sizeof(phc->pins[2].name));
	phc->pins[2].index = 2;
	phc->pins[2].func = PTP_PF_NONE;
	phc->pins[2].chan = 0;

	strscpy(phc->pins[3].name, "U.FL1", sizeof(phc->pins[3].name));
	phc->pins[3].index = 3;
	phc->pins[3].func = PTP_PF_NONE;
	phc->pins[3].chan = 0;

	strscpy(phc->pins[4].name, "U.FL2", sizeof(phc->pins[4].name));
	phc->pins[4].index = 4;
	phc->pins[4].func = PTP_PF_NONE;
	phc->pins[4].chan = 0;

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
		.enable		= mock_phc_enable,
		.verify		= mock_phc_verify,
	};

	phc->logical_clk_id = logical_clk_id;

	spin_lock_init(&phc->lock);
	kref_init(&phc->ref);

	hrtimer_init(&phc->extts_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
	phc->extts_timer.function = mock_phc_extts_timer;

	phc->last_mono_ns = ktime_get_ns();
	phc->offset_ns = 0;
	phc->freq_ppb = 0;

	phc->clock = ptp_clock_register(&phc->info, dev);
	if (!IS_ERR(phc->clock))
		hrtimer_start(&phc->extts_timer, ns_to_ktime(EXTTS_POLL_NS),
			      HRTIMER_MODE_REL);
	if (IS_ERR(phc->clock)) {
		err = PTR_ERR(phc->clock);
		goto out_free_phc;
	}

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
	pr_info("Releasing mock phc. Current ref count before kref_put: %u\n",
		kref_read(&phc->ref));

	kref_put(&phc->ref, mock_phc_destroy);
}
EXPORT_SYMBOL_GPL(mock_phc_release);

MODULE_DESCRIPTION("Mock-up PTP Hardware Clock driver");
MODULE_LICENSE("GPL");
