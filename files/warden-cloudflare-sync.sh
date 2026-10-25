#!/bin/bash
# Managed by warden, local changes are overwritten on the next run.
# Fetches Cloudflare's published address ranges and keeps the firewall sets
# that let only them reach the public ports current. Bad or short data is
# refused and the ranges already in place stay, the sets are never emptied.

set -uo pipefail

state_directory="${WARDEN_STATE_DIRECTORY:-/var/lib/warden}"
base="${WARDEN_CLOUDFLARE_URL:-https://www.cloudflare.com}"
cache="$state_directory/cloudflare"
mkdir -p "$state_directory"
install -d -m 0755 "$cache"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# fetch <family> <pattern> <shortest prefix>, keeps only a list of at least 5
# valid ranges. Cloudflare publishes small blocks, a short prefix such as /0
# would open the public ports to everyone, so it is refused.
fetch() {
    local family="$1"
    local pattern="$2"
    local shortest="$3"
    curl --silent --show-error --fail --proto '=https' --tlsv1.2 --max-time 20 "$base/ips-$family" >"$work/$family" || return 1
    [[ "$(grep -c . "$work/$family")" -ge 5 ]] || return 1
    ! grep -qvE "$pattern" "$work/$family" || return 1
    awk -F/ -v shortest="$shortest" '$2 + 0 < shortest { bad = 1 } END { exit bad }' "$work/$family"
}

fetch v4 '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$' 8 || {
    echo "Cloudflare's IPv4 ranges could not be fetched or look wrong, keeping the current ones." >&2
    exit 1
}
fetch v6 '^[0-9a-fA-F:]+/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])$' 16 || {
    echo "Cloudflare's IPv6 ranges could not be fetched or look wrong, keeping the current ones." >&2
    exit 1
}

# The firewall has the last word. Nothing reaches the cache before nft has
# accepted it, so a list it rejects can never stop the next run.
{
    echo "table inet warden_check {"
    echo "    set cloudflare4 { type ipv4_addr; flags interval; elements = { $(paste -sd, "$work/v4") } }"
    echo "    set cloudflare6 { type ipv6_addr; flags interval; elements = { $(paste -sd, "$work/v6") } }"
    echo "}"
} >"$work/check.nft"
nft -c -f "$work/check.nft" || {
    echo "The firewall rejects Cloudflare's ranges, keeping the current ones." >&2
    exit 1
}

changed=false
for pair in "v4 ipv4" "v6 ipv6"; do
    read -r family name <<<"$pair"
    if ! cmp -s "$work/$family" "$cache/$name"; then
        install -m 0644 "$work/$family" "$cache/$name"
        changed=true
    fi
done
[[ "$changed" == true ]] && echo "Cloudflare ranges changed."

# Replace the live sets in one transaction, when the firewall has them yet.
if nft list set inet warden cloudflare4 >/dev/null 2>&1; then
    {
        echo "flush set inet warden cloudflare4"
        echo "add element inet warden cloudflare4 { $(paste -sd, "$cache/ipv4") }"
        echo "flush set inet warden cloudflare6"
        echo "add element inet warden cloudflare6 { $(paste -sd, "$cache/ipv6") }"
    } >"$work/sets.nft"
    nft -c -f "$work/sets.nft" && nft -f "$work/sets.nft"
fi
