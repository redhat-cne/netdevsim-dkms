# netdevsim DKMS Driver

Out-of-tree DKMS package for the enhanced **netdevsim** kernel module with
fake PCI device simulation, DPLL/GNSS emulation, PTP EXTTS support, and
logical clock ID sharing.

Based on Linux 6.9.5 kernel sources.

## Modules Included

| Module | Description |
|--------|-------------|
| `netdevsim.ko` | Enhanced netdevsim with fake PCI, DPLL, ethtool, logical clock IDs |
| `nsim_ptp_mock.ko` | Mock PTP clock with kref lifecycle, 2-pin layout, EXTTS simulation |
| `nsim_ptp.ko` | PTP core with `nsim_ptp_class` export and `get_ptp_clock_info()` helper |
| `nsim_dpll.ko` | DPLL subsystem with `genlmsg_multicast_allns` for cross-namespace events |

> **Note:** Modules are renamed from the upstream names (`ptp` → `nsim_ptp`,
> `dpll` → `nsim_dpll`, `ptp_mock` → `nsim_ptp_mock`) to avoid symbol
> conflicts with the kernel's built-in PTP and DPLL subsystems.

## Kernel Compatibility

This package targets **Linux 6.9.x** kernels. Internal kernel APIs (devlink,
dpll, netdevice, PTP) may differ in other kernel versions. Building against a
substantially different kernel version will likely require source modifications.

## Prerequisites

- `dkms` package installed
- Kernel headers for the target kernel (`linux-headers-$(uname -r)`)

## Installation

### Using DKMS (recommended)

```bash
# Copy source tree to the DKMS source directory
sudo cp -r . /usr/src/netdevsim-6.9.5

# Register and build
sudo dkms add netdevsim/6.9.5
sudo dkms build netdevsim/6.9.5
sudo dkms install netdevsim/6.9.5
```

### Manual build (without DKMS)

```bash
make
sudo make modules_install
```

## Uninstallation

```bash
sudo dkms remove netdevsim/6.9.5 --all
sudo rm -rf /usr/src/netdevsim-6.9.5
```

## Loading the modules

Load the modules in dependency order:

```bash
sudo modprobe nsim_ptp
sudo modprobe nsim_dpll
sudo modprobe netdevsim pci_bus_nr=0x1f
```

## udev Rule

Install the udev rule to create `/dev/ptp*` compat device nodes:

```bash
sudo cp 99-nsim-ptp.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
```

The `nsim_ptp` module registers a separate device class (`/dev/nsim_ptp*`)
to avoid colliding with the kernel's built-in PTP subsystem. The udev rule
creates real `/dev/ptpN` device nodes (via `mknod`, same major:minor) so
that `ethtool -T` PHC indices resolve correctly for `ptp4l` and other
linuxptp tools. Real device nodes propagate into containers, unlike
symlinks which only exist on the host devtmpfs.

## Usage

Create netdevsim devices via the bus interface:

```bash
# Format: "id pci_addr clk_id [num_ports]"
echo "1 0000:1f:02.0 1 2" | sudo tee /sys/bus/netdevsim/new_device
```

The `pci_bus_nr` module parameter controls the fake PCI host bridge bus:

```bash
sudo modprobe netdevsim pci_bus_nr=0x1f
```

Link two netdevsim interfaces as peers (required for packet forwarding):

```bash
exec 3< /proc/self/ns/net
IF0_IDX=$(cat /sys/class/net/eth0/ifindex)
IF1_IDX=$(cat /sys/class/net/eth1/ifindex)
echo "3:${IF0_IDX} 3:${IF1_IDX}" > /sys/bus/netdevsim/link_device
exec 3<&-
```

## Container / Kubernetes Notes

When using netdevsim inside containers or Kubernetes pods:

- **Device permissions:** The `nsim_ptp` char devices use a non-standard
  major number (234) that may be blocked by cgroup device allowlists. The
  udev rule sets `MODE="0666"` to work around this. If devices were created
  before the rule was installed, run `chmod 666 /dev/nsim_ptp*`.

- **Systemd services:** Services with `DevicePolicy=closed` only allow
  `char-ptp` class devices. Override with a drop-in:
  `DeviceAllow=char-* rw` and `DevicePolicy=auto`.

