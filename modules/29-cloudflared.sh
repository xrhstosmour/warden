#!/bin/bash
# Web traffic through a Cloudflare Tunnel, so the server needs no public
# port for it. `cloudflared` only dials out, and the routes live in the
# Cloudflare dashboard. Runs before the firewall, which holds no web port
# with a tunnel. Off unless `CLOUDFLARE_TUNNEL_TOKEN_FILE` is set.

if ! uses_cloudflare_tunnel; then
    # Only what warden made. A tunnel the operator set up with Cloudflare's own
    # `cloudflared service install` has no warden header and is left running.
    if grep -qs '^# Managed by warden' /etc/systemd/system/cloudflared.service; then
        systemctl disable -q --now cloudflared.service 2>/dev/null || true
        rm -f /etc/systemd/system/cloudflared.service "$CLOUDFLARED_ENVIRONMENT_FILE"
        rmdir /etc/cloudflared 2>/dev/null || true
        systemctl daemon-reload
        purge_packages cloudflared
        rm -f /etc/apt/sources.list.d/cloudflared.list /usr/share/keyrings/cloudflare-main.gpg
        log_info "Removed the Cloudflare Tunnel, CLOUDFLARE_TUNNEL_TOKEN_FILE in warden.conf brings it back. Delete the tunnel in the Zero Trust dashboard too."
    fi
    return 0
fi

# Cloudflare's own repository, Debian ships no package.
keyring=/usr/share/keyrings/cloudflare-main.gpg
# The fingerprint of Cloudflare's package signing key. Its key ID, 8A682D308D4E5E73,
# is the one named in cloudflare/cloudflared issue 1779, Cloudflare publishes no
# fingerprint itself, so compare it with the key from pkg.cloudflare.com by hand
# when it changes. Checked 2026-11-03.
place_signing_key "https://pkg.cloudflare.com/cloudflare-main.gpg" "$keyring" \
    CC94B39C77AE7342A68B89628A682D308D4E5E73
if place_content /etc/apt/sources.list.d/cloudflared.list 0644 <<EOF; then
# Managed by warden, local changes are overwritten on the next run.
deb [signed-by=$keyring] https://pkg.cloudflare.com/cloudflared any main
EOF
    apt-get update -q
fi
install_packages cloudflared

# The uploaded file is the only copy of the token outside Cloudflare. Once it
# is in the service's own file it is removed, and later runs keep that one.
token_file="$CLOUDFLARED_ENVIRONMENT_FILE"
install -d -m 0700 -o root -g root /etc/cloudflared
if [[ -f "$CLOUDFLARE_TUNNEL_TOKEN_FILE" ]]; then
    token=$(tr -d '[:space:]' <"$CLOUDFLARE_TUNNEL_TOKEN_FILE")
    # Never echoed, a token is a password.
    is_tunnel_token "$token" ||
        fail "$CLOUDFLARE_TUNNEL_TOKEN_FILE does not hold a tunnel token, copy it from the tunnel's page in the Zero Trust dashboard."
    printf 'TUNNEL_TOKEN=%s\n' "$token" | place_content "$token_file" 0600 && token_changed=true
    unset token
    if [[ "$CLOUDFLARE_TUNNEL_TOKEN_FILE" == "$WARDEN_DIRECTORY/secrets/"* ]]; then
        rm -f "$CLOUDFLARE_TUNNEL_TOKEN_FILE"
    fi
else
    [[ -f "$token_file" ]] || fail "$CLOUDFLARE_TUNNEL_TOKEN_FILE is missing, it should hold the tunnel token named in warden.conf."
fi

if ! id cloudflared >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin cloudflared
    log_info "Created the cloudflared user."
fi

changed=false
render_cloudflared_unit | place_content /etc/systemd/system/cloudflared.service 0644 && changed=true
[[ "$changed" == true ]] && systemctl daemon-reload

if [[ "$changed" == true || "${token_changed:-false}" == true ]]; then
    ensure_service cloudflared.service restart
else
    ensure_service cloudflared.service
fi
