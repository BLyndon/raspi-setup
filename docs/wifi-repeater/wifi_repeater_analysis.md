# WiFi Repeater Ansible Role: Analysis & Hardening Guide

> **Status (2026-10-05):** Implemented with deviations, see `docs/superpowers/plans/2026-10-05-wifi-repeater-hardening.md` (section "Abweichungen von den Analysen").

## Executive Summary

Your setup is well-structured but suffers from **reliability issues** caused by:

1. **No interface state persistence** — IP config is lost on reboot
2. **No iptables persistence** — firewall rules are ephemeral
3. **Insufficient service health monitoring** — daemons crash silently
4. **Race conditions** — services may start before interfaces are ready
5. **Single point of failure** — no watchdog/recovery mechanism
6. **Unoptimized WiFi settings** — DTIM/beacon timing can cause clients to lose connectivity

---

## Part 1: Code Refactoring

### Problem: main.yml is a "god task file"

Currently it mixes concerns:

- ✗ Validation → Package install → Virtual interface creation → Config templating → iptables → IP setup → Service management

### Solution: Split into semantic task files

**Proposed structure:**

```
role/wifi-repeater/
├── tasks/
│   ├── main.yml                    # Entry point (includes all)
│   ├── 00-validate.yml             # Pre-flight checks
│   ├── 01-packages.yml             # Dependencies
│   ├── 02-interface-setup.yml      # Virtual AP interface
│   ├── 03-hostapd-config.yml       # hostapd configuration
│   ├── 04-dnsmasq-config.yml       # dnsmasq configuration
│   ├── 05-network-config.yml       # IP, sysctl, bridging
│   ├── 06-firewall.yml             # iptables rules (moved to netfilter)
│   └── 07-services.yml             # daemon lifecycle
├── templates/
│   ├── hostapd.conf.j2
│   ├── dnsmasq.conf.j2
│   ├── 99-wifi-repeater.netplan.j2 (NEW)
│   └── wifi-repeater-watchdog.sh.j2 (NEW)
├── files/
│   └── iptables-save.j2            (NEW - persistent firewall)
└── handlers/
    ├── main.yml                    # List all
    ├── restart-hostapd.yml
    ├── restart-dnsmasq.yml
    └── reload-netplan.yml          (NEW)
```

### New task files (example structure)

#### `tasks/00-validate.yml`

```yaml
---
- name: Validate repeater interface configuration
  ansible.builtin.assert:
    that:
      - wifi_interface_uplink != wifi_interface_repeater
      - wifi_interface_uplink | length > 0
      - wifi_interface_repeater | length > 0
    fail_msg: |
      WiFi interface validation failed:
      - uplink ({{ wifi_interface_uplink }}) must differ from repeater ({{ wifi_interface_repeater }})
      - Both must be non-empty strings
  tags: [wifi, wifi-repeater, validate]

- name: Check if nl80211 is available
  ansible.builtin.command: "modinfo nl80211"
  register: nl80211_check
  failed_when: false
  changed_when: false
  tags: [wifi, wifi-repeater, validate]

- name: Warn if nl80211 driver not loaded
  ansible.builtin.debug:
    msg: "WARNING: nl80211 module not found. WiFi AP may not work."
  when: nl80211_check.rc != 0
  tags: [wifi, wifi-repeater, validate]

- name: Check WiFi interface capabilities for AP mode
  ansible.builtin.command: "iw list | grep -A 10 'Supported interface modes'"
  register: iw_modes
  failed_when: false
  changed_when: false
  tags: [wifi, wifi-repeater, validate]

- name: Verify repeater interface supports AP mode
  ansible.builtin.assert:
    that:
      - "'AP' in iw_modes.stdout"
    fail_msg: |
      Your WiFi adapter does not support AP mode (access point).
      Check compatibility: sudo iw list | grep -A 10 'Supported interface modes'
  tags: [wifi, wifi-repeater, validate]
```

#### `tasks/05-network-config.yml`

```yaml
---
- name: Create netplan configuration for persistent IP
  ansible.builtin.template:
    src: 99-wifi-repeater.netplan.j2
    dest: /etc/netplan/99-wifi-repeater.yaml
    owner: root
    group: root
    mode: "0600"
  notify: Apply netplan
  tags: [wifi, wifi-repeater, network]

- name: Apply netplan immediately
  ansible.builtin.command: "netplan apply"
  changed_when: false
  tags: [wifi, wifi-repeater, network]
  when: not ansible_check_mode

- name: Configure IPv4 forwarding
  ansible.posix.sysctl:
    name: net.ipv4.ip_forward
    value: "1"
    sysctl_set: true
    state: present
  tags: [wifi, wifi-repeater, network]
```

