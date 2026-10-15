# warden

Turns a fresh Debian 13 VPS into a locked down host for containerised applications, with one command from your own machine. Idempotent, run it again any time and it applies only what drifted.

See [`AGENTS.md`](AGENTS.md) if you are an agent.

## Use

1. Create two key pairs, one for administering the server and one for deployments:

   ```bash
   ./keys.sh app
   ```

2. Copy `warden.conf.example` to `warden.conf` and fill it in, the keys from step 1, the SSH port, and optionally the addresses allowed to reach SSH.

3. Point it at the server with the provider's initial login:

   ```bash
   ./provision.sh root@203.0.113.10
   ```

   It copies warden over, runs it with a terminal so you can choose the admin's `sudo` password, then logs in as both accounts on the new port before it reports success. Keep the first session open until that check passes.

4. Later runs go through the admin account:

   ```bash
   ./provision.sh admin@203.0.113.10 -p 2222 -i ~/.ssh/app_admin
   ```

On the server itself, `sudo ./install.sh` does the same without the copying.

## What it does

- Accounts: an admin with key login and password `sudo`, a deploy user with key login, no password and no `sudo`, a sudoers drop-in with `use_pty` and a log
- SSH: its own port, keys only, no root, only the two accounts, post-quantum key exchange, strong ciphers only, small Diffie-Hellman groups removed, forwarding for the admin only
- Firewall: `nftables`, inbound denied except SSH and the public ports, optionally SSH from listed ranges only, forwarding closed, the old SSH port kept open until SSH has moved
- `fail2ban`: SSH bans growing with each repeat, and a week long ban on every port for repeat offenders
- Docker: rootless for the deploy user, the system wide daemon masked, so a container escape lands in an unprivileged account, real client addresses reach the proxy, resource limits delegated, logs capped
- Kernel: hardened network and kernel parameters, unused protocols and file systems blocked from loading, BBR congestion control
- Updates: security and stable updates daily including Docker, services restarted after library updates, reboots at a set time when the kernel needs one
- Time: `chrony` with Network Time Security sources only
- Logs: persistent journal capped at 1 GB and one month, no core dumps, `auditd` rules for accounts, privileges, SSH, firewall and kernel changes, AppArmor on
- Rest: `/dev/shm` without executables or devices, umask `027`, a swap file when there is none, no survey or plain text remote shell packages

## What it does not do

- Provider side: snapshots, the provider's firewall, and console access are yours to set up. Keep console access, it is the way back in if SSH is ever misconfigured.
- Applications: warden prepares the deploy user, the application's own deploy puts the containers there.
- Off-box backups: belong with the application, which knows what to back up.

## Development

```bash
shellcheck -x -S style install.sh provision.sh keys.sh library/*.sh modules/*.sh tests/integration/*.sh
bats tests/
tests/integration/run.sh
```

`tests/integration/run.sh` runs warden twice in a Debian 13 container under systemd, fails if the second run changes anything, then checks the result.
