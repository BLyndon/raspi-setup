# duckdns

Keeps `<name>.duckdns.org` pointed at the Pi's public IPv4 via a systemd timer.

## Manual steps on duckdns.org

1. Open <https://www.duckdns.org> and sign in (GitHub, Google, Reddit, ...).
2. Under **domains**, enter a subdomain (e.g. `mypi`) and click **add domain**.
3. Copy the **token** shown at the top of the page.
4. Add both to `ansible/group_vars/pi_nodes.local.yml` (gitignored):

   ```yaml
   duckdns_enabled: true
   duckdns_domains: "mypi" # without .duckdns.org, comma-separated for several
   duckdns_token: "<token>"
   ```

Nothing else is needed on the website; the IP field is filled by the Pi.

## Deploy and verify

```bash
ansible-playbook ansible/site.yml -i ansible/hosts.ini --tags duckdns
```

On duckdns.org, **current ip** and **changed** of the subdomain should update. On the Pi: `journalctl -u duckdns-update`.

## If the token leaks

Click **recreate token** on duckdns.org, update `duckdns_token` and re-run the playbook.
