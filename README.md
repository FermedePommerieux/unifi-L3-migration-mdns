# mdns-bridge-nm
> A simple and secure mDNS reflector bridge for UniFi / Debian / Raspberry Pi environments using only stock Debian tools.

---

## ✨ Overview

When VLAN inter-routing is moved from the UniFi Gateway (UDM/UXG) to a Layer-3 switch, **mDNS discovery stops working** across those migrated VLANs.  
This script restores Bonjour / AirPlay / AirPrint / Sonos / Home Assistant discovery **without exposing any unwanted traffic**.

It uses a **tiny Linux host** (Raspberry Pi, VM, or container) connected to a VLAN trunk:
- Network management handled by **NetworkManager (`nmcli`)**
- mDNS reflection handled by **Avahi (`avahi-daemon`)**
- Firewall isolation handled by **nftables**

---

## 🧩 What it does

- Creates VLAN interfaces (LAN + migrated VLANs) via `nmcli`
- Configures **Avahi** to listen, publish, and reflect mDNS across VLANs
- Hardens the system with a minimal **nftables** firewall (only DHCP + mDNS allowed)
- Installs a persistent `systemd` unit to re-apply configuration on every boot

---

## 🧰 Requirements

| Component | Tested version | Purpose |
|------------|----------------|----------|
| Debian Bookworm | (12.x) | Base OS |
| NetworkManager | ≥ 1.42 | VLAN management |
| Avahi-daemon | ≥ 0.8 | mDNS reflector |
| nftables | ≥ 1.0 | Firewall |
| Raspberry Pi 4B / VM | any | Host platform |

---

## ⚙️ Installation

```bash
sudo apt update
sudo apt install -y network-manager avahi-daemon avahi-utils nftables curl netcat-traditional
git clone https://github.com/<yourusername>/mdns-bridge-nm.git
cd mdns-bridge-nm
sudo chmod +x setup-mdns-bridge-nm.sh
```

---

## 🚀 Usage

### 1️⃣ Apply configuration (one-shot)
```bash
sudo ./setup-mdns-bridge-nm.sh apply
```
This immediately configures VLANs, Avahi, and nftables.

### 2️⃣ Install persistent service (recommended)
```bash
sudo ./setup-mdns-bridge-nm.sh install
```
This installs `/etc/mdns-bridge.env` and a `systemd` service:
```
/etc/systemd/system/mdns-bridge.service
```
which automatically reapplies the config at each boot (after NetworkManager is online).

### 3️⃣ Uninstall everything
```bash
sudo ./setup-mdns-bridge-nm.sh uninstall
```

---

## 🧾 Configuration

All settings are stored in `/etc/mdns-bridge.env`.

Example:
```bash
PHY_IF="eth0"
MGMT_MODE="untagged"   # or "tagged"
MGMT_VID="1"
VLAN_LIST_STR="10 30 50"

MGMT_IP_METHOD="dhcp"
MGMT_ADDR="192.168.1.50/24"
MGMT_GW="192.168.1.1"
MGMT_DNS_STR="192.168.1.1 1.1.1.1"

AVAHI_REFLECT_FILTERS=""
AVAHI_REFLECT_IPV="yes"
```

---

## 🧪 Validation

### Check active interfaces
```bash
nmcli con show --active
```

### Check Avahi status
```bash
systemctl status avahi-daemon --no-pager
grep -E 'allow-interfaces|reflect|publish' /etc/avahi/avahi-daemon.conf
```

### Check reflected services
```bash
avahi-browse -alr
```

### Check firewall
```bash
sudo nft list ruleset | sed -n '1,160p'
```

---

## 🧱 Network topology example

```
              +----------------------+
              |   UniFi Gateway / UXG|
              |  (still routes LAN)  |
              +----------+-----------+
                         |
                         | trunk (LAN + VLAN 10,30,50)
                         |
               +---------+-------------+
               | Raspberry Pi (bridge) |
               |  Avahi + nftables     |
               +----------+------------+
               | VLAN 10 / VLAN 30 / VLAN 50
               |  (routed by L3 switch)
```

---

## 🔒 Security model

- `nftables` denies all by default.
- VLAN interfaces only allow:
  - DHCP client traffic (for the Pi itself)
  - mDNS UDP/5353
- Management interface allows full access (SSH, updates, etc.)
- No packet forwarding between VLANs → **only multicast reflection**.

---

## 🩺 Troubleshooting

- **Service discovered but not reachable?**
  → Check your **gateway firewall/ACLs**. The mDNS reflection is working, but **unicast routing may be blocked**.  
  After migrating VLANs to Layer-3, some firewall rules might break.  
  If you previously allowed traffic from a VLAN that is now L3-routed, the rule must be recreated.  
  The migrated VLANs will no longer appear in the UniFi “Network” list (this is normal),  
  so you need to manually define them — use an **Address List** instead of a “Network”

- **Avahi fails to start?**
  → Likely invalid key in `/etc/avahi/avahi-daemon.conf`. Run:
    ```bash
    sudo journalctl -xeu avahi-daemon
    ```

---

## 🧠 Credits

Developed for UniFi users migrating to Layer-3 switching while preserving multicast service discovery.

---

## 📜 License

MIT License © 2025 FermdePommerieux
