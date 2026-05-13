// SPDX-License-Identifier: GPL-2.0
/*
 * FakePCI Module Driver - Creates fake PCI devices using sysfs simulation
 *
 * This version works as a loadable module by simulating PCI devices in sysfs
 * without using non-exported kernel functions.
 *
 * Copyright (C) 2024
 */

#include <dkms_compat.h>
#include <linux/pci.h>

#include "netdevsim.h"

#define DRIVER_NAME "fakepci"
#define CLASS_NAME "fakepci"

static int pci_bus_nr = -1;
module_param(pci_bus_nr, int, 0644);
MODULE_PARM_DESC(pci_bus_nr, "Domain number where the fake pci host bridge will be created.");


/* Red Hat Vendor with fake device IDs */
#define FAKE_VENDOR_ID 0x1b36
#define FAKE_DEVICE_ID 0x5555

static struct pci_bus *root_bus;
struct device *fake_bridge_parent_dev;
/* List to track fake PCI devices */
struct fake_pci_device {
	struct pci_dev *pci_dev;
	struct list_head list;
	u8 bus;
	u8 device;
	u8 function;
};

static LIST_HEAD(fake_devices_list);
static DEFINE_MUTEX(fake_devices_mutex);

static LIST_HEAD(pci_host_bridge_resources);

#ifdef CONFIG_X86
static struct pci_sysdata sysdata = {
	.domain = 0,
	.node = NUMA_NO_NODE
};
#else
struct arm_sysdata {
	int domain;
	int node;
};
static struct arm_sysdata sysdata = {
	.domain = 0,
	.node = NUMA_NO_NODE
};
#endif

static u8 pci_fake_devs_config_space[PCI_CFG_SPACE_SIZE];

/* Find fake device by address */
static struct fake_pci_device *find_fake_device(u8 bus, u8 device, u8 function)
{
	struct fake_pci_device *fake_dev;

	list_for_each_entry(fake_dev, &fake_devices_list, list) {
		if (fake_dev->bus == bus &&
		    fake_dev->device == device &&
		    fake_dev->function == function) {
			return fake_dev;
		}
	}
	return NULL;
}

static
int bridge_read_op(struct pci_bus *bus, unsigned int devfn, int where, int size, u32 *val) {
	const u8 dev = PCI_SLOT(devfn);
	const u8 func = PCI_FUNC(devfn);
	struct fake_pci_device *fake_dev;

	// pr_info("Faking read op on %02x:%02x:%01x, where=%d, size=%d\n", bus->number, dev, func, where, size);

	/* Check if this device/function exists in our fake devices list */
	mutex_lock(&fake_devices_mutex);
	fake_dev = find_fake_device(bus->number, dev, func);
	mutex_unlock(&fake_devices_mutex);

	if (!fake_dev) {
		/* Device doesn't exist, return 0xFFFFFFFF as per PCI spec */
		*val = 0xFFFFFFFF;
		return PCIBIOS_DEVICE_NOT_FOUND;
	}

	/* Bounds check */
	if (where >= PCI_CFG_SPACE_SIZE) {
		*val = 0;
		return PCIBIOS_BAD_REGISTER_NUMBER;
	}

    switch (size) {
    case 1:
        *val = pci_fake_devs_config_space[where];
        break;
    case 2:
        *val = *(u16 *)&pci_fake_devs_config_space[where];
        break;
    case 4:
        *val = *(u32 *)&pci_fake_devs_config_space[where];
        break;
    default:
        *val = 0;
        return PCIBIOS_BAD_REGISTER_NUMBER;
    }

    return PCIBIOS_SUCCESSFUL;
};

static
int bridge_write_op(struct pci_bus *bus, unsigned int devfn, int where, int size, u32 val) {
	const u8 dev = PCI_SLOT(devfn);
	const u8 func = PCI_FUNC(devfn);
	struct fake_pci_device *fake_dev;

	// pr_info("Faking write op! dev/fn=%u/%u, where=%d, size=%d, val=0x%x\n", dev, func, where, size, val);

	/* Check if this device/function exists in our fake devices list */
	mutex_lock(&fake_devices_mutex);
	fake_dev = find_fake_device(bus->number, dev, func);
	mutex_unlock(&fake_devices_mutex);

	if (!fake_dev) {
		/* Device doesn't exist */
		return PCIBIOS_DEVICE_NOT_FOUND;
	}

	/* Bounds check */
	if (where >= PCI_CFG_SPACE_SIZE) {
		return PCIBIOS_BAD_REGISTER_NUMBER;
	}

	/* For this fake implementation, we'll just log the write but not actually store it */
	/* In a real implementation, you might want to handle specific registers */

	return PCIBIOS_SUCCESSFUL;
};

