# Security policy

Report a vulnerability privately through the repository's Security tab, "Report a vulnerability". Please do not open a public issue for it.

warden changes SSH, firewall and user settings on servers, so a report about a lockout, a weakened default or a way to escalate privileges is welcome.

## Cloudflare Tunnel

The tunnel token is made on the operator's machine, uploaded over SSH, kept at `/etc/cloudflared/token.env` readable by root alone, and passed to `cloudflared` through the environment, never a command line. `provision.sh` refuses a token file others can read. The repository signing key is pinned by fingerprint, see the README for how that pin was checked and its limits. A tunnel and an open public port are refused together, because the open port is a way around it.

## Tailnet policy

With Tailscale, warden relies on the tailnet policy to limit the server. It joins with a role tag from `TAILSCALE_TAG` and refuses to join without one, because an untagged machine of the owner gets the access of a personal device. The tag only limits the server if the policy defines it, so check the policy in the admin console before trusting it. SSH over the tailnet is Tailscale SSH on port 22 as a non-root user, behind the policy's browser approval.

With `SSH_ACCESS=tailscale`, the run that moves SSH opens it to everyone for a moment, closes it and arms `warden-ssh-rollback` to reopen it `rollback_minutes` (40) later. The timer is a pair of unit files with an absolute deadline, so a reboot in that window does not remove it. `provision.sh` stops and disables it once it has logged in over the tailnet, and the server remembers that proof for the SSH port in `/var/lib/warden/ssh-proven`, so later runs neither open SSH to everyone nor arm it again. If the rollback fires, the rule it adds is put back after a reboot by `warden-ssh-reopen` until a tailnet login is proven. A server that was never provisioned that way, or whose `SSH_PORT` changed, starts over and reopens unless `sudo systemctl disable --now warden-ssh-rollback.timer` is run in time. Last verified in `modules/30-firewall.sh`, `modules/90-ssh.sh` and `files/warden-ssh-rollback-stop.sh`, 2026-11-05.
