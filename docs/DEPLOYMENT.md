# Deployment Runbook (Raspberry Pi)

This page is the operational checklist for deployment and verification.
For initial setup and configuration files, use the README.

## 1) Validate before deploy

```bash
ansible-playbook ansible/site.yml -i ansible/hosts.ini --syntax-check
ansible-playbook ansible/site.yml -i ansible/hosts.ini --check --diff
```

## 2) Deploy

```bash
ansible-playbook ansible/site.yml -i ansible/hosts.ini
```

Or via helper script:

```bash
bash scripts/deploy.sh -k -K
```

## 3) Verify on Raspberry Pi

```bash
ssh <user>@<pi-ip>
systemctl status hostapd --no-pager
systemctl status dnsmasq --no-pager
sysctl net.ipv4.ip_forward
ip a
docker --version
```

NAT check (iptables):

```bash
sudo iptables -t nat -S
sudo iptables -S
```

nftables check (if used):

```bash
sudo nft list ruleset
```

## 4) Functional test

From a client connected to Pi AP:

1. receives DHCP lease
2. can ping Pi AP IP
3. can resolve DNS
4. has internet access

## 5) Terraform (optional)

Use Terraform separately for app deployment orchestration.

```bash
cd terraform
terraform init -backend=false
terraform validate
terraform plan
terraform apply
```

## Troubleshooting quick notes

- `hostapd` fails: check chipset/AP support and channel config.
- no DHCP: check `dnsmasq` binding and DHCP range.
- no internet: check `net.ipv4.ip_forward` and NAT rules.
- intermittent WiFi: prefer two radios (upstream + AP).