static struct pci_ops pci_host_bridge_ops = {
	.read = &bridge_read_op,
	.write = &bridge_write_op
};

static int fake_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id);
static void fake_pci_remove(struct pci_dev *pdev);

/* PCI device ID table for our fake devices */
static const struct pci_device_id fake_pci_ids[] = {
	{ PCI_DEVICE(FAKE_VENDOR_ID, FAKE_DEVICE_ID) },
	{ 0, }
};
MODULE_DEVICE_TABLE(pci, fake_pci_ids);

/* PCI driver structure */
static struct pci_driver fake_pci_driver = {
	.name = DRIVER_NAME,
	.id_table = fake_pci_ids,
	.probe = fake_pci_probe,
	.remove = fake_pci_remove,
};



static int find_free_bus_number(void) {
	const int max_bus_num = 256;
    int bus_num;
    for (bus_num = 0; bus_num < max_bus_num; bus_num++) {
        if (!pci_find_bus(0, bus_num)) {
            return bus_num;
        }
    }

    return -ENODEV;
}

static void init_fake_pci_devices_config(void)
{
    u8 *config = pci_fake_devs_config_space;

    /* Clear entire config space */
    memset(config, 0, PCI_CFG_SPACE_SIZE);

    /* Device/Vendor ID (0x00-0x03) */
    *(u16 *)&config[0x00] = FAKE_VENDOR_ID;
    *(u16 *)&config[0x02] = FAKE_DEVICE_ID;

    /* Command register (0x04) */
    *(u16 *)&config[0x04] = PCI_COMMAND_MEMORY | PCI_COMMAND_IO;

    /* Status register (0x06) */
    *(u16 *)&config[0x06] = PCI_STATUS_CAP_LIST;

    /* Revision ID (0x08) */
    config[0x08] = 0x01;

    /* Class code (0x09-0x0B) */
    config[0x09] = 0x00;  /* Programming interface */
    *(u16 *)&config[0x0A] = PCI_CLASS_NETWORK_ETHERNET;

    /* Cache Line Size (0x0C) */
    config[0x0C] = 0x10;  /* 64 bytes */

    /* Latency Timer (0x0D) */
    config[0x0D] = 0x00;

    /* Header Type (0x0E) */
    config[0x0E] = PCI_HEADER_TYPE_MFD;

    /* BIST (0x0F) */
    config[0x0F] = 0x00;

    /* Subsystem Vendor/Device ID (0x2C-0x2F) */
    *(u16 *)&config[0x2C] = FAKE_VENDOR_ID;
    *(u16 *)&config[0x2E] = FAKE_DEVICE_ID;

    /* Interrupt Line (0x3C) */
    config[0x3C] = 0x00;

    /* Interrupt Pin (0x3D) */
    config[0x3D] = 0x01;  /* INTA# */

    pr_info("netdevsim: Initialized config space for fake device\n");
}

