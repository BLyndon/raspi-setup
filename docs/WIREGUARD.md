# WireGuard Role Guide

This role configures a Raspberry Pi as a WireGuard endpoint.

It creates and manages:

- WireGuard packages
- `/etc/wireguard/wg0.conf` (or selected interface)
- Private key file `/etc/wireguard/<interface>.key`
- Service `wg-quick@<interface>`

## Variables used by this role

Set these in `ansible/group_vars/pi_nodes.yml` or `ansible/group_vars/pi_nodes.local.yml`.

Required:

- `wireguard_enabled: true`
- `wireguard_addresses` (example: `["10.8.0.1/24"]`)

Common optional values:

- `wireguard_interface` (default: `wg0`)
- `wireguard_listen_port` (default: `51820`)
- `wireguard_dns`
- `wireguard_mtu`
- `wireguard_peers`

If `wireguard_private_key` is empty, the role generates and persists one on the host.

## Connect a client to the VPN

Use this flow for phone/laptop clients.

### 1) Add the role variables

Example server-side variables:

```yaml
wireguard_enabled: true
wireguard_interface: "wg0"
wireguard_listen_port: 51820
wireguard_addresses:
  - "10.8.0.1/24"
wireguard_dns:
  - "1.1.1.1"
wireguard_enable_ip_forward: true

wireguard_peers: []
```

### 2) Generate a client keypair (on your client machine)

```bash
wg genkey | tee client1_private.key | wg pubkey > client1_public.key
```

### 3) Add the client peer to server config

Add this client entry to `wireguard_peers` in your vars file:

```yaml
wireguard_peers:
  - public_key: "<contents of client1_public.key>"
    allowed_ips: ["10.8.0.2/32"]
    persistent_keepalive: 25
```

### 4) Apply Ansible

```bash
ansible-playbook ansible/site.yml -i ansible/hosts.ini --tags wireguard
```

### 5) Get the server public key

```bash
ssh <user>@<pi-ip> "sudo wg show wg0 public-key"
```

### 6) Build client config

Create `client1.conf`:

```ini
[Interface]
PrivateKey = <contents of client1_private.key>
Address = 10.8.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = <server-public-key-from-step-5>
Endpoint = <public-ip-or-dns>:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

Notes:

- If the Pi is behind a router, forward UDP port `51820` to the Pi.
- If you only want access to the VPN subnet (not full tunnel), set `AllowedIPs = 10.8.0.0/24`.

### 7) Import and connect

- WireGuard app (iOS/Android/macOS/Windows/Linux): import `client1.conf`.
- Connect and confirm handshake.

## Verification

On the server:

```bash
sudo systemctl status wg-quick@wg0 --no-pager
sudo wg show wg0
```

You should see the client peer with a recent handshake after connecting.

## Troubleshooting

- No handshake:
  - Check router port forward UDP/51820.
  - Confirm `Endpoint` points to reachable public IP/DNS.
  - Confirm server has the client public key in `wireguard_peers`.

- Connects but no traffic:
  - Check forwarding: `sysctl net.ipv4.ip_forward` should be `1`.
  - Ensure firewall/NAT rules allow forwarding if full tunnel is intended.

- Wrong key errors:
  - Verify private/public key pairing.
  - Re-apply playbook after updating `wireguard_peers`.

## Dynamic public IP

If your home IP changes, clients lose connection. See [Dynamic DNS with DuckDNS](DYNAMIC_DNS.md) for the recommended fix.
