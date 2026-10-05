# WiFi-Repeater: Refactoring & Stabilität – Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Die Rolle `wifi_repeater` wieder lauffähig machen und so härten, dass der Repeater Reboots, Dienst-Abstürze und Kanalwechsel des Uplinks ohne manuellen Eingriff übersteht.

**Architecture:** Alles, was heute nur zur Ansible-Laufzeit per `shell` gesetzt wird (virtuelles `ap0`, IP, NAT-Regeln), wandert in kleine, idempotente Skripte unter `/usr/local/sbin/`, die von eigenen systemd-Units beim Boot ausgeführt werden. hostapd/dnsmasq bekommen systemd-Drop-ins (Restart + Startreihenfolge), hostapd startet mit einer Laufzeitkopie der Konfiguration, deren Kanal dem Uplink folgt. Ein systemd-Timer prüft alle 2 Minuten und repariert. Eine Datei `09-verify.yml` prüft den Soll-Zustand auf dem Pi und dient als Test für jeden Task.

**Tech Stack:** Ansible (`ansible.builtin`, `ansible.posix`), systemd, hostapd, dnsmasq, iptables (nft-Backend), NetworkManager, Debian 13 auf Raspberry Pi.

**Spec:** `docs/wifi-repeater/wifi_repeater_analysis.md`, `docs/wifi-repeater/wifi_repeater_implementation.md`, `docs/wifi-repeater/wifi_repeater_quick_fix.md`. Die Analysen sind die Grundlage, an mehreren Stellen weicht der Plan bewusst davon ab, siehe nächster Abschnitt.

## Abweichungen von den Analysen (bewusst)

| Analyse schlägt vor | Problem | Plan macht stattdessen |
|---|---|---|
| netplan für persistente IP | Auf dem Pi (Debian 13) verwaltet NetworkManager die Interfaces, netplan ist dort kein Standard. `wifis:` ohne `access-points` ist in netplan zudem ungültig. | systemd-Unit `wifi-repeater-iface.service` legt `ap0` an und setzt die IP. NetworkManager ignoriert `ap0` per `unmanaged-devices`. |
| (fehlt) | `ap0` wird heute nur einmalig per `iw … interface add` angelegt. **Nach einem Reboot existiert `ap0` nicht mehr**, hostapd startet nicht. Wahrscheinlich die Hauptursache für „Repeater verschwindet“. | Dieselbe Unit legt `ap0` bei jedem Boot an. |
| (fehlt) | `ap0` läuft auf demselben Funkchip wie `wlan0`. Der Chip kann AP und Client nur **auf demselben Kanal** betreiben. Wechselt der Router den Kanal, fällt der AP aus. | hostapd übernimmt beim Start den aktuellen Uplink-Kanal; der Watchdog startet bei Abweichung neu. |
| `iptables-persistent` + komplette `rules.v4` | `iptables-restore` einer kompletten Datei leert die Tabellen `filter`/`nat` und damit **Dockers Regeln** (Docker läuft auf demselben Pi). | Idempotentes Skript (`-C … \|\| -I …`) als systemd-Unit, das nur die eigenen 3 Regeln setzt. |
| `WatchdogSec=30` in den Drop-ins | hostapd/dnsmasq senden keine sd_notify-Keepalives. systemd würde sie **alle 30 s killen**. | Nur `Restart=always`, `RestartSec`, `StartLimit*` (im `[Unit]`-Abschnitt). |
| dnsmasq-Drop-in mit `Type=dbus` | Falscher Service-Typ für das Debian-Paket. | `Type` nicht anfassen, nur Reihenfolge + Restart. |
| Watchdog per cron, eigenes Logfile + logrotate | cron ist auf Debian 13 nicht garantiert vorhanden. Der `ss`-grep `dnsmasq.*IP:53` passt nie (falsche Feldreihenfolge), dadurch würde dnsmasq alle 5 min neu gestartet. | systemd-Timer, Ausgabe ins Journal, DHCP-Check auf Port 67. |
| hostapd-Optionen `deauth_request_pending`, `session_timeout` | Keine gültigen hostapd-Optionen. | Nur gültige Optionen. Zusätzlich `ctrl_interface`, ohne das `hostapd_cli` (und damit jeder Health-Check) nicht funktioniert. |
| `modinfo nl80211`, `command: "iw list \| grep …"` | nl80211 ist kein Kernelmodul; `command` kennt keine Pipes. Das Assert schlägt **immer** fehl, die Rolle bricht heute schon in `00-validate.yml` ab. | `iw list` ohne Pipe, Assert auf `* AP`. |

## Global Constraints

- Zielsystem: Debian 13 (Raspberry Pi), Host `raspi-01`, Uplink `wlan0`, AP `ap0` (virtuell, `wifi_virtual_ap_enabled: true`), Subnetz `192.168.2.0/24`.
- Module immer mit FQCN (`ansible.builtin.*`, `ansible.posix.*`). Keine neuen Collections.
- Tags jedes Tasks: `[wifi, wifi-repeater, <bereich>]`. Verify-Tasks: `[wifi, wifi-repeater, wifi-verify]`.
- Registrierte Variablen und neue Defaults beginnen mit `wifi_repeater_` (ansible-lint `var-naming[no-role-prefix]`).
- Vom Ansible erzeugte Dateien auf dem Pi beginnen mit dem Kommentar `# Managed by Ansible (wifi_repeater role)`.
- Kommentare/Doku im Repo auf Englisch (wie bestehender Code), Commit-Messages kurz und klein geschrieben (Repo-Stil).
- `pi_nodes.local.yml` ist gitignored und enthält Secrets. Niemals committen oder ausgeben.

**Befehle (aus dem Repo-Root, Zugang zum Pi vorausgesetzt):**

- Syntax: `(cd ansible && ansible-playbook site.yml --syntax-check)`
- Deploy: `(cd ansible && ansible-playbook site.yml -l raspi-01 --tags wifi-repeater --skip-tags common)`
- Verify: `(cd ansible && ansible-playbook site.yml -l raspi-01 --tags wifi-verify --skip-tags common)`

## Review Focus

1. **Reboot des Pi** → `ap0`, IP, NAT, hostapd, dnsmasq sind ohne Eingriff wieder da. Test: Task 2 Step 7 und Task 8.
2. **hostapd stürzt ab (`kill -9`)** → AP ist nach ≤10 s wieder sichtbar. Test: Task 4 Step 6.
3. **Router wechselt den Kanal / Uplink ist beim Boot nicht verbunden** → AP folgt dem Uplink-Kanal spätestens nach einem Watchdog-Lauf. Test: Task 5 Step 7, Task 6 Step 7.
4. **`systemctl restart docker`** → Repeater-Clients haben weiter Internet. Test: Task 3 Step 6.
5. **Zweiter Ansible-Lauf ohne Änderungen** → `changed=0` für die Rolle, hostapd wird nicht neu gestartet, Clients fliegen nicht raus. Test: Task 7 Step 6.

---

### Task 0: Ist-Zustand auf dem Pi erheben (nur lesen)

Kein Code. Bestätigt die Annahmen des Plans, bevor etwas geändert wird.

**Files:**
- Create: `docs/wifi-repeater/diagnosis-2026-10-05.md`

- [ ] **Step 1: Befehle auf dem Pi ausführen** (`ssh pi@raspi-01`), Ausgabe in die Diagnose-Datei kopieren:

```bash
head -3 /etc/os-release
systemctl is-active NetworkManager networking dhcpcd wpa_supplicant docker
nmcli -t -f DEVICE,TYPE,STATE device
ls -l /etc/network/interfaces.d/ && cat /etc/network/interfaces.d/wlan0
command -v netplan cron iptables nft; iptables -V
iw dev
iw list | grep -A6 'valid interface combinations'
systemctl cat hostapd | grep -E '^(Type|PIDFile|ExecStart|EnvironmentFile|Restart)'
systemctl cat dnsmasq | grep -E '^(Type|ExecStart|Restart)'
journalctl -u hostapd --since "-7 days" --no-pager | grep -iE 'fail|channel|terminat|disconn|DFS' | tail -30
```

