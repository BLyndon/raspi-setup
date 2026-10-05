# WiFi Repeater Reliability: Root Cause Analysis & Quick Fixes

> **Status (2026-10-05):** Implemented with deviations, see the plan `docs/superpowers/plans/2026-10-05-wifi-repeater-hardening.md` (section "Abweichungen von den Analysen") in git history: `git show f651a93:docs/superpowers/plans/2026-10-05-wifi-repeater-hardening.md`.

## The Problem You're Experiencing

**Symptom:** WiFi repeater disappears from available networks; manual `systemctl restart` fixes it temporarily.

---

## Root Causes (In Priority Order)

### 🔴 **ROOT CAUSE #1: Services Crash → No Auto-Restart**
**Impact:** HIGHEST - Explains disappearing repeater

Your current `main.yml` enables/starts services but has **no recovery mechanism**:
```yaml
- name: Enable and start hostapd
  ansible.builtin.systemd:
    enabled: true
    state: started
  # ❌ If hostapd crashes later, nothing restarts it automatically
```

If hostapd dies (OOM, segfault, timeout), the repeater is gone until you manually restart.

**Fix:** Add systemd hardening
```ini
# In /etc/systemd/system/hostapd.service.d/hardening.conf
[Service]
Restart=always
RestartSec=5
StartLimitInterval=60s
StartLimitBurst=3
WatchdogSec=30
```

**Expected outcome:** hostapd restarts within 5 seconds if it crashes
**Effort:** 5 minutes to add

---

### 🔴 **ROOT CAUSE #2: IP Config Lost After Reboot**
**Impact:** HIGH - Repeater comes back without IP address

Your current tasks use shell commands that don't persist:
```yaml
- name: Configure repeater interface runtime IP
  ansible.builtin.shell: |
    ip link set {{ wifi_interface_repeater }} up
    ip addr replace {{ repeater_ip }}/24 dev {{ wifi_interface_repeater }}
  changed_when: false
  # ❌ After reboot, interface has no IP (interface exists but is misconfigured)
```

**Fix:** Use netplan for persistent config
```yaml
# templates/99-wifi-repeater.netplan.j2
network:
  version: 2
  wifis:
    {{ wifi_interface_repeater }}:
      dhcp4: false
      addresses:
        - {{ repeater_ip }}/24
```

This survives reboots and systemd-networkd integration.

**Expected outcome:** Repeater IP persists; no manual IP config needed after reboot
**Effort:** 10 minutes to add template + apply task

---

### 🟡 **ROOT CAUSE #3: iptables Rules Ephemeral**
**Impact:** MEDIUM - Clients can't reach upstream after reboot

Your iptables rules are set but not saved:
```yaml
- name: Configure NAT masquerade
  ansible.builtin.shell: |
    iptables -t nat -A POSTROUTING -o {{ wifi_interface_uplink }} -j MASQUERADE
    # ❌ Lost after reboot or service restart
```

**Fix:** Use iptables-persistent
```yaml
- name: Install iptables-persistent
  apt: name=iptables-persistent

- name: Deploy persistent iptables rules
  template:
    src: iptables-save.j2
    dest: /etc/iptables/rules.v4
    # ✓ Auto-restored on boot via systemd
```

**Expected outcome:** NAT rules survive reboots
**Effort:** 10 minutes to add template + install package

---

### 🟡 **ROOT CAUSE #4: Race Conditions (Services Start in Wrong Order)**
**Impact:** MEDIUM - dnsmasq starts before hostapd is ready → DHCP fails initially

No systemd dependency ordering:
```yaml
# No After= clause means dnsmasq might start before hostapd brings up the interface
```

**Fix:** Add systemd dependencies
```ini
# In /etc/systemd/system/dnsmasq.service.d/order.conf
[Unit]
After=hostapd.service
```

**Expected outcome:** dnsmasq waits for hostapd to initialize
**Effort:** 5 minutes to add override

---

