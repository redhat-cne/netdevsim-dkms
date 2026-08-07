# netdevsim-dkms Architecture

Out-of-tree DKMS package that brings an enhanced **netdevsim** kernel
module — with fake PCI device simulation, DPLL/GNSS emulation, PTP
hardware clock support, and logical clock ID sharing — to standard
Ubuntu runners without requiring custom kernel builds or dedicated
hardware.

Source: [github.com/redhat-cne/netdevsim-dkms](https://github.com/redhat-cne/netdevsim-dkms)
Based on: Linux 6.9.5 kernel sources

---

## Why This Exists

The upstream kernel ships `netdevsim`, `ptp`, and `dpll` subsystems
either built-in (`=y`) or as modules (`=m`).  The upstream versions
lack simulation features needed by `ptp-operator` CI (mock PTP clocks,
EXTTS, DPLL pin emulation, fake PCI topology).  Building a custom
kernel for every CI run is impractical, so this DKMS package installs
enhanced modules alongside the stock kernel.

The key challenge is **symbol collision**: loading a second `ptp.ko` or
`dpll.ko` would conflict with the kernel's own copies.  This is solved
by the **nsim\_ symbol prefix** layer (see below).

---

## Module Map

```
┌──────────────────────────────────────────────────────────────┐
│                     netdevsim.ko                             │
│  Fake PCI bus · devlink · ethtool · FIB · BPF offload ·     │
│  IPsec · MACsec · hwstats · UDP tunnels · psample · DPLL    │
│                                                              │
│  Imports: nsim_ptp_*, nsim_dpll_*, nsim_mock_phc_*           │
├──────────────┬───────────────────────────┬───────────────────┤
│ nsim_ptp.ko  │   nsim_ptp_mock.ko        │  nsim_dpll.ko     │
│              │                           │                   │
│ PTP core:    │ Mock PTP clock:           │ DPLL subsystem:   │
│ clock reg,   │ kref lifecycle,           │ device/pin reg,   │
│ chardev,     │ 2-pin layout,             │ netlink,          │
│ sysfs,       │ EXTTS simulation,         │ multicast_allns,  │
│ vclock       │ logical clock IDs         │ change ntf        │
│              │                           │                   │
│ Exports:     │ Exports:                  │ Exports:          │
│ nsim_ptp_*   │ nsim_mock_phc_*           │ nsim_dpll_*       │
└──────────────┴───────────────────────────┴───────────────────┘
```

| Module | Source dir | Built from | Description |
|--------|-----------|------------|-------------|
| `nsim_ptp.ko` | `ptp/` | `ptp_clock.c`, `ptp_chardev.c`, `ptp_sysfs.c`, `ptp_vclock.c` | PTP core with `nsim_ptp_class` export |
| `nsim_ptp_mock.ko` | `ptp/` | `ptp_mock.c` | Mock PTP hardware clock with EXTTS simulation |
| `nsim_dpll.ko` | `dpll/` | `dpll_core.c`, `dpll_netlink.c`, `dpll_nl.c` | DPLL subsystem with cross-namespace genetlink |
| `netdevsim.ko` | `netdevsim/` | 14 source files (see below) | Main simulation driver |

### netdevsim.ko components

| File | Feature | Kernel config gate |
|------|---------|-------------------|
| `netdev.c` | Net device, ethtool, module entry | always |
| `dev.c` | Device lifecycle, devlink, debugfs | always |
| `bus.c` | Simulated bus, sysfs new/del device | always |
| `fakepci.c` | Fake PCI host bridge and device | always |
| `ethtool.c` | Ethtool ops, PHC index reporting | always |
| `fib.c` | FIB offload simulation | always |
| `health.c` | Devlink health reporters | always |
| `hwstats.c` | Hardware statistics simulation | always |
| `udp_tunnels.c` | UDP tunnel NIC offload simulation | always |
| `dpll.c` | DPLL pin wiring into netdevsim | always |
| `bpf.c` | BPF program offload | `CONFIG_BPF_SYSCALL` |
| `ipsec.c` | IPsec / XFRM offload | `CONFIG_XFRM_OFFLOAD` |
| `psample.c` | Packet sampling | `CONFIG_PSAMPLE` |
| `macsec.c` | MACsec offload | `CONFIG_MACSEC` |

---

## Build Order and Symbol Dependencies

```
     ┌─────────┐
     │  ptp/   │  ← builds first
     │ nsim_ptp│  ← exports nsim_ptp_clock_register, nsim_ptp_class, ...
     │ nsim_ptp│     nsim_mock_phc_create, nsim_mock_phc_index, ...
     │  _mock  │
     └────┬────┘
          │ Module.symvers
     ┌────▼────┐
     │  dpll/  │  ← builds second
     │nsim_dpll│  ← exports nsim_dpll_device_register, nsim_dpll_pin_get, ...
     └────┬────┘
          │ Module.symvers
     ┌────▼──────┐
     │ netdevsim/│  ← builds last, KBUILD_EXTRA_SYMBOLS from ptp + dpll
     │ netdevsim │  ← imports nsim_ptp_* and nsim_dpll_*, no own exports
     └───────────┘
```

The top-level `Makefile` enforces this order:

```makefile
all:
    $(MAKE) -C $(KDIR) M=$(PWD)/ptp    ... modules
    $(MAKE) -C $(KDIR) M=$(PWD)/dpll   ... modules
    $(MAKE) -C $(KDIR) M=$(PWD)/netdevsim \
        KBUILD_EXTRA_SYMBOLS="$(PWD)/ptp/Module.symvers $(PWD)/dpll/Module.symvers" \
        modules
```

---

## Symbol Renaming (nsim\_ prefix)

`include/nsim_rename.h` contains ~70 `#define` macros that rename every
exported and link-visible symbol:

```c
#define ptp_clock_register    nsim_ptp_clock_register
#define dpll_device_register  nsim_dpll_device_register
#define mock_phc_create       nsim_mock_phc_create
// ... etc
```

This is included transitively by every source file via:

```
source.c → netdevsim.h (or ptp_private.h) → dkms_compat.h → nsim_rename.h
```

The C source files remain **unmodified** from the 6.9.5 kernel; all
renaming happens at the preprocessor level.

---

## Kernel Version Compatibility Layer

`include/dkms_compat.h` provides shims so the 6.9.5 source compiles on
kernels from **6.8** (Ubuntu 22.04) through **6.17** (Ubuntu 24.04 HWE):

| Shim | Kernel boundary | What changed |
|------|----------------|--------------|
| `HAVE_POSIX_CLOCK_CONTEXT` | >= 6.8 | PTP chardev gets per-fd context struct |
| `HAVE_PTP_CLOCK_EXTOFF` | >= 6.9 | External-timestamp-as-offset support |
| `PTP_EXTTS_EVENT_VALID` / `PTP_EXT_OFFSET` | < 6.9 → stub 0 | Flags didn't exist in 6.8 |
| `DPLL_DEVICE_CONST` / `DPLL_PIN_CONST` | >= 6.8 | Const-qualified DPLL ops pointers |
| `DPLL_NO_LOCK_STATUS_ERROR` | < 6.9 | Lock status error enum didn't exist |
| `genlmsg_multicast_allns` | < 6.9 / >= 6.12 | Signature changed 3 times across versions |
| `nla_put_sint` | < 6.7 | Inline fallback for missing helper |
| `hrtimer_init` → `hrtimer_setup` | >= 6.15 | Old API removed in favor of combined init |
| `CYCLECOUNTER_READ_CONST` | >= 6.14 | Const qualifier removed from read callback |
| `no_llseek` → `noop_llseek` | >= 6.12 | Symbol removed from fs.h |
| `HAVE_DEBUGFS_GET_AUX` | >= 6.16 | `debugfs_real_fops` removed, new aux API |
| `HAVE_XFRMDEV_OPS_DEV_PARAM` | >= 6.16 | xfrm callbacks gained `net_device *` param |
| `UDP_TUNNEL_NIC_INFO_MAY_SLEEP` | >= 6.17 → stub 0 | Flag removed from tunnel infrastructure |
| `NSIM_ETHTOOL_TS_INFO` | >= 6.11 | `ethtool_ts_info` → `kernel_ethtool_ts_info` |

Each block is guarded by `LINUX_VERSION_CODE` so the code compiles
cleanly on the native 6.9.x tree as well (no shims active).

---

## DKMS Packaging

`dkms.conf` registers four modules:

```
Module 0: nsim_ptp.ko       from ptp/
Module 1: nsim_ptp_mock.ko  from ptp/
Module 2: nsim_dpll.ko      from dpll/
Module 3: netdevsim.ko      from netdevsim/
```

The `POST_INSTALL` hook (`install-udev-rule.sh`) copies the udev rule
into `/etc/udev/rules.d/` and reloads.

### udev Rule

`99-nsim-ptp.rules` creates real `/dev/ptpN` device nodes (via `mknod`)
with the same major:minor as the corresponding `/dev/nsim_ptpN` devices.
Real device nodes are used instead of symlinks so they propagate into
containers (Kind nodes, Kubernetes pods):

```
SUBSYSTEM=="nsim_ptp", KERNEL=="nsim_ptp[0-9]*", MODE="0666", \
    RUN+="/bin/sh -c 'rm -f /dev/ptp%n; mknod /dev/ptp%n c %M %m; chmod 666 /dev/ptp%n'"
SUBSYSTEM=="nsim_ptp", KERNEL=="nsim_ptp[0-9]*", ACTION=="remove", \
    RUN+="/bin/rm -f /dev/ptp%n"
```

`MODE="0666"` is needed because the non-standard major number (234)
falls outside default cgroup device allowlists.  Without it, containers
and systemd-sandboxed services would get `EPERM`.

---

## Module Loading Order

```bash
sudo modprobe gnss              # optional, needed by netdevsim
sudo modprobe nsim_ptp          # PTP core
sudo modprobe nsim_ptp_mock     # mock clocks
sudo modprobe nsim_dpll         # DPLL subsystem
sudo modprobe netdevsim pci_bus_nr=0x1f  # main driver
```

Creating a simulated device:

```bash
echo "1 0000:1f:02.0 1" | sudo tee /sys/bus/netdevsim/new_device
```

Format: `<id> <pci_addr> <logical_clk_id> [num_ports]`

---

## Directory Layout

```
netdevsim-dkms/
├── .github/workflows/ci.yml    # GitHub Actions CI
├── include/
│   ├── dkms_compat.h           # Kernel version shims (6.8 → 6.17)
│   ├── nsim_rename.h           # nsim_ symbol prefix macros
│   └── linux/
│       ├── ptp_clock_kernel.h  # PTP kernel API header
│       └── ptp_mock.h          # Mock PHC API header
├── ptp/                        # nsim_ptp.ko + nsim_ptp_mock.ko
│   ├── Makefile
│   ├── ptp_clock.c             # PTP core: register, events, index
│   ├── ptp_chardev.c           # /dev/nsim_ptpN character device
│   ├── ptp_sysfs.c             # Sysfs attributes
│   ├── ptp_vclock.c            # Virtual clocks
│   ├── ptp_mock.c              # Mock PHC: EXTTS, logical clock IDs
│   └── ptp_private.h           # Shared PTP internal header
├── dpll/                       # nsim_dpll.ko
│   ├── Makefile
│   ├── dpll_core.c             # Device/pin registration
│   ├── dpll_netlink.c          # Genetlink interface, change ntf
│   ├── dpll_nl.c               # Generated netlink policy
│   └── dpll_*.h                # Internal headers
├── netdevsim/                  # netdevsim.ko
│   ├── Makefile
│   ├── netdevsim.h             # Central struct nsim_dev
│   ├── netdev.c                # Module entry, net_device ops
│   ├── dev.c                   # Device lifecycle, devlink
│   ├── bus.c                   # Simulated bus, sysfs
│   ├── fakepci.c               # Fake PCI host bridge
│   ├── ethtool.c               # Ethtool ops
│   ├── fib.c                   # FIB offload
│   ├── dpll.c                  # DPLL pin wiring
│   ├── health.c                # Devlink health
│   ├── hwstats.c               # Hardware statistics
│   ├── udp_tunnels.c           # UDP tunnel offload
│   ├── bpf.c                   # BPF offload (optional)
│   ├── ipsec.c                 # IPsec/XFRM offload (optional)
│   ├── psample.c               # Packet sampling (optional)
│   └── macsec.c                # MACsec offload (optional)
├── scripts/
│   ├── create-vrt-clocks.sh    # Per-Kind-node stand-in mock PHCs (virtual RT)
│   ├── test-dpll.sh            # DPLL unit tests (make test-dpll)
│   ├── test-phc.sh             # Mock PHC unit tests (make test-phc)
│   ├── test-gnss-ubx.sh        # GNSS/UBX unit tests (make test-gnss-ubx)
│   └── test-utm-ubuntu.sh      # Local macOS testing via UTM
├── shim/                       # CI LD_PRELOAD: phc2sys CLOCK_REALTIME → mock PHC
│   ├── ptp_vrt_shim.c
│   ├── phc2sys-wrapper
│   └── README.md
├── Makefile                    # Top-level: ordered build, tarball, RPM
├── dkms.conf                   # DKMS registration (4 modules)
├── install-udev-rule.sh        # POST_INSTALL hook
├── 99-nsim-ptp.rules           # udev: /dev/ptpN device nodes (mknod, same major:minor)
├── LICENSE                     # GPL-2.0
└── README.md
```

---

## CI Architecture

### netdevsim-dkms CI (`ci.yml`)

Runs in the [netdevsim-dkms](https://github.com/redhat-cne/netdevsim-dkms)
repository on every PR and workflow_dispatch:

```
  ┌─────────────────────────────┐
  │       dkms-test             │
  │  matrix: [22.04, 24.04]    │
  │                             │
  │  Clone → Build DKMS →      │
  │  Load modules → Smoke test │
  └──────────┬──────────────────┘
             │ (workflow_dispatch only)
  ┌──────────▼──────────────────┐
  │       ptp-images            │
  │  ubuntu-22.04               │
  │                             │
  │  Build ptp-operator images  │
  │  Upload tarball artifact    │
  └──────────┬──────────────────┘
             │
  ┌──────────▼──────────────────┐
  │       ptp-test              │
  │  matrix: [22.04, 24.04]    │
  │        × [oc, bc, ...]     │
  │                             │
  │  Install DKMS + load images │
  │  Deploy kind cluster        │
  │  Run ptp-operator scenario  │
  └─────────────────────────────┘
```

### ptp-operator CI (`netdevsim-ci.yml`)

Runs in the [ptp-operator](https://github.com/k8snetworkplumbingwg/ptp-operator)
repository — inverted: ptp-operator is checked out, netdevsim-dkms is
cloned for DKMS source only.  Full e2e runs on every PR (no OIDC or
cloud credentials needed).

---

## Container and Kubernetes Notes

| Issue | Solution |
|-------|----------|
| Non-standard major (234) blocked by cgroup | udev rule sets `MODE="0666"` |
| `systemd DevicePolicy=closed` | Drop-in: `DeviceAllow=char-* rw`, `DevicePolicy=auto` |
| `/dev/ptpN` missing in pods | udev rule creates real device nodes (mknod); check cgroup allowlist |
| `chrony` vs `chronyd` service name | `run-tests.sh` handles both portably |

---

## Supported Kernel Versions

| Ubuntu | Kernel | Status |
|--------|--------|--------|
| 22.04 (HWE) | 6.8.x | Tested in CI |
| 24.04 (HWE) | 6.17.x | Tested in CI |
| 6.9.x (native) | 6.9.x | Source origin — no shims needed |