- [ ] **Step 2: Erwartung prüfen und festhalten**
  - `iptables -V` zeigt `nf_tables` → Plan passt.
  - `valid interface combinations` enthält `#channels <= 1` → Kanal-Kopplung (Task 5) ist nötig.
  - hostapd `Type=forking`, `PIDFile=/run/hostapd.pid` → Drop-in in Task 5 passt. Weicht das ab, die Werte im Drop-in aus Task 5 an die Ausgabe angleichen.
  - NetworkManager `active` **und** `/etc/network/interfaces.d/wlan0` existiert → zwei Netzwerk-Stacks konkurrieren um `wlan0`. Als offener Punkt notieren (siehe „Nach diesem Plan“), nicht in diesem Plan lösen.
  - Journal zeigt Kanal-/DFS-Meldungen → bestätigt die Kanal-Hypothese.

- [ ] **Step 3: Commit**

```bash
git add docs/wifi-repeater/diagnosis-2026-10-05.md
git commit -m "add wifi repeater diagnosis"
```

---

### Task 1: Rolle refaktorieren und wieder lauffähig machen

Reines Refactoring ohne Verhaltensänderung: `main.yml` nur noch Imports, Inline-Tasks in die Teil-Dateien, kaputte Validierung reparieren, nicht existierende Templates (netplan, iptables-save, watchdog) aus dem Ablauf nehmen. `import_tasks` statt `include_tasks`, damit Tags und `--check` auf die enthaltenen Tasks wirken.

**Files:**
- Modify: `ansible/roles/wifi_repeater/tasks/main.yml` (komplett ersetzen)
- Modify: `ansible/roles/wifi_repeater/tasks/00-validate.yml` (komplett ersetzen)
- Modify: `ansible/roles/wifi_repeater/tasks/01-packages.yml`, `02-interface-setup.yml`, `03-hostapd-config.yml`, `04-dnsmasq-config.yml`, `05-network-config.yml`, `06-firewall.yml`, `07-services.yml`
- Delete: `ansible/roles/wifi_repeater/tasks/08-monitoring.yml` (wird in Task 6 neu erstellt)
- Create: `ansible/roles/wifi_repeater/tasks/09-verify.yml`

**Interfaces:**
- Produces: `09-verify.yml` mit zwei Loop-Tasks („Check repeater units are enabled/active“). Spätere Tasks erweitern deren `loop`-Liste. `main.yml` importiert `09-verify.yml` nach `flush_handlers`, nur außerhalb von Check-Mode.

- [ ] **Step 1: Verify-Datei schreiben (der „Test“)**

`ansible/roles/wifi_repeater/tasks/09-verify.yml`:

```yaml
---
# Post-deployment checks for the WiFi repeater.
# Run only these with: ansible-playbook site.yml -l raspi-01 --tags wifi-verify --skip-tags common

- name: Check repeater units are enabled
  ansible.builtin.command: "systemctl is-enabled {{ item }}"
  loop:
    - hostapd.service
    - dnsmasq.service
  register: wifi_repeater_verify_enabled
  changed_when: false
  failed_when: wifi_repeater_verify_enabled.stdout != 'enabled'
  tags: [wifi, wifi-repeater, wifi-verify]

- name: Check repeater units are active
  ansible.builtin.command: "systemctl is-active {{ item }}"
  loop:
    - hostapd.service
    - dnsmasq.service
  register: wifi_repeater_verify_active
  changed_when: false
  failed_when: wifi_repeater_verify_active.stdout != 'active'
  tags: [wifi, wifi-repeater, wifi-verify]
```

- [ ] **Step 2: Aktuellen Stand deployen und Fehlschlag bestätigen**

Run: Deploy-Befehl
Expected: FAIL bei `Verify repeater interface supports AP mode` (Pipe im `command`-Modul, `iw_modes.stdout` ist leer).

- [ ] **Step 3: Teil-Dateien schreiben**

`00-validate.yml` (komplett):

```yaml
---
- name: Validate repeater configuration
  ansible.builtin.assert:
    that:
      - wifi_interface_uplink | length > 0
      - wifi_interface_repeater | length > 0
      - wifi_interface_uplink != wifi_interface_repeater
      - wifi_repeater_ssid | length > 0
      - wifi_repeater_password | length >= 8
      - wifi_repeater_password | length <= 63
      - wifi_repeater_password != 'CHANGE_ME'
      - repeater_ip is match('^([0-9]{1,3}\.){3}[0-9]{1,3}$')
    fail_msg: |
      WiFi repeater configuration is invalid:
      - uplink ({{ wifi_interface_uplink }}) and repeater ({{ wifi_interface_repeater }}) must be set and differ
      - wifi_repeater_ssid must be set
      - wifi_repeater_password must be 8-63 characters and not the CHANGE_ME placeholder
      - repeater_ip must be an IPv4 address
    quiet: true
  tags: [wifi, wifi-repeater, validate]
```

`01-packages.yml`: `---` als erste Zeile ergänzen und `iptables` in die erste Paketliste aufnehmen:

```yaml
---
- name: Install WiFi repeater dependencies
  ansible.builtin.apt:
    name:
      - hostapd
      - dnsmasq
      - iptables
      - bridge-utils
      - wavemon
      - rfkill
    state: present
  tags: [wifi, wifi-repeater, packages]

- name: Install nl80211 driver support
  ansible.builtin.apt:
    name:
      - iw
      - wireless-tools
      - wpasupplicant
    state: present
  tags: [wifi, wifi-repeater, packages]
```

`02-interface-setup.yml` (komplett, Hardware-Check läuft jetzt nach der Paketinstallation; der Runtime-IP-Task kommt unverändert aus `main.yml` und wird in Task 2 ersetzt):

```yaml
---
- name: Read WiFi hardware capabilities
  ansible.builtin.command: iw list
  register: wifi_repeater_iw_list
  changed_when: false
  check_mode: false
  tags: [wifi, wifi-repeater, validate]

- name: Verify the WiFi hardware supports AP mode
  ansible.builtin.assert:
    that:
      - "'* AP' in wifi_repeater_iw_list.stdout"
    fail_msg: "No AP mode in 'iw list' output. This adapter cannot run an access point."
    quiet: true
  tags: [wifi, wifi-repeater, validate]

- name: Check if repeater interface exists
  ansible.builtin.command: "ip link show {{ wifi_interface_repeater }}"
  register: wifi_repeater_interface_exists
  failed_when: false
  changed_when: false
  tags: [wifi, wifi-repeater, validate]

- name: Create virtual repeater interface
  ansible.builtin.command: "iw dev {{ wifi_interface_uplink }} interface add {{ wifi_interface_repeater }} type __ap"
  changed_when: true
  when:
    - wifi_virtual_ap_enabled | default(false) | bool
    - wifi_repeater_interface_exists.rc != 0
  tags: [wifi, wifi-repeater, network]

- name: Configure repeater interface runtime IP
  ansible.builtin.shell: |
    ip link set {{ wifi_interface_repeater }} up
    ip addr replace {{ repeater_ip }}/24 dev {{ wifi_interface_repeater }}
  changed_when: false
  tags: [wifi, wifi-repeater, network]
  when: not ansible_check_mode
```

`03-hostapd-config.yml`: nur `---` als erste Zeile ergänzen, Inhalt sonst unverändert.

`04-dnsmasq-config.yml` (aus `main.yml` verschoben):

