# warden

Hardens a fresh Debian 13 VPS for containers in one command, run from your own machine. Run it again any time, it only changes what drifted.

## Features

- Admin account with key login and password `sudo`, deploy account with key login only
- SSH on its own port, keys only, no root, post-quantum key exchange
- SSH open to everyone, to listed ranges, or to your tailnet only
- `nftables` firewall, only SSH, HTTP and HTTPS inbound
- Rootless Docker for the deploy account, system daemon masked
- `fail2ban` with growing bans for repeat offenders
- Daily security updates and reboots in a quiet hour
- Hardened kernel and network parameters, BBR
- Encrypted time sync, capped logs, `auditd`, AppArmor, no core dumps

## Use

```bash
git clone https://github.com/xrhstosmour/warden && cd warden
cp warden.conf.example warden.conf
./provision.sh root@203.0.113.10
```

It makes an SSH key pair per account, asks for the admin's `sudo` password, checks both accounts log in on the new port, and writes an SSH config next to the keys, so `ssh app-admin` and `ssh app-deploy` work. Later runs go through the admin, `./provision.sh admin@203.0.113.10 -p 2222`.

For SSH over Tailscale only, set `SSH_ACCESS=tailscale` in `warden.conf`. With no `TAILSCALE_AUTH_KEY`, the first run prints a login URL to approve in your browser. Turn off key expiry for the server in the Tailscale admin console afterwards. If the tailnet login fails, public SSH reopens by itself after 15 minutes.
