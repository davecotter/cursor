# Server Health Automations

This folder provides a health-check automation for a Linux web server.

## What it checks

- Apache service status (`apache2`/`httpd`)
- SQL service status (`mysql`/`mariadb`/`mysqld`)
- HTTP connectivity for configured URLs
- Recent error-like lines in Apache and SQL logs
- Recent `journalctl` errors (if systemd is available)
- Basic diagnosis hints when issues are detected

It exits with:

- `0` when there are no FAIL checks
- `1` when one or more FAIL checks exist

## Files

- `server_health.sh` - the automation script
- `server_health.conf.example` - example config

## Setup

1. Copy config and customize:

   ```bash
   cp automations/server_health.conf.example automations/server_health.conf
   ```

2. Edit `automations/server_health.conf`:
   - Set your real health endpoint(s) in `CHECK_URLS`
   - Set `REPORT_FILE` to a writable location
   - Enable `AUTO_RESTART_SERVICES=true` only if you want auto-restart behavior

3. Make script executable:

   ```bash
   chmod +x automations/server_health.sh
   ```

## Run manually

```bash
./automations/server_health.sh ./automations/server_health.conf
```

## Schedule with cron (every 5 minutes)

Add this line to root's crontab (`sudo crontab -e`):

```cron
*/5 * * * * /path/to/repo/automations/server_health.sh /path/to/repo/automations/server_health.conf >> /var/log/server-health/cron.log 2>&1
```

## Optional systemd timer alternative

If you prefer systemd timers over cron, create a service+timer that runs:

```bash
/path/to/repo/automations/server_health.sh /path/to/repo/automations/server_health.conf
```

## Notes

- For service restarts and some logs, run as root or with appropriate permissions.
- If your services/logs use different names/paths, adjust candidates in the config.