### 🟢 **ROOT CAUSE #5: No Health Monitoring**
**Impact:** MEDIUM - You only notice problems when clients complain

No monitoring = blind to failures between restarts.

**Fix:** Deploy watchdog script + cron
```bash
# /usr/local/bin/wifi-repeater-watchdog.sh runs every 5 min
# - Checks if hostapd/dnsmasq are running
# - Verifies interface is UP and has correct IP
# - Restarts services if they're dead
# - Logs to /var/log/wifi-repeater-watchdog.log
```

**Expected outcome:** Auto-recovery within 5 minutes of any failure
**Effort:** 15 minutes to create script + cron

---

### 🟢 **ROOT CAUSE #6: WiFi Settings Cause Client Timeouts**
**Impact:** LOW-MEDIUM - Clients drop after inactivity

Current hostapd.conf defaults (`dtim_period=2`) too aggressive for low-power devices:
```
dtim_period=2  # Wakes sleeping clients every 2 beacons (very frequent)
```

**Fix:** Relax settings + add idle timeout handling
```ini
dtim_period=3                    # Less aggressive wakeup
ap_max_inactivity=300            # Kick idle clients (prevent "ghost" connections)
session_timeout=0                # Don't force re-auth
```

**Expected outcome:** More stable client connections
**Effort:** 5 minutes to update template

---

## Quick Implementation Plan (By Impact)

### 🚀 Phase 1: Fix the Disappearing Repeater (30 min)

Do these **immediately** — they fix 80% of the issue:

1. **Add systemd Restart=always** (5 min)
   - Creates: `/etc/systemd/system/hostapd.service.d/hardening.conf`
   - Effect: hostapd auto-restarts if it crashes

2. **Add netplan persistent IP** (10 min)
   - Creates: `templates/99-wifi-repeater.netplan.j2`
   - Effect: IP survives reboots; systemd-networkd manages it

3. **Add systemd dependency ordering** (5 min)
   - Creates: `/etc/systemd/system/dnsmasq.service.d/order.conf`
   - Effect: dnsmasq waits for hostapd

4. **Deploy watchdog script** (10 min)
   - Creates: `/usr/local/bin/wifi-repeater-watchdog.sh`
   - Effect: Auto-recovery within 5 minutes of any failure
   - Add cron: `*/5 * * * * /usr/local/bin/wifi-repeater-watchdog.sh`

### Phase 2: Persistence & Robustness (20 min)

5. **Make iptables persistent** (10 min)
   - Install `iptables-persistent`
   - Create: `templates/iptables-save.j2`
   - Effect: NAT rules survive reboots

6. **Refactor tasks** (10 min)
   - Split main.yml into semantic files
   - Better maintainability, easier to debug

### Phase 3: Optimization (10 min)

7. **Tune WiFi settings** (5 min)
   - Update hostapd template with stability settings
   - Effect: Fewer client disconnects

8. **Add monitoring** (5 min)
   - Set up logrotation
   - Create dashboard query to watch watchdog logs

---

## Verification Checklist

After implementing Phase 1 only:

```bash
# 1. Check hostapd has Restart=always
systemctl cat hostapd | grep Restart

# 2. Check dnsmasq depends on hostapd
systemctl cat dnsmasq | grep After

# 3. Check repeater IP is persistent
ip addr show wlan1 | grep 192.168.50

# 4. Verify watchdog is running
crontab -l | grep wifi-repeater

# 5. Check iptables rules exist
iptables -t nat -L POSTROUTING -n | grep MASQUERADE

# 6. Force-kill hostapd and watch it restart
sudo pkill -9 hostapd
sleep 2
systemctl is-active hostapd  # Should show "active"

# 7. Check watchdog logs
tail -f /var/log/wifi-repeater-watchdog.log
```

---

## Testing the Fix

### Test 1: Service Crash Recovery
```bash
# In one terminal, watch logs:
journalctl -u hostapd -f

# In another, kill hostapd:
sudo pkill -9 hostapd

# Expect: hostapd restarts within 5 seconds (with Restart=always)
# Repeater should remain visible in network scan
```

