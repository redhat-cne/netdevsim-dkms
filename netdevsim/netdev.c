/*
 * Copyright (C) 2017 Netronome Systems, Inc.
 *
 * This software is licensed under the GNU General License Version 2,
 * June 1991 as shown in the file COPYING in the top-level directory of this
 * source tree.
 *
 * THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES PROVIDE THE PROGRAM "AS IS"
 * WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING,
 * BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE. THE ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE
 * OF THE PROGRAM IS WITH YOU. SHOULD THE PROGRAM PROVE DEFECTIVE, YOU ASSUME
 * THE COST OF ALL NECESSARY SERVICING, REPAIR OR CORRECTION.
 */

#include <dkms_compat.h>
#include <linux/debugfs.h>
#include <linux/etherdevice.h>
#include <linux/ptp_clock_kernel.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/pci.h>
#include <linux/slab.h>
#include <net/netlink.h>
#include <net/pkt_cls.h>
#include <net/rtnetlink.h>
#include <net/udp_tunnel.h>
#include <linux/skbuff.h>
#include "netdevsim.h"
#include <linux/device.h>

// #define LOG_FUNC pr_info("netdevsim (fix):  %s\n",__func__);

static netdev_tx_t nsim_start_xmit(struct sk_buff *skb, struct net_device *dev)
{
	struct netdevsim *ns = netdev_priv(dev);
	unsigned int len = skb->len;
	struct netdevsim *peer_ns;

	rcu_read_lock();
	if (!nsim_ipsec_tx(ns, skb))
		goto out_drop_free;

	peer_ns = rcu_dereference(ns->peer);
	if (!peer_ns)
		goto out_drop_free;

	skb_tx_timestamp(skb);
	int gen_tx_tstamp = skb_shinfo(skb)->tx_flags & SKBTX_HW_TSTAMP;
	struct timespec64 tx_ts, rx_ts;

	struct sk_buff *skb_orig;
	if (gen_tx_tstamp) {
		struct ptp_clock_info *ptp_info =
			mock_phc_get_ptp_info(ns->phc);
		if (ptp_info)
			ptp_info->gettime64(ptp_info, &tx_ts);

		skb_orig = skb;
		skb = skb_copy(skb_orig, GFP_ATOMIC);
		skb_shinfo(skb_orig)->tx_flags |= SKBTX_IN_PROGRESS;
	}
	/* Generate Rx tstamp based on the peer clock */
	struct ptp_clock_info *ptp_info = mock_phc_get_ptp_info(peer_ns->phc);
	if (ptp_info)
		ptp_info->gettime64(ptp_info, &rx_ts);
	skb_hwtstamps(skb)->hwtstamp = timespec64_to_ktime(rx_ts);
	if (unlikely(dev_forward_skb(peer_ns->netdev, skb) == NET_RX_DROP))
		goto out_drop_cnt;
	/* only timestamp the outbound packet if the user has requested it */
	if (gen_tx_tstamp) {
		struct skb_shared_hwtstamps shhwtstamps;
		shhwtstamps.hwtstamp = timespec64_to_ktime(tx_ts);
		skb_tstamp_tx(skb_orig, &shhwtstamps);
		dev_kfree_skb_any(skb_orig);
	}
	rcu_read_unlock();
	u64_stats_update_begin(&ns->syncp);
	ns->tx_packets++;
	ns->tx_bytes += len;
	u64_stats_update_end(&ns->syncp);
	return NETDEV_TX_OK;

out_drop_free:
	dev_kfree_skb(skb);
out_drop_cnt:
	rcu_read_unlock();
	u64_stats_update_begin(&ns->syncp);
	ns->tx_dropped++;
	u64_stats_update_end(&ns->syncp);
	return NETDEV_TX_OK;
}

static void nsim_set_rx_mode(struct net_device *dev)
{

}