```yaml
---
- name: Create dnsmasq configuration for WiFi repeater
  ansible.builtin.template:
    src: dnsmasq.conf.j2
    dest: /etc/dnsmasq.d/wifi-repeater.conf
    owner: root
    group: root
    mode: "0644"
  notify: Restart dnsmasq
  tags: [wifi, wifi-repeater, config]
```

`05-network-config.yml` (netplan raus, nur Forwarding bleibt):

```yaml
---
- name: Configure IPv4 forwarding
  ansible.posix.sysctl:
    name: net.ipv4.ip_forward
    value: "1"
    sysctl_set: true
    state: present
  tags: [wifi, wifi-repeater, network]
```

`06-firewall.yml` (die drei Shell-Tasks unverändert aus `main.yml`, werden in Task 3 ersetzt):

```yaml
---
- name: Configure NAT masquerade for repeater clients
  ansible.builtin.shell: |
    iptables -t nat -C POSTROUTING -o {{ wifi_interface_uplink }} -j MASQUERADE || \
    iptables -t nat -A POSTROUTING -o {{ wifi_interface_uplink }} -j MASQUERADE
  changed_when: false
  tags: [wifi, wifi-repeater, firewall]
  when: not ansible_check_mode

- name: Allow repeater -> uplink forwarding
  ansible.builtin.shell: |
    iptables -C FORWARD -i {{ wifi_interface_repeater }} -o {{ wifi_interface_uplink }} -j ACCEPT || \
    iptables -A FORWARD -i {{ wifi_interface_repeater }} -o {{ wifi_interface_uplink }} -j ACCEPT
  changed_when: false
  tags: [wifi, wifi-repeater, firewall]
  when: not ansible_check_mode

- name: Allow established uplink -> repeater forwarding
  ansible.builtin.shell: |
    iptables -C FORWARD -i {{ wifi_interface_uplink }} -o {{ wifi_interface_repeater }} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || \
    iptables -A FORWARD -i {{ wifi_interface_uplink }} -o {{ wifi_interface_repeater }} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  changed_when: false
  tags: [wifi, wifi-repeater, firewall]
  when: not ansible_check_mode
```

`07-services.yml`:

```yaml
---
- name: Unmask repeater services
  ansible.builtin.systemd:
    name: "{{ item }}"
    masked: false
  loop: [hostapd, dnsmasq]
  tags: [wifi, wifi-repeater, service]
  when: not ansible_check_mode

- name: Enable and start repeater services
  ansible.builtin.systemd:
    name: "{{ item }}"
    enabled: true
    state: started
  loop: [hostapd, dnsmasq]
  tags: [wifi, wifi-repeater, service]
  when: not ansible_check_mode
```

`08-monitoring.yml` löschen: `rm ansible/roles/wifi_repeater/tasks/08-monitoring.yml`

- [ ] **Step 4: `main.yml` ersetzen**

```yaml
---
# WiFi Repeater role - Configure hostapd and dnsmasq for WiFi repeating
# Prerequisites: network role (for network configuration)

- name: Import validation tasks
  ansible.builtin.import_tasks: 00-validate.yml

- name: Import package installation tasks
  ansible.builtin.import_tasks: 01-packages.yml

- name: Import interface setup tasks
  ansible.builtin.import_tasks: 02-interface-setup.yml

- name: Import hostapd configuration tasks
  ansible.builtin.import_tasks: 03-hostapd-config.yml

- name: Import dnsmasq configuration tasks
  ansible.builtin.import_tasks: 04-dnsmasq-config.yml

- name: Import network configuration tasks
  ansible.builtin.import_tasks: 05-network-config.yml

- name: Import firewall tasks
  ansible.builtin.import_tasks: 06-firewall.yml

- name: Import service tasks
  ansible.builtin.import_tasks: 07-services.yml

- name: Apply pending changes before verification
  ansible.builtin.meta: flush_handlers

- name: Import verification tasks
  ansible.builtin.import_tasks: 09-verify.yml
  when: not ansible_check_mode

- name: Display WiFi repeater configuration
  ansible.builtin.debug:
    msg: |
      WiFi Repeater Configuration:
      - SSID: {{ wifi_repeater_ssid }}
      - Channel: {{ wifi_channel }}
      - Country: {{ wifi_country }}
      - Repeater IP: {{ repeater_ip }}
      - DHCP Range: {{ repeater_dhcp_start }} - {{ repeater_dhcp_end }}
      - Uplink Interface: {{ wifi_interface_uplink }}
      - Repeater Interface: {{ wifi_interface_repeater }}

      Verify with:
        sudo systemctl status hostapd
        sudo systemctl status dnsmasq
        sudo hostapd_cli status
  tags: [debug, wifi, wifi-repeater]
```

- [ ] **Step 5: Syntax prüfen**

Run: Syntax-Befehl
Expected: `playbook: site.yml`, kein Fehler.

- [ ] **Step 6: Deployen und verifizieren**

Run: Deploy-Befehl
Expected: PASS, die Verify-Tasks `Check repeater units are enabled/active` sind grün.

- [ ] **Step 7: Commit** (nimmt die bereits angefangenen, uncommitteten Refactoring-Dateien und die README-Änderung mit)

```bash
git add README.md ansible/roles/wifi_repeater/tasks/
git commit -m "refactor wifi repeater role into task files"
```

---

### Task 2: `ap0` und IP persistent machen

**Files:**
- Create: `ansible/roles/wifi_repeater/defaults/main.yml`
- Create: `ansible/roles/wifi_repeater/templates/wifi-repeater-iface.sh.j2`
- Create: `ansible/roles/wifi_repeater/templates/wifi-repeater-iface.service.j2`
- Modify: `ansible/roles/wifi_repeater/tasks/02-interface-setup.yml` (die letzten drei Tasks ersetzen)
- Modify: `ansible/roles/wifi_repeater/handlers/main.yml` (komplett ersetzen)
- Modify: `ansible/roles/wifi_repeater/tasks/09-verify.yml`

**Interfaces:**
- Produces: Unit `wifi-repeater-iface.service` (oneshot, `RemainAfterExit=yes`, läuft `Before=hostapd.service dnsmasq.service`). Handler `Reload systemd`, `Reload NetworkManager config`, `Restart wifi-repeater-iface`, `Restart wifi-repeater-firewall`, `Restart hostapd`, `Restart dnsmasq`. Defaults `wifi_repeater_subnet`, `wifi_repeater_uplink_power_save`, `wifi_repeater_channel_follow_uplink`, `wifi_repeater_watchdog_interval`, `wifi_repeater_dtim_period`, `wifi_repeater_beacon_int`, `wifi_repeater_ap_max_inactivity`, `wifi_repeater_dns_servers`.

- [ ] **Step 1: Verify erweitern**

In `09-verify.yml` bei **beiden** Loop-Tasks die Liste ersetzen durch:

```yaml
  loop:
    - wifi-repeater-iface.service
    - hostapd.service
    - dnsmasq.service
```

Und am Dateiende anhängen:

```yaml
- name: Read AP interface address
  ansible.builtin.command: "ip -4 -o addr show dev {{ wifi_interface_repeater }}"
  register: wifi_repeater_verify_addr
  changed_when: false
  failed_when: ("inet " ~ repeater_ip ~ "/24") not in wifi_repeater_verify_addr.stdout
  tags: [wifi, wifi-repeater, wifi-verify]
```

- [ ] **Step 2: Verify laufen lassen, Fehlschlag bestätigen**

Run: Verify-Befehl
Expected: FAIL bei `Check repeater units are enabled` für `wifi-repeater-iface.service` (`Failed to get unit file state`).

- [ ] **Step 3: Defaults anlegen** (alle Defaults des Plans auf einmal, damit spätere Tasks sie nicht einzeln ergänzen müssen)

`ansible/roles/wifi_repeater/defaults/main.yml`:

