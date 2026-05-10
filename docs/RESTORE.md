# Restore

> Status: experimental. The restore flow has not yet been tested end-to-end on a fresh VPS.

## Basic flow

1. Prepare a fresh Ubuntu VPS.
2. Install Docker and Docker Compose.
3. Create `/opt/zyna`.
4. Copy and unpack a Zyna backup archive.
5. Update DNS records to the new VPS IP.
6. Update `external-ip` in `coturn/turnserver.conf` if the server IP changed.
7. Run:

```bash
cd /opt/zyna
./scripts/restore.sh /path/to/unpacked_backup_dir