static int nsim_change_mtu(struct net_device *dev, int new_mtu)
{
	struct netdevsim *ns = netdev_priv(dev);

	if (ns->xdp.prog && new_mtu > NSIM_XDP_MAX_MTU)
		return -EBUSY;

	dev->mtu = new_mtu;

	return 0;
}

static void nsim_get_stats64(struct net_device *dev,
			     struct rtnl_link_stats64 *stats)
{
	struct netdevsim *ns = netdev_priv(dev);
	unsigned int start;

	do {
		start = u64_stats_fetch_begin(&ns->syncp);
		stats->tx_bytes = ns->tx_bytes;
		stats->tx_packets = ns->tx_packets;
		stats->tx_dropped = ns->tx_dropped;
	} while (u64_stats_fetch_retry(&ns->syncp, start));
}

static int nsim_setup_tc_block_cb(enum tc_setup_type type, void *type_data,
				  void *cb_priv)
{
	return nsim_bpf_setup_tc_block_cb(type, type_data, cb_priv);
}

static int nsim_set_vf_mac(struct net_device *dev, int vf, u8 *mac)
{
	struct netdevsim *ns = netdev_priv(dev);
	struct nsim_dev *nsim_dev = ns->nsim_dev;

	/* Only refuse multicast addresses, zero address can mean unset/any. */
	if (vf >= nsim_dev_get_vfs(nsim_dev) || is_multicast_ether_addr(mac))
		return -EINVAL;
	memcpy(nsim_dev->vfconfigs[vf].vf_mac, mac, ETH_ALEN);

	return 0;
}

static int nsim_set_vf_vlan(struct net_device *dev, int vf, u16 vlan, u8 qos,
			    __be16 vlan_proto)
{
	struct netdevsim *ns = netdev_priv(dev);
	struct nsim_dev *nsim_dev = ns->nsim_dev;

	if (vf >= nsim_dev_get_vfs(nsim_dev) || vlan > 4095 || qos > 7)
		return -EINVAL;

	nsim_dev->vfconfigs[vf].vlan = vlan;
	nsim_dev->vfconfigs[vf].qos = qos;
	nsim_dev->vfconfigs[vf].vlan_proto = vlan_proto;

	return 0;
}

static int nsim_set_vf_rate(struct net_device *dev, int vf, int min, int max)
{
	struct netdevsim *ns = netdev_priv(dev);
	struct nsim_dev *nsim_dev = ns->nsim_dev;

	if (nsim_esw_mode_is_switchdev(ns->nsim_dev)) {
		pr_err("Not supported in switchdev mode. Please use devlink API.\n");
		return -EOPNOTSUPP;
	}

	if (vf >= nsim_dev_get_vfs(nsim_dev))
		return -EINVAL;

	nsim_dev->vfconfigs[vf].min_tx_rate = min;
	nsim_dev->vfconfigs[vf].max_tx_rate = max;

	return 0;
}

static int nsim_set_vf_spoofchk(struct net_device *dev, int vf, bool val)
{
	struct netdevsim *ns = netdev_priv(dev);
	struct nsim_dev *nsim_dev = ns->nsim_dev;

	if (vf >= nsim_dev_get_vfs(nsim_dev))
		return -EINVAL;
	nsim_dev->vfconfigs[vf].spoofchk_enabled = val;

	return 0;
}

static int nsim_set_vf_rss_query_en(struct net_device *dev, int vf, bool val)
{
	struct netdevsim *ns = netdev_priv(dev);
	struct nsim_dev *nsim_dev = ns->nsim_dev;

	if (vf >= nsim_dev_get_vfs(nsim_dev))
		return -EINVAL;
	nsim_dev->vfconfigs[vf].rss_query_enabled = val;

	return 0;
}

