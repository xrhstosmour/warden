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

# The hook has fixed paths and takes nothing from the environment, so the
# tests run a copy with those paths pointed at a stub and a scratch directory.
login_hook() {
    sed "s|/usr/local/sbin/warden-alert|$work/alert|; s|/run/warden-alert|$work/stamp|" \
        "$directory/warden-alert-login.sh" >"$work/login"
    chmod +x "$work/login"
    cat >"$work/alert" <<EOF
#!/bin/bash
echo "\$@" >>"$work/alert-calls"
EOF
    chmod +x "$work/alert"
}

wait_for_alerts() {
    for _ in $(seq 1 25); do
        [ "$(cat "$work/alert-calls" 2>/dev/null | wc -l)" -ge "$1" ] && return 0
        sleep 0.2
    done
    return 1
}

@test "a login alert carries the user and never the client address" {
    login_hook
    PAM_TYPE=open_session PAM_USER=admin PAM_RHOST=198.51.100.7 run "$work/login"
    [ "$status" -eq 0 ]
    wait_for_alerts 1
    grep -q 'admin logged in' "$work/alert-calls"
    ! grep -q '198.51.100.7' "$work/alert-calls"
}

@test "a repeat login from one address within a minute is one alert, another address and a closed session differ" {
    login_hook
    PAM_TYPE=close_session PAM_USER=admin PAM_RHOST=198.51.100.7 run "$work/login"
    PAM_TYPE=open_session PAM_USER=admin PAM_RHOST=198.51.100.7 run "$work/login"
    PAM_TYPE=open_session PAM_USER=admin PAM_RHOST=198.51.100.7 run "$work/login"
    wait_for_alerts 1
    sleep 0.5
    [ "$(wc -l <"$work/alert-calls")" -eq 1 ]

    PAM_TYPE=open_session PAM_USER=admin PAM_RHOST=203.0.113.9 run "$work/login"
    wait_for_alerts 2
}

@test "login stamps older than an hour are removed, recent ones stay" {
    login_hook
    mkdir -p "$work/stamp"
    touch -t 202001010000 "$work/stamp/login-old-0000"
    touch "$work/stamp/login-recent-0000"
    PAM_TYPE=open_session PAM_USER=admin PAM_RHOST=198.51.100.7 run "$work/login"
    [ ! -e "$work/stamp/login-old-0000" ]
    [ -e "$work/stamp/login-recent-0000" ]
    # The hook sends its alert in the background, teardown must not remove
    # the directory while it writes.
    wait_for_alerts 1
}