#### `tasks/06-firewall.yml`

```yaml
---
- name: Create iptables save directory
  ansible.builtin.file:
    path: /etc/iptables
    state: directory
    mode: "0755"
  tags: [wifi, wifi-repeater, firewall]

- name: Deploy iptables-persistent rules
  ansible.builtin.template:
    src: iptables-save.j2
    dest: /etc/iptables/rules.v4
    owner: root
    group: root
    mode: "0600"
  notify: Restore iptables rules
  tags: [wifi, wifi-repeater, firewall]

- name: Install iptables-persistent for auto-restore
  ansible.builtin.apt:
    name: iptables-persistent
    state: present
  tags: [wifi, wifi-repeater, packages]

- name: Enable and start netfilter-persistent
  ansible.builtin.systemd:
    name: netfilter-persistent
    enabled: true
    state: started
  tags: [wifi, wifi-repeater, service]
```

---

## Part 2: Hardening Measures for Reliability

### Problem 1: Service Crashes → No Auto-Recovery

**Root cause:** hostapd and dnsmasq can crash or hang silently.

**Solutions:**

#### A. Add systemd service hardening (create in `files/`)

**`hostapd.service` override:**

```ini
[Unit]
Description=IEEE 802.11 AP and WPA Authenticator
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/hostapd.pid

# Hardening
Restart=always
RestartSec=5
StartLimitInterval=60s
StartLimitBurst=3

# Watchdog
WatchdogSec=30
WatchdogSignal=SIGKILL

# Resource limits
LimitNOFILE=65535
MemoryLimit=256M

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hostapd

[Install]
WantedBy=multi-user.target
```

**`dnsmasq.service` override:**

```ini
[Unit]
Description=Dnsmasq DNS and DHCP Server
After=network.target hostapd.service
Wants=hostapd.service

[Service]
Type=dbus
Restart=always
RestartSec=5
StartLimitInterval=60s
StartLimitBurst=3

# Watchdog
WatchdogSec=30
WatchdogSignal=SIGKILL

# Add dependency on hostapd (ensures AP is up first)
ConditionFileNotEmpty=/etc/hostapd/hostapd.conf

StandardOutput=journal
StandardError=journal
SyslogIdentifier=dnsmasq

[Install]
WantedBy=multi-user.target
```

**Ansible task:**

```yaml
- name: Deploy systemd service overrides
  ansible.builtin.copy:
    src: "{{ item }}.service.override"
    dest: "/etc/systemd/system/{{ item }}.service.d/hardening.conf"
    owner: root
    group: root
    mode: "0644"
  loop:
    - hostapd
    - dnsmasq
  notify: Reload systemd
  tags: [wifi, wifi-repeater, service]
```

---

### Problem 2: No Interface State Persistence

**Root cause:** IP is set at task runtime but lost after reboot. Tasks use `shell` with `changed_when: false`, which hides failures.

**Solution:** Use netplan for persistent IP config

**New template: `templates/99-wifi-repeater.netplan.j2`**

```yaml
---
network:
  version: 2
  ethernets:
    # Leave uplink untouched (managed by other role)
  wifis:
    {{ wifi_interface_repeater }}:
      # Only if virtual AP was created, or interface is real
      addresses:
        - {{ repeater_ip }}/24
      # Don't set gateway/nameservers; clients get them via DHCP
      dhcp4: false
      dhcp6: false

  # Alternative: bridge approach (if you need more advanced setup)
  # bridges:
  #   br-repeater:
  #     interfaces: [{{ wifi_interface_repeater }}]
  #     addresses:
  #       - {{ repeater_ip }}/24
```

---

### Problem 3: Ephemeral iptables Rules

**Root cause:** Rules set by `shell` tasks are lost after reboot. No persistence mechanism.

**Solution:** Use iptables-persistent + save rules to file

**New template: `templates/iptables-save.j2`**

```
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]

# Allow established connections
-A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Repeater → Uplink (clients can reach uplink)
-A FORWARD -i {{ wifi_interface_repeater }} -o {{ wifi_interface_uplink }} -j ACCEPT

# Uplink → Repeater (return traffic)
-A FORWARD -i {{ wifi_interface_uplink }} -o {{ wifi_interface_repeater }} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

# Masquerade: clients' source IPs appear as Pi's IP to uplink
-A POSTROUTING -o {{ wifi_interface_uplink }} -j MASQUERADE

COMMIT
```