```yaml
---
# WiFi Repeater role defaults (override in group_vars/host_vars)

# Repeater subnet, derived from repeater_ip (/24)
wifi_repeater_subnet: "{{ repeater_ip | regex_replace('\\.[0-9]+$', '.0') }}/24"

# Disable power saving on the uplink (brcmfmac drops connections with it on)
wifi_repeater_uplink_power_save: false

# Single-radio setups: AP must use the uplink's current channel
wifi_repeater_channel_follow_uplink: true

# How often the self-healing watchdog runs
wifi_repeater_watchdog_interval: "2min"

# hostapd client stability tuning
wifi_repeater_dtim_period: 3
wifi_repeater_beacon_int: 100
wifi_repeater_ap_max_inactivity: 300

# DNS servers handed out to repeater clients via DHCP
wifi_repeater_dns_servers: ["8.8.8.8", "8.8.4.4"]
```

- [ ] **Step 4: Skript und Unit anlegen**

`templates/wifi-repeater-iface.sh.j2`:

```bash
#!/bin/bash
# Managed by Ansible (wifi_repeater role)
# Creates the AP interface and assigns its static address. Runs at boot
# via wifi-repeater-iface.service; safe to run repeatedly.
set -u

UPLINK="{{ wifi_interface_uplink }}"
AP="{{ wifi_interface_repeater }}"
ADDR="{{ repeater_ip }}/24"

{% if wifi_virtual_ap_enabled | default(false) | bool %}
if ! ip link show "$AP" >/dev/null 2>&1; then
    iw dev "$UPLINK" interface add "$AP" type __ap || exit 1
fi
{% endif %}
{% if not wifi_repeater_uplink_power_save | bool %}
iw dev "$UPLINK" set power_save off 2>/dev/null || true
{% endif %}

ip link set "$AP" up || exit 1
ip addr replace "$ADDR" dev "$AP" || exit 1
```

`templates/wifi-repeater-iface.service.j2`:

```ini
# Managed by Ansible (wifi_repeater role)
[Unit]
Description=WiFi repeater AP interface ({{ wifi_interface_repeater }})
Wants=sys-subsystem-net-devices-{{ wifi_interface_uplink }}.device
After=sys-subsystem-net-devices-{{ wifi_interface_uplink }}.device NetworkManager.service
Before=hostapd.service dnsmasq.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/wifi-repeater-iface

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 5: Tasks und Handler**

In `02-interface-setup.yml` die drei Tasks `Check if repeater interface exists`, `Create virtual repeater interface` und `Configure repeater interface runtime IP` ersetzen durch:

```yaml
- name: Keep NetworkManager away from the AP interface
  ansible.builtin.copy:
    dest: /etc/NetworkManager/conf.d/99-wifi-repeater.conf
    content: |
      # Managed by Ansible (wifi_repeater role)
      [keyfile]
      unmanaged-devices=interface-name:{{ wifi_interface_repeater }}
    owner: root
    group: root
    mode: "0644"
  notify: Reload NetworkManager config
  tags: [wifi, wifi-repeater, network]

- name: Deploy repeater interface script
  ansible.builtin.template:
    src: wifi-repeater-iface.sh.j2
    dest: /usr/local/sbin/wifi-repeater-iface
    owner: root
    group: root
    mode: "0755"
  notify: Restart wifi-repeater-iface
  tags: [wifi, wifi-repeater, network]

- name: Deploy repeater interface unit
  ansible.builtin.template:
    src: wifi-repeater-iface.service.j2
    dest: /etc/systemd/system/wifi-repeater-iface.service
    owner: root
    group: root
    mode: "0644"
  notify:
    - Reload systemd
    - Restart wifi-repeater-iface
  tags: [wifi, wifi-repeater, network]

- name: Enable and start repeater interface unit
  ansible.builtin.systemd:
    name: wifi-repeater-iface
    enabled: true
    state: started
    daemon_reload: true
  tags: [wifi, wifi-repeater, network]
  when: not ansible_check_mode
```

`handlers/main.yml` (komplett; Handler laufen in dieser Reihenfolge, daher `Reload systemd` zuerst; ein Neustart von `wifi-repeater-iface` startet hostapd über `Requires=` aus Task 4 mit):

```yaml
---
# WiFi Repeater role handlers (executed in definition order)

- name: Reload systemd
  ansible.builtin.systemd:
    daemon_reload: true

- name: Reload NetworkManager config
  ansible.builtin.command: nmcli general reload conf
  changed_when: true
  when: not ansible_check_mode

- name: Restart wifi-repeater-iface
  ansible.builtin.systemd:
    name: wifi-repeater-iface
    state: restarted
  when: not ansible_check_mode

- name: Restart wifi-repeater-firewall
  ansible.builtin.systemd:
    name: wifi-repeater-firewall
    state: restarted
  when: not ansible_check_mode

- name: Restart hostapd
  ansible.builtin.systemd:
    name: hostapd
    state: restarted

- name: Restart dnsmasq
  ansible.builtin.systemd:
    name: dnsmasq
    state: restarted
```

- [ ] **Step 6: Deployen und verifizieren**

Run: Syntax-Befehl, dann Deploy-Befehl
Expected: PASS inkl. `Read AP interface address`.

- [ ] **Step 7: Reboot-Test (Review Focus 1)**

```bash
ssh pi@raspi-01 'sudo reboot'; sleep 90
```
Run: Verify-Befehl
Expected: PASS. Zusätzlich `ssh pi@raspi-01 'nmcli -t -f DEVICE,STATE device | grep ap0'` → `ap0:unmanaged`.

- [ ] **Step 8: Commit**

```bash
git add ansible/roles/wifi_repeater/
git commit -m "persist wifi repeater ap interface via systemd unit"
```

---

### Task 3: Firewall-Regeln persistent, Docker-verträglich

**Files:**
- Create: `ansible/roles/wifi_repeater/templates/wifi-repeater-firewall.sh.j2`
- Create: `ansible/roles/wifi_repeater/templates/wifi-repeater-firewall.service.j2`
- Modify: `ansible/roles/wifi_repeater/tasks/06-firewall.yml` (komplett ersetzen)
- Modify: `ansible/roles/wifi_repeater/tasks/09-verify.yml`

**Interfaces:**
- Consumes: `wifi_repeater_subnet` (Task 2), Handler `Reload systemd`, `Restart wifi-repeater-firewall`.
- Produces: `/usr/local/sbin/wifi-repeater-firewall` (idempotent, Exit 0 = alle Regeln vorhanden), wird vom Watchdog (Task 6) aufgerufen.

- [ ] **Step 1: Verify erweitern**

In beiden Loop-Tasks die Liste ersetzen durch:

```yaml
  loop:
    - wifi-repeater-iface.service
    - wifi-repeater-firewall.service
    - hostapd.service
    - dnsmasq.service
```

Anhängen:

```yaml
- name: Check IPv4 forwarding is enabled
  ansible.builtin.command: sysctl -n net.ipv4.ip_forward
  register: wifi_repeater_verify_forward
  changed_when: false
  failed_when: wifi_repeater_verify_forward.stdout != '1'
  tags: [wifi, wifi-repeater, wifi-verify]

- name: Check NAT and forwarding rules
  ansible.builtin.command: "iptables -t {{ item.table }} -C {{ item.rule }}"
  loop:
    - table: nat
      rule: "POSTROUTING -s {{ wifi_repeater_subnet }} -o {{ wifi_interface_uplink }} -j MASQUERADE"
    - table: filter
      rule: "FORWARD -i {{ wifi_interface_repeater }} -o {{ wifi_interface_uplink }} -s {{ wifi_repeater_subnet }} -j ACCEPT"
    - table: filter
      rule: "FORWARD -i {{ wifi_interface_uplink }} -o {{ wifi_interface_repeater }} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
  loop_control:
    label: "{{ item.table }}: {{ item.rule }}"
  changed_when: false
  tags: [wifi, wifi-repeater, wifi-verify]