@test "variables set by the logging in user cannot redirect the hook" {
    login_hook
    printf '#!/bin/bash\necho hijacked >"%s/hijacked"\n' "$work" >"$work/evil"
    chmod +x "$work/evil"
    WARDEN_ALERT="$work/evil" WARDEN_STAMP_DIRECTORY="$work/elsewhere" WARDEN_CONFIGURATION_DIRECTORY="$work/elsewhere" \
        PAM_TYPE=open_session PAM_USER=admin PAM_RHOST=198.51.100.7 run "$work/login"
    wait_for_alerts 1
    [ ! -e "$work/hijacked" ]
    [ ! -e "$work/elsewhere" ]
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

@test "a threshold under 50 is ignored, as the configuration refuses it" {
    printf '#!/bin/bash\necho "$1" >>"$WORK/alert-calls"\n' >"$work/alert"
    printf 'Use%%\n 20%%\n' >"$work/df-output"
    printf '#!/bin/bash\ncat "$WORK/df-output"\n' >"$work/bin/df"
    printf '#!/bin/bash\n' >"$work/bin/systemctl"
    chmod +x "$work/alert" "$work/bin/df" "$work/bin/systemctl"
    export WARDEN_ALERT="$work/alert"
    echo "ALERT_DISK_PERCENT=10" >>"$WARDEN_CONFIGURATION_DIRECTORY/alerts.conf"
    run "$directory/warden-alert-check.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$work/alert-calls" ]
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

# A check run with every source stubbed, so each test sets only what it reads.
check_with() {
    cat >"$work/alert" <<'EOS'
#!/bin/bash
echo "$1 $2 $3" >>"$WORK/alert-calls"
EOS
    cat >"$work/bin/df" <<'EOS'
#!/bin/bash
printf 'Use%%\n 10%%\n'
EOS
    printf '#!/bin/bash\n' >"$work/bin/systemctl"
    printf '#!/bin/bash\necho 4\n' >"$work/bin/nproc"
    chmod +x "$work/alert" "$work/bin/df" "$work/bin/systemctl" "$work/bin/nproc"
    export WARDEN_ALERT="$work/alert"
    export WARDEN_PROC_DIRECTORY="$work/proc"
    mkdir -p "$work/proc"
    printf 'MemTotal: 1000 kB\nMemAvailable: %s kB\n' "${1:-500}" >"$work/proc/meminfo"
    echo "${2:-0.10} ${2:-0.10} ${2:-0.10} 1/100 1" >"$work/proc/loadavg"
}

@test "high memory alerts once and again when it recovers" {
    check_with 50
    run "$directory/warden-alert-check.sh"
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Memory almost full' "$work/alert-calls")" -eq 1 ]

    check_with 500
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Memory back' "$work/alert-calls")" -eq 1 ]
}

@test "memory is judged by what is available, a full cache is not an alert" {
    check_with 750
    # 80 percent is not free, 25 percent is cache that can be given back.
    printf 'MemTotal: 1000 kB\nMemFree: 50 kB\nMemAvailable: 750 kB\nCached: 700 kB\n' >"$work/proc/meminfo"
    run "$directory/warden-alert-check.sh"
    ! grep -q 'Memory' "$work/alert-calls" 2>/dev/null
}

@test "load alerts at twice the cores over 15 minutes, and not below" {
    check_with 500 7.99
    run "$directory/warden-alert-check.sh"
    ! grep -q 'Load high' "$work/alert-calls" 2>/dev/null

    check_with 500 8.00
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Load high' "$work/alert-calls")" -eq 1 ]

    check_with 500 0.5
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Load back' "$work/alert-calls")" -eq 1 ]
}

@test "full inodes alert on their own, with the disk space fine" {
    check_with
    cat >"$work/bin/df" <<'EOS'
#!/bin/bash
case "$*" in *ipcent*) printf 'IUse%%\n 97%%\n' ;; *) printf 'Use%%\n 10%%\n' ;; esac
EOS
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Inodes almost full' "$work/alert-calls")" -eq 1 ]
    ! grep -q 'Disk almost full' "$work/alert-calls"
}

@test "a clock out of sync alerts, an unknown answer does not" {
    check_with
    printf '#!/bin/bash\necho no\n' >"$work/bin/timedatectl"
    chmod +x "$work/bin/timedatectl"
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Clock out of sync' "$work/alert-calls")" -eq 1 ]

    rm -f "$work/alert-calls" "$work/state/clock-unsynchronised"
    printf '#!/bin/bash\nexit 1\n' >"$work/bin/timedatectl"
    run "$directory/warden-alert-check.sh"
    ! grep -q 'Clock' "$work/alert-calls" 2>/dev/null
}

# The container check asks Docker as the deploy user, so the tests stand in
# for the user lookup, runuser and timeout. The timeout stub only records the
# limit and can report that it was hit, a real wait would slow the suite.
containers_with() {
    check_with
    echo "DEPLOY_USER=deploy" >>"$WARDEN_CONFIGURATION_DIRECTORY/alerts.conf"
    printf '#!/bin/bash\n[ "$1" = -u ] && echo 1000 || exit 0\n' >"$work/bin/id"
    printf '#!/bin/bash\necho deploy:x:1000:1000::/home/deploy:/bin/bash\n' >"$work/bin/getent"
    printf '#!/bin/bash\necho "$@" >>"$WORK/runuser-arguments"\ncat "$WORK/containers"\nexit "${DOCKER_STATUS:-0}"\n' >"$work/bin/runuser"
    printf '#!/bin/bash\necho "$1" >>"$WORK/timeout-limits"\n[ -n "${TIMEOUT_HIT:-}" ] && exit 124\nshift\nexec "$@"\n' >"$work/bin/timeout"
    chmod +x "$work/bin/id" "$work/bin/getent" "$work/bin/runuser" "$work/bin/timeout"
}