- **Kubernetes pods:** The udev rule creates real `/dev/ptpN` device
  nodes (not symlinks) so they propagate into containers.

## Local libvirt/KVM VMs (Linux x86_64)

### Prerequisites

1. A Linux x86_64 host with KVM support.
2. Install libvirt, QEMU, and cloud-image-utils:

```bash
sudo apt-get install -y qemu-kvm libvirt-daemon-system virtinst cloud-image-utils
```

3. Add your user to the `libvirt` and `kvm` groups (no root needed after this):

```bash
sudo usermod -aG libvirt,kvm $USER
# Log out and back in for group membership to take effect
```

### Quick Setup (no tests)

`scripts/setup-libvirt-ubuntu.sh` creates a libvirt VM with the DKMS modules
installed and loaded, adds an SSH config entry, and stops — no tests are run.

```bash
./scripts/setup-libvirt-ubuntu.sh

# Then connect:
ssh netdevsim-ubuntu-test
```

### Running ptp-operator Tests

Once the VM is set up, SSH in and run the ptp-operator test suite. Clone the
[ptp-operator](https://github.com/k8snetworkplumbingwg/ptp-operator) repo on
the VM, then run:

```bash
cd ptp-operator/scripts
./run-on-vm.sh --dkms --mode oc,bc,dualnicbc,dualnicbcha,dualfollower <VM_IP> | tee logs.txt
```

This builds and deploys the ptp-operator on a Kind cluster inside the VM and
runs all five test scenarios (ordinary clock, boundary clock, dual-NIC boundary
clock, dual-NIC boundary clock HA, dual follower). Results are streamed to
`logs.txt`.

To run a single scenario:

```bash
./run-on-vm.sh --dkms --mode bc <VM_IP> | tee logs.txt
```

### Managing the VM

```bash
virsh list --all                         # list VMs
virsh domifaddr netdevsim-ubuntu-test    # get VM IP
virsh shutdown netdevsim-ubuntu-test     # stop VM
virsh undefine --remove-all-storage netdevsim-ubuntu-test  # delete VM
```

## Local UTM VMs (macOS)

### Prerequisites

1. Install UTM from https://mac.getutm.app or `brew install --cask utm`.
2. Symlink `utmctl` so it's on your PATH:

```bash
sudo ln -sf /Applications/UTM.app/Contents/MacOS/utmctl /usr/local/bin/utmctl
```

### Quick Setup (no tests)

`scripts/setup-utm-ubuntu.sh` creates a UTM VM with the DKMS modules
installed and loaded, adds an SSH config entry, and stops — no tests are run.

```bash
# Default: Ubuntu 24.04, DKMS installed, SSH config added
./scripts/setup-utm-ubuntu.sh

# Then connect:
ssh netdevsim-ubuntu-test

# Ubuntu 22.04 with a custom VM name
./scripts/setup-utm-ubuntu.sh --release 22.04 --vm-name my-dev-vm
ssh my-dev-vm

# Drop into a shell immediately after setup
./scripts/setup-utm-ubuntu.sh --shell

# Tear down VM and remove the SSH config entry
./scripts/setup-utm-ubuntu.sh --vm-name my-dev-vm --cleanup
```

If an SSH config entry for the VM name already exists, the script prompts
you to remove it or pick a different `--vm-name`.

### Testing

`scripts/test-utm-ubuntu.sh` does the same VM setup plus smoke tests and
(optionally) the full ptp-operator test suite.

```bash
# Ubuntu 22.04 (kernel 6.8 HWE) — smoke tests only
./scripts/test-utm-ubuntu.sh --release 22.04 --skip-ptp-operator --shell

# Ubuntu 24.04 (kernel 6.17 HWE) — smoke tests only
./scripts/test-utm-ubuntu.sh --release 24.04 --skip-ptp-operator --shell
```

The `--shell` flag drops you into an SSH session after the tests pass.
Use `--skip-ptp-operator` to only run the DKMS build and smoke tests.

### Managing the VM

```bash
utmctl list                              # list VMs
utmctl ip-address netdevsim-ubuntu-test  # get VM IP
utmctl stop netdevsim-ubuntu-test        # stop VM
utmctl delete netdevsim-ubuntu-test      # delete VM
```

## License

GPL-2.0
