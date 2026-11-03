# warden

Hardens a fresh Debian VPS for containers in one command, run from your own machine. Run it again any time, it only changes what drifted.

## Features

- Admin account with key login and password `sudo`, deploy account with key login only
- SSH on its own port, keys only, no root, post-quantum key exchange
- SSH open to everyone, to listed ranges, or to your tailnet only, through Tailscale SSH on port 22 as a non-root user
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
./setup.sh
./provision.sh root@<server-address>
```

`./setup.sh` asks a few questions and writes `warden.conf`, SSH over your tailnet or public, web through a Cloudflare Tunnel, open ports or none, the tailnet tag. Secrets are asked for without echo. The tunnel token is kept in `~/.warden`, readable by you alone, and `warden.conf` names it. A one-off Tailscale auth key goes into `warden.conf` itself, which only you can read. It never overwrites a `warden.conf` or a token file from another server. Or skip it, `cp warden.conf.example warden.conf` and edit the comments by hand.

It makes an SSH key pair per account, asks for the admin's `sudo` password, checks both accounts log in on the new port, and writes an SSH config next to the keys, so `ssh app-admin` and `ssh app-deploy` work. Later runs go through the admin, `./provision.sh <server-administrator-username>@<server-address> -p <server-ssh-port>`, or with SSH kept to the tailnet, `-p 22` and the server's tailnet address.

Run it from the same machine each time, or keep the keys it made in `~/.ssh` with you. With the public keys left empty in `warden.conf`, warden names the keys after `SERVER_HOSTNAME` or the address, and the server accepts only the keys from the latest run. A later run through the admin on another machine, or under another name, stops with a message instead of replacing the working key. Set `SERVER_HOSTNAME` or paste both public keys into `warden.conf` then.

## Supported systems

Debian 13 (trixie) only. On another Debian release warden warns and carries on, so expect surprises. Other distributions stop at the start. The first login needs root, or a user with `sudo`, because `provision.sh` runs `sudo` over SSH. A provider that only offers a password login asks for it on every connection warden makes, copy your key to that user first with `ssh-copy-id` to avoid the repeats.

## What leaves the server

- Debian mirrors, for `apt` and the daily security updates.
- `download.docker.com`, Docker's `apt` repository, its signing key is pinned to the fingerprint Docker publishes. Unattended upgrades take Docker packages from it too, and reboot the server when a kernel needs it. A bad Docker release would reach every server within a day, hold the packages with `apt-mark hold` if you want to update them by hand.
- `pkgs.tailscale.com`, only with Tailscale, pinned and updated the same way.
- `www.cloudflare.com`, only with `CLOUDFLARE_ONLY=yes`, for the address ranges.
- `pkg.cloudflare.com` and Cloudflare's tunnel network, only with `CLOUDFLARE_TUNNEL_TOKEN_FILE`, for `cloudflared` and the tunnel itself.
- `NTFY_SERVER`, only with `ALERTS=ntfy`, and the backup target, only with `BACKUP_REPOSITORY`.

Nothing else is contacted, and nothing is sent to the author of warden.

## When something goes wrong

- Locked out by a wrong `SSH_SOURCES` or firewall change: open the provider's web console, log in as the admin with its password, then `sudo nft insert rule inet warden input tcp dport <ssh-port> accept` and fix `warden.conf`. The next run rewrites the firewall.
- Locked out with `SSH_ACCESS=tailscale`: public SSH reopens by itself 40 minutes after SSH moved.
- A rebuilt server with the same address has a new host key, so `ssh` stops with `REMOTE HOST IDENTIFICATION HAS CHANGED`. Clear the old one with `ssh-keygen -R <address>` and `ssh-keygen -R "[<address>]:<ssh-port>"`.
- Changing `ADMIN_USER` or `DEPLOY_USER` later makes a new account and leaves the old one, with its home and, for an admin, `sudo`. SSH refuses it from then on, remove it with `sudo userdel -r <old-user>`.
- To rotate keys, make a new pair with `./keys.sh <name>`, put the public keys in `warden.conf` and run again, `authorized_keys` is rewritten, so the old keys stop working.
- There is no uninstall. `/etc` is in git with `etckeeper`, `sudo etckeeper vcs log` shows each change warden made and you can revert them. For a clean slate, reinstall the image.

## Tailscale

warden expects a tailnet policy that treats an untagged machine of yours as a personal device with full reach. It joins the server with a role tag so the policy limits it, and refuses to join without one. Keep your policy file next to your notes, its copy in the admin console wins, warden does not ship or change it.

- Set `TAILSCALE_TAG` to `tag:server`, `tag:web`, `tag:shared` or `tag:internal`. Only an admin can apply a tag. A one-off auth key made in the admin console with the same tag works, so does the login URL when you are an admin owning the tag. A server that joined untagged before stops the run, tag it in the admin console.
- For SSH over Tailscale only, set `SSH_ACCESS=tailscale` and `TAILSCALE_SSH=yes`. The policy grants the tailnet port 22 only, which Tailscale SSH serves, so plain `sshd` on `SSH_PORT` is not reachable through the tailnet. Logins are as the admin or deploy user, never root.
- The policy asks for a browser approval on a login. `provision.sh` prints the URL Tailscale gives and waits up to 15 minutes in all for both accounts. The rollback timer is 40 minutes after SSH moved, which covers the first backup, both approvals and the final `sudo` login. If it does, `provision.sh` says so instead of reporting a tailnet only server, run it again.
- No tag reaches your own devices, so backups to your laptop over Tailscale stop working unless you grant it.
- Tailscale SSH ignores the `sshd` settings and `fail2ban`, the policy decides who gets in.
- Turn off key expiry for a server joined with the login URL in the admin console afterwards.

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

- `sftp:user@host:/path`: any SFTP host. Your own laptop over Tailscale no longer works with the tailnet policy, no tag reaches a personal device. A narrow grant from the server tag to the laptop on port 22 would allow it, and also lets a taken-over server reach the laptop's SSH, so decide that in your policy yourself.
- `rclone:remote:path`: anything `rclone` reaches, such as Filen or Google Drive. Filen needs `rclone` 1.73 or newer, the Debian package may be older and warden warns when it is.

The password and keys are made on your machine, never on the server. Name the files in `warden.conf` and `provision.sh` copies them to `/var/lib/warden/backup`, readable by root alone and outside `/etc`, so `etckeeper` never commits them.

1. Make a long random restic password in a file, `openssl rand -base64 32 > ~/backup-password`, and keep a copy off the server, without it the backups cannot be read.
2. For `sftp`, make a key for backups alone, `ssh-keygen -t ed25519 -f ~/backup-key`, and authorize its public half on the target.
3. For `sftp`, get the target's host key with `ssh-keyscan -t ed25519 <host>`, add `-p <port>` for a port other than 22, check its fingerprint, and paste the line into `BACKUP_HOST_KEY`. It must start with the host, or `[host]:port` for another port, as in `BACKUP_REPOSITORY`. The host is never trusted blindly.
4. Run warden. After SSH has moved, the first run starts the repository, takes a backup and restores one file to prove it works, in 9 minutes at most so the SSH rollback timer cannot fire first. A backup cut short carries on in the daily timer. Every later run repeats the restore test. If anything fails it says so loudly and carries on, the hardening is not held up by the target.

Backups run daily at `BACKUP_TIME` and `/etc` is always included. A weekly job runs `restic check` to look for a damaged repository, then frees the space of forgotten snapshots with `restic prune`. Databases need a dump first, a copy of live database files may not restore. Docker images are skipped. A failed backup sends an alert when alerts are on. The uploaded password, key and `rclone.conf` are deleted from warden's directory once placed. The server holds the credentials to prune the repository, so someone who takes over the server can delete its backups too, keep a second copy on a target the server cannot write to, or use snapshots on the target.

## Cloudflare only

`CLOUDFLARE_ONLY=yes` lets only Cloudflare's address ranges reach every port in `PUBLIC_TCP_PORTS` and `PUBLIC_UDP_PORTS`, refreshed daily, so nobody reaches the server around the proxy. It is off by default because it breaks anything not behind Cloudflare: direct visits, monitors, and certificate checks that connect straight to port 80, such as Let's Encrypt HTTP-01. Use a Cloudflare origin certificate or DNS-01 instead. If the ranges cannot be fetched the run stops, and a refresh that returns bad data keeps the ranges already in place. SSH is not affected. Cloudflare sees all web traffic either way, this only closes the way around it.

## Cloudflare Tunnel

`CLOUDFLARE_TUNNEL_TOKEN_FILE` names a file on your machine holding a tunnel token from the Zero Trust dashboard. `provision.sh` uploads it, `cloudflared` dials out to Cloudflare, and web traffic comes back through that, so `PUBLIC_TCP_PORTS` and `PUBLIC_UDP_PORTS` must be empty. Point the tunnel's public hostnames at the loopback ports your containers publish. With `SSH_ACCESS=tailscale` too, nothing listens on the public address: the firewall drops the Tailscale direct port as well, so Tailscale uses its relays, slower but closed. The token is kept in `/etc/cloudflared/token.env`, readable by root alone, and the service runs as its own unprivileged user. Multipath TCP is switched off on every server, `net.mptcp.enabled = 0`, on the host only, a container namespace has its own setting. Any server with Tailscale and no public port, tunnel or not, also loses the Tailscale direct port on its next run and uses relays.

Setting it up:

1. In the Zero Trust dashboard, Networks, Tunnels, create a Cloudflared tunnel and copy the token from the install command it shows.
2. `./setup.sh` and answer `tunnel`, or put the token in a file with `chmod 600` and set `CLOUDFLARE_TUNNEL_TOKEN_FILE`. `provision.sh` refuses a file others can read, or one that is not shaped like a token, before it touches the server.
3. Add a public hostname to the tunnel for each site, pointing at the loopback port its container publishes, such as `http://127.0.0.1:8080`. Containers must publish on `127.0.0.1`, not on every address, `sudo warden-audit` fails while anything listens on all addresses behind a tunnel.
4. `./provision.sh`. The token is deleted from warden's directory on the server once placed. Keep the file on your machine, every `provision.sh` run checks and uploads it again, and the server only changes when the token did.

Rotate a token in the dashboard, put the new one in the file, and run `provision.sh` again, the service restarts only when it changed. Remove the setting to turn the tunnel off, the next run stops and removes the service, the token, the `cloudflared` package and its `apt` source, and delete the tunnel in the dashboard too. Only a tunnel warden made is removed, one you set up yourself with `cloudflared service install` is left alone. Turning the tunnel on replaces that service with warden's. Anyone who takes over the server can read the token, so it grants a tunnel and nothing more, revoke it in the dashboard if that happens.

The `apt` repository key is pinned to fingerprint `CC94B39C77AE7342A68B89628A682D308D4E5E73`, checked on every run. Cloudflare publishes no fingerprint, so the pin rests on the key from `pkg.cloudflare.com` over HTTPS, and on its key ID `8A682D308D4E5E73` being the one named in [cloudflare/cloudflared issue 1779](https://github.com/cloudflare/cloudflared/issues/1779). Check it yourself with `curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | gpg --show-keys`, last checked 2026-11-03. If Cloudflare rotates the key the run stops with a message instead of trusting the new one.

Not covered: a tunnel carries web traffic only. Cloudflare sees it all, and an outage on their side is an outage for the site.
