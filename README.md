<div align="center">

<img src=".github/assets/icon.svg" width="128" alt="warden">

# warden

**A fresh Debian 13 VPS, hardened for containers, in one command.**

Run it from your own machine against a new server. It locks the server down,
moves SSH where you want it, and leaves rootless Docker ready for your
deployments. Run it again any time, it only changes what drifted.

</div>

## Use

```bash
git clone https://github.com/xrhstosmour/warden && cd warden
cp warden.conf.example warden.conf   # pick the SSH port, Tailscale, the rest
./provision.sh root@203.0.113.10     # the provider's first login
```

With the public keys left empty, `provision.sh` makes an `ed25519` key pair per
account on your machine first. It asks you for the admin's `sudo` password on the
server, logs in as both accounts on the new port before it calls it done, and
writes an SSH config for them next to the keys:

```bash
ssh app-admin    # administer
ssh app-deploy   # deploy
```

Later runs go through the admin, `./provision.sh admin@203.0.113.10 -p 2222`.
On the server itself, `sudo ./install.sh` does the same without the copying.

## SSH over Tailscale only

```bash
SSH_ACCESS=tailscale
SSH_PORT=2222
TAILSCALE_AUTH_KEY=""   # optional, a one-off tskey-auth-... key
TAILSCALE_SSH=no        # yes adds Tailscale SSH on the tailnet
```

Without a key, the first run prints a Tailscale login URL, open it on your
machine and approve the server. Then turn off key expiry for it in the admin
console, or it drops off the tailnet in 180 days.

The server joins your tailnet, and SSH answers there only, nothing on the public
address but HTTP and HTTPS. Your machine has to be on the tailnet too.
`provision.sh` logs in over it before it closes the old way in, and should that
login fail, public SSH reopens by itself after 15 minutes, so a mistake never
locks you out.

## What it does

**Accounts**: an admin with key login and password `sudo`, and a deploy user with
key login, no password and no `sudo`.

**SSH**: its own port, keys only, no root, the two accounts only, post-quantum key
exchange, strong ciphers only. Open to everyone, to listed ranges, or to your
tailnet alone.

**Firewall**: `nftables`, everything inbound dropped except SSH, HTTP and HTTPS.
Nothing is forwarded.

**Rootless Docker** for the deploy user, the system daemon masked, so escaping a
container lands in an account that can do nothing. Real client addresses still
reach your proxy.

**`fail2ban`**: SSH bans that grow with each repeat, and a week on every port for
repeat offenders.

**Updates**: security updates applied daily, and a reboot in your chosen quiet
hour when the kernel needs one.

**Kernel**: hardened network and kernel parameters, unused protocols and file
systems blocked, BBR congestion control.

**The rest**: encrypted time sync, logs kept a month and capped, no core dumps,
`auditd` watching logins and keys, AppArmor on, `/dev/shm` without executables, a
swap file on small machines.

## Test

```bash
bats tests/                  # the rendered configuration
tests/integration/run.sh     # warden twice in a Debian 13 container
```

The second run must change nothing.
