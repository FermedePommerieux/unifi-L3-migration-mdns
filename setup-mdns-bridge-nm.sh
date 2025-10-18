#!/usr/bin/env bash
# setup-mdns-bridge-nm.sh
#
# Clean mDNS bridge for Debian 12 (bookworm) using only standard components:
#   - NetworkManager (nmcli) for mgmt + VLAN interfaces
#   - Avahi (mDNS reflector) listening AND publishing on LAN + migrated VLANs
#   - nftables firewall
#
# Subcommands:
#   apply      -> create/activate NM profiles, configure Avahi & nftables now
#   install    -> make it persistent at boot (systemd unit + /etc/mdns-bridge.env)
#   uninstall  -> remove unit/config and NM profiles created by this script
#
# After reboot (install mode), the service runs after NetworkManager is online,
# rewrites Avahi config, validates nftables, and restarts both daemons.

set -euo pipefail

# -------------------------
# Defaults (EDIT THESE)
# -------------------------
# Trunk interface carrying mgmt + migrated VLANs
PHY_IF="eth0"

# Management lives either untagged on PHY_IF or tagged with a VID on PHY_IF
MGMT_MODE="untagged"   # "untagged" | "tagged"
MGMT_VID="1"           # used only if MGMT_MODE="tagged"

# ONLY the VLAN IDs offloaded to the L3 switch (NOT VLANs still routed by UDM/UXG)
VLAN_LIST=(10 30 50)

# IPv4 on management IF (applied ONLY when we create the mgmt profile)
MGMT_IP_METHOD="dhcp"              # "dhcp" | "static"
MGMT_ADDR="192.168.1.50/24"        # if static
MGMT_GW="192.168.1.1"              # if static
MGMT_DNS=("192.168.1.1" "1.1.1.1") # optional for static

# Optional reflector filters (leave empty to reflect all)
#AVAHI_REFLECT_FILTERS="_amazonecho-remote._tcp,_workstation._tcp.local,_amzn-wplay._tcp.local,_androidtvremote._tcp.local,_airdrop._tcp.local,_appletv-v2._tcp.local,_raop._tcp.local,_airplay._tcp.local,_companion-link._tcp.local,_afpovertcp._tcp.local,_presence._tcp.local,_ichat._tcp.local,_apple-mobdev2._tcp.local,_apple-mobdev._tcp.local,_atc._tcp.local,_daap._tcp.local,_home-sharing._tcp.local,_dacp._tcp.local,_aqara-setup._tcp.local,_aqara._tcp.local,_bose._tcp.local,_dns-sd._udp.local,_ftp._tcp.local,_sftp-ssh._tcp.local,_googlecast._tcp.local,_googlezone._tcp.local,_homekit._tcp.local,_hap._tcp.local,_matter._tcp,_matterc._udp,_matterd._udp,_matter_gateway._tcp,_philipshue._tcp.local,_http._tcp.local,_canon-bjnp1._tcp.local,_ipps._tcp.local,_ipp._tcp.local,_ptp._tcp.local,_http_alt._tcp.local,_ica-networking2._tcp.local,_ica-networking._tcp.local,_ipp-tls._tcp.local,_fax-ipp._tcp.local,_ippusb._tcp.local,_printer._tcp.local,_pdl-datastream._tcp.local,_scanner._tcp.local,_riousbprint._tcp.local,_scan-target._tcp.local,_roku._tcp.local,_rsp._tcp.local,_scanner._tcp,_uscans._tcp.local,_uscan._tcp.local,_sonos._tcp.local,_spotify-connect._tcp.local,_ssh._tcp.local,_adisk._tcp.local,_https._tcp.local,_smb._tcp.local,_smbdirect._tcp.local"
AVAHI_REFLECT_FILTERS=""
# Cross-family reflection (IPv4<->IPv6)
AVAHI_REFLECT_IPV="yes"

# -------------------------
# Paths / constants
# -------------------------
CONFIG_FILE="/etc/mdns-bridge.env"
INSTALL_BIN="/usr/local/sbin/mdns-bridge-nm"
SYSTEMD_UNIT="/etc/systemd/system/mdns-bridge.service"
STATE_DIR="/var/lib/mdns-bridge"
mkdir -p "$STATE_DIR"

# Names for NM connections we create
MGMT_CON_UNTAGGED="mdns-mgmt-${PHY_IF}-untagged"
MGMT_CON_TAGGED="mdns-mgmt-${PHY_IF}.${MGMT_VID}"
VLAN_CON_PREFIX="mdns-vlan"     # final name: mdns-vlan<VID>

