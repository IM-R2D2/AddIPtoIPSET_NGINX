# Dynamic IP → ipset & nginx allow

Scripts for servers with a **dynamic IP** that must be allowed in firewall (ipset) and/or nginx. They resolve the current IP by DNS, compare it with the stored value, and update ipset lists and/or nginx `allow` directives when it changes. Notifications can be sent to Telegram.

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
3. Run deploy (creates dirs, ipset sets if needed, **installs to `/usr/local/bin/addip-to-ipset_nginx`** for root, **adds cron to root** every 5 min):
   ```bash
   ./deploy.sh
   # if you use ipset: sudo ./deploy.sh
   ```
   Deploy copies scripts and `.env` into `/usr/local/bin/addip-to-ipset_nginx` with **owner root**. Cron runs as **root** (ipset and nginx need root). Root crontab gets:
   - `*/5 * * * * /usr/local/bin/addip-to-ipset_nginx/add_ip_to_ipset.sh`
   - `*/5 * * * * /usr/local/bin/addip-to-ipset_nginx/add_ip_to_nginx.sh`  
   To edit `.env` after install: `sudo nano /usr/local/bin/addip-to-ipset_nginx/.env`

## Scripts

| Script | Purpose |
|--------|--------|
| **deploy.sh** | One-time setup: create dirs from `.env`, check ipset and create sets, **install to `/usr/local/bin/addip-to-ipset_nginx` as root**, **add root cron every 5 min** for both scripts (ipset and nginx require root). |
| **add_ip_to_ipset.sh** | Resolve `DNS_RECORD` → IP; if IP changed, update ipset sets (remove old IP, add new), save config, notify Telegram. State: `OLD_IP_FILE`. |
| **add_ip_to_nginx.sh** | Resolve `DNS_RECORD` → IP; find lines with `NGINX_ALLOW_MARKER` (e.g. `allow 1.2.3.4; # SYSADMIN`), replace IP if changed, `nginx -t` and `systemctl reload nginx`, notify Telegram. Can work on one file or all configs in `NGINX_SITES_AVAILABLE`. |
| **send_tg.sh** | Sends one argument as a message to Telegram using `TG_TOKEN` and `TG_CHAT_ID` from `.env`. Used by the other scripts for alerts. |

## Configuration (.env)

All behaviour is driven by `.env` (no defaults in scripts). Use `.env_example` as a template.

- **Common:** `DNS_RECORD`, `host`, `TGBOT` (path to `send_tg.sh`).
- **Telegram:** `TG_TOKEN`, `TG_CHAT_ID`.
- **ipset:** `IPSET_LOGFILE`, `IPSET_LISTS`, `OLD_IP_FILE`, `IPSET_CONF`.
- **nginx:** `NGINX_LOGFILE`, `NGINX_ALLOW_MARKER`, and either `NGINX_SITES_AVAILABLE` (directory) or `nginx_conf` (single file).

See comments in `.env_example` for each variable.

## How it works

- **IP source:** `dig +short "$DNS_RECORD"`; result is validated (IPv4, not 127.x).
- **ipset:** Previous IP is read from `OLD_IP_FILE`. If current IP differs, the script removes the old IP from each set in `IPSET_LISTS`, adds the new IP, runs `ipset save` to `IPSET_CONF`, then writes the new IP to `OLD_IP_FILE`.
- **nginx:** Config(s) are searched for the line containing `NGINX_ALLOW_MARKER`; the IP in the `allow` directive is replaced. One `nginx -t` and one `systemctl reload nginx` after edits. On error, changed files are restored from backup.

## Publishing this repo (GitHub / GitLab)

The project is already a git repo with an initial commit. To publish it as a **public** repository:

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