```

- [ ] **Step 2: Verify laufen lassen, Fehlschlag bestätigen**

Run: Verify-Befehl
Expected: FAIL bei `wifi-repeater-firewall.service` (Unit fehlt).

- [ ] **Step 3: Skript und Unit**

`templates/wifi-repeater-firewall.sh.j2`:

```bash
#!/bin/bash
# Managed by Ansible (wifi_repeater role)
# Idempotently installs NAT/forwarding rules for repeater clients.
# Only touches its own rules, so Docker's chains stay intact. Rules go to
# the top of FORWARD so Docker's DROP policy does not affect them.
set -u

UPLINK="{{ wifi_interface_uplink }}"
AP="{{ wifi_interface_repeater }}"
SUBNET="{{ wifi_repeater_subnet }}"
rc=0

ensure() {
    local table="$1"
    shift
    iptables -t "$table" -C "$@" 2>/dev/null || iptables -t "$table" -I "$@" || rc=1
}

ensure nat POSTROUTING -s "$SUBNET" -o "$UPLINK" -j MASQUERADE
ensure filter FORWARD -i "$UPLINK" -o "$AP" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ensure filter FORWARD -i "$AP" -o "$UPLINK" -s "$SUBNET" -j ACCEPT

exit "$rc"
```

`templates/wifi-repeater-firewall.service.j2`:

```ini
# Managed by Ansible (wifi_repeater role)
[Unit]
Description=WiFi repeater NAT and forwarding rules
After=network.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/wifi-repeater-firewall

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: `06-firewall.yml` ersetzen**

```yaml
---
- name: Deploy repeater firewall script
  ansible.builtin.template:
    src: wifi-repeater-firewall.sh.j2
    dest: /usr/local/sbin/wifi-repeater-firewall
    owner: root
    group: root
    mode: "0755"
  notify: Restart wifi-repeater-firewall
  tags: [wifi, wifi-repeater, firewall]

- name: Deploy repeater firewall unit
  ansible.builtin.template:
    src: wifi-repeater-firewall.service.j2
    dest: /etc/systemd/system/wifi-repeater-firewall.service
    owner: root
    group: root
    mode: "0644"
  notify:
    - Reload systemd
    - Restart wifi-repeater-firewall
  tags: [wifi, wifi-repeater, firewall]

- name: Enable and start repeater firewall unit
  ansible.builtin.systemd:
    name: wifi-repeater-firewall
    enabled: true
    state: started
    daemon_reload: true
  tags: [wifi, wifi-repeater, firewall]
  when: not ansible_check_mode
```

- [ ] **Step 5: Deployen und verifizieren**

Run: Deploy-Befehl
Expected: PASS. Die alten, per `-A` gesetzten Regeln ohne `-s` existieren bis zum nächsten Reboot parallel, das ist harmlos.

- [ ] **Step 6: Docker-Restart-Test (Review Focus 4)**

```bash
ssh pi@raspi-01 'sudo systemctl restart docker'
```
Run: Verify-Befehl
Expected: PASS. Zusätzlich mit einem Handy im Repeater-WLAN eine Webseite öffnen.

- [ ] **Step 7: Commit**

```bash
git add ansible/roles/wifi_repeater/
git commit -m "persist wifi repeater firewall rules without touching docker"
```

---

### Task 4: hostapd/dnsmasq automatisch neu starten, Startreihenfolge

**Files:**
- Create: `ansible/roles/wifi_repeater/templates/hostapd-override.conf.j2`
- Create: `ansible/roles/wifi_repeater/templates/dnsmasq-override.conf.j2`
- Modify: `ansible/roles/wifi_repeater/tasks/07-services.yml` (zwei Tasks vorne einfügen)
- Modify: `ansible/roles/wifi_repeater/tasks/09-verify.yml`

**Interfaces:**
- Consumes: `wifi-repeater-iface.service` (Task 2).
- Produces: Drop-ins `/etc/systemd/system/{hostapd,dnsmasq}.service.d/wifi-repeater.conf`. Task 5 erweitert `hostapd-override.conf.j2`.

- [ ] **Step 1: Verify erweitern** (anhängen)

```yaml
- name: Check restart policy of repeater services
  ansible.builtin.command: "systemctl show {{ item }} --property=Restart --value"
  loop: [hostapd.service, dnsmasq.service]
  register: wifi_repeater_verify_restart
  changed_when: false
  failed_when: wifi_repeater_verify_restart.stdout != 'always'
  tags: [wifi, wifi-repeater, wifi-verify]

- name: Check dnsmasq starts after hostapd
  ansible.builtin.command: systemctl show dnsmasq.service --property=After --value
  register: wifi_repeater_verify_order
  changed_when: false
  failed_when: "'hostapd.service' not in wifi_repeater_verify_order.stdout"
  tags: [wifi, wifi-repeater, wifi-verify]
```

- [ ] **Step 2: Verify laufen lassen, Fehlschlag bestätigen**

Run: Verify-Befehl
Expected: FAIL bei `Check restart policy` (Debian-Default ist `on-failure` bzw. `no`).

- [ ] **Step 3: Drop-in-Templates**

`templates/hostapd-override.conf.j2`:

```ini
# Managed by Ansible (wifi_repeater role)
[Unit]
Requires=wifi-repeater-iface.service
After=wifi-repeater-iface.service
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Restart=always
RestartSec=5
```

`templates/dnsmasq-override.conf.j2`:

```ini
# Managed by Ansible (wifi_repeater role)
[Unit]
Wants=wifi-repeater-iface.service
After=wifi-repeater-iface.service hostapd.service
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Restart=always
RestartSec=5
```

- [ ] **Step 4: Tasks am Anfang von `07-services.yml` einfügen** (direkt nach `---`)

```yaml
- name: Create systemd drop-in directories for repeater services
  ansible.builtin.file:
    path: "/etc/systemd/system/{{ item }}.service.d"
    state: directory
    owner: root
    group: root
    mode: "0755"
  loop: [hostapd, dnsmasq]
  tags: [wifi, wifi-repeater, service]

- name: Deploy systemd drop-ins for repeater services
  ansible.builtin.template:
    src: "{{ item }}-override.conf.j2"
    dest: "/etc/systemd/system/{{ item }}.service.d/wifi-repeater.conf"
    owner: root
    group: root
    mode: "0644"
  loop: [hostapd, dnsmasq]
  notify:
    - Reload systemd
    - Restart hostapd
    - Restart dnsmasq
  tags: [wifi, wifi-repeater, service]
```

- [ ] **Step 5: Deployen und verifizieren**

Run: Deploy-Befehl
Expected: PASS.

- [ ] **Step 6: Crash-Test (Review Focus 2)**

```bash
ssh pi@raspi-01 'sudo pkill -9 hostapd; sleep 8; systemctl is-active hostapd'
```
Expected: `active`. Das SSID ist am Handy nach wenigen Sekunden wieder sichtbar.

- [ ] **Step 7: Commit**

```bash
git add ansible/roles/wifi_repeater/
git commit -m "restart wifi repeater services automatically"
```

---

### Task 5: hostapd-Kanal an den Uplink koppeln

hostapd startet künftig mit `/run/wifi-repeater/hostapd.conf`, die bei jedem Start aus `/etc/hostapd/hostapd.conf` erzeugt wird und dabei den Live-Kanal von `wlan0` übernimmt. `ExecStart` wird im Drop-in selbst gesetzt. Damit hängt der Start nicht mehr von `/etc/default/hostapd` ab (das laut `ansible.log` auf dem Pi gar nicht existierte).

**Files:**
- Create: `ansible/roles/wifi_repeater/templates/wifi-repeater-hostapd-conf.sh.j2`
- Modify: `ansible/roles/wifi_repeater/templates/hostapd-override.conf.j2` (komplett ersetzen)
- Modify: `ansible/roles/wifi_repeater/tasks/03-hostapd-config.yml` (komplett ersetzen)
- Modify: `ansible/roles/wifi_repeater/tasks/09-verify.yml`

