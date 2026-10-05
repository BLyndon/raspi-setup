# Architecture

This document describes the current project architecture.

## Scope

- Ansible provisions and configures the Raspberry Pi host.
- Terraform is optional and used separately for app deployment orchestration.
- Docker runs application containers on the Pi.

## High-Level Flow

```text
Control machine
  - Ansible
  - Terraform (optional)
        |
       SSH
        |
Raspberry Pi
  - OS and network config
  - WiFi repeater services (optional)
  - Docker engine
  - Containers
```

## Ansible Role Order

The current playbook flow is:

```text
common -> network -> wifi_repeater -> duckdns -> docker
```

Role purpose:

- common: base system tasks (packages, timezone, hostname, SSH settings)
- network: interface and network baseline for repeater mode
- wifi_repeater: hostapd, dnsmasq, forwarding, NAT when enabled
- duckdns: systemd timer pushing the public IPv4 to DuckDNS when enabled
- docker: Docker engine and Docker Compose binary installation

Reference: ansible/site.yml.

## Configuration Model

Use defaults plus local overrides:

1. ansible/group_vars/pi_nodes.yml

- Shared defaults
- Tracked in Git

1. ansible/group_vars/pi_nodes.local.yml

- Local and sensitive overrides
- Gitignored

The local override file is loaded in pre_tasks only when it exists.

## Deployment Split

- Host provisioning:
  - ansible-playbook ansible/site.yml -i ansible/hosts.ini
- App deployment orchestration (optional):
  - terraform workflow in terraform/

This keeps host lifecycle and app rollout concerns separated.

## Security Notes

- Keep secrets out of tracked defaults.
- Prefer SSH keys over password auth.
- Use local overrides for per-environment credentials.

## Verification Checklist

After deployment, verify:

- systemctl status hostapd --no-pager
- systemctl status dnsmasq --no-pager
- sysctl net.ipv4.ip_forward
- docker --version

For step-by-step deployment and troubleshooting commands, see docs/DEPLOYMENT.md.