static int nsim_set_vf_trust(struct net_device *dev, int vf, bool val)
{
	struct netdevsim *ns = netdev_priv(dev);
	struct nsim_dev *nsim_dev = ns->nsim_dev;

	if (vf >= nsim_dev_get_vfs(nsim_dev))
		return -EINVAL;
	nsim_dev->vfconfigs[vf].trusted = val;

	return 0;
}

static int nsim_get_vf_config(struct net_device *dev, int vf,
			      struct ifla_vf_info *ivi)
{
	struct netdevsim *ns = netdev_priv(dev);
	struct nsim_dev *nsim_dev = ns->nsim_dev;

	if (vf >= nsim_dev_get_vfs(nsim_dev))
		return -EINVAL;

	ivi->vf = vf;
	ivi->linkstate = nsim_dev->vfconfigs[vf].link_state;
	ivi->min_tx_rate = nsim_dev->vfconfigs[vf].min_tx_rate;
	ivi->max_tx_rate = nsim_dev->vfconfigs[vf].max_tx_rate;
	ivi->vlan = nsim_dev->vfconfigs[vf].vlan;
	ivi->vlan_proto = nsim_dev->vfconfigs[vf].vlan_proto;
	ivi->qos = nsim_dev->vfconfigs[vf].qos;
	memcpy(&ivi->mac, nsim_dev->vfconfigs[vf].vf_mac, ETH_ALEN);
	ivi->spoofchk = nsim_dev->vfconfigs[vf].spoofchk_enabled;
	ivi->trusted = nsim_dev->vfconfigs[vf].trusted;
	ivi->rss_query_en = nsim_dev->vfconfigs[vf].rss_query_enabled;

	return 0;
}

static int nsim_set_vf_link_state(struct net_device *dev, int vf, int state)
{
	struct netdevsim *ns = netdev_priv(dev);
	struct nsim_dev *nsim_dev = ns->nsim_dev;

	if (vf >= nsim_dev_get_vfs(nsim_dev))
		return -EINVAL;

	switch (state) {
	case IFLA_VF_LINK_STATE_AUTO:
	case IFLA_VF_LINK_STATE_ENABLE:
	case IFLA_VF_LINK_STATE_DISABLE:
		break;
	default:
		return -EINVAL;
	}

	nsim_dev->vfconfigs[vf].link_state = state;

	return 0;
}

static void nsim_taprio_stats(struct tc_taprio_qopt_stats *stats)
{
	stats->window_drops = 0;
	stats->tx_overruns = 0;
}

static int nsim_setup_tc_taprio(struct net_device *dev,
				struct tc_taprio_qopt_offload *offload)
{
	int err = 0;

	switch (offload->cmd) {
	case TAPRIO_CMD_REPLACE:
	case TAPRIO_CMD_DESTROY:
		break;
	case TAPRIO_CMD_STATS:
		nsim_taprio_stats(&offload->stats);
		break;
	default:
		err = -EOPNOTSUPP;
	}

	return err;
}

static LIST_HEAD(nsim_block_cb_list);

static int nsim_setup_tc(struct net_device *dev, enum tc_setup_type type,
			 void *type_data)
{
	struct netdevsim *ns = netdev_priv(dev);

	switch (type) {
	case TC_SETUP_QDISC_TAPRIO:
		return nsim_setup_tc_taprio(dev, type_data);
	case TC_SETUP_BLOCK:
		return flow_block_cb_setup_simple(type_data,
						  &nsim_block_cb_list,
						  nsim_setup_tc_block_cb, ns,
						  ns, true);
	default:
		return -EOPNOTSUPP;
	}
}

static int nsim_set_features(struct net_device *dev, netdev_features_t features)
{
	struct netdevsim *ns = netdev_priv(dev);

	if ((dev->features & NETIF_F_HW_TC) > (features & NETIF_F_HW_TC))
		return nsim_bpf_disable_tc(ns);

	return 0;
}

