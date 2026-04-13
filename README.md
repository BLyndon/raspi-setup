# Raspberry Pi Setup

Infrastructure-as-Code for turning a Raspberry Pi into a reproducible home-lab node.

This repository uses Ansible for host setup and Terraform for optional service deployment. It is designed for small, repeatable Raspberry Pi environments where you want setup captured as code instead of manual shell history.

## What you get

- repeatable Raspberry Pi provisioning with Ansible
- optional WiFi repeater setup with `hostapd` and `dnsmasq`
- optional WireGuard VPN endpoint setup
- Docker installation and base system configuration
- optional Terraform-based app deployment on top of the host setup

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
- [WireGuard setup](docs/WIREGUARD.md)
- [Dynamic DNS with DuckDNS](docs/DYNAMIC_DNS.md)

## Repository overview

```text
ansible/    host provisioning, roles, variables, inventory
terraform/  optional deployment orchestration
docs/       architecture and operational documentation
```
