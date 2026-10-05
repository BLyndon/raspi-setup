# Raspberry Pi Setup

Infrastructure-as-Code for turning a Raspberry Pi into a reproducible home-lab node.

This repository uses Ansible for host setup and Terraform for optional service deployment. It is designed for small, repeatable Raspberry Pi environments where you want setup captured as code instead of manual shell history.

## What you get

- repeatable Raspberry Pi provisioning with Ansible
- optional WiFi repeater setup with `hostapd` and `dnsmasq`
- Docker installation and base system configuration
- optional Terraform-based app deployment on top of the host setup

## Modules

The playbook (`ansible/site.yml`) applies these roles in order. Each runs only when its condition is met, so a node gets just the pieces it needs.

| Module | Role | What it does | Deployed when | Tags |
| --- | --- | --- | --- | --- |
| Base system | `common` | apt updates, hostname, timezone, locale, SSH hardening, user SSH keys | always | `common` |
| Network | `network` | DHCP/static interface config and connectivity checks; prerequisite for the WiFi repeater | host is in the `wifi_repeater_nodes` group | `network`, `wifi` |
| WiFi repeater | `wifi_repeater` | `hostapd` + `dnsmasq` access point, IPv4 forwarding, NAT and firewall rules | `wifi_repeater_enabled: true` | `wifi`, `wifi-repeater` |
| Docker | `docker` | Docker Engine, CLI, containerd and Docker Compose | `docker_enabled: true` (default) | `docker`, `containers` |

Run a single module with `ansible-playbook ansible/site.yml -i ansible/hosts.ini --tags <tag>`.

## Who this is for

Use this repo if you want to bootstrap or rebuild a Pi without redoing the same machine setup by hand each time.

## Quick start

```bash
cp ansible/hosts.ini.example ansible/hosts.ini
ansible-galaxy install -r ansible/requirements.yml
```

Then add your local values in `ansible/group_vars/pi_nodes.local.yml`, update `ansible/hosts.ini`, and run the playbook.

## Documentation

The README is intentionally short. Detailed setup and design notes live in the docs:

- [Deployment guide](docs/DEPLOYMENT.md)
- [Architecture overview](docs/ARCHITECTURE.md)
- [WiFi repeater details](docs/WIFI_REPEATER.MD)

## Repository overview

```text
ansible/    host provisioning, roles, variables, inventory
terraform/  optional deployment orchestration
docs/       architecture and operational documentation
```
