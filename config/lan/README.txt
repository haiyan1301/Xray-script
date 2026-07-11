Xray routed virtual LAN edge package

Install:
  sudo bash install.sh

Status and logs:
  systemctl status xray-lan
  journalctl -u xray-lan -e

Uninstall:
  sudo bash install.sh uninstall

Gateway mode:
  Configure the local router or DHCP server with static routes for the remote
  CIDRs. The next hop must be this edge machine's physical LAN address.

Notes:
  - The edge requires Xray-core with TUN inbound support, jq, iproute2 and
    iptables in gateway mode.
  - Only the remote private CIDRs are routed through xray0. The default route
    is never changed.
  - Broadcast discovery and arbitrary ICMP are not provided by Xray TUN.
  - Use TCP/UDP service checks instead of ping for reachability tests.