@test "an unhealthy, restarting or crashed container alerts, a finished one does not" {
    containers_with
    printf '%s\n' 'web|Up 2 hours (unhealthy)' 'worker|Restarting (1) 5 seconds ago' \
        'job|Exited (137) 3 minutes ago' 'migrate|Exited (0) 3 minutes ago' 'db|Up 2 hours (healthy)' >"$work/containers"
    run "$directory/warden-alert-check.sh"
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Container unhealthy' "$work/alert-calls")" -eq 1 ]
    grep -q 'job web worker' "$work/alert-calls"
    ! grep -q 'migrate' "$work/alert-calls"

    printf '%s\n' 'web|Up 2 hours (healthy)' >"$work/containers"
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Containers healthy' "$work/alert-calls")" -eq 1 ]
}

@test "Docker is asked as the deploy user on its own socket, within a time limit" {
    containers_with
    : >"$work/containers"
    run "$directory/warden-alert-check.sh"
    grep -q -- '-u deploy -- env HOME=/home/deploy DOCKER_HOST=unix:///run/user/1000/docker.sock docker ps' "$work/runuser-arguments"
    [ "$(cat "$work/timeout-limits")" = 30 ]
}

@test "another container breaking while one is broken is a new alert" {
    containers_with
    printf '%s\n' 'web|Up 2 hours (unhealthy)' >"$work/containers"
    run "$directory/warden-alert-check.sh"
    printf '%s\n' 'web|Up 2 hours (unhealthy)' 'worker|Restarting (1) 5 seconds ago' >"$work/containers"
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Container unhealthy' "$work/alert-calls")" -eq 2 ]
    grep -q 'Container unhealthy .*web worker' "$work/alert-calls"
}

@test "a container name Docker would not allow never reaches the message" {
    containers_with
    printf '%s\n' 'web; all clear|Up 2 hours (unhealthy)' 'db|Restarting (1) 5 seconds ago' >"$work/containers"
    run "$directory/warden-alert-check.sh"
    grep -q 'Container unhealthy .*db' "$work/alert-calls"
    ! grep -q 'all clear' "$work/alert-calls"
}

@test "a Docker daemon that does not answer alerts once, not as healthy containers, and again when it is back" {
    containers_with
    printf '%s\n' 'web|Exited (1) 3 minutes ago' >"$work/containers"
    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Container unhealthy' "$work/alert-calls")" -eq 1 ]

    : >"$work/containers"
    DOCKER_STATUS=1 run "$directory/warden-alert-check.sh"
    DOCKER_STATUS=1 run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Docker not answering' "$work/alert-calls")" -eq 1 ]
    ! grep -q 'Containers healthy' "$work/alert-calls"

    run "$directory/warden-alert-check.sh"
    [ "$(grep -c 'Docker answering' "$work/alert-calls")" -eq 1 ]
}

@test "a Docker call that hits its time limit is a daemon that does not answer, and the later checks still run" {
    containers_with
    echo "nginx.service loaded failed failed Web server" >"$work/failed"
    printf '#!/bin/bash\ncat "$WORK/failed"\n' >"$work/bin/systemctl"
    TIMEOUT_HIT=1 run "$directory/warden-alert-check.sh"
    grep -q 'Docker not answering' "$work/alert-calls"
    grep -q 'Unit failed' "$work/alert-calls"
}

@test "containers are not asked about without a deploy user" {
    check_with
    printf '#!/bin/bash\ntouch "$WORK/asked"\n' >"$work/bin/runuser"
    chmod +x "$work/bin/runuser"
    run "$directory/warden-alert-check.sh"
    [ ! -e "$work/asked" ]
}

@test "a bad memory threshold falls back to 90 and the other alerts still run" {
    # Exactly 90 percent used, so only a fallback of 90 or less alerts.
    check_with 100
    echo "ALERT_MEMORY_PERCENT=abc" >>"$WARDEN_CONFIGURATION_DIRECTORY/alerts.conf"
    cat >"$work/bin/df" <<'EOS'
#!/bin/bash
printf 'Use%%\n 91%%\n'
EOS
    run "$directory/warden-alert-check.sh"
    grep -q 'Disk almost full' "$work/alert-calls"
    grep -q 'Memory almost full' "$work/alert-calls"
}
