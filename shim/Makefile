CC ?= gcc
CFLAGS ?= -O2 -fPIC -Wall -Wextra
LDFLAGS ?= -shared -ldl -lpthread

LIB = libptp_vrt_shim.so
TESTCLI = test_vrt_cli

.PHONY: all clean install

all: $(LIB) $(TESTCLI)

$(LIB): ptp_vrt_shim.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

$(TESTCLI): test_vrt_cli.c
	$(CC) -O2 -Wall -Wextra -o $@ $<

clean:
	rm -f $(LIB) $(TESTCLI)

install: $(LIB)
	install -d $(DESTDIR)/usr/local/lib
	install -m 755 $(LIB) $(DESTDIR)/usr/local/lib/
	install -d $(DESTDIR)/usr/local/sbin
	install -m 755 phc2sys-wrapper $(DESTDIR)/usr/local/sbin/phc2sys-wrapper
