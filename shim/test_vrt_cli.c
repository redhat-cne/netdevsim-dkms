/* Minimal CLI to verify LD_PRELOAD redirects CLOCK_REALTIME to PTP_VRT_PHC. */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <sys/timex.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	struct timespec ts, ts2;
	struct timex tx;
	const char *cmd = argc > 1 ? argv[1] : "gettime";

	if (strcmp(cmd, "gettime") == 0) {
		if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
			perror("clock_gettime");
			return 1;
		}
		printf("%ld.%09ld\n", (long)ts.tv_sec, ts.tv_nsec);
		return 0;
	}
	if (strcmp(cmd, "step") == 0) {
		memset(&tx, 0, sizeof(tx));
		tx.modes = ADJ_SETOFFSET | ADJ_NANO;
		tx.time.tv_sec = 0;
		tx.time.tv_usec = 1000; /* 1000 ns when ADJ_NANO */
		if (clock_adjtime(CLOCK_REALTIME, &tx) < 0) {
			perror("clock_adjtime");
			return 1;
		}
		if (clock_gettime(CLOCK_REALTIME, &ts2) != 0) {
			perror("clock_gettime");
			return 1;
		}
		printf("after_step %ld.%09ld\n", (long)ts2.tv_sec, ts2.tv_nsec);
		return 0;
	}
	fprintf(stderr, "usage: %s [gettime|step]\n", argv[0]);
	return 2;
}
