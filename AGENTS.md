# Agent guide

## What this is

warden hardens a fresh Debian 13 server for hosting containers. `install.sh` runs on the server as root and executes every `modules/*.sh` in name order, each in its own subshell. `provision.sh` and `keys.sh` run on the operator's machine, under the bash 3 macOS ships, so no `mapfile` or other bash 4 features there.

## Layout

- `library/common.sh`: logging, `place` and `place_content` for idempotent file installs, package and service helpers.
- `library/configuration.sh`: defaults, loading and validation of `warden.conf`. Every value a module writes into a system file is validated here first.
- `library/render.sh`: configuration files built from `warden.conf`, printing only, so `tests/render.bats` checks them without a server.
- `modules/NN-name.sh`: one concern each. The number is the order.
- `files/`: static payloads a module installs as they are.

## Rules

- Idempotent: a second run must change nothing. `place` returns 0 only after a real change, restart a service only then. `tests/integration/run.sh` fails on any `Updated`, `Installing`, `Created`, `Masked`, `Removed` or `Added` line in the second run, keep those words for real changes.
- No lockout: SSH moves last, in `90-ssh.sh`. Until then the firewall keeps the port SSH listens on now open to everyone, also with `SSH_ACCESS=tailscale`, and `90-ssh.sh` closes it after the move. With `SSH_ACCESS=tailscale` it also schedules `warden-ssh-rollback`, which reopens public SSH after 15 minutes unless `provision.sh` proves a tailnet login and stops it. Validate before restarting, `sshd -t`, `nft -c`, `visudo -c`, `fail2ban-client -t`.
- Tailscale is optional, `uses_tailscale` decides. `25-tailscale.sh` returns early without it, and runs before the firewall, so the tailnet is up before SSH is kept to it. The auth key is read from a file, never passed on a command line.
- Keys are made on the operator's machine, never on the server. `provision.sh` makes them with `keys.sh` only when `warden.conf` leaves the public keys empty, `WARDEN_KEYS` overrides `~/.ssh` for tests.
- Never weaken a default without a comment saying why the server needs it.
- Unprivileged user namespaces must stay enabled, rootless Docker depends on them.
- The system wide Docker daemon stays masked. Nothing joins the `docker` group, it is root equivalent.
- Comments end with a period and sit above the code. Whole words in names, `configuration` not `config`, `temporary` not `tmp`.

## Verification

All must pass before a commit:

```bash
shellcheck -x -S style install.sh provision.sh keys.sh library/*.sh modules/*.sh files/*.sh tests/integration/*.sh
bats tests/
tests/integration/run.sh
```

The integration run needs Docker and runs privileged. It cannot join a tailnet, so check Tailscale changes with `bats` and by hand on a real server. Kernel parameters it sets apply to the Docker host's kernel, on Docker Desktop that is its virtual machine.

## Commits

Single line, imperative, under about ten words, identifiers in backticks, no prefixes, no trailers.
