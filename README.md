# Raspberry Pi Setup

Infrastructure-as-Code for Raspberry Pi using Ansible for host setup and Terraform for app deployment.

## What it does

- configures a Raspberry Pi with Ansible
- optionally sets up WiFi repeater services with hostapd and dnsmasq
- installs Docker on the Pi
- keeps local machine-specific values out of Git via `ansible/group_vars/pi_nodes.local.yml`

## Prerequisites

- Raspberry Pi running Debian-based Raspberry Pi OS
- SSH access to the Pi
- Ansible installed on your control machine

## Quick start

From the project root:

```bash
cp ansible/hosts.ini.example ansible/hosts.ini
ansible-galaxy install -r ansible/requirements.yml
```

Create `ansible/group_vars/pi_nodes.local.yml` for local overrides, for example:

```yaml
hostname: "your-pi-hostname"
wifi_repeater_password: "your-secure-password"
```

Edit `ansible/hosts.ini` with your Pi address and SSH user.

## Main config files

- `ansible/group_vars/pi_nodes.yml` - shared defaults committed to Git
- `ansible/group_vars/pi_nodes.local.yml` - local overrides, gitignored
- `ansible/hosts.ini` - local inventory, gitignored
- `ansible/site.yml` - main playbook

## Deploy

Validate:

```bash
ansible-playbook ansible/site.yml -i ansible/hosts.ini --syntax-check
ansible-playbook ansible/site.yml -i ansible/hosts.ini --check
```

Apply:

```bash
ansible-playbook ansible/site.yml -i ansible/hosts.ini
```

## What Ansible manages

- common system setup
- network configuration
- WiFi repeater setup
- Docker installation

## Terraform

Terraform is optional and can be used separately for app deployment orchestration. It does not replace the Ansible host setup in this repo.

## Verify on the Pi

```bash
ssh <user>@<pi-ip>
systemctl status hostapd --no-pager
systemctl status dnsmasq --no-pager
docker --version
```

## Project layout

```text
ansible/    playbooks, inventory, roles, variables
terraform/  optional deployment orchestration
docs/       deeper design and deployment notes
```
