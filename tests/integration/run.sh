#!/bin/bash
# Run warden twice inside a Debian 13 container under systemd, then check
# the result. The second run must change nothing.
#
#   tests/integration/run.sh
#
# Needs Docker. Leaves nothing behind, the container is removed on exit,
# unless WARDEN_KEEP_CONTAINER=1 keeps it to look around after a failure.

set -euo pipefail

directory=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
image="warden-integration"
container="warden-integration-$$"

docker build -q -t "$image" "$directory/tests/integration" >/dev/null
# `/home` on a volume, rootless Docker stacks its own overlay mounts under
# the deploy user's home, which the kernel refuses on top of the image's
# overlay. A real server's disk has no such layer.
# A private cgroup namespace, so systemd inside owns the whole tree the way
# it does on a virtual machine, and the deploy user's slice is where the
# rootless daemon looks for it.
docker run -d --name "$container" --privileged --cgroupns=private \
    -v /home "$image" >/dev/null
if [[ "${WARDEN_KEEP_CONTAINER:-0}" == "1" ]]; then
    echo "Keeping $container."
else
    trap 'docker rm -f -v "$container" >/dev/null' EXIT
fi

# Wait for systemd to finish booting.
for _ in $(seq 1 30); do
    state=$(docker exec "$container" systemctl is-system-running 2>/dev/null || true)
    [[ "$state" == "running" || "$state" == "degraded" ]] && break
    sleep 1
done

temporary=$(mktemp -d)
ssh-keygen -q -t ed25519 -N "" -C admin -f "$temporary/admin"
ssh-keygen -q -t ed25519 -N "" -C deploy -f "$temporary/deploy"

cat >"$temporary/warden.conf" <<EOF
ADMIN_USER=admin
ADMIN_PUBLIC_KEY="$(cat "$temporary/admin.pub")"
DEPLOY_USER=deploy
DEPLOY_PUBLIC_KEY="$(cat "$temporary/deploy.pub")"
SSH_PORT=2222
SWAP_SIZE=0
ALERTS=ntfy
NTFY_SERVER=https://ntfy.invalid
CLOUDFLARE_ONLY=yes
EOF

COPYFILE_DISABLE=1 tar -C "$directory" -czf - install.sh library modules files tests/integration/check.sh tests/integration/curl.sh |
    docker exec -i "$container" sh -c 'mkdir -p /root/warden && tar -xzf - -C /root/warden'
docker cp "$temporary/warden.conf" "$container:/root/warden/warden.conf"
rm -rf "$temporary"

# The Cloudflare ranges come from a fixed list, the run needs no network for them.
docker exec "$container" install -m 0755 /root/warden/tests/integration/curl.sh /usr/local/bin/curl

# Docker Desktop's kernel has netfilter built in, but the container cannot
# see the list of built-in modules a real host has on disk.
docker exec "$container" sh -c 'mkdir -p "/lib/modules/$(uname -r)" && echo kernel/net/netfilter/nf_tables.ko >>"/lib/modules/$(uname -r)/modules.builtin"'

# The admin password is normally typed at the prompt, set it up front here.
docker exec "$container" sh -c 'useradd -m -s /bin/bash -G sudo admin && echo "admin:integration-only" | chpasswd'

echo "First run."
docker exec "$container" bash /root/warden/install.sh /root/warden/warden.conf

echo "Second run, must change nothing."
second=$(docker exec "$container" bash /root/warden/install.sh /root/warden/warden.conf 2>&1)
echo "$second"
if grep -E "Updated |Installing |Created |Masked |Removed |Added " <<<"$second"; then
    echo "The second run changed something, warden is not idempotent." >&2
    exit 1
fi

docker exec "$container" bash /root/warden/tests/integration/check.sh