/* Create a fake PCI device entry */
int create_fake_pci_device(u16 domain, u8 bus, u8 device, u8 function)
{
	struct fake_pci_device *fake_dev;

	// Make sure domain number matches the fake pci host root one.
	if ((int)domain != pci_domain_nr(root_bus)) {
		pr_err("netdevsim: Invalid domain number %d.\n", domain);
		return -ENODEV;
	}

	// Make sure bus number matches the fake pci host root one.
	if ((int)bus != pci_bus_nr) {
		pr_err("netdevsim: Invalid bus number %d.\n", bus);
		return -ENODEV;
	}

	/* Check if device already exists */
	mutex_lock(&fake_devices_mutex);
	/* If function is not 0, make sure a previous device with function 0 exists */
	if (function != 0) {
		if (!find_fake_device(bus, device, 0)) {
			mutex_unlock(&fake_devices_mutex);
			pr_err("netdevsim: No previous device with function 0 exists\n");
			return -ENODEV;
		}
	}

	if (find_fake_device(bus, device, function)) {
		mutex_unlock(&fake_devices_mutex);
		return -EEXIST;
	}

	/* Allocate fake device structure */
	fake_dev = kzalloc(sizeof(*fake_dev), GFP_KERNEL);
	if (!fake_dev) {
		mutex_unlock(&fake_devices_mutex);
		return -ENOMEM;
	}

	/* Use our fake root bus instead of looking for existing buses */
	if (!root_bus) {
		pr_err("netdevsim: root bus not available\n");
		kfree(fake_dev);
		mutex_unlock(&fake_devices_mutex);
		return -ENODEV;
	}

	bus = root_bus->number;  /* Use the actual bus number of our root bus */

	/* Initialize the fake device structure - no pci_dev needed */
	fake_dev->pci_dev = NULL;  /* Will be created during bus scan */
	fake_dev->bus = bus;
	fake_dev->device = device;
	fake_dev->function = function;

	/* Add to our tracking list */
	list_add(&fake_dev->list, &fake_devices_list);

	pr_info("netdevsim: Created fake PCI device entry %02x:%02x.%x\n",
		bus, device, function);

	mutex_unlock(&fake_devices_mutex);

	/* Trigger bus rescan to discover the new device */
	if (root_bus) {
		pci_lock_rescan_remove();
		pci_rescan_bus(root_bus);
		pci_unlock_rescan_remove();
	}

	return 0;
}

/* Remove a fake PCI device entry */
int remove_fake_pci_device(u16 domain, u8 bus, u8 device, u8 function)
{
	struct fake_pci_device *fake_dev;
	struct pci_dev *pdev = NULL;

	// Make sure domain number matches the fake pci host root one.
	if ((int)domain != pci_domain_nr(root_bus)) {
		pr_err("netdevsim: Invalid domain number %d.\n", domain);
		return -ENODEV;
	}

	// Make sure bus number matches the fake pci host root one.
	if ((int)bus != pci_bus_nr) {
		pr_err("netdevsim: Invalid bus number %d.\n", bus);
		return -ENODEV;
	}

	mutex_lock(&fake_devices_mutex);
	fake_dev = find_fake_device(bus, device, function);
	if (!fake_dev) {
		mutex_unlock(&fake_devices_mutex);
		return -ENODEV;
	}

	/* Get reference to pci_dev before removing from list */
	pdev = fake_dev->pci_dev;

	/* Remove from tracking list */
	list_del(&fake_dev->list);
	mutex_unlock(&fake_devices_mutex);

	/* Explicitly remove the PCI device from the kernel subsystem */
	if (pdev) {
		pci_lock_rescan_remove();
		pci_stop_and_remove_bus_device(pdev);
		pci_unlock_rescan_remove();
	}

	/* Free the fake device structure */
	kfree(fake_dev);

	pr_info("netdevsim: Removed fake PCI device %02x:%02x.%x\n",
		bus, device, function);

	return 0;
}



/* Remove function called when PCI device is removed */
static void fake_pci_remove(struct pci_dev *pdev)
{
	struct fake_pci_device *fake_dev;
	u8 bus = pdev->bus->number;
	u8 device = PCI_SLOT(pdev->devfn);
	u8 function = PCI_FUNC(pdev->devfn);

	dev_info(&pdev->dev, "netdevsim: pci device removed: %02x:%02x.%x\n",
		 bus, device, function);

	/* Clear the pci_dev pointer from our tracking structure */
	mutex_lock(&fake_devices_mutex);
	fake_dev = find_fake_device(bus, device, function);
	if (fake_dev) {
		fake_dev->pci_dev = NULL;
	}
	mutex_unlock(&fake_devices_mutex);
}

/* Probe function called when PCI device is detected */
static int fake_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct fake_pci_device *fake_dev;
	u8 bus = pdev->bus->number;
	u8 device = PCI_SLOT(pdev->devfn);
	u8 function = PCI_FUNC(pdev->devfn);

	dev_info(&pdev->dev, "netdevsim: pci device probed: %02x:%02x.%x\n",
		 bus, device, function);

	/* Store the pci_dev pointer in our tracking structure */
	mutex_lock(&fake_devices_mutex);
	fake_dev = find_fake_device(bus, device, function);
	if (fake_dev) {
		fake_dev->pci_dev = pdev;
	}
	mutex_unlock(&fake_devices_mutex);

	return 0;
}

