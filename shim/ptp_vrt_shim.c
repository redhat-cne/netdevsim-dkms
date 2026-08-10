/*
 * CI-only LD_PRELOAD shim: redirect CLOCK_REALTIME ops from phc2sys onto a
 * per-node stand-in mock PHC, and rewrite PTP_SYS_OFFSET* so measurement uses
 * that virtual RT instead of the shared host CLOCK_REALTIME.
 *
 * Activation: set PTP_VRT_PHC=/dev/ptpN (or PTP_VRT_DEVICE_FILE pointing at a
 * file that contains that path). Inactive when unset/missing.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/timex.h>
#include <time.h>
#include <unistd.h>
#include <linux/ptp_clock.h>

#ifndef CLOCKFD
#define CLOCKFD 3
#endif
#ifndef FD_TO_CLOCKID
#define FD_TO_CLOCKID(fd) ((clockid_t)((((unsigned int)~(fd)) << 3) | CLOCKFD))
#endif

typedef int (*clock_gettime_fn)(clockid_t, struct timespec *);
typedef int (*clock_settime_fn)(clockid_t, const struct timespec *);
typedef int (*clock_adjtime_fn)(clockid_t, struct timex *);
typedef int (*adjtimex_fn)(struct timex *);
typedef int (*ioctl_fn)(int, unsigned long, ...);

static clock_gettime_fn real_clock_gettime;
static clock_settime_fn real_clock_settime;
static clock_adjtime_fn real_clock_adjtime;
static adjtimex_fn real_adjtimex;
static ioctl_fn real_ioctl;

static pthread_once_t once = PTHREAD_ONCE_INIT;
static int vrt_fd = -1;
static clockid_t vrt_clk = CLOCK_REALTIME;
static bool vrt_active;

static void resolve_reals(void)
{
	real_clock_gettime = (clock_gettime_fn)dlsym(RTLD_NEXT, "clock_gettime");
	real_clock_settime = (clock_settime_fn)dlsym(RTLD_NEXT, "clock_settime");
	real_clock_adjtime = (clock_adjtime_fn)dlsym(RTLD_NEXT, "clock_adjtime");
	real_adjtimex = (adjtimex_fn)dlsym(RTLD_NEXT, "adjtimex");
	real_ioctl = (ioctl_fn)dlsym(RTLD_NEXT, "ioctl");
}

static void init_vrt(void)
{
	const char *path = NULL;
	char buf[256];
	const char *file;

	resolve_reals();

	path = getenv("PTP_VRT_PHC");
	if (!path || !path[0]) {
		file = getenv("PTP_VRT_DEVICE_FILE");
		if (!file || !file[0])
			file = "/var/run/vrt/device";
		FILE *f = fopen(file, "r");
		if (!f)
			return;
		if (!fgets(buf, sizeof(buf), f)) {
			fclose(f);
			return;
		}
		fclose(f);
		buf[strcspn(buf, "\r\n")] = '\0';
		if (!buf[0])
			return;
		path = buf;
	}

	vrt_fd = open(path, O_RDWR);
	if (vrt_fd < 0)
		return;

	vrt_clk = FD_TO_CLOCKID(vrt_fd);
	vrt_active = true;
}

static void ensure_init(void)
{
	pthread_once(&once, init_vrt);
}

static bool is_rt(clockid_t clk)
{
	return clk == CLOCK_REALTIME;
}

static void ts_to_ptp(const struct timespec *ts, struct ptp_clock_time *pct)
{
	pct->sec = ts->tv_sec;
	pct->nsec = (unsigned int)ts->tv_nsec;
	pct->reserved = 0;
}

static int read_vrt(struct timespec *ts)
{
	return real_clock_gettime(vrt_clk, ts);
}

static int read_phc_fd(int fd, struct timespec *ts)
{
	clockid_t clk = FD_TO_CLOCKID(fd);
	return real_clock_gettime(clk, ts);
}

static int fake_sys_offset(int fd, struct ptp_sys_offset *sysoff)
{
	unsigned int i, n;
	struct timespec ts;

	if (!sysoff)
		return -1;
	n = sysoff->n_samples;
	if (n > PTP_MAX_SAMPLES) {
		errno = EINVAL;
		return -1;
	}

	/* Interleaved sys, phc, ... ending with an extra sys sample. */
	for (i = 0; i < n; i++) {
		if (read_vrt(&ts) < 0)
			return -1;
		ts_to_ptp(&ts, &sysoff->ts[2 * i]);
		if (read_phc_fd(fd, &ts) < 0)
			return -1;
		ts_to_ptp(&ts, &sysoff->ts[2 * i + 1]);
	}
	if (read_vrt(&ts) < 0)
		return -1;
	ts_to_ptp(&ts, &sysoff->ts[2 * n]);
	return 0;
}