static int nsim_get_iflink(const struct net_device *dev)
{
	struct netdevsim *nsim, *peer;
	int iflink;

	nsim = netdev_priv(dev);

	rcu_read_lock();
	peer = rcu_dereference(nsim->peer);
	iflink = peer ? READ_ONCE(peer->netdev->ifindex) : 0;
	rcu_read_unlock();

	return iflink;
}

static int nsim_get_ts_config(struct net_device *netdev,
			      struct kernel_hwtstamp_config *config)
{
	struct netdevsim *ns = netdev_priv(netdev);

	pr_info("netdevsim: %04x:%02x:%02x:%01x -> getting timestamping config (phc index: %d, logical clk id: %d)\n",
		ns->nsim_bus_dev->pci_addr.domain,
		ns->nsim_bus_dev->pci_addr.bus,
		ns->nsim_bus_dev->pci_addr.device,
		ns->nsim_bus_dev->pci_addr.function,
		mock_phc_index(ns->phc),
		ns->nsim_bus_dev->logical_clk_id
	);

	*config = ns->tstamp_config;

	return 0;
}

static int nsim_set_ts_config(struct net_device *netdev,
			      struct kernel_hwtstamp_config *config,
			      struct netlink_ext_ack *extack)
{
	struct netdevsim *ns = netdev_priv(netdev);

	pr_info("netdevsim: %04x:%02x:%02x:%01x -> setting timestamping config (phc index: %d)\n",
		ns->nsim_bus_dev->pci_addr.domain,
		ns->nsim_bus_dev->pci_addr.bus,
		ns->nsim_bus_dev->pci_addr.device,
		ns->nsim_bus_dev->pci_addr.function,
		ns->nsim_bus_dev->logical_clk_id
	);

	if (!ns->phc)
		return -EOPNOTSUPP;

	switch (config->tx_type) {
	case HWTSTAMP_TX_OFF:
		ns->tstamp_config.tx_type = HWTSTAMP_TX_OFF;
		break;
	case HWTSTAMP_TX_ON:
		ns->tstamp_config.tx_type = HWTSTAMP_TX_ON;
		break;
	default:
		return -ERANGE;
	}

	switch (config->rx_filter) {
	case HWTSTAMP_FILTER_NONE:
		ns->tstamp_config.rx_filter = HWTSTAMP_FILTER_NONE;
		break;
	case HWTSTAMP_FILTER_PTP_V1_L4_EVENT:
	case HWTSTAMP_FILTER_PTP_V1_L4_SYNC:
	case HWTSTAMP_FILTER_PTP_V1_L4_DELAY_REQ:
	case HWTSTAMP_FILTER_PTP_V2_EVENT:
	//case HWTSTAMP_FTLTER_PTP_V2_L4_EVENT:
	case HWTSTAMP_FILTER_PTP_V2_SYNC:
	case HWTSTAMP_FILTER_PTP_V2_L4_SYNC:
	case HWTSTAMP_FILTER_PTP_V2_DELAY_REQ:
	case HWTSTAMP_FILTER_PTP_V2_L4_DELAY_REQ:
#ifdef HAVE_HWTSTAMP_FILTER_NTP_ALL
	case HWTSTAMP_FILTER_NTP_ALL:
#endif /* HAVE_HWTSTAMP_FILTER_NTP_ALL */
	case HWTSTAMP_FILTER_ALL:
		ns->tstamp_config.rx_filter = HWTSTAMP_FILTER_ALL;
		break;
	default:
		return -ERANGE;
	}
	return 0;
}
static void nsim_link_up_work(struct work_struct *work)
{
	struct netdevsim *ns =
		container_of(work, struct netdevsim, link_up_dwork.work);

	netif_carrier_on(ns->netdev);
}

static int nsim_open(struct net_device *dev)
{
	struct netdevsim *ns = netdev_priv(dev);
	u32 delay = READ_ONCE(ns->link_up_delay_ms);

	if (delay)
		schedule_delayed_work(&ns->link_up_dwork,
				      msecs_to_jiffies(delay));
	else
		netif_carrier_on(dev);

	return 0;
}

