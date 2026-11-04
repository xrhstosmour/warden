#!/usr/bin/env bats

setup() {
    stub="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$stub"
    # An ssh that records its arguments and fails, so provision.sh stops at
    # its first remote command.
    cat >"$stub/ssh" <<'STUB'
#!/bin/bash
echo "$*" >>"$BATS_TEST_TMPDIR/ssh"
exit 1
STUB
    chmod +x "$stub/ssh"
    export PATH="$stub:$PATH"
    export BATS_TEST_TMPDIR
    cat >"$BATS_TEST_TMPDIR/warden.conf" <<'CONF'
ADMIN_USER=admin
DEPLOY_USER=deploy
SSH_PORT=2222
ADMIN_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOSWAHsCf+sZ6GEGPlRvVDuNAa/vjrxWpqgaFxT/Dsxt admin@laptop"
DEPLOY_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICMxjodA14l51z5VGfmg5g/Okt4x3V08Kz/XOy5hTcli deploy@laptop"
CONF
    export WARDEN_CONFIGURATION="$BATS_TEST_TMPDIR/warden.conf"
}

# macOS ships bash 3.2, where expanding an empty array fails under `set -u`.
@test "runs without ssh options under the bash macOS ships" {
    run /bin/bash "$BATS_TEST_DIRNAME/../provision.sh" root@192.0.2.1
    [[ "$output" != *"unbound variable"* ]]
    grep -q "root@192.0.2.1" "$BATS_TEST_TMPDIR/ssh"
}

@test "passes ssh options on" {
    run /bin/bash "$BATS_TEST_DIRNAME/../provision.sh" root@192.0.2.1 -p 2222
    grep -q -- "-p 2222 root@192.0.2.1" "$BATS_TEST_TMPDIR/ssh"
}

@test "a target without a user is refused" {
    run /bin/bash "$BATS_TEST_DIRNAME/../provision.sh" 192.0.2.1
    [ "$status" -eq 1 ]
    [ ! -e "$BATS_TEST_TMPDIR/ssh" ]
}
