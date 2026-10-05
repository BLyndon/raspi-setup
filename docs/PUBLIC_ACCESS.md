# Public Access via DuckDNS and HTTPS

This page describes what is needed to reach services on the Pi from the internet over HTTPS, which tools are the first choice, and which steps stay manual.

Status: the DuckDNS updater is implemented; pieces marked *planned* do not exist yet.

## Target Picture

```text
Browser
  -> https://<name>.duckdns.org
  -> DuckDNS resolves to the current public IP
  -> Router forwards TCP 443 (and 80) to the Pi
  -> Reverse proxy on the Pi terminates TLS (Let's Encrypt)
  -> Docker container (app)
```

## Building Blocks

| Block | First choice | Managed by | Why |
| --- | --- | --- | --- |
| DNS name | DuckDNS subdomain | manual (web UI) | Free, no API to create subdomains |
| Keep IP current | systemd timer on the Pi calling the DuckDNS update URL | Ansible role `duckdns` | IP changes on reconnect; needs a recurring job, not a one-shot apply |
| Reachability | Port forwarding on the router | manual (router UI) | Router config is outside this repo |
| HTTPS + routing | Caddy as reverse proxy in Docker | Ansible / Docker Compose (planned) | Automatic Let's Encrypt certificates and renewal, minimal config |
| Host firewall | nftables / ufw allowing only 80, 443 and SSH from LAN | Ansible (roadmap: Firewall Configuration) | Exposed host needs a closed default |

Terraform is not used here: DuckDNS has no Terraform provider and its API only updates records of existing subdomains. See [ROADMAP.md](../ROADMAP.md).

## Step 0: Check the Internet Connection (manual)

Everything below depends on whether the connection has a public IPv4 address.

1. Read the WAN IPv4 in the router UI.
2. Compare it with `curl -4 ifconfig.me` from the LAN.

| Result | Meaning | Consequence |
| --- | --- | --- |
| Both match | Public IPv4 | Standard setup below works |
| Router shows `100.64.x.x`–`100.127.x.x` or no IPv4 | CGNAT / DS-Lite | IPv4 port forwarding is impossible. Use IPv6 only (update with `ipv6=`, open port in the router's IPv6 firewall for the Pi) or a tunnel (see Alternatives) |

## Step 1: DuckDNS Account and Subdomain (manual)

1. Log in at <https://www.duckdns.org> (GitHub, Google, etc.).
2. Create the subdomain, e.g. `mypi`.
3. Copy the token into `ansible/group_vars/pi_nodes.local.yml` (gitignored):

```yaml
duckdns_enabled: true
duckdns_domains: "mypi"
duckdns_token: "<token>"
```

Never commit the token.

## Step 2: Keep the IP Current (automated)

Ansible role `duckdns`, enabled with `duckdns_enabled: true`:

- `duckdns-update.timer` runs every `duckdns_interval` (default `5min`) and pushes the public IPv4
- the update URL with the token lives in `/etc/duckdns/curl.conf` (`0600`) and is passed to the unprivileged service as a systemd credential
- a rejected update (wrong domain or token) fails the unit and the playbook run; errors go to the journal
- IPv4 only; DS-Lite (IPv6-only) setups are not covered yet

```bash
ansible-playbook ansible/site.yml -i ansible/hosts.ini --tags duckdns
```

Alternative: many routers (e.g. FRITZ!Box) have a built-in DynDNS client with a custom update URL. That works as well, but lives outside this repo.

Verify:

```bash
dig +short <name>.duckdns.org
curl -4 ifconfig.me
systemctl list-timers | grep duckdns
```

## Step 3: Router Port Forwarding (manual)

- Forward TCP `443` to the Pi's LAN IP (HTTPS).
- Forward TCP `80` to the Pi only if certificates use the HTTP-01 challenge.
- Give the Pi a fixed LAN IP (DHCP reservation in the router or `network_static_ip`).
- Do **not** forward SSH (`22`). Use VPN for remote administration (roadmap: Wireguard).

## Step 4: Reverse Proxy with HTTPS (automated, planned)

First choice: **Caddy** in Docker. It obtains and renews Let's Encrypt certificates automatically.

Minimal `Caddyfile`:

```caddyfile
mypi.duckdns.org {
    reverse_proxy app:8080
}
```

Certificate challenge options:

| Challenge | Needs | When |
| --- | --- | --- |
| HTTP-01 (Caddy default) | Port 80 forwarded | Simplest; works with the stock Caddy image |
| DNS-01 via DuckDNS | Same DuckDNS token; Caddy image built with the `caddy-dns/duckdns` module | Port 80 unavailable, or wildcard certificates (`*.mypi.duckdns.org`) |

Traefik is the alternative if label-based routing for many containers is preferred; it supports DuckDNS DNS-01 out of the box.

## Step 5: Harden Before Exposing (partly manual)

- Set `password_authentication: "no"` once SSH keys work.
- Enable the host firewall (only 80/443 from anywhere, SSH from LAN only).
- Expose only services that have their own authentication.
- Keep the system updated (`common` role).

## Alternatives When Port Forwarding Is Not Possible

| Option | Notes |
| --- | --- |
| IPv6 only | Works with DS-Lite; clients without IPv6 cannot connect |
| Tailscale Funnel | HTTPS without port forwarding, uses a `*.ts.net` name instead of DuckDNS |
| Cloudflare Tunnel | Needs an own domain managed by Cloudflare; DuckDNS cannot be used |
| Small VPS + WireGuard | Public entry point on the VPS, traffic tunneled to the Pi |

## Summary: Manual vs. Automated

| Task | Manual | Automated |
| --- | --- | --- |
| Check connection type (public IPv4 / DS-Lite) | x | |
| Create DuckDNS account, subdomain, copy token | x | |
| Store token in `pi_nodes.local.yml` | x | |
| DuckDNS update timer on the Pi | | x (Ansible) |
| Router port forwarding and LAN IP reservation | x | |
| Reverse proxy and certificates | | x (Docker/Ansible, planned) |
| Host firewall and SSH hardening | | x (Ansible, roadmap) |
| Final test from outside the LAN (mobile data) | x | |