static int nsim_stop(struct net_device *dev)
{
	struct netdevsim *ns = netdev_priv(dev);

	cancel_delayed_work_sync(&ns->link_up_dwork);
	netif_carrier_off(dev);

	return 0;
}

static const struct net_device_ops nsim_netdev_ops = {
	.ndo_start_xmit = nsim_start_xmit,
	.ndo_open = nsim_open,
	.ndo_stop = nsim_stop,
	.ndo_set_rx_mode = nsim_set_rx_mode,
	.ndo_set_mac_address = eth_mac_addr,
	.ndo_validate_addr = eth_validate_addr,
	.ndo_change_mtu = nsim_change_mtu,
	.ndo_get_stats64 = nsim_get_stats64,
	.ndo_set_vf_mac = nsim_set_vf_mac,
	.ndo_set_vf_vlan = nsim_set_vf_vlan,
	.ndo_set_vf_rate = nsim_set_vf_rate,
	.ndo_set_vf_spoofchk = nsim_set_vf_spoofchk,
	.ndo_set_vf_trust = nsim_set_vf_trust,
	.ndo_get_vf_config = nsim_get_vf_config,
	.ndo_set_vf_link_state = nsim_set_vf_link_state,
	.ndo_set_vf_rss_query_en = nsim_set_vf_rss_query_en,
	.ndo_setup_tc = nsim_setup_tc,
	.ndo_set_features = nsim_set_features,
	.ndo_get_iflink = nsim_get_iflink,
	.ndo_bpf = nsim_bpf,
	.ndo_hwtstamp_get = nsim_get_ts_config,
	.ndo_hwtstamp_set = nsim_set_ts_config
};

static const struct net_device_ops nsim_vf_netdev_ops = {
	.ndo_start_xmit = nsim_start_xmit,
	.ndo_set_rx_mode = nsim_set_rx_mode,
	.ndo_set_mac_address = eth_mac_addr,
	.ndo_validate_addr = eth_validate_addr,
	.ndo_change_mtu = nsim_change_mtu,
	.ndo_get_stats64 = nsim_get_stats64,
	.ndo_setup_tc = nsim_setup_tc,
	.ndo_set_features = nsim_set_features,
};

static void nsim_setup(struct net_device *dev)
{
	ether_setup(dev);
	eth_hw_addr_random(dev);

	dev->tx_queue_len = 0;
	dev->flags &= ~IFF_MULTICAST;
	dev->priv_flags |= IFF_LIVE_ADDR_CHANGE | IFF_NO_QUEUE;
	dev->features |= NETIF_F_HIGHDMA | NETIF_F_SG | NETIF_F_FRAGLIST |
			 NETIF_F_HW_CSUM | NETIF_F_TSO;
	dev->hw_features |= NETIF_F_HW_TC;
	dev->max_mtu = ETH_MAX_MTU;
	dev->xdp_features = NETDEV_XDP_ACT_HW_OFFLOAD;
}

static struct mock_phc *mock_phc_from_ptp(struct ptp_clock *ptp)
{
	if (!ptp)
		return NULL;

	struct ptp_clock_info *clk_info = get_ptp_clock_info(ptp);
	if (!clk_info)
		return NULL;

	return container_of(clk_info, struct mock_phc, info);
}

// int index_to_match=0;
static int ptp_match_logical_clk_id(struct device *dev, const void *logical_clk_id_to_match)
{
	struct ptp_clock *ptp = dev_get_drvdata(dev);
	if (ptp) {
		struct mock_phc *phc = mock_phc_from_ptp(ptp);
		if (mock_phc_logical_clk_id(phc) == *(int*)logical_clk_id_to_match) {
			return 1;
		} else {
			return 0;
		}
	}
	return 0;
}