---

### Problem 4: Race Conditions (Services Start Before Interfaces Ready)

**Root cause:** dnsmasq starts before hostapd is fully up. No dependency ordering.

**Solution:** Add systemd dependencies and health checks

**Ansible tasks:**

```yaml
- name: Add systemd dependency (dnsmasq waits for hostapd)
  ansible.builtin.lineinfile:
    path: /etc/systemd/system/dnsmasq.service.d/hardening.conf
    line: "After=hostapd.service"
    insertafter: "\[Unit\]"
    state: present
  notify: Reload systemd
  tags: [wifi, wifi-repeater, service]

- name: Add health check for hostapd readiness
  ansible.builtin.shell: |
    mkdir -p /etc/systemd/system/dnsmasq.service.d
    cat > /etc/systemd/system/dnsmasq.service.d/health-check.conf <<EOF
    [Service]
    ExecStartPost=/bin/bash -c 'for i in {1..30}; do hostapd_cli status > /dev/null 2>&1 && break || sleep 1; done'
    EOF
  changed_when: false
  tags: [wifi, wifi-repeater, service]
```

---

### Problem 5: No Monitoring or Recovery (Watchdog)

**Root cause:** If hostapd or dnsmasq crashes, you don't know until a client complains.

**Solution: Deploy a systemd watchdog + manual recovery script**

**New file: `files/wifi-repeater-watchdog.sh`**

```bash
#!/bin/bash
set -euo pipefail

# WiFi Repeater Health Monitor
# Runs every 5 minutes via cron; restarts services if dead

HOSTAPD_INTERFACE="{{ wifi_interface_repeater }}"
DNSMASQ_CONF="/etc/dnsmasq.d/wifi-repeater.conf"
LOG_FILE="/var/log/wifi-repeater-watchdog.log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Check if hostapd is running
if ! systemctl is-active --quiet hostapd; then
    log "ERROR: hostapd not running. Restarting..."
    systemctl restart hostapd
    sleep 2
fi

# Check if dnsmasq is running
if ! systemctl is-active --quiet dnsmasq; then
    log "ERROR: dnsmasq not running. Restarting..."
    systemctl restart dnsmasq
    sleep 2
fi

# Check if hostapd interface is UP
if ! ip link show "$HOSTAPD_INTERFACE" | grep -q "UP"; then
    log "ERROR: $HOSTAPD_INTERFACE is DOWN. Bringing up..."
    ip link set "$HOSTAPD_INTERFACE" up
    sleep 2
fi

# Check if dnsmasq is listening on repeater IP
REPEATER_IP="{{ repeater_ip }}"
if ! ss -tlnup | grep -q "dnsmasq.*$REPEATER_IP:53"; then
    log "ERROR: dnsmasq not listening on $REPEATER_IP:53. Restarting..."
    systemctl restart dnsmasq
    sleep 2
fi

# Check if hostapd can serve clients
if ! hostapd_cli -i "$HOSTAPD_INTERFACE" status > /dev/null 2>&1; then
    log "ERROR: hostapd_cli status failed. Restarting hostapd..."
    systemctl restart hostapd
    sleep 2
fi

# Verify at least one client (optional; remove if not needed)
# CLIENTS=$(hostapd_cli -i "$HOSTAPD_INTERFACE" list_sta 2>/dev/null | wc -l)
# log "STATUS: $CLIENTS clients connected to $HOSTAPD_INTERFACE"

log "STATUS: All services OK"
exit 0
```

**Ansible task to install watchdog:**

```yaml
- name: Deploy WiFi repeater watchdog script
  ansible.builtin.template:
    src: wifi-repeater-watchdog.sh.j2
    dest: /usr/local/bin/wifi-repeater-watchdog.sh
    owner: root
    group: root
    mode: "0755"
  tags: [wifi, wifi-repeater, monitoring]

- name: Install watchdog cron job (every 5 minutes)
  ansible.builtin.cron:
    name: "WiFi Repeater Health Check"
    minute: "*/5"
    job: "/usr/local/bin/wifi-repeater-watchdog.sh"
    user: root
    state: present
  tags: [wifi, wifi-repeater, monitoring]

- name: Create log file for watchdog
  ansible.builtin.file:
    path: /var/log/wifi-repeater-watchdog.log
    state: touch
    owner: root
    group: root
    mode: "0644"
  tags: [wifi, wifi-repeater, monitoring]
```

