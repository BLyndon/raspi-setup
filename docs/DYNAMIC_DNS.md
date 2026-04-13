# Dynamic DNS with DuckDNS

If your ISP assigns a dynamic public IP (it changes periodically), external clients
can no longer reach your Pi using a fixed address. Dynamic DNS (DDNS) solves this by
mapping a stable hostname to your current public IP automatically.

This guide uses [DuckDNS](https://www.duckdns.org) — a free DDNS service with
simple API and good community support.

## How it works

1. You register a free subdomain on DuckDNS, for example `mypi.duckdns.org`.
2. A cron job or systemd timer on the Pi regularly calls the DuckDNS API with your
   current public IP.
3. DuckDNS updates the DNS record.
4. WireGuard clients point their `Endpoint` at `mypi.duckdns.org:51820` instead of
   a raw IP.

---

## 1) Register a DuckDNS domain

1. Go to [https://www.duckdns.org](https://www.duckdns.org) and sign in with GitHub,
   Google, or similar.
2. Create a subdomain, for example `mypi`.
3. Copy your **token** from the top of the page (keep this secret).

---

## 2) Set up the IP updater on the Pi

SSH into the Pi and run:

```bash
mkdir -p ~/duckdns

cat > ~/duckdns/duck.sh << 'EOF'
#!/bin/bash
DOMAIN="mypi"
TOKEN="your-duckdns-token"
echo url="https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&ip=" \
  | curl -k -o ~/duckdns/duck.log -K -
EOF

chmod +x ~/duckdns/duck.sh
```

Test it immediately:

```bash
~/duckdns/duck.sh
cat ~/duckdns/duck.log   # should print: OK
```

---

## 3) Schedule automatic updates with cron

```bash
crontab -e
```

Add this line to update every 5 minutes:

```cron
*/5 * * * * ~/duckdns/duck.sh >/dev/null 2>&1
```

---

## 4) Update your WireGuard client config

On each peer device, change the `Endpoint` in the client config from the raw IP to
your DuckDNS hostname:

```ini
[Peer]
PublicKey = <server-public-key>
Endpoint = mypi.duckdns.org:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

The `PersistentKeepalive` keeps the tunnel alive and re-resolves the hostname when
the IP changes.

---

## 5) Router port forwarding

For WireGuard to be reachable from the internet, forward the WireGuard port on your
router to the Pi's LAN IP:

| Protocol | External port | Internal IP   | Internal port |
| -------- | ------------- | ------------- | ------------- |
| UDP      | 51820         | `<Pi LAN IP>` | 51820         |

To find your Pi's LAN IP:

```bash
ip -4 addr show eth0 | grep inet
```

---

## 6) Verify DNS propagation

From any external machine (or your phone on mobile data, not home WiFi):

```bash
dig mypi.duckdns.org +short
curl "https://www.duckdns.org/update?domains=mypi&token=<token>&ip="
```

---

## Troubleshooting

- DuckDNS returns `KO`: check your token and domain spelling.
- Hostname resolves to old IP: wait up to 5 minutes for the next cron run, or trigger
  `~/duckdns/duck.sh` manually.
- WireGuard cannot connect: confirm UDP/51820 is forwarded and the Pi firewall allows
  it.
- IP resolves correctly but no handshake: check that `PersistentKeepalive` is set
  on the client so it retries after an IP change.