static int fake_sys_offset_extended(int fd, struct ptp_sys_offset_extended *ex)
{
	unsigned int i, n;
	struct timespec pre, mid, post;

	if (!ex)
		return -1;
	n = ex->n_samples;
	if (n > PTP_MAX_SAMPLES) {
		errno = EINVAL;
		return -1;
	}
	for (i = 0; i < n; i++) {
		if (read_vrt(&pre) < 0)
			return -1;
		if (read_phc_fd(fd, &mid) < 0)
			return -1;
		if (read_vrt(&post) < 0)
			return -1;
		ts_to_ptp(&pre, &ex->ts[i][0]);
		ts_to_ptp(&mid, &ex->ts[i][1]);
		ts_to_ptp(&post, &ex->ts[i][2]);
	}
	return 0;
}

static int fake_sys_offset_precise(int fd, struct ptp_sys_offset_precise *pr)
{
	struct timespec dev, sys;

	if (!pr)
		return -1;
	if (read_phc_fd(fd, &dev) < 0)
		return -1;
	if (read_vrt(&sys) < 0)
		return -1;
	ts_to_ptp(&dev, &pr->device);
	ts_to_ptp(&sys, &pr->sys_realtime);
	/* sys_monoraw unused by phc2sys RT path; leave zeroed. */
	memset(&pr->sys_monoraw, 0, sizeof(pr->sys_monoraw));
	return 0;
}

int clock_gettime(clockid_t clk, struct timespec *tp)
{
	ensure_init();
	if (vrt_active && is_rt(clk))
		return real_clock_gettime(vrt_clk, tp);
	return real_clock_gettime(clk, tp);
}

int clock_settime(clockid_t clk, const struct timespec *tp)
{
	ensure_init();
	if (vrt_active && is_rt(clk))
		return real_clock_settime(vrt_clk, tp);
	return real_clock_settime(clk, tp);
}

int clock_adjtime(clockid_t clk, struct timex *buf)
{
	ensure_init();
	if (vrt_active && is_rt(clk))
		return real_clock_adjtime(vrt_clk, buf);
	return real_clock_adjtime(clk, buf);
}

int adjtimex(struct timex *buf)
{
	ensure_init();
	if (vrt_active)
		return real_clock_adjtime(vrt_clk, buf);
	return real_adjtimex(buf);
}

int ioctl(int fd, unsigned long request, ...)
{
	va_list ap;
	void *arg;
	int rc;

	ensure_init();

	va_start(ap, request);
	arg = va_arg(ap, void *);
	va_end(ap);

	if (vrt_active && fd >= 0 && fd != vrt_fd) {
		switch (request) {
		case PTP_SYS_OFFSET:
		case PTP_SYS_OFFSET2:
			rc = fake_sys_offset(fd, arg);
			return rc;
		case PTP_SYS_OFFSET_EXTENDED:
		case PTP_SYS_OFFSET_EXTENDED2:
			rc = fake_sys_offset_extended(fd, arg);
			return rc;
		case PTP_SYS_OFFSET_PRECISE:
		case PTP_SYS_OFFSET_PRECISE2:
			rc = fake_sys_offset_precise(fd, arg);
			return rc;
		default:
			break;
		}
	}

	return real_ioctl(fd, request, arg);
}
