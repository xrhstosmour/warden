#!/bin/bash
# Keep /etc in git, so every change warden or an administrator makes is a
# commit that can be diffed and undone. Runs last, to record what the other
# modules changed. Switched off with `ETCKEEPER=no`.

if [[ "$ETCKEEPER" != "yes" ]]; then
    log_info "etckeeper is off, ETCKEEPER=yes in warden.conf puts /etc under git."
    return 0
fi

setup_etckeeper() {
    install_packages etckeeper git || return 1
    if [[ ! -d /etc/.git ]]; then
        etckeeper init >/dev/null || return 1
    fi

    # A commit needs an author, root has none configured.
    export GIT_AUTHOR_NAME=warden GIT_AUTHOR_EMAIL=warden@localhost
    export GIT_COMMITTER_NAME=warden GIT_COMMITTER_EMAIL=warden@localhost

    if etckeeper unclean; then
        etckeeper commit "Apply warden" >/dev/null || return 1
        log_info "Committed the changes in /etc."
    fi
}

# SSH has already moved by now, so a failure here must not stop the run,
# `provision.sh` would never prove the new login and a tailnet only server
# would reopen public SSH. The next run tries again.
setup_etckeeper || log_warning "etckeeper did not finish, /etc is not fully in git yet. Run warden again."
