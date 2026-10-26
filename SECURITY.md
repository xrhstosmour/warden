# Security policy

Report a vulnerability privately through the repository's Security tab, "Report a vulnerability". Please do not open a public issue for it.

warden changes SSH, firewall and user settings on servers, so a report about a lockout, a weakened default or a way to escalate privileges is welcome.

## Tailnet policy

With Tailscale, warden relies on the tailnet policy to limit the server. It joins with a role tag from `TAILSCALE_TAG` and refuses to join without one, because an untagged machine of the owner gets the access of a personal device. The tag only limits the server if the policy defines it, so check the policy in the admin console before trusting it. SSH over the tailnet is Tailscale SSH on port 22 as a non-root user, behind the policy's browser approval.
