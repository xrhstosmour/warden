#!/bin/sh
# Stands in for curl inside the integration container, so the Cloudflare
# sync runs without the network. Serves a fixed list for the two Cloudflare
# paths, anything else goes to the real curl.

for argument; do
    url="$argument"
done

case "$url" in
*/ips-v4)
    printf '%s\n' 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18
    ;;
*/ips-v6)
    printf '%s\n' 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32
    ;;
*)
    exec /usr/bin/curl "$@"
    ;;
esac
