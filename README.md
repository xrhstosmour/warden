# warden

Hardens a fresh Debian VPS for containers in one command, run from your own machine. Run it again any time, it only changes what drifted.

## Features

- Admin account with key login and password `sudo`, deploy account with key login only
- SSH on its own port, keys only, no root, post-quantum key exchange
- SSH open to everyone, to listed ranges, or to your tailnet only
- `nftables` firewall, only SSH, HTTP and HTTPS inbound
- Rootless Docker for the deploy account, system daemon masked, container networks from their own range, `DOCKER_ADDRESS_POOL`
- `fail2ban` with growing bans for repeat offenders
- Daily security updates and reboots in a quiet hour
- Hardened kernel and network parameters, BBR
- Encrypted time sync, capped logs, `auditd`, AppArmor, no core dumps
- A status line on every SSH login, load, disk, failed units, a pending reboot, listening ports, off with `LOGIN_STATUS=no`
- `sudo warden-audit` checks the server still matches what warden set up, read only, off with `AUDIT_TOOL=no`
- Optional, off until set in `warden.conf`: phone alerts through `ntfy`, encrypted `restic` backups, public ports for Cloudflare alone
- `/etc` kept in git with `etckeeper`, every change a commit you can read and undo, off with `ETCKEEPER=no`

## Use

```bash
git clone https://github.com/xrhstosmour/warden && cd warden
cp warden.conf.example warden.conf
./provision.sh root@<server-address>
```

It makes an SSH key pair per account, asks for the admin's `sudo` password, checks both accounts log in on the new port, and writes an SSH config next to the keys, so `ssh app-admin` and `ssh app-deploy` work. Later runs go through the admin, `./provision.sh <server-administrator-username>@<server-address> -p <server-ssh-port>`.

Run it from the same machine each time, or keep the keys it made in `~/.ssh` with you. With the public keys left empty in `warden.conf`, warden names the keys after `SERVER_HOSTNAME` or the address, and the server accepts only the keys from the latest run. A later run through the admin on another machine, or under another name, stops with a message instead of replacing the working key. Set `SERVER_HOSTNAME` or paste both public keys into `warden.conf` then.

For SSH over Tailscale only, set `SSH_ACCESS=tailscale` in `warden.conf`. With no `TAILSCALE_AUTH_KEY`, the first run prints a login URL to approve in your browser. Turn off key expiry for the server in the Tailscale admin console afterwards. If the tailnet login fails, public SSH reopens by itself after 15 minutes.

## Alerts

Off by default. `ALERTS=ntfy` in `warden.conf` pushes a full disk, a failed unit and, with `ALERT_SSH_LOGIN=yes`, every SSH login to your phone through [ntfy](https://ntfy.sh).

1. Install the ntfy app on your phone. The F-Droid build has no Google dependency, the Play build gets its pushes through Google.
2. Run warden. It makes a random topic on the server and sends a test message once.
3. Read the topic with `sudo cat /var/lib/warden/ntfy-topic`, then add a subscription in the app with the server from `NTFY_SERVER` and that topic.
4. Let priority 4 and 5 override Do Not Disturb in the app, and keep its instant delivery service on, or messages can arrive late.

What to know first:

- The topic is the only password. Anyone who learns it can read your alerts or send fake ones, and a public server has no read-only access for the phone. Treat it like a password, delete the file and run warden again for a new one.
- The server operator can read the text. Messages hold the server name and user name only, never client addresses or secrets.
- A dead or unreachable server sends nothing, so this does not tell you the server is down.
- `ALERT_SSH_LOGIN=yes` adds one line to `/etc/pam.d/sshd`, a file `openssh-server` owns. Warden also keeps your edited version on upgrades (`--force-confold`), because unattended upgrades otherwise hold the package back to ask which file to keep.
- The topic lives in `/var/lib/warden`, outside `/etc`, so `etckeeper` never commits it.

## Backups

Off while `BACKUP_REPOSITORY` is empty. [restic](https://restic.net) encrypts and deduplicates on the server, so the target only ever holds ciphertext. It still sees that you back up, when, and how much.

Pick a target in `warden.conf`:

- `sftp:user@host:/path`: any SFTP host. A laptop reached over Tailscale works while it is awake and on, so treat it as a second copy.
- `rclone:remote:path`: anything `rclone` reaches, such as Filen or Google Drive. Filen needs `rclone` 1.73 or newer, the Debian package may be older and warden warns when it is.

The password and keys are made on your machine, never on the server. Name the files in `warden.conf` and `provision.sh` copies them to `/var/lib/warden/backup`, readable by root alone and outside `/etc`, so `etckeeper` never commits them.

1. Make a long random restic password in a file, `openssl rand -base64 32 > ~/backup-password`, and keep a copy off the server, without it the backups cannot be read.
2. For `sftp`, make a key for backups alone, `ssh-keygen -t ed25519 -f ~/backup-key`, and authorize its public half on the target.
3. For `sftp`, get the target's host key with `ssh-keyscan -t ed25519 <host>`, add `-p <port>` for a port other than 22, check its fingerprint, and paste the line into `BACKUP_HOST_KEY`. It must start with the host, or `[host]:port` for another port, as in `BACKUP_REPOSITORY`. The host is never trusted blindly.
4. Run warden. After SSH has moved, the first run starts the repository, takes a backup and restores one file to prove it works, in 8 minutes at most so the SSH rollback timer cannot fire first. A backup cut short carries on in the daily timer. Every later run repeats the restore test. If anything fails it says so loudly and carries on, the hardening is not held up by the target.

Backups run daily at `BACKUP_TIME` and `/etc` is always included. A weekly `restic check` looks for a damaged repository. Databases need a dump first, a copy of live database files may not restore. Docker images are skipped. A failed backup sends an alert when alerts are on. The uploaded password, key and `rclone.conf` are deleted from warden's directory once placed. The server holds the credentials to prune the repository, so someone who takes over the server can delete its backups too, keep a second copy on a target the server cannot write to, or use snapshots on the target.

## Cloudflare only

`CLOUDFLARE_ONLY=yes` lets only Cloudflare's address ranges reach every port in `PUBLIC_TCP_PORTS` and `PUBLIC_UDP_PORTS`, refreshed daily, so nobody reaches the server around the proxy. It is off by default because it breaks anything not behind Cloudflare: direct visits, monitors, and certificate checks that connect straight to port 80, such as Let's Encrypt HTTP-01. Use a Cloudflare origin certificate or DNS-01 instead. If the ranges cannot be fetched the run stops, and a refresh that returns bad data keeps the ranges already in place. SSH is not affected. Cloudflare sees all web traffic either way, this only closes the way around it.