static struct mock_phc *get_ptp_clock_by_logical_clk_id(int logical_clk_id)
{
	// Iterate over network devices
	struct device *dev;

	dev = class_find_device(&ptp_class, NULL, &logical_clk_id, ptp_match_logical_clk_id);
	if (dev != NULL) {
		// There's an get_device() inside the find_class_device() that increments
		// the ref count, so we need to decrease it here.
		put_device(dev);

		struct ptp_clock *ptp = dev_get_drvdata(dev);
		return mock_phc_from_ptp(ptp);
	}
	return NULL; // If no PTP clock matches the logical clk id, return NULL
}

static int nsim_init_netdevsim(struct netdevsim *ns)
{
	struct mock_phc *phc = NULL;
	int err;

	int logical_clk_id = ns->nsim_bus_dev->logical_clk_id;

	if (logical_clk_id != -1) {
		phc = get_ptp_clock_by_logical_clk_id(logical_clk_id);
	}
	
	// phc is null if no PTP clock found for that logical index or logical_clk_id == -1
	if (phc == NULL) {
		pr_info("netdevsim: creating new phc with logical clk id: %d\n", logical_clk_id);
		phc = mock_phc_create(&ns->nsim_bus_dev->dev, logical_clk_id);
		if (IS_ERR(phc)) {
			pr_err("netdevsim: failed to create new phc with logical clk id: %d\n", logical_clk_id);
			return PTR_ERR(phc);
		}
		pr_info("netdevsim: new phc created, index=%d (logical clk id: %d)\n", 
			ptp_clock_index(phc->clock), logical_clk_id);
	} else {
		pr_info("netdevsim: sharing PTP clock index %d with logical clk id: %d\n", 
			mock_phc_index(phc), logical_clk_id);
		// We're sharing a PTP clock, so we need to increment the reference count
		kref_get(&phc->ref);
	}


	ns->phc = phc;
	ns->netdev->netdev_ops = &nsim_netdev_ops;

	INIT_DELAYED_WORK(&ns->link_up_dwork, nsim_link_up_work);

	err = nsim_udp_tunnels_info_create(ns->nsim_dev, ns->netdev);
	if (err)
		goto err_phc_destroy;

	rtnl_lock();
	err = nsim_bpf_init(ns);
	if (err)
		goto err_utn_destroy;

	nsim_macsec_init(ns);
	nsim_ipsec_init(ns);

	netif_carrier_off(ns->netdev);

	err = register_netdevice(ns->netdev);
	if (err)
		goto err_ipsec_teardown;
	rtnl_unlock();
	return 0;

err_ipsec_teardown:
	nsim_ipsec_teardown(ns);
	nsim_macsec_teardown(ns);
	nsim_bpf_uninit(ns);
err_utn_destroy:
	rtnl_unlock();
	nsim_udp_tunnels_info_destroy(ns->netdev);
err_phc_destroy:
	mock_phc_release(phc);

	return err;
}

static int nsim_init_netdevsim_vf(struct netdevsim *ns)
{
	int err;

	ns->netdev->netdev_ops = &nsim_vf_netdev_ops;
	rtnl_lock();
	err = register_netdevice(ns->netdev);
	rtnl_unlock();
	return err;
}

static void nsim_exit_netdevsim(struct netdevsim *ns)
{
	nsim_udp_tunnels_info_destroy(ns->netdev);
	mock_phc_release(ns->phc);
}

struct netdevsim *nsim_create(struct nsim_dev *nsim_dev,
			      struct nsim_dev_port *nsim_dev_port)
{
	struct net_device *dev;
	struct netdevsim *ns;
	int err;

	dev = alloc_netdev_mq(sizeof(*ns), "eth%d", NET_NAME_UNKNOWN,
			      nsim_setup, nsim_dev->nsim_bus_dev->num_queues);
	if (!dev)
		return ERR_PTR(-ENOMEM);

