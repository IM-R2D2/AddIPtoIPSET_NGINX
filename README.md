# Dynamic IP → ipset & nginx allow

Scripts for servers with a **dynamic IP** that must be allowed in firewall (ipset) and/or nginx. They resolve the current IP(s) by DNS (`dig` on `DNS_RECORD`), compare with stored state, and update ipset lists and/or nginx `allow` directives when the set of IPs changes. Notifications can be sent to Telegram.

**Multiple A records:** If the DNS name returns several IPv4 addresses, all of them are used: ipset gets add/remove for each change; nginx include files get one `allow <IP>;` line per IP.

## Requirements

- Linux, bash
- **ipset** (for `add_ip_to_ipset.sh`)
- **dig** (dnsutils)
- **nginx** (for `add_ip_to_nginx.sh`)
- Optional: Telegram bot (for notifications via `send_tg.sh`)

## Quick start

1. Clone the repo and `cd` into it.
2. Copy env example and edit:
   ```bash
   cp .env_example .env
   # edit .env: DNS_RECORD, paths, TG_TOKEN/TG_CHAT_ID if using Telegram
   ```
3. Run deploy (creates dirs from `.env`, ipset sets if configured, installs scripts to `/usr/local/bin/addip-to-ipset_nginx` as root, adds root cron every 5 min):
   ```bash
   ./deploy.sh
   # if you use ipset: sudo ./deploy.sh
   ```
   - If `NGINX_IP_ALLOW_DIR` has no `*.conf` file, deploy will ask whether to create `host.conf` with an IP you enter; if you decline, deploy exits (add a `.conf` manually and run deploy again).
   - Deploy copies `common.sh`, `add_ip_to_ipset.sh`, `add_ip_to_nginx.sh`, `send_tg.sh`, and `.env`. Cron entries are added only if missing (no duplicates on re-run).
   - Root crontab gets:
     - `*/5 * * * * /usr/local/bin/addip-to-ipset_nginx/add_ip_to_ipset.sh`
     - `*/5 * * * * /usr/local/bin/addip-to-ipset_nginx/add_ip_to_nginx.sh`
   - To edit `.env` after install: `sudo nano /usr/local/bin/addip-to-ipset_nginx/.env`

## Scripts

| Script | Purpose |
|--------|--------|
| **common.sh** | Shared library (sourced by both scripts): load `.env`, `log_to`, `send_telegram`, `get_dns_ips` (all A records, valid IPv4, exclude 127.x). |
| **deploy.sh** | One-time setup: create dirs from `.env`, ensure at least one `*.conf` in `NGINX_IP_ALLOW_DIR` (or prompt to create `host.conf`), check/create ipset sets, install files to `/usr/local/bin/addip-to-ipset_nginx`, add root cron every 5 min. |
| **add_ip_to_ipset.sh** | Resolve `DNS_RECORD` → all IPs; diff with `OLD_IP_FILE` (one IP per line); remove IPs no longer in DNS from each set in `IPSET_LISTS`, add new IPs, `ipset save` to `IPSET_CONF`, update state file; notify Telegram. |
| **add_ip_to_nginx.sh** | Resolve `DNS_RECORD` → all IPs; for each `*.conf` in `NGINX_IP_ALLOW_DIR`, find lines with `NGINX_ALLOW_MARKER`, replace the allow block with one `allow <IP>;` per current IP; `nginx -t` and `systemctl reload nginx`; on error, restore backups; notify Telegram. Silent exit if nothing changed. |
| **send_tg.sh** | Sends one argument as a message to Telegram using `TG_TOKEN` and `TG_CHAT_ID` from `.env`. |

## Configuration (.env)

All behaviour is driven by `.env` (use `.env_example` as template). See comments there for each variable.

- **Common:** `DNS_RECORD`, `host`, `TGBOT` (path to `send_tg.sh`; deploy rewrites to install path). Optional: `DNS_IGNORE_IPS` — space-separated IPs to ignore from DNS (e.g. CDN/proxy); they are never added to ipset or nginx.
- **Telegram:** `TG_TOKEN`, `TG_CHAT_ID`.
- **ipset:** `IPSET_LOGFILE`, `IPSET_LISTS`, `OLD_IP_FILE`, `IPSET_CONF`.
- **nginx:** `NGINX_LOGFILE`, `NGINX_ALLOW_MARKER`, `NGINX_IP_ALLOW_DIR` (directory of include files; each file has lines like `allow IP; #SYSADMIN`).

## How it works

- **IP source:** `dig +short "$DNS_RECORD"`; all IPv4 A records are collected, validated (octets, exclude 127.x). Any IP in `DNS_IGNORE_IPS` (if set) is dropped. The result is stored in `NEW_IPS`.
- **ipset:** State file `OLD_IP_FILE` holds one IP per line (previous list). Script computes IPs to remove (in old, not in DNS) and to add (in DNS, not in old). For each set in `IPSET_LISTS`, it runs `ipset del` for removed IPs and `ipset add` for new ones, then `ipset save` and writes the new list to `OLD_IP_FILE`.
- **nginx:** For each file in `NGINX_IP_ALLOW_DIR`, script extracts IPs from lines containing `NGINX_ALLOW_MARKER`. If that set differs from `NEW_IPS`, it replaces the whole “allow … MARKER” block with one `allow <IP>; MARKER` per IP in `NEW_IPS`. Then `nginx -t`; if OK, `systemctl reload nginx`; on failure, changed files are restored from backup.

## Publishing this repo (GitHub / GitLab)

The project is a git repo. To publish as a **public** repository:

**GitHub:**
1. Create a new repository on [github.com](https://github.com/new) (do not add README or .gitignore).
2. Add the remote and push:
   ```bash
   git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPO.git
   git branch -M main
   git push -u origin main
   ```
3. In repository Settings → General → Danger Zone, visibility is Public by default for new repos.

**GitLab:**
1. Create a new project on [gitlab.com](https://gitlab.com/projects/new) (visibility: Public, empty repo).
2. Add the remote and push:
   ```bash
   git remote add origin https://gitlab.com/YOUR_USERNAME/YOUR_REPO.git
   git branch -M main
   git push -u origin main
   ```

## License

Use as you like. No warranty.