# -------------------------
# Helpers
# -------------------------
need_pkg() { dpkg -s "$1" >/dev/null 2>&1 || { apt-get update -y && apt-get install -y "$1"; }; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf "\033[1;32m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }

nm_on() { systemctl enable --now NetworkManager; }

nm_active_con_for_dev() { nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$1" '$2==d{print $1; exit}'; }
nm_con_exists() { nmcli -g NAME con show | grep -qx "$1"; }

# -------------------------
# Load overrides from /etc/mdns-bridge.env (if present)
# -------------------------
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/etc/mdns-bridge.env
  . "$CONFIG_FILE"
  [[ "${VLAN_LIST_STR:-}" != "" ]] && read -r -a VLAN_LIST <<< "$VLAN_LIST_STR"
  [[ "${MGMT_DNS_STR:-}"  != "" ]] && read -r -a MGMT_DNS  <<< "$MGMT_DNS_STR"
fi

# -------------------------
# Core steps
# -------------------------
ensure_deps() {
  log "Installing required packages (network-manager, avahi-daemon, nftables)…"
  need_pkg network-manager
  need_pkg avahi-daemon
  need_pkg avahi-utils
  need_pkg nftables

  require_cmd nmcli
  require_cmd avahi-daemon
  require_cmd nft
}

ensure_nm_manages() {
  nm_on
  # Warn if /etc/network/interfaces likely manages the device
  if grep -qs "iface\s\+$PHY_IF" /etc/network/interfaces 2>/dev/null; then
    warn "ifupdown config seems present for $PHY_IF. Prefer letting NetworkManager manage it (avoid mixing)."
  fi
}

nm_ensure_mgmt() {
  local mgmt_if con_name
  if [[ "$MGMT_MODE" == "untagged" ]]; then
    mgmt_if="$PHY_IF"
    con_name="$MGMT_CON_UNTAGGED"
    local existing; existing="$(nm_active_con_for_dev "$mgmt_if" || true)"
    if [[ -z "$existing" ]]; then
      if ! nm_con_exists "$con_name"; then
        log "Creating untagged mgmt connection $con_name on $mgmt_if"
        nmcli con add type ethernet ifname "$mgmt_if" con-name "$con_name"
        if [[ "$MGMT_IP_METHOD" == "dhcp" ]]; then
          nmcli con mod "$con_name" ipv4.method auto ipv4.never-default no ipv6.method ignore connection.autoconnect yes
        else
          nmcli con mod "$con_name" \
            ipv4.method manual ipv4.addresses "$MGMT_ADDR" ipv4.gateway "$MGMT_GW" \
            ipv4.never-default no ipv6.method ignore connection.autoconnect yes
          if [[ ${#MGMT_DNS[@]} -gt 0 ]]; then
            nmcli con mod "$con_name" ipv4.dns "$(IFS=, ; echo "${MGMT_DNS[*]}")" ipv4.ignore-auto-dns yes
          fi
        fi
      else
        log "Using existing mgmt connection $con_name"
      fi
      nmcli con up "$con_name" || true
      MGMT_CONN="$con_name"
    else
      # Reuse active profile without changing its IP config
      log "Reusing active mgmt connection '$existing' on $mgmt_if (leaving IP settings untouched)"
      MGMT_CONN="$existing"
    fi
  else
    mgmt_if="${PHY_IF}.${MGMT_VID}"
    con_name="$MGMT_CON_TAGGED"
    if ! nm_con_exists "$con_name"; then
      log "Creating tagged mgmt connection $con_name (VID=$MGMT_VID on $PHY_IF)"
      nmcli con add type vlan ifname "$mgmt_if" dev "$PHY_IF" id "$MGMT_VID" con-name "$con_name"
      if [[ "$MGMT_IP_METHOD" == "dhcp" ]]; then
        nmcli con mod "$con_name" ipv4.method auto ipv4.never-default no ipv6.method ignore connection.autoconnect yes
      else
        nmcli con mod "$con_name" \
          ipv4.method manual ipv4.addresses "$MGMT_ADDR" ipv4.gateway "$MGMT_GW" \
          ipv4.never-default no ipv6.method ignore connection.autoconnect yes
        if [[ ${#MGMT_DNS[@]} -gt 0 ]]; then
          nmcli con mod "$con_name" ipv4.dns "$(IFS=, ; echo "${MGMT_DNS[*]}")" ipv4.ignore-auto-dns yes
        fi
      fi
    else
      log "Using existing tagged mgmt connection $con_name"
    fi
    nmcli con up "$con_name" || true
    MGMT_CONN="$con_name"
  fi

  MGMT_IFNAME="$mgmt_if"
}

nm_ensure_vlan_list() {
  VLAN_IFNAMES=()
  local vid ifname cname
  for vid in "${VLAN_LIST[@]}"; do
    ifname="${PHY_IF}.${vid}"
    cname="${VLAN_CON_PREFIX}${vid}"
    if ! nm_con_exists "$cname"; then
      log "Creating VLAN connection $cname (VID=$vid on $PHY_IF)"
      nmcli con add type vlan ifname "$ifname" dev "$PHY_IF" id "$vid" con-name "$cname"
    else
      log "Using existing VLAN connection $cname"
    fi
    nmcli con mod "$cname" ipv4.method auto ipv4.never-default yes ipv6.method ignore connection.autoconnect yes
    nmcli con up "$cname" || true
    VLAN_IFNAMES+=("$ifname")
  done
}

configure_avahi() {
  log "Configuring Avahi reflector (listen + publish on LAN and migrated VLANs)…"
  local iflist; iflist="$MGMT_IFNAME"
  local x; for x in "${VLAN_IFNAMES[@]}"; do iflist+=",$x"; done

  install -d -m 0755 /etc/avahi
  if [[ -f /etc/avahi/avahi-daemon.conf && ! -f /etc/avahi/avahi-daemon.conf.bak ]]; then
    cp -a /etc/avahi/avahi-daemon.conf /etc/avahi/avahi-daemon.conf.bak
  fi

  cat > /etc/avahi/avahi-daemon.conf <<EOF
[server]
use-ipv4=yes
use-ipv6=yes
cache-entries-max=0
ratelimit-interval-usec=1000000
ratelimit-burst=1000
allow-interfaces=${iflist}

[reflector]
enable-reflector=yes
reflect-ipv=${AVAHI_REFLECT_IPV}
$( [[ -n "$AVAHI_REFLECT_FILTERS" ]] && echo "reflect-filters=${AVAHI_REFLECT_FILTERS}" )

[wide-area]
enable-wide-area=yes

[publish]
publish-hinfo=no
publish-workstation=no

EOF

  systemctl enable avahi-daemon
  systemctl restart avahi-daemon
}

configure_nftables() {
  log "Applying nftables policy…"
  if [[ -f /etc/nftables.conf && ! -f /etc/nftables.conf.bak ]]; then
    cp -a /etc/nftables.conf /etc/nftables.conf.bak
  fi

  local MGMT_SET VLAN_SET i
  MGMT_SET="\"$MGMT_IFNAME\""
  VLAN_SET=""
  for i in "${VLAN_IFNAMES[@]}"; do VLAN_SET+="\"$i\", "; done
  VLAN_SET="${VLAN_SET%, }"

  cat > /etc/nftables.conf <<EOF
flush ruleset
table inet filter {
  set mgmt_iface {
    type ifname
    elements = { ${MGMT_SET} }
  }

  set vlan_ifaces {
    type ifname
    elements = { ${VLAN_SET} }
  }

  chain input {
    type filter hook input priority 0; policy drop;

    # Loopback & established
    iif "lo" accept
    ct state established,related accept

    # Control protocols (multicast helpers)
    ip protocol icmp accept
    ip protocol igmp accept
    ip6 nexthdr icmpv6 accept

    # Management: allow everything (admin/SSH/updates)
    iifname @mgmt_iface accept

    # DHCP replies (server -> client) on migrated VLANs
    iifname @vlan_ifaces udp sport 67 udp dport 68 accept

    # mDNS (UDP/5353) on mgmt and migrated VLANs
    iifname @mgmt_iface  udp dport 5353 accept
    iifname @vlan_ifaces udp dport 5353 accept
  }

  chain forward { type filter hook forward priority 0; policy drop; }
  chain output  { type filter hook output  priority 0; policy accept; }
}
EOF

  if nft -c -f /etc/nftables.conf; then
    systemctl enable nftables
    systemctl restart nftables
  else
    die "/etc/nftables.conf failed validation. Not restarting nftables."
  fi
}

summary_banner() {
  log "Done."
  echo
  echo "Management connection: ${MGMT_CONN} (${MGMT_IFNAME})"
  echo "Migrated VLAN IFs:     ${VLAN_IFNAMES[*]}"
  echo "Avahi:                 listen+publish on LAN+VLANs, reflect-ipv=${AVAHI_REFLECT_IPV}"
  echo "nftables:              input DROP; mgmt=ACCEPT; VLANs allow DHCP(client) + mDNS"
  echo
  echo "Quick tests:"
  echo "  - nmcli con show --active"
  echo "  - systemctl status avahi-daemon --no-pager"
  echo "  - sudo nft -c -f /etc/nftables.conf && sudo nft list ruleset | sed -n '1,160p'"
  echo "  - From a VLAN client: avahi-browse -a"
}

apply_now() {
  [[ $EUID -eq 0 ]] || die "Run as root."
  ensure_deps
  ensure_nm_manages
  nm_ensure_mgmt
  nm_ensure_vlan_list
  configure_avahi
  configure_nftables
  summary_banner
}

write_env_from_current() {
  local vlan_str dns_str
  vlan_str="$(IFS=' ' ; echo "${VLAN_LIST[*]}")"
  dns_str="$(IFS=' ' ; echo "${MGMT_DNS[*]}")"
  cat > "$CONFIG_FILE" <<EOF
# mdns-bridge (NetworkManager) config
PHY_IF="${PHY_IF}"
MGMT_MODE="${MGMT_MODE}"
MGMT_VID="${MGMT_VID}"
VLAN_LIST_STR="${vlan_str}"

MGMT_IP_METHOD="${MGMT_IP_METHOD}"
MGMT_ADDR="${MGMT_ADDR}"
MGMT_GW="${MGMT_GW}"
MGMT_DNS_STR="${dns_str}"

AVAHI_REFLECT_FILTERS="${AVAHI_REFLECT_FILTERS}"
AVAHI_REFLECT_IPV="${AVAHI_REFLECT_IPV}"
EOF
  chmod 0644 "$CONFIG_FILE"
}

install_persistent() {
  [[ $EUID -eq 0 ]] || die "Run as root."
  ensure_deps
  ensure_nm_manages

  install -m 0755 "$0" "$INSTALL_BIN"
  write_env_from_current
  log "Wrote config to $CONFIG_FILE (edit and 'systemctl restart mdns-bridge' to apply)."

  # Systemd oneshot that runs 'apply' after NM is online
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=mDNS bridge setup (NetworkManager + Avahi + nftables)
Wants=network-online.target NetworkManager-wait-online.service
After=network-online.target NetworkManager-wait-online.service

[Service]
Type=oneshot
EnvironmentFile=$CONFIG_FILE
ExecStart=$INSTALL_BIN apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now mdns-bridge.service
  log "Installed and enabled mdns-bridge.service (runs after NetworkManager is online)"
}

uninstall_all() {
  [[ $EUID -eq 0 ]] || die "Run as root."

  systemctl disable --now mdns-bridge.service 2>/dev/null || true
  rm -f "$SYSTEMD_UNIT"
  systemctl daemon-reload
  rm -f "$INSTALL_BIN"
  rm -f "$CONFIG_FILE"

  # Remove NM profiles created by us (do NOT touch user's other profiles)
  if nm_con_exists "$MGMT_CON_UNTAGGED"; then nmcli con delete "$MGMT_CON_UNTAGGED" || true; fi
  if nm_con_exists "$MGMT_CON_TAGGED";   then nmcli con delete "$MGMT_CON_TAGGED"   || true; fi
  local vid cname
  for vid in "${VLAN_LIST[@]}"; do
    cname="${VLAN_CON_PREFIX}${vid}"
    nm_con_exists "$cname" && nmcli con delete "$cname" || true
  done

  # Restore backups if present
  if [[ -f /etc/avahi/avahi-daemon.conf.bak ]]; then
    cp -a /etc/avahi/avahi-daemon.conf.bak /etc/avahi/avahi-daemon.conf
    systemctl restart avahi-daemon || true
    log "Restored /etc/avahi/avahi-daemon.conf"
  fi
  if [[ -f /etc/nftables.conf.bak ]]; then
    cp -a /etc/nftables.conf.bak /etc/nftables.conf
    if nft -c -f /etc/nftables.conf; then
      systemctl restart nftables || true
      log "Restored /etc/nftables.conf"
    else
      warn "Backup /etc/nftables.conf.bak is invalid; left current config in place."
    fi
  fi

  log "Uninstalled mdns-bridge (NetworkManager variant)."
}

# -------------------------
# Main
# -------------------------
cmd="${1:-apply}"
case "$cmd" in
  apply)      apply_now ;;
  install)    install_persistent ;;
  uninstall)  uninstall_all ;;
  *)
    echo "Usage: sudo $0 {apply|install|uninstall}"
    exit 1
    ;;
esac
