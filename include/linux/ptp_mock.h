/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Mock-up PTP Hardware Clock driver for virtual network devices
 *
 * Copyright 2023 NXP
 */

#ifndef _PTP_MOCK_H_
#define _PTP_MOCK_H_

#include <linux/ptp_clock_kernel.h>
#include <linux/kref.h>
#include <linux/hrtimer.h>

struct device;
struct mock_phc {
	struct ptp_clock_info info;
	struct ptp_clock *clock;
	int logical_clk_id;
	struct kref ref;
	spinlock_t lock;
	/* MONOTONIC-based timekeeping (immune to phc2sys steps) */
	s64 offset_ns;		/* PHC = monotonic + offset_ns */
	s64 freq_ppb;		/* rate correction from adjfine */
	u64 last_mono_ns;	/* CLOCK_MONOTONIC snapshot at last update */
	/*
	 * E810-style pin layout: GNSS-1PPS input + 4 external connectors.
	 * Pin index 0 = GNSS-1PPS (ts2phc default), followed by SMA1, SMA2,
	 * U.FL1, U.FL2 so the dashboard SMA probe discovers them.
	 */
	struct ptp_pin_desc pins[5];
	/* EXTTS (1PPS) simulation */
	struct hrtimer extts_timer;
	bool extts_enabled;
	int extts_channel;
};

#if IS_ENABLED(CONFIG_PTP_1588_CLOCK_MOCK)

struct mock_phc *mock_phc_create(struct device *dev, int logical_clk_id);
int mock_phc_index(struct mock_phc *phc);
int mock_phc_logical_clk_id(struct mock_phc *phc);
void mock_phc_release(struct mock_phc *phc);
struct kobject *mock_phc_dev_kobj(struct mock_phc *phc);

struct ptp_clock_info *mock_phc_get_ptp_info(struct mock_phc *phc);
#else
struct ptp_clock_info *mock_phc_get_ptp_info(struct mock_phc *phc)
{
  return NULL;
}

static inline struct mock_phc *mock_phc_create(struct device *dev, int logical_clk_id)
{
	return NULL;
}

static inline void mock_phc_destroy(struct mock_phc *phc)
{
}

static inline int mock_phc_index(struct mock_phc *phc)
{
	return -1;
}

#endif

#endif /* _PTP_MOCK_H_ */