	dev_net_set(dev, nsim_dev_net(nsim_dev));
	ns = netdev_priv(dev);
	ns->netdev = dev;
	u64_stats_init(&ns->syncp);
	ns->nsim_dev = nsim_dev;
	ns->nsim_dev_port = nsim_dev_port;
	ns->nsim_bus_dev = nsim_dev->nsim_bus_dev;

	/* Set network device parent to fake PCI device if available, otherwise use bus device */
	if (nsim_dev->fake_pci_dev) {
		SET_NETDEV_DEV(dev, &nsim_dev->fake_pci_dev->dev);
		pr_info("netdevsim: Setting network device parent to fake PCI device %04x:%02x:%02x.%x\n",
			ns->nsim_bus_dev->pci_addr.domain, ns->nsim_bus_dev->pci_addr.bus,
			ns->nsim_bus_dev->pci_addr.device, ns->nsim_bus_dev->pci_addr.function);
	} else {
		SET_NETDEV_DEV(dev, &ns->nsim_bus_dev->dev);
		pr_warn("netdevsim: No fake PCI device found, using bus device as network device parent\n");
	}

	SET_NETDEV_DEVLINK_PORT(dev, &nsim_dev_port->devlink_port);
	nsim_ethtool_init(ns);
	if (nsim_dev_port_is_pf(nsim_dev_port))
		err = nsim_init_netdevsim(ns);
	else
		err = nsim_init_netdevsim_vf(ns);
	if (err)
		goto err_free_netdev;
	return ns;

err_free_netdev:
	free_netdev(dev);
	return ERR_PTR(err);
}

void nsim_destroy(struct netdevsim *ns)
{
	struct net_device *dev = ns->netdev;
	struct netdevsim *peer;

	cancel_delayed_work_sync(&ns->link_up_dwork);

	rtnl_lock();
	peer = rtnl_dereference(ns->peer);
	if (peer)
		RCU_INIT_POINTER(peer->peer, NULL);
	RCU_INIT_POINTER(ns->peer, NULL);
	unregister_netdevice(dev);
	if (nsim_dev_port_is_pf(ns->nsim_dev_port)) {
		nsim_macsec_teardown(ns);
		nsim_ipsec_teardown(ns);
		nsim_bpf_uninit(ns);
	}
	rtnl_unlock();
	if (nsim_dev_port_is_pf(ns->nsim_dev_port))
		nsim_exit_netdevsim(ns);
	free_netdev(dev);
}

bool netdev_is_nsim(struct net_device *dev)
{
	return dev->netdev_ops == &nsim_netdev_ops;
}

static int nsim_validate(struct nlattr *tb[], struct nlattr *data[],
			 struct netlink_ext_ack *extack)
{
	NL_SET_ERR_MSG_MOD(
		extack,
		"Please use: echo \"[ID] [PORT_COUNT] [NUM_QUEUES]\" > /sys/bus/netdevsim/new_device");
	return -EOPNOTSUPP;
}

static struct rtnl_link_ops nsim_link_ops __read_mostly = {
	.kind = DRV_NAME,
	.validate = nsim_validate,
};

static int __init nsim_module_init(void)
{
	int err;

	fakepci_init();

	err = nsim_dev_init();
	if (err)
		return err;

	err = nsim_bus_init();
	if (err)
		goto err_dev_exit;

	err = rtnl_link_register(&nsim_link_ops);
	if (err)
		goto err_bus_exit;

	return 0;

err_bus_exit:
	nsim_bus_exit();
err_dev_exit:
	nsim_dev_exit();
	return err;
}

static void __exit nsim_module_exit(void)
{
	rtnl_link_unregister(&nsim_link_ops);
	nsim_bus_exit();
	nsim_dev_exit();
	fakepci_exit();
}

module_init(nsim_module_init);
module_exit(nsim_module_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Simulated networking device for testing");
MODULE_ALIAS_RTNL_LINK(DRV_NAME);
