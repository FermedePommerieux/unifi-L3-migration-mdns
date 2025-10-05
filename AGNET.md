# mdns-bridge-nm – Agent internals

This document describes the internal logic of the mdns-bridge-nm script and how it interacts with Debian subsystems.

---

## 🧱 Architecture

**Core components:**
- **NetworkManager (`nmcli`)** – manages physical and VLAN interfaces declaratively.
- **Avahi-daemon** – performs mDNS reflection (multicast DNS across VLANs).
- **nftables** – enforces isolation and restricts traffic to mDNS + DHCP.
- **systemd service** – ensures persistence and re-application at boot.

---

## ⚙️ Boot sequence (install mode)

```
systemd → network-online.target
         ↳ mdns-bridge.service
              ↳ /usr/local/sbin/mdns-bridge-nm apply
                  ├─ ensures dependencies (nmcli, avahi, nft)
                  ├─ creates VLANs via nmcli
                  ├─ rewrites /etc/avahi/avahi-daemon.conf
                  ├─ validates /etc/nftables.conf
                  ├─ restarts avahi-daemon + nftables
```

---

## 🧩 Internal workflow

1. **ensure_deps()** – installs required packages (NetworkManager, Avahi, nftables).  
2. **ensure_nm_manages()** – enables NetworkManager and checks `interfaces`.  
3. **nm_ensure_mgmt() / nm_ensure_vlan_list()** – creates VLAN & management profiles.  
4. **configure_avahi()** – generates `/etc/avahi/avahi-daemon.conf`.  
5. **configure_nftables()** – enforces minimal firewall policy.  
6. **summary_banner()** – prints summary and validation commands.

---

## 🔁 Persistence design

- `/etc/mdns-bridge.env` – persistent config file.  
- `/usr/local/sbin/mdns-bridge-nm` – installed binary script.  
- `/etc/systemd/system/mdns-bridge.service` – systemd oneshot unit executed at boot.

```bash
ExecStart=/usr/local/sbin/mdns-bridge-nm apply
EnvironmentFile=/etc/mdns-bridge.env
```

---

## 🔒 Security rationale

- mDNS reflection only (UDP/5353 multicast).  
- No IP forwarding or NAT.  
- nftables: drop all by default, allow only:
  - DHCP client (UDP/67→68)
  - mDNS (UDP/5353)
  - ICMP for diagnostics
  - Everything on management interface.

---

## 🧠 Design principles

- **Idempotent** – re-runnable safely.  
- **Stateless** – config from `/etc/mdns-bridge.env`.  
- **Standard** – only Debian Bookworm tools.  
- **Persistent** – fully managed by systemd.

---

## 🧪 Testing matrix

| Platform | Status | Notes |
|-----------|---------|-------|
| Raspberry Pi 4B (Bookworm 64-bit) | ✅ | production tested |
| Debian 12 VM | ✅ | requires nmcli ≥ 1.42 |
| Ubuntu 24.04 | ✅ | identical behavior |
| L3 switch + UniFi UXG | ✅ | verified reflection & ACL routing |

---

## 🧾 Example logs

```
[INFO] Creating VLAN connection mdns-vlan10 (VID=10 on eth0)
[INFO] Configuring Avahi reflector…
Joining mDNS multicast group on interface eth0.30.IPv4
Reflecting mDNS message on eth0.50 to eth0.
```

---

## 🩺 Debug tips

```bash
sudo journalctl -u avahi-daemon | grep Reflect
avahi-browse -alr
sudo nft -c -f /etc/nftables.conf
nmcli con show --active
```

---

## 📜 License

MIT License © 2025 Eloi Primaux