**Interfaces:**
- Consumes: `wifi_repeater_channel_follow_uplink` (Task 2), Drop-in aus Task 4.
- Produces: `/usr/local/sbin/wifi-repeater-hostapd-conf`, Laufzeit-Config `/run/wifi-repeater/hostapd.conf`.

- [ ] **Step 1: Verify erweitern** (anhängen)

```yaml
- name: Read uplink and AP channels
  ansible.builtin.shell: |
    iw dev {{ wifi_interface_uplink }} info | awk '/channel/ && !c {print $2; c=1}'
    iw dev {{ wifi_interface_repeater }} info | awk '/channel/ && !c {print $2; c=1}'
  register: wifi_repeater_verify_channels
  changed_when: false
  when:
    - wifi_repeater_channel_follow_uplink | bool
    - wifi_virtual_ap_enabled | default(false) | bool
  tags: [wifi, wifi-repeater, wifi-verify]

- name: Check AP uses the uplink channel
  ansible.builtin.assert:
    that:
      - wifi_repeater_verify_channels.stdout_lines | length == 2
      - wifi_repeater_verify_channels.stdout_lines | unique | length == 1
    fail_msg: "Channel mismatch (uplink, ap): {{ wifi_repeater_verify_channels.stdout_lines }}"
    quiet: true
  when:
    - wifi_repeater_channel_follow_uplink | bool
    - wifi_virtual_ap_enabled | default(false) | bool
  tags: [wifi, wifi-repeater, wifi-verify]

- name: Check hostapd runs from the runtime config
  ansible.builtin.command: systemctl show hostapd.service --property=ExecStart --value
  register: wifi_repeater_verify_execstart
  changed_when: false
  failed_when: "'/run/wifi-repeater/hostapd.conf' not in wifi_repeater_verify_execstart.stdout"
  tags: [wifi, wifi-repeater, wifi-verify]
```

- [ ] **Step 2: Verify laufen lassen, Fehlschlag bestätigen**

Run: Verify-Befehl
Expected: FAIL bei `Check hostapd runs from the runtime config`. Steht der Router zufällig nicht auf Kanal 6, schlägt schon `Check AP uses the uplink channel` fehl.

- [ ] **Step 3: Render-Skript**

`templates/wifi-repeater-hostapd-conf.sh.j2`:

```bash
#!/bin/bash
# Managed by Ansible (wifi_repeater role)
# Renders the runtime hostapd config. On single-radio setups the AP has to
# use the uplink's channel, so the channel is taken from the live uplink.
set -u

SRC=/etc/hostapd/hostapd.conf
DST=/run/wifi-repeater/hostapd.conf
UPLINK="{{ wifi_interface_uplink }}"

install -d -m 0700 "$(dirname "$DST")"
install -m 0600 "$SRC" "$DST" || exit 1

{% if wifi_repeater_channel_follow_uplink | bool %}
CHANNEL=$(iw dev "$UPLINK" info 2>/dev/null | awk '/channel/ && !c {print $2; c=1}')
if [ -n "$CHANNEL" ]; then
    if [ "$CHANNEL" -gt 14 ]; then HW_MODE=a; else HW_MODE=g; fi
    sed -i -e "s/^channel=.*/channel=$CHANNEL/" -e "s/^hw_mode=.*/hw_mode=$HW_MODE/" "$DST"
    echo "using uplink channel $CHANNEL (hw_mode=$HW_MODE)"
else
    echo "uplink $UPLINK not associated, using configured channel"
fi
{% endif %}
```

- [ ] **Step 4: Drop-in ersetzen** (`templates/hostapd-override.conf.j2`, komplett; `Type`/`PIDFile` gemäß Task-0-Ausgabe)

```ini
# Managed by Ansible (wifi_repeater role)
[Unit]
Requires=wifi-repeater-iface.service
After=wifi-repeater-iface.service
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=forking
PIDFile=/run/hostapd.pid
ExecStartPre=/usr/local/sbin/wifi-repeater-hostapd-conf
ExecStart=
ExecStart=/usr/sbin/hostapd -B -P /run/hostapd.pid /run/wifi-repeater/hostapd.conf
Restart=always
RestartSec=5
```

- [ ] **Step 5: `03-hostapd-config.yml` ersetzen** (der `/etc/default/hostapd`-Task entfällt)

```yaml
---
- name: Create hostapd configuration
  ansible.builtin.template:
    src: hostapd.conf.j2
    dest: /etc/hostapd/hostapd.conf
    owner: root
    group: root
    mode: "0600"
  notify: Restart hostapd
  tags: [wifi, wifi-repeater, config]

- name: Deploy hostapd runtime config renderer
  ansible.builtin.template:
    src: wifi-repeater-hostapd-conf.sh.j2
    dest: /usr/local/sbin/wifi-repeater-hostapd-conf
    owner: root
    group: root
    mode: "0755"
  notify: Restart hostapd
  tags: [wifi, wifi-repeater, config]
```

- [ ] **Step 6: Deployen und verifizieren**

Run: Deploy-Befehl
Expected: PASS. `ssh pi@raspi-01 'journalctl -u hostapd -n 5 --no-pager'` zeigt `using uplink channel N`.

- [ ] **Step 7: Kanalwechsel-Test (Review Focus 3)**

Im Router-Webinterface den 2,4-GHz-Kanal ändern (z. B. 6 → 11), 1 Minute warten:

```bash
ssh pi@raspi-01 'sudo systemctl restart hostapd; iw dev wlan0 info | grep channel; iw dev ap0 info | grep channel'
```
Expected: beide Zeilen zeigen denselben Kanal. Der automatische Neustart bei Kanalwechsel kommt in Task 6.

- [ ] **Step 8: Commit**

```bash
git add ansible/roles/wifi_repeater/
git commit -m "follow uplink channel in hostapd"
```

---

### Task 6: Selbstheilender Watchdog (systemd-Timer)

**Files:**
- Create: `ansible/roles/wifi_repeater/templates/wifi-repeater-watchdog.sh.j2`
- Create: `ansible/roles/wifi_repeater/templates/wifi-repeater-watchdog.service.j2`
- Create: `ansible/roles/wifi_repeater/templates/wifi-repeater-watchdog.timer.j2`
- Create: `ansible/roles/wifi_repeater/tasks/08-monitoring.yml`
- Modify: `ansible/roles/wifi_repeater/templates/hostapd.conf.j2` (`ctrl_interface` ergänzen)
- Modify: `ansible/roles/wifi_repeater/tasks/main.yml` (Import ergänzen)
- Modify: `ansible/roles/wifi_repeater/tasks/09-verify.yml`

**Interfaces:**
- Consumes: `/usr/local/sbin/wifi-repeater-firewall` (Task 3), `wifi-repeater-iface.service` (Task 2), `wifi_repeater_watchdog_interval`, `wifi_repeater_channel_follow_uplink` (Task 2).

- [ ] **Step 1: Verify erweitern**

In beiden Loop-Tasks die Liste ersetzen durch:

```yaml
  loop:
    - wifi-repeater-iface.service
    - wifi-repeater-firewall.service
    - hostapd.service
    - dnsmasq.service
    - wifi-repeater-watchdog.timer
```

Anhängen:

```yaml
- name: Check hostapd control interface answers
  ansible.builtin.command: "hostapd_cli -i {{ wifi_interface_repeater }} ping"
  register: wifi_repeater_verify_ping
  changed_when: false
  failed_when: "'PONG' not in wifi_repeater_verify_ping.stdout"
  tags: [wifi, wifi-repeater, wifi-verify]

- name: Run watchdog once
  ansible.builtin.command: systemctl start wifi-repeater-watchdog.service
  changed_when: false
  tags: [wifi, wifi-repeater, wifi-verify]

- name: Check watchdog finished successfully
  ansible.builtin.command: systemctl show wifi-repeater-watchdog.service --property=Result --value
  register: wifi_repeater_verify_watchdog
  changed_when: false
  failed_when: wifi_repeater_verify_watchdog.stdout != 'success'
  tags: [wifi, wifi-repeater, wifi-verify]
```

