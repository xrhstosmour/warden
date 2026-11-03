#!/bin/bash
# Runs inside the integration container after the first two runs and
# `check.sh`. Turns the Cloudflare Tunnel on with a made up token, so the real
# `cloudflared` runs under the real unit and its sandbox, then off again. It
# cannot reach Cloudflare's edge with that token, so what it proves is that the
# unit starts and keeps running, not that traffic flows.

# Each check is a command string for `sh -c`, expanded there.
# shellcheck disable=SC2016

set -uo pipefail

failures=0
check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok   $description"
    else
        echo "FAIL $description"
        failures=$((failures + 1))
    fi
}

directory=/root/warden
base="$directory/warden.conf"
tunnel="$directory/warden-tunnel.conf"
unit=/etc/systemd/system/cloudflared.service

# The same shape the dashboard gives, a base64 JSON with the account, the
# tunnel and a secret, none of it known to Cloudflare. The same number makes
# the same token, so a rerun is the same upload.
make_token() {
    printf '{"a":"%s","t":"%s","s":"%s"}' "$(printf '%032x' "$1")" "00000000-0000-0000-0000-00000000000$1" "$(printf '%032d' "$1" | base64 -w0)" |
        base64 -w0 >"$directory/secrets/cloudflare-tunnel-token"
}

run_warden() {
    WARDEN_VERIFY_FILE=/etc/passwd bash "$directory/install.sh" "$1" 2>&1
}

# A tunnel the operator made with Cloudflare's own installer is not warden's.
printf '[Service]\nExecStart=/bin/true\n' >"$unit"
run_warden "$base" >/dev/null
check "a tunnel warden did not make is left alone with the tunnel off" test -f "$unit"
rm -f "$unit"

cp "$base" "$tunnel"
cat >>"$tunnel" <<EOF
CLOUDFLARE_ONLY=no
PUBLIC_TCP_PORTS=""
PUBLIC_UDP_PORTS=""
CLOUDFLARE_TUNNEL_TOKEN_FILE=$directory/secrets/cloudflare-tunnel-token
EOF

echo "Tunnel on."
make_token 1
if ! run_warden "$tunnel" >/dev/null; then
    echo "FAIL the run with the tunnel on failed"
    exit 1
fi
sleep 10
check "the tunnel service runs" systemctl is-active cloudflared.service
check "the sandbox did not stop the process" sh -c '! journalctl -u cloudflared.service --no-pager | grep -qiE "operation not permitted|address family not supported|permission denied|cannot allocate"'
check "the token file is readable by root alone" sh -c 'test "$(stat -c %a /etc/cloudflared/token.env)" = 600'
check "the uploaded token is deleted" test ! -e "$directory/secrets/cloudflare-tunnel-token"
check "nothing listens on all addresses" sh -c '! ss -Htln | awk "\$4 ~ /^(0\\.0\\.0\\.0|\\*|\\[::\\]):/ && \$4 !~ /:2222\$/" | grep -q .'
check "the firewall opens no web port" sh -c '! nft list chain inet warden input | grep -qE "dport \{ ?(80|443)"'
check "the audit sees the tunnel" sh -c 'warden-audit 2>&1 | grep -q "ok   the tunnel service runs"'
check "the audit finds no wide listener" sh -c 'warden-audit 2>&1 | grep -q "ok   behind the tunnel nothing listens on all addresses"'

echo "Second run, must change nothing."
make_token 1
second=$(run_warden "$tunnel")
if grep -E "Updated |Installing |Created |Masked |Removed |Added " <<<"$second"; then
    echo "FAIL the second run with the tunnel on changed something"
    failures=$((failures + 1))
fi

# The same token put back is not a change, a new one restarts the service.
before=$(systemctl show -p ActiveEnterTimestampMonotonic --value cloudflared.service)
make_token 2
run_warden "$tunnel" >/dev/null
after=$(systemctl show -p ActiveEnterTimestampMonotonic --value cloudflared.service)
check "a new token restarts the service" test "$before" != "$after"

echo "Tunnel off."
run_warden "$base" >/dev/null
check "the unit is removed" test ! -e "$unit"
check "the token is removed" test ! -e /etc/cloudflared/token.env
check "the package is purged" sh -c '! dpkg -s cloudflared 2>/dev/null | grep -q "Status: install ok installed"'
check "the apt source is removed" test ! -e /etc/apt/sources.list.d/cloudflared.list
check "the service is gone from systemd" sh -c '! systemctl cat cloudflared.service >/dev/null 2>&1'

rm -f "$tunnel"
if ((failures > 0)); then
    echo "$failures tunnel check(s) failed." >&2
    exit 1
fi
echo "All tunnel checks passed."