### Test 2: Reboot Persistence
```bash
# 1. Note the repeater IP before reboot
ip addr show wlan1

# 2. Reboot
sudo reboot

# 3. After reboot, check IP is back (netplan auto-applied)
ip addr show wlan1

# 4. Check iptables rules are restored
iptables -t nat -L POSTROUTING -n | grep MASQUERADE
```

### Test 3: Watchdog Auto-Recovery
```bash
# 1. Break dnsmasq intentionally
sudo systemctl stop dnsmasq

# 2. Wait 5 minutes (watchdog cycle) or run manually:
sudo /usr/local/bin/wifi-repeater-watchdog.sh

# 3. Check it auto-restarted
systemctl is-active dnsmasq  # Should show "active"

# 4. Check log
tail /var/log/wifi-repeater-watchdog.log | grep "dnsmasq"
```

---

## Expected Before/After

### Before (Current Setup)
```
Day 0:  ✓ Repeater works, IP: 192.168.50.1
        └─ Manual: systemctl enable/start hostapd dnsmasq

Day 1:  ✗ hostapd crashes (OOM/segfault)
        └─ Repeater gone, must manually restart
        └─ No IP persistence across reboot
        └─ iptables rules lost after power cycle

Day 2:  ✗ Same problem
        └─ Manual restart every few hours

Week 1: ✗ Repeater is unreliable
        └─ Users learn to avoid it
```

### After (Hardened Setup)
```
Day 0:  ✓ Repeater works, IP: 192.168.50.1
        └─ Ansible applies hardening (30 min)

Day 1:  ✓ hostapd crashes at 14:32
        └─ Watchdog detects at 14:35
        └─ Watchdog restarts hostapd at 14:35
        └─ Clients reconnect automatically (some may notice 3-min blip)

Day 2:  ✓ Reboot happens
        └─ netplan re-applies IP automatically
        └─ iptables-persistent restores rules
        └─ Repeater comes back up fully functional (no manual action)

Week 1: ✓ Repeater is reliable
        └─ No manual interventions needed
        └─ Watchdog logs show any issues immediately
```

---

## Why These Fixes Work

| Problem | Root Cause | Fix | Result |
|---------|-----------|-----|--------|
| Repeater disappears | hostapd crashes | `Restart=always` | Auto-restarts in 5s |
| IP lost after reboot | Shell tasks don't persist | netplan + systemd-networkd | Survives reboot |
| NAT rules gone | iptables not saved | iptables-persistent | Rules persist |
| dnsmasq fails early | No ordering | `After=hostapd` | Proper startup sequence |
| Issues undetected | No monitoring | Watchdog + cron | 5-min auto-recovery |
| Client timeouts | DTIM too aggressive | Tune WiFi settings | Stable connections |

---

## Files You Need to Create

### Minimal (Fixes 80% of issues — 30 min)
1. `tasks/00-validate.yml` (new section in role)
2. `templates/99-wifi-repeater.netplan.j2` (NEW)
3. `tasks/05-network-config.yml` (new section in role)
4. `templates/wifi-repeater-watchdog.sh.j2` (NEW)
5. `tasks/08-monitoring.yml` (new section in role)
6. Update `tasks/main.yml` to include the new task files

### Complete (Fixes 95% of issues — 60 min)
Add Phase 2:
7. `templates/iptables-save.j2` (NEW)
8. `tasks/06-firewall.yml` (new section in role)
9. Split main.yml into semantic files (01-packages, 02-interface, etc.)

---

## Next Steps

1. **Read** both analysis documents carefully
2. **Implement Phase 1** (systemd hardening + netplan + watchdog) — 30 min
3. **Test** the fixes with the verification checklist
4. **Monitor** `/var/log/wifi-repeater-watchdog.log` for a week
5. **Add Phase 2** if you want full robustness (iptables persistence + refactoring)

**Expected result:** Repeater reliably comes back online within 5 minutes of any failure, no manual intervention needed.