- [ ] **Step 2: Verify laufen lassen, Fehlschlag bestätigen**

Run: Verify-Befehl
Expected: FAIL bei `wifi-repeater-watchdog.timer` (fehlt). Danach würde auch der `hostapd_cli`-Ping fehlschlagen (kein `ctrl_interface`).

- [ ] **Step 3: `ctrl_interface` in `templates/hostapd.conf.j2`** (direkt nach `driver=nl80211` einfügen)

```ini
ctrl_interface=/run/hostapd
ctrl_interface_group=0
```

- [ ] **Step 4: Watchdog-Skript, Service, Timer**

`templates/wifi-repeater-watchdog.sh.j2`:

```bash
#!/bin/bash
# Managed by Ansible (wifi_repeater role)
# Periodic self-healing for the WiFi repeater. Silent when healthy;
# repairs are logged to the journal: journalctl -u wifi-repeater-watchdog
set -u

UPLINK="{{ wifi_interface_uplink }}"
AP="{{ wifi_interface_repeater }}"
AP_IP="{{ repeater_ip }}"

restart() {
    echo "restarting $1: $2"
    systemctl reset-failed "$1" 2>/dev/null
    systemctl restart "$1"
}

channel_of() {
    iw dev "$1" info 2>/dev/null | awk '/channel/ && !c {print $2; c=1}'
}

# Interface gone or address lost. Restarting the unit also restarts
# hostapd through its Requires= dependency.
if ! ip -4 addr show dev "$AP" 2>/dev/null | grep -q "inet $AP_IP/"; then
    restart wifi-repeater-iface.service "$AP missing or without $AP_IP"
fi

if ! systemctl is-active --quiet hostapd.service; then
    restart hostapd.service "not active"
elif ! timeout 5 hostapd_cli -i "$AP" ping 2>/dev/null | grep -q PONG; then
    restart hostapd.service "control interface not answering"
fi

{% if wifi_repeater_channel_follow_uplink | bool %}
uplink_channel=$(channel_of "$UPLINK")
ap_channel=$(channel_of "$AP")
if [ -n "$uplink_channel" ] && [ -n "$ap_channel" ] && [ "$uplink_channel" != "$ap_channel" ]; then
    restart hostapd.service "channel mismatch (uplink $uplink_channel, ap $ap_channel)"
fi
{% endif %}

if ! systemctl is-active --quiet dnsmasq.service; then
    restart dnsmasq.service "not active"
elif ! ss -Hulpn 'sport = :67' 2>/dev/null | grep -q dnsmasq; then
    restart dnsmasq.service "not serving DHCP"
fi

/usr/local/sbin/wifi-repeater-firewall || echo "could not apply firewall rules"

exit 0
```

`templates/wifi-repeater-watchdog.service.j2`:

```ini
# Managed by Ansible (wifi_repeater role)
[Unit]
Description=WiFi repeater health check
After=wifi-repeater-iface.service hostapd.service dnsmasq.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wifi-repeater-watchdog
```

`templates/wifi-repeater-watchdog.timer.j2`:

```ini
# Managed by Ansible (wifi_repeater role)
[Unit]
Description=Run WiFi repeater health check periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec={{ wifi_repeater_watchdog_interval }}

[Install]
WantedBy=timers.target
```

- [ ] **Step 5: `tasks/08-monitoring.yml`**

```yaml
---
- name: Deploy repeater watchdog script
  ansible.builtin.template:
    src: wifi-repeater-watchdog.sh.j2
    dest: /usr/local/sbin/wifi-repeater-watchdog
    owner: root
    group: root
    mode: "0755"
  tags: [wifi, wifi-repeater, monitoring]

- name: Deploy repeater watchdog units
  ansible.builtin.template:
    src: "wifi-repeater-watchdog.{{ item }}.j2"
    dest: "/etc/systemd/system/wifi-repeater-watchdog.{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop: [service, timer]
  notify: Reload systemd
  tags: [wifi, wifi-repeater, monitoring]

- name: Enable and start repeater watchdog timer
  ansible.builtin.systemd:
    name: wifi-repeater-watchdog.timer
    enabled: true
    state: started
    daemon_reload: true
  tags: [wifi, wifi-repeater, monitoring]
  when: not ansible_check_mode
```

In `main.yml` nach dem Import von `07-services.yml` einfügen:

```yaml
- name: Import monitoring tasks
  ansible.builtin.import_tasks: 08-monitoring.yml
```

- [ ] **Step 6: Deployen und verifizieren**

Run: Deploy-Befehl
Expected: PASS.

- [ ] **Step 7: Selbstheilungs-Test (Review Focus 3)**

```bash
ssh pi@raspi-01 'sudo systemctl stop dnsmasq; sudo ip addr flush dev ap0; sudo systemctl start wifi-repeater-watchdog; journalctl -u wifi-repeater-watchdog -n 10 --no-pager'
```
Expected: Log-Zeilen `restarting wifi-repeater-iface.service …` und `restarting dnsmasq.service: not active`. Danach ist der Verify-Befehl PASS. Kanalwechsel aus Task 5 Step 7 wiederholen, **ohne** hostapd manuell neu zu starten: nach ≤2 min meldet das Journal `channel mismatch`, danach sind die Kanäle wieder gleich.

- [ ] **Step 8: Commit**

```bash
git add ansible/roles/wifi_repeater/
git commit -m "add self-healing watchdog for wifi repeater"
```

---

### Task 7: hostapd-Tuning und dnsmasq bereinigen

`address=/#/{{ repeater_ip }}` in dnsmasq beantwortet **jede** DNS-Anfrage mit der Pi-IP (Captive-Portal-Verhalten). Das fällt heute nur nicht auf, weil die Clients per DHCP 8.8.8.8 bekommen. Die Zeile fliegt raus, die DNS-Server werden konfigurierbar.

**Files:**
- Modify: `ansible/roles/wifi_repeater/templates/hostapd.conf.j2` (komplett ersetzen)
- Modify: `ansible/roles/wifi_repeater/templates/dnsmasq.conf.j2` (komplett ersetzen)
- Modify: `ansible/roles/wifi_repeater/tasks/09-verify.yml`

**Interfaces:**
- Consumes: `wifi_repeater_dtim_period`, `wifi_repeater_beacon_int`, `wifi_repeater_ap_max_inactivity`, `wifi_repeater_dns_servers` (Task 2).

- [ ] **Step 1: Verify erweitern** (anhängen)

```yaml
- name: Read active hostapd tuning
  ansible.builtin.command: grep -E '^(dtim_period|ap_max_inactivity)=' /run/wifi-repeater/hostapd.conf
  register: wifi_repeater_verify_tuning
  changed_when: false
  failed_when: >-
    ('dtim_period=' ~ wifi_repeater_dtim_period) not in wifi_repeater_verify_tuning.stdout or
    ('ap_max_inactivity=' ~ wifi_repeater_ap_max_inactivity) not in wifi_repeater_verify_tuning.stdout
  tags: [wifi, wifi-repeater, wifi-verify]

- name: Check dnsmasq does not hijack DNS
  ansible.builtin.command: grep -c '^address=/#/' /etc/dnsmasq.d/wifi-repeater.conf
  register: wifi_repeater_verify_hijack
  changed_when: false
  failed_when: wifi_repeater_verify_hijack.stdout != '0'
  tags: [wifi, wifi-repeater, wifi-verify]
```

