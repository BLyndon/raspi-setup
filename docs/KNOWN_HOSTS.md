# SSH Known Hosts Quick Guide

When `host_key_checking = True`, Ansible verifies each target host key against your
local `~/.ssh/known_hosts` file. This protects against man-in-the-middle attacks.

Use this guide when provisioning a new Pi or when a Pi was reimaged and its host key
changed.

## First-time trust (new host)

Add the host key before running Ansible:

```bash
ssh-keyscan -H <pi-ip-or-hostname> >> ~/.ssh/known_hosts
```

Optional verification (recommended): compare fingerprint out-of-band:

```bash
ssh-keygen -lf ~/.ssh/known_hosts | grep "<pi-ip-or-hostname>"
```

## Host key changed (reimage/reinstall)

If SSH/Ansible reports a host key mismatch:

```bash
ssh-keygen -R <pi-ip-or-hostname>
ssh-keyscan -H <pi-ip-or-hostname> >> ~/.ssh/known_hosts
```

Then retry your playbook.

## Batch update from inventory

If your inventory uses `ansible_host=...`, this command refreshes host keys for all
listed targets:

```bash
awk '/ansible_host=/{for(i=1;i<=NF;i++) if($i ~ /^ansible_host=/){split($i,a,"="); print a[2]}}' ansible/hosts.ini \
  | sort -u \
  | xargs -I{} sh -c 'ssh-keygen -R {} >/dev/null 2>&1; ssh-keyscan -H {} >> ~/.ssh/known_hosts'
```

## Run after refresh

```bash
ansible-playbook ansible/site.yml -i ansible/hosts.ini
```