---

### Problem 6: WiFi Settings Cause Client Disconnects

**Root cause:** Default hostapd settings can cause clients to drop after inactivity:

- `dtim_period=2` might be too aggressive for low-power clients
- No explicit idle timeout handling
- No PSK caching for quick reconnection

**Solution: Optimize hostapd settings**

**Update `templates/hostapd.conf.j2`:**

```ini
# ===== CLIENT STABILITY TUNING =====

# Increase DTIM for low-power devices (phones in sleep mode)
# 3-5 means AP waits 3-5 beacon intervals before notifying sleeping clients
dtim_period={{ wifi_dtim_period | default(3) }}
# Default (2) can cause immediate disconnects; 3-5 is more stable

# Beacon interval (lower = faster roaming, more overhead)
beacon_int={{ wifi_beacon_int | default(100) }}

# Idle timeout: kick clients that haven't sent data in N seconds
# Prevents "ghost" connected devices
ap_max_inactivity=300

# Session timeout: force re-authentication every N seconds
# 0 = disabled (more reliable but less secure)
session_timeout=0

# Management frame protection (helps with roaming)
ieee80211w={{ wifi_pmf | default(1) }}

# Allow PMF optional (1) instead of required (2) for device compatibility
# pmf_sa_query_max_timeout=100
# pmf_sa_query_retry_timeout=100

# ===== ADDITIONAL STABILITY =====

# Allow clients to quickly reconnect without full re-auth
# (reduces "connecting..." delays)
wpa_ptk_rekey=0

# Snooping timeout: how long to remember a disassociated client
disassoc_low_ack=0

# Explicit DEAUTH handling
deauth_request_pending=true
```

**Add defaults to `defaults/main.yml`:**

```yaml
wifi_dtim_period: 3
wifi_beacon_int: 100
wifi_pmf: 1 # Management Frame Protection (optional)
```

---

## Part 3: Debugging & Monitoring Commands

### For operators to diagnose issues:

```bash
# 1. Check service status
systemctl status hostapd dnsmasq

# 2. View recent restarts
journalctl -u hostapd -u dnsmasq --since "1 hour ago" -n 50

# 3. Check connected clients
sudo hostapd_cli -i wlan1 list_sta

# 4. Monitor realtime signal/stats
sudo wavemon

# 5. Check DHCP assignments
sudo dnsmasq-lease-query 192.168.50.1

# 6. Verify iptables rules are loaded
sudo iptables -t nat -L POSTROUTING -n
sudo iptables -L FORWARD -n

# 7. Check netplan status
sudo netplan status

# 8. Monitor watchdog logs
tail -f /var/log/wifi-repeater-watchdog.log

# 9. Trace hostapd events
sudo hostapd_cli -i wlan1 -a /path/to/event_handler

# 10. Check WiFi driver logs
dmesg | grep -i "wlan1"
```

---

## Part 4: Template Additions Summary

| File                           | Purpose                                                |
| ------------------------------ | ------------------------------------------------------ |
| `99-wifi-repeater.netplan.j2`  | Persistent IP config (replaces shell tasks)            |
| `iptables-save.j2`             | Persistent firewall rules                              |
| `wifi-repeater-watchdog.sh.j2` | Health check script (detects & restarts dead services) |
| `hostapd.service.override`     | systemd hardening (restart on crash, watchdog)         |
| `dnsmasq.service.override`     | systemd hardening + dependency ordering                |

---

## Implementation Checklist

- [ ] Split `tasks/main.yml` into semantic files (00-validate, 01-packages, etc.)
- [ ] Create `netplan` template for persistent IP
- [ ] Add `iptables-persistent` package + rules file
- [ ] Deploy systemd service overrides (Restart=always, WatchdogSec)
- [ ] Create and install watchdog script
- [ ] Add cron job for health monitoring
- [ ] Update hostapd template with stability tuning
- [ ] Add dependency ordering to dnsmasq unit
- [ ] Test role on clean system
- [ ] Document in README:
  - Required variables
  - Debugging commands
  - Expected behavior after restart
  - Known limitations

---

## Expected Outcome

After these changes:
✅ Services auto-restart if they crash
✅ IP config survives reboots
✅ iptables rules persist
✅ dnsmasq waits for hostapd
✅ Health checks detect issues within 5 minutes
✅ Clients have more stable connections
✅ Easy to debug via systemd logs