/* Module initialization */
int fakepci_init(void)
{
	int ret;

	pr_info("netdevsim: Loading fake PCI driver (module version)\n");

	// Register PCI driver
	ret = pci_register_driver(&fake_pci_driver);
	if (ret) {
		pr_err("netdevsim: Failed to register PCI driver: %d\n", ret);
		return ret;
	}

	// If custom bus number is provided, make sure it's valid.
	if (pci_bus_nr >= 0) {
		if (pci_bus_nr > 255) {
			pr_err("netdevsim: Input bus number %d is out of range 0-255\n", pci_bus_nr);
			return -ENODEV;
		}
	} else  {
		// If not provided, search for the next free one.
		pr_info("netdevsim: Bus number not provided (or negative)");
		pci_bus_nr = find_free_bus_number();
		if (pci_bus_nr < 0) {
			pr_err("netdevsim: Failed to find free PCI bus number\n");
			return -ENOMEM;
		}
	}

	pr_info("netdevsim: Installing PCI host bridge on bus nr=%d\n", pci_bus_nr);
	init_fake_pci_devices_config();

	// Create a fake parent device
	fake_bridge_parent_dev = root_device_register("fake-pci-host");
	if (IS_ERR(fake_bridge_parent_dev)) {
		pr_err("netdevsim: Failed to create fake PCI parent device\n");
		return PTR_ERR(fake_bridge_parent_dev);
	}

	root_bus = pci_create_root_bus(fake_bridge_parent_dev, pci_bus_nr, &pci_host_bridge_ops, &sysdata,
		&pci_host_bridge_resources);
	if (!root_bus) {
		pr_err("netdevsim: Failed to create PCI host bridge root bus nr=%d\n",
			pci_bus_nr);
		return -ENODEV;
	}

	pr_info("netdevsim: root bus: bus->domain_nr=%d, bridge->domain_nr=%d\n",
		pci_domain_nr(root_bus), to_pci_host_bridge(root_bus->bridge)->domain_nr);

	// Create fake <bus-nr>:00:0 device
	ret = create_fake_pci_device(pci_domain_nr(root_bus), pci_bus_nr, 0, 0);
	if (ret) {
		pr_err("netdevsim: Failed to create fake %02x:00:0 device\n", pci_bus_nr);
		return ret;
	}

	pr_info("netdevsim: Driver loaded successfully.\n");

	return 0;
}

/* Find a fake PCI device by address and return the underlying pci_dev */
struct pci_dev *find_fake_pci_device_by_addr(u16 domain, u8 bus, u8 device, u8 function)
{
	struct fake_pci_device *fake_dev;
	struct pci_dev *pdev = NULL;

	// Make sure domain number matches the fake pci host root one.
	if ((int)domain != pci_domain_nr(root_bus)) {
		pr_err("netdevsim: Invalid domain number %d.\n", domain);
		return NULL;
	}

	// Make sure bus number matches the fake pci host root one.
	if ((int)bus != pci_bus_nr) {
		pr_err("netdevsim: Invalid bus number %d.\n", bus);
		return NULL;
	}

	mutex_lock(&fake_devices_mutex);
	fake_dev = find_fake_device(bus, device, function);
	if (fake_dev && fake_dev->pci_dev) {
		pdev = fake_dev->pci_dev;
		/* Get a reference to prevent the device from being freed */
		get_device(&pdev->dev);
	}
	mutex_unlock(&fake_devices_mutex);

	return pdev;
}

/* Module cleanup */
void fakepci_exit(void)
{
	pr_info("netdevsim: Removing PCI root bus nr=%d, bus->domain_nr=%d, bridge->domain_nr=%d\n",
		root_bus->number, pci_domain_nr(root_bus), to_pci_host_bridge(root_bus->bridge)->domain_nr);

	pci_remove_root_bus(root_bus);

	pr_info("netdevsim: Unregistering fake PCI parent device\n");
	root_device_unregister(fake_bridge_parent_dev);

	pr_info("netdevsim: Unregistering fake PCI driver\n");
	pci_unregister_driver(&fake_pci_driver);

	pr_info("netdevsim: Fake pci devs driver unloaded\n");
}
