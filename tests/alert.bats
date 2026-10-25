#!/usr/bin/env bats

setup() {
    directory="$BATS_TEST_DIRNAME/../files"
    work=$(mktemp -d)
    export WARDEN_CONFIGURATION_DIRECTORY="$work/etc"
    export WARDEN_STATE_DIRECTORY="$work/state"
    export WARDEN_STAMP_DIRECTORY="$work/stamp"
    mkdir -p "$WARDEN_CONFIGURATION_DIRECTORY" "$WARDEN_STATE_DIRECTORY" "$work/bin"
    echo "NTFY_SERVER=https://ntfy.example" >"$WARDEN_CONFIGURATION_DIRECTORY/alerts.conf"
    echo "ALERT_DISK_PERCENT=85" >>"$WARDEN_CONFIGURATION_DIRECTORY/alerts.conf"
    printf 'AbCdEf0123456789AbCdEf0123456789AbCdEf0123456789' >"$WARDEN_STATE_DIRECTORY/ntfy-topic"

    # A curl that records what it is given instead of sending it.
    cat >"$work/bin/curl" <<'EOF'
#!/bin/bash
echo "$@" >>"$WORK/curl-arguments"
cat >>"$WORK/curl-input"
exit "${CURL_STATUS:-0}"
EOF
    chmod +x "$work/bin/curl"
    export WORK="$work"
    export PATH="$work/bin:$PATH"
}

teardown() {
    rm -rf "$work"
}

@test "the topic reaches curl on standard input, not on the command line" {
    run "$directory/warden-alert.sh" 4 "Unit failed" "app-1: nginx.service" warning
    [ "$status" -eq 0 ]
    [[ "$(cat "$work/curl-arguments")" != *AbCdEf* ]]
    grep -q 'url = "https://ntfy.example/AbCdEf0123456789AbCdEf0123456789AbCdEf0123456789"' "$work/curl-input"
    grep -q 'header = "Priority: 4"' "$work/curl-input"
    grep -q 'header = "Title: Unit failed"' "$work/curl-input"
}

@test "curl is held to https" {
    run "$directory/warden-alert.sh" 3 "Title" "Message"
    [[ "$(cat "$work/curl-arguments")" == *"--proto =https"* ]]
}

@test "a plain http server is refused and nothing is sent" {
    echo "NTFY_SERVER=http://ntfy.example" >"$WARDEN_CONFIGURATION_DIRECTORY/alerts.conf"
    run "$directory/warden-alert.sh" 3 "Title" "Message"
    [ "$status" -eq 0 ]
    [ ! -e "$work/curl-input" ]
}

@test "a missing or malformed topic sends nothing" {
    echo "short" >"$WARDEN_STATE_DIRECTORY/ntfy-topic"
    run "$directory/warden-alert.sh" 3 "Title" "Message"
    [ "$status" -eq 0 ]
    [ ! -e "$work/curl-input" ]
}

@test "a failed send is reported to the caller" {
    CURL_STATUS=22 run "$directory/warden-alert.sh" 3 "Title" "Message"
    [ "$status" -eq 1 ]
}

@test "a message starting with an at sign is sent as text, not read as a file" {
    run "$directory/warden-alert.sh" 3 "Title" "@/etc/passwd"
    [ "$status" -eq 0 ]
    grep -q 'data-raw = "@/etc/passwd"' "$work/curl-input"
}

@test "quotes and line breaks cannot break the curl configuration" {
    run "$directory/warden-alert.sh" 3 'Ti"tle' $'Mess"age\nheader = "X-Evil: 1"'
    [ "$status" -eq 0 ]
    [ "$(grep -c '^header = ' "$work/curl-input")" -eq 3 ]
    ! grep -q 'X-Evil' <(grep '^header = ' "$work/curl-input")
}

@test "a full disk alerts once and again when it recovers" {
    cat >"$work/alert" <<'EOF'
#!/bin/bash
echo "$1 $2" >>"$WORK/alert-calls"
EOF
    cat >"$work/bin/df" <<'EOF'
#!/bin/bash
printf 'Use%%\n %s%%\n' "$(cat "$WORK/usage")"
EOF
    printf '#!/bin/bash\n' >"$work/bin/systemctl"
    chmod +x "$work/alert" "$work/bin/df" "$work/bin/systemctl"
    export WARDEN_ALERT="$work/alert"

    echo 91 >"$work/usage"
    run "$directory/warden-alert-check.sh"
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Disk almost full' "$work/alert-calls")" -eq 1 ]

    echo 40 >"$work/usage"
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Disk space back' "$work/alert-calls")" -eq 1 ]
}

@test "a failed unit alerts once and again when it is healthy" {
    cat >"$work/alert" <<'EOF'
#!/bin/bash
echo "$1 $2" >>"$WORK/alert-calls"
EOF
    cat >"$work/bin/df" <<'EOF'
#!/bin/bash
printf 'Use%%\n 10%%\n'
EOF
    cat >"$work/bin/systemctl" <<'EOF'
#!/bin/bash
cat "$WORK/failed" 2>/dev/null
EOF
    chmod +x "$work/alert" "$work/bin/df" "$work/bin/systemctl"
    export WARDEN_ALERT="$work/alert"

    echo "nginx.service loaded failed failed Web server" >"$work/failed"
    run "$directory/warden-alert-check.sh"
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Unit failed' "$work/alert-calls")" -eq 1 ]

    : >"$work/failed"
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Units healthy' "$work/alert-calls")" -eq 1 ]
}

@test "an alert that did not go out is sent again on the next check" {
    cat >"$work/alert" <<'EOF'
#!/bin/bash
echo "$1 $2" >>"$WORK/alert-calls"
[ -f "$WORK/sends-work" ]
EOF
    cat >"$work/bin/df" <<'EOF'
#!/bin/bash
printf 'Use%%\n 91%%\n'
EOF
    printf '#!/bin/bash\n' >"$work/bin/systemctl"
    chmod +x "$work/alert" "$work/bin/df" "$work/bin/systemctl"
    export WARDEN_ALERT="$work/alert"

    run "$directory/warden-alert-check.sh"
    touch "$work/sends-work"
    run "$directory/warden-alert-check.sh"
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Disk almost full' "$work/alert-calls")" -eq 2 ]
}