- [ ] **Step 2: Verify laufen lassen, Fehlschlag bestätigen**

Run: Verify-Befehl
Expected: FAIL bei `Read active hostapd tuning` (`dtim_period=2`, kein `ap_max_inactivity`).

- [ ] **Step 3: `templates/hostapd.conf.j2` ersetzen**

```ini
# hostapd configuration for WiFi repeater
# Generated by Ansible. hostapd reads a runtime copy with the live uplink
# channel: /run/wifi-repeater/hostapd.conf (see wifi-repeater-hostapd-conf)

interface={{ wifi_interface_repeater }}
driver=nl80211
ctrl_interface=/run/hostapd
ctrl_interface_group=0

# WiFi Network Settings
ssid={{ wifi_repeater_ssid }}
country_code={{ wifi_country }}
ieee80211d=1
hw_mode=g
channel={{ wifi_channel }}
ieee80211n=1
wmm_enabled=1
max_num_sta=10

# WPA2 Security
wpa=2
wpa_passphrase={{ wifi_repeater_password }}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP

# Client stability
beacon_int={{ wifi_repeater_beacon_int }}
dtim_period={{ wifi_repeater_dtim_period }}
ap_max_inactivity={{ wifi_repeater_ap_max_inactivity }}
disassoc_low_ack=0
rts_threshold=2347
fragm_threshold=2346
```

- [ ] **Step 4: `templates/dnsmasq.conf.j2` ersetzen**

```ini
# dnsmasq configuration for WiFi repeater DHCP/DNS
# Generated by Ansible

# Interface configuration
interface={{ wifi_interface_repeater }}
bind-dynamic
listen-address={{ repeater_ip }}
no-dhcp-interface={{ wifi_interface_uplink }}

# DHCP Configuration
dhcp-range={{ repeater_dhcp_start }},{{ repeater_dhcp_end }},12h
dhcp-option=option:router,{{ repeater_ip }}
dhcp-option=option:dns-server,{{ wifi_repeater_dns_servers | join(',') }}

# Logging
# Keep logging in journald/syslog defaults for compatibility.
```

- [ ] **Step 5: Deployen und verifizieren**

Run: Deploy-Befehl
Expected: PASS. Handy neu verbinden, Webseite öffnen.

- [ ] **Step 6: Idempotenz-Test (Review Focus 5)**

Run: Deploy-Befehl ein zweites Mal
Expected: Im `PLAY RECAP` für `raspi-01` steht `changed=0`, in der Ausgabe taucht kein Handler `Restart hostapd` auf. Meldet ein Task `changed`, ist er nicht idempotent und muss korrigiert werden, bevor committet wird.

- [ ] **Step 7: Commit**

```bash
git add ansible/roles/wifi_repeater/
git commit -m "tune hostapd and stop dns hijacking in dnsmasq"
```

---

### Task 8: Dokumentation, Roadmap, End-to-End-Abnahme

**Files:**
- Modify: `docs/WIFI_REPEATER.MD` (neuer Abschnitt `## Operations` am Ende)
- Modify: `ansible/roles/wifi_repeater/tasks/main.yml` (Debug-Hinweise)
- Modify: `ROADMAP.md`
- Modify: `docs/wifi-repeater/wifi_repeater_analysis.md`, `wifi_repeater_implementation.md`, `wifi_repeater_quick_fix.md` (Status-Hinweis oben)

- [ ] **Step 1: `docs/WIFI_REPEATER.MD` – Abschnitt anhängen**

````markdown
## Operations

### Boot sequence

1. `wifi-repeater-iface.service` creates `ap0` on `wlan0`, sets `192.168.2.1/24`, disables uplink power save.
2. `hostapd.service` renders `/run/wifi-repeater/hostapd.conf` with the uplink's current channel, then starts the AP.
3. `dnsmasq.service` serves DHCP on `ap0`.
4. `wifi-repeater-firewall.service` adds NAT/forwarding rules (only its own, Docker's rules are untouched).
5. `wifi-repeater-watchdog.timer` checks every 2 minutes and repairs.

The AP shares the radio with the uplink and must use the same channel. If the router changes channel, the watchdog restarts hostapd on the new one (short client drop). An uplink on a 5 GHz DFS channel cannot host an AP.

### Debugging

```bash
systemctl status wifi-repeater-iface hostapd dnsmasq wifi-repeater-firewall
journalctl -u wifi-repeater-watchdog --since today      # repairs done by the watchdog
journalctl -u hostapd -u dnsmasq -n 50
sudo hostapd_cli -i ap0 status
sudo hostapd_cli -i ap0 list_sta                        # connected clients
iw dev wlan0 info | grep channel; iw dev ap0 info | grep channel
sudo iptables -t nat -S POSTROUTING; sudo iptables -S FORWARD
```

### Verify from the control machine

```bash
cd ansible && ansible-playbook site.yml -l raspi-01 --tags wifi-verify --skip-tags common
```
````

- [ ] **Step 2: Debug-Hinweise in `main.yml`** – im Task `Display WiFi repeater configuration` den `Verify with:`-Block ersetzen durch:

```yaml
      Verify with:
        sudo systemctl status wifi-repeater-iface hostapd dnsmasq
        sudo hostapd_cli -i {{ wifi_interface_repeater }} status
        journalctl -u wifi-repeater-watchdog --since today
```

- [ ] **Step 3: Status-Hinweis in die drei Analyse-Dokumente** (jeweils als erste Zeile nach der H1)

```markdown
> **Status (2026-10-05):** Implemented with deviations, see `docs/superpowers/plans/2026-10-05-wifi-repeater-hardening.md` (section "Abweichungen von den Analysen").
```

- [ ] **Step 4: `ROADMAP.md`** – unter `Wifi-Repeater` die Punkte `Refactor Ansible Role` und `Harden Stability` auf `[x]` setzen, unter `Update Documentation` den Punkt `WIFI_REPEATER.md` auf `[x]`.

- [ ] **Step 5: End-to-End-Abnahme (alle Review-Focus-Punkte am Stück)**

```bash
ssh pi@raspi-01 'sudo reboot'; sleep 120
(cd ansible && ansible-playbook site.yml -l raspi-01 --tags wifi-verify --skip-tags common)   # PASS
ssh pi@raspi-01 'sudo pkill -9 hostapd; sleep 8; systemctl is-active hostapd'                   # active
ssh pi@raspi-01 'sudo systemctl restart docker'
(cd ansible && ansible-playbook site.yml -l raspi-01 --tags wifi-verify --skip-tags common)   # PASS
```
Danach 24 h laufen lassen und prüfen: `ssh pi@raspi-01 'journalctl -u wifi-repeater-watchdog --since -24h --no-pager'`. Zeigt das Journal wiederholt dieselbe Reparatur, ist das der nächste Ansatzpunkt.

- [ ] **Step 6: Commit**

```bash
git add docs/ ROADMAP.md ansible/roles/wifi_repeater/tasks/main.yml
git commit -m "document wifi repeater operations and update roadmap"
```

---

## Nach diesem Plan (bewusst nicht enthalten)

- **Netzwerk-Rolle bereinigen:** `roles/network` installiert `ifupdown` + `isc-dhcp-client` und schreibt `/etc/network/interfaces.d/wlan0`, obwohl NetworkManager läuft. Zwei DHCP-Clients auf `wlan0` können IP-Wechsel und damit Abbrüche verursachen. Entscheidung je nach Task-0-Ergebnis, eigener Plan.
- **Harden Security (ROADMAP):** WPA3/PMF (`ieee80211w`), Client-Isolation, Zugriff von Repeater-Clients auf Pi-Dienste (SSH, Docker-Ports) beschränken, `password_authentication: "yes"` in `group_vars`.
- **Paperless-Rolle:** `ansible.log` zeigt, dass `community.docker.docker_compose` entfernt wurde → Migration auf `docker_compose_v2`.
