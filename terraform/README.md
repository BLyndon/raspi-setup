# Terraform Notes

Minimal guide for the Terraform folder.

## Purpose

This folder manages service deployment on the Raspberry Pi.

- `variables.tf` defines configurable inputs.
- `terraform.tfvars` provides local values for those inputs.
- `main.tf` contains Terraform setup and shared locals.

Terraform handles application deployment (Ollama, Open WebUI). Ansible handles host provisioning.

## Quick commands

From this folder:

```bash
terraform init
terraform validate
terraform plan
```

Apply when ready:

```bash
terraform apply
```

## Deploy Services Separately

You can deploy only one service at a time with Terraform targets.

Deploy only Ollama:

```bash
terraform apply -target=terraform_data.ollama
```

Deploy only Open WebUI:

```bash
terraform apply -target=terraform_data.open_webui
```

Notes:

- `open_webui` depends on `ollama`, so targeting Open WebUI may also reconcile Ollama first.
- Prefer full `terraform apply` for regular operations; use `-target` for focused changes or debugging.

## Hardening Controls

The Terraform config includes basic hardening options:

- Input validation for hostnames/URLs/ports to catch bad values before apply.
- Configurable image tag for Open WebUI (`open_webui_image_tag`) to avoid implicit tag drift.
- Ollama LAN allow rule via UFW (applied when `ufw` is installed):
  - `ollama_allowed_cidr = "192.168.1.0/24"`
  - keep UFW default incoming policy as `deny` for effective restriction

Recommended production direction:

- Use a remote backend with state locking and encryption (instead of local state).
- Do not store sensitive values in `terraform.tfvars`; inject with environment variables or secret manager.
- Prefer full `terraform apply` in CI with plan review.

## Variable values

`terraform.tfvars` is loaded automatically.

For sensitive values, prefer environment variables over storing secrets in plain text:

```bash
export TF_VAR_pi_ssh_key_path="~/.ssh/id_ed25519"
terraform plan
```

## Current state

This directory is prepared for future app deployment orchestration.
Infrastructure resources are intentionally minimal right now.
