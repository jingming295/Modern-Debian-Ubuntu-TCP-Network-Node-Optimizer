#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Modern Debian / Ubuntu TCP & Network Node Optimizer
#
# Designed for:
#   - CDN / OpenResty / Nginx
#   - Proxy / Xray / V2Ray / VLESS / Trojan / sing-box
#   - VPN / routing nodes
#   - High-BDP long-haul TCP links
#
# Features:
#   - Command-line arguments
#   - Interactive fallback
#   - Idempotent configuration
#   - Debian / Ubuntu support
#   - BBR + fq
#   - BDP-based TCP socket sizing
#   - Optional initcwnd/initrwnd
#   - Per-service systemd NOFILE limits
#
###############################################################################

SCRIPT_NAME="${0##*/}"
VERSION="1.1.1"

SYSCTL_FILE="/etc/sysctl.d/90-network-node-performance.conf"
MODULES_FILE="/etc/modules-load.d/90-network-node-performance.conf"

STATE_DIR="/var/lib/network-node-optimizer"
STATE_SERVICES="${STATE_DIR}/services.list"

ROUTE_HELPER="/usr/local/sbin/network-node-route-tune"
ROUTE_UNIT="/etc/systemd/system/network-node-route-tune.service"

NOFILE_DROPIN="90-network-node-nofile.conf"

###############################################################################
# Logging
###############################################################################

log() {
    printf '[+] %s\n' "$*"
}

warn() {
    printf '[!] %s\n' "$*" >&2
}

die() {
    printf '[x] %s\n' "$*" >&2
    exit 1
}

###############################################################################
# Help
###############################################################################

usage() {
    cat <<EOF
Usage:

  sudo ${SCRIPT_NAME} [options]

Options:

  --profile cdn|proxy|vpn|mixed

  --bandwidth-gbps N
      Target TCP throughput in Gbit/s.

  --rtt-ms N
      Target RTT in milliseconds.

  --interface auto|IFACE
      Long-haul/default egress interface.

  --forwarding keep|off|ipv4|dual
      keep  = do not change forwarding
      off   = disable IPv4 and IPv6 forwarding
      ipv4  = enable IPv4 forwarding only
      dual  = enable IPv4 and IPv6 forwarding

  --init-cwnd N
      0      = keep Linux default
      10-256 = explicitly set initcwnd/initrwnd

  --nofile N
      Per-service systemd LimitNOFILE.

  --services LIST
      Comma-separated systemd services.

      Examples:
        openresty
        nginx
        xray
        openresty,xray
        none

  --restart-services yes|no
      Restart affected services if their configuration changes.

  --install-tools yes|no
      Install and enable:
        vnstat
        ethtool
        irqbalance

  -h, --help
      Show this help.

Examples:

  CDN node:

  sudo ./${SCRIPT_NAME} \\
      --profile cdn \\
      --bandwidth-gbps 3 \\
      --rtt-ms 300 \\
      --interface auto \\
      --forwarding off \\
      --init-cwnd 16 \\
      --nofile 1048576 \\
      --services openresty \\
      --restart-services no \\
      --install-tools yes

  Proxy node:

  sudo ./${SCRIPT_NAME} \\
      --profile proxy \\
      --bandwidth-gbps 3 \\
      --rtt-ms 300 \\
      --interface auto \\
      --forwarding keep \\
      --init-cwnd 0 \\
      --nofile 1048576 \\
      --services xray \\
      --restart-services no \\
      --install-tools yes

If an option is omitted, the script asks interactively.
EOF
}

###############################################################################
# Helpers
###############################################################################

ask_default() {
    local prompt="$1"
    local default="$2"
    local reply=""

    [[ -r /dev/tty ]] ||
        die "A required parameter is missing and no interactive TTY is available."

    IFS= read -r \
        -p "${prompt} [${default}]: " \
        reply \
        </dev/tty ||
        die "Failed to read from terminal."

    printf '%s\n' "${reply:-$default}"
}

is_positive_number() {
    local value="$1"

    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
        return 1

    awk \
        -v n="$value" \
        'BEGIN { exit !(n > 0) }'
}

normalize_yes_no() {
    case "${1,,}" in

        y|yes|true|1)
            printf 'yes\n'
            ;;

        n|no|false|0)
            printf 'no\n'
            ;;

        *)
            return 1
            ;;
    esac
}

unit_exists() {
    local unit="${1%.service}"

    systemctl cat \
        "${unit}.service" \
        >/dev/null 2>&1
}

###############################################################################
# Write a managed file only if the content changed
###############################################################################

write_if_changed() {
    local path="$1"
    local mode="${2:-0644}"

    local dir
    local tmp

    dir="$(dirname "$path")"

    install \
        -d \
        -m 0755 \
        "$dir"

    tmp="$(
        mktemp \
            "${dir}/.${SCRIPT_NAME}.XXXXXX"
    )"

    cat >"$tmp"

    chmod "$mode" "$tmp"

    if [[ -f "$path" ]] &&
       cmp -s "$tmp" "$path"
    then

        rm -f "$tmp"

        return 1
    fi

    install \
        -o root \
        -g root \
        -m "$mode" \
        "$tmp" \
        "$path"

    rm -f "$tmp"

    return 0
}

###############################################################################
# Parameters
###############################################################################

PROFILE=""
BANDWIDTH_GBPS=""
RTT_MS=""
IFACE_ARG=""
FORWARDING=""
INIT_CWND=""
NOFILE=""
SERVICES_RAW=""
RESTART_SERVICES=""
INSTALL_TOOLS=""

###############################################################################
# Parse arguments
###############################################################################

while (($# > 0)); do

    case "$1" in

        --profile)

            (($# >= 2)) ||
                die "--profile requires a value"

            PROFILE="$2"

            shift 2
            ;;

        --profile=*)

            PROFILE="${1#*=}"

            shift
            ;;

        --bandwidth-gbps)

            (($# >= 2)) ||
                die "--bandwidth-gbps requires a value"

            BANDWIDTH_GBPS="$2"

            shift 2
            ;;

        --bandwidth-gbps=*)

            BANDWIDTH_GBPS="${1#*=}"

            shift
            ;;

        --rtt-ms)

            (($# >= 2)) ||
                die "--rtt-ms requires a value"

            RTT_MS="$2"

            shift 2
            ;;

        --rtt-ms=*)

            RTT_MS="${1#*=}"

            shift
            ;;

        --interface)

            (($# >= 2)) ||
                die "--interface requires a value"

            IFACE_ARG="$2"

            shift 2
            ;;

        --interface=*)

            IFACE_ARG="${1#*=}"

            shift
            ;;

        --forwarding)

            (($# >= 2)) ||
                die "--forwarding requires a value"

            FORWARDING="$2"

            shift 2
            ;;

        --forwarding=*)

            FORWARDING="${1#*=}"

            shift
            ;;

        --init-cwnd)

            (($# >= 2)) ||
                die "--init-cwnd requires a value"

            INIT_CWND="$2"

            shift 2
            ;;

        --init-cwnd=*)

            INIT_CWND="${1#*=}"

            shift
            ;;

        --nofile)

            (($# >= 2)) ||
                die "--nofile requires a value"

            NOFILE="$2"

            shift 2
            ;;

        --nofile=*)

            NOFILE="${1#*=}"

            shift
            ;;

        --services)

            (($# >= 2)) ||
                die "--services requires a value"

            SERVICES_RAW="$2"

            shift 2
            ;;

        --services=*)

            SERVICES_RAW="${1#*=}"

            shift
            ;;

        --restart-services)

            (($# >= 2)) ||
                die "--restart-services requires a value"

            RESTART_SERVICES="$2"

            shift 2
            ;;

        --restart-services=*)

            RESTART_SERVICES="${1#*=}"

            shift
            ;;

        --install-tools)

            (($# >= 2)) ||
                die "--install-tools requires a value"

            INSTALL_TOOLS="$2"

            shift 2
            ;;

        --install-tools=*)

            INSTALL_TOOLS="${1#*=}"

            shift
            ;;

        -h|--help)

            usage

            exit 0
            ;;

        *)

            die "Unknown argument: $1"

            ;;
    esac
done

###############################################################################
# Root check
###############################################################################

(( EUID == 0 )) ||
    die "Run this script as root."

###############################################################################
# OS check
###############################################################################

[[ -r /etc/os-release ]] ||
    die "/etc/os-release not found."

# shellcheck disable=SC1091
. /etc/os-release

case "${ID:-}" in

    debian|ubuntu)
        ;;

    *)
        die "Only Debian and Ubuntu are supported. Detected: ${ID:-unknown}"
        ;;
esac

###############################################################################
# systemd check
###############################################################################

[[ -d /run/systemd/system ]] ||
    die "systemd is not running."

###############################################################################
# Required commands
###############################################################################

REQUIRED_COMMANDS=(
    awk
    cmp
    dirname
    grep
    install
    ip
    mktemp
    modprobe
    nproc
    sed
    sort
    sysctl
    systemctl
    tc
    uname
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do

    command -v "$cmd" >/dev/null 2>&1 ||
        die "Required command not found: $cmd"

done

###############################################################################
# Gather profile
###############################################################################

while :; do

    [[ -n "$PROFILE" ]] ||
        PROFILE="$(
            ask_default \
                "Node profile (cdn/proxy/vpn/mixed)" \
                "cdn"
        )"

    PROFILE="${PROFILE,,}"

    case "$PROFILE" in

        cdn|proxy|vpn|mixed)
            break
            ;;

        *)

            warn "Invalid profile: $PROFILE"

            PROFILE=""
            ;;
    esac
done

###############################################################################
# Gather bandwidth
###############################################################################

while :; do

    [[ -n "$BANDWIDTH_GBPS" ]] ||
        BANDWIDTH_GBPS="$(
            ask_default \
                "Target TCP throughput in Gbit/s" \
                "3"
        )"

    if is_positive_number "$BANDWIDTH_GBPS"; then
        break
    fi

    warn "Bandwidth must be a positive number."

    BANDWIDTH_GBPS=""
done

###############################################################################
# Gather RTT
###############################################################################

while :; do

    [[ -n "$RTT_MS" ]] ||
        RTT_MS="$(
            ask_default \
                "Target RTT in milliseconds" \
                "300"
        )"

    if is_positive_number "$RTT_MS"; then
        break
    fi

    warn "RTT must be a positive number."

    RTT_MS=""
done

###############################################################################
# Interface
###############################################################################

[[ -n "$IFACE_ARG" ]] ||
    IFACE_ARG="$(
        ask_default \
            "Long-haul egress interface" \
            "auto"
    )"

###############################################################################
# Forwarding
###############################################################################

while :; do

    [[ -n "$FORWARDING" ]] ||
        FORWARDING="$(
            ask_default \
                "IP forwarding (keep/off/ipv4/dual)" \
                "keep"
        )"

    FORWARDING="${FORWARDING,,}"

    case "$FORWARDING" in

        keep|off|ipv4|dual)
            break
            ;;

        *)

            warn "Invalid forwarding mode: $FORWARDING"

            FORWARDING=""
            ;;
    esac
done

###############################################################################
# Initial congestion window
###############################################################################

while :; do

    [[ -n "$INIT_CWND" ]] ||
        INIT_CWND="$(
            ask_default \
                "Initial cwnd (0 = kernel default)" \
                "0"
        )"

    if [[ "$INIT_CWND" =~ ^[0-9]+$ ]] &&
       (( INIT_CWND == 0 ||
          (INIT_CWND >= 10 && INIT_CWND <= 256) ))
    then
        break
    fi

    warn "init-cwnd must be 0 or an integer between 10 and 256."

    INIT_CWND=""
done

###############################################################################
# NOFILE
###############################################################################

while :; do

    [[ -n "$NOFILE" ]] ||
        NOFILE="$(
            ask_default \
                "Per-service open-file limit" \
                "1048576"
        )"

    if [[ "$NOFILE" =~ ^[0-9]+$ ]] &&
       (( NOFILE >= 65536 &&
          NOFILE <= 1048576 ))
    then
        break
    fi

    warn "nofile must be between 65536 and 1048576."

    NOFILE=""
done

###############################################################################
# Detect services
###############################################################################

detect_services() {

    local -a candidates=()
    local -a found=()

    local unit

    case "$PROFILE" in

        cdn)

            candidates=(
                openresty
                nginx
            )
            ;;

        proxy|vpn)

            candidates=(
                xray
                v2ray
                sing-box
                trojan
                trojan-go
            )
            ;;

        mixed)

            candidates=(
                openresty
                nginx
                xray
                v2ray
                sing-box
                trojan
                trojan-go
            )
            ;;
    esac

    for unit in "${candidates[@]}"; do

        if unit_exists "$unit"; then
            found+=("$unit")
        fi

    done

    if ((${#found[@]} == 0)); then

        printf 'none\n'

    else

        local IFS=,

        printf '%s\n' "${found[*]}"

    fi
}

DETECTED_SERVICES="$(detect_services)"

[[ -n "$SERVICES_RAW" ]] ||
    SERVICES_RAW="$(
        ask_default \
            "systemd services for high NOFILE, comma-separated" \
            "$DETECTED_SERVICES"
    )"

###############################################################################
# Install tools
###############################################################################

while :; do

    [[ -n "$INSTALL_TOOLS" ]] ||
        INSTALL_TOOLS="$(
            ask_default \
                "Install/enable vnstat, ethtool and irqbalance (yes/no)" \
                "yes"
        )"

    if INSTALL_TOOLS="$(
        normalize_yes_no "$INSTALL_TOOLS"
    )"
    then
        break
    fi

    warn "Please answer yes or no."

    INSTALL_TOOLS=""
done

###############################################################################
# Restart services
###############################################################################

if [[ "${SERVICES_RAW,,}" == "none" ]]; then

    RESTART_SERVICES="no"

else

    while :; do

        [[ -n "$RESTART_SERVICES" ]] ||
            RESTART_SERVICES="$(
                ask_default \
                    "Restart selected services if configuration changed (yes/no)" \
                    "no"
            )"

        if RESTART_SERVICES="$(
            normalize_yes_no "$RESTART_SERVICES"
        )"
        then
            break
        fi

        warn "Please answer yes or no."

        RESTART_SERVICES=""
    done

fi

###############################################################################
# Detect network interface
###############################################################################

if [[ "${IFACE_ARG,,}" == "auto" ]]; then

    IFACE="$(
        ip -4 route show default 2>/dev/null |
            awk \
                '{
                    for (i = 1; i <= NF; i++)
                        if ($i == "dev") {
                            print $(i + 1)
                            exit
                        }
                }'
    )"

    if [[ -z "$IFACE" ]]; then

        IFACE="$(
            ip -6 route show default 2>/dev/null |
                awk \
                    '{
                        for (i = 1; i <= NF; i++)
                            if ($i == "dev") {
                                print $(i + 1)
                                exit
                            }
                    }'
        )"

    fi

    [[ -n "$IFACE" ]] ||
        die "Could not determine the default-route interface."

else

    IFACE="$IFACE_ARG"

fi

###############################################################################
# Validate interface
###############################################################################

[[ "$IFACE" =~ ^[A-Za-z0-9_.:@-]+$ ]] ||
    die "Invalid interface name: $IFACE"

[[ -d "/sys/class/net/${IFACE}" ]] ||
    die "Network interface does not exist: $IFACE"

###############################################################################
# Parse service list
###############################################################################

declare -a SERVICE_UNITS=()

declare -A SERVICE_SEEN=()

declare -A SERVICE_CHANGED=()

if [[ "${SERVICES_RAW,,}" != "none" ]]; then

    services_text="${SERVICES_RAW//,/ }"

    read -r -a requested_units <<<"$services_text"

    for unit in "${requested_units[@]}"; do

        unit="${unit%.service}"

        [[ -n "$unit" ]] ||
            continue

        [[ "$unit" =~ ^[A-Za-z0-9_.@-]+$ ]] ||
            die "Invalid systemd unit name: $unit"

        unit_exists "$unit" ||
            die "systemd service not found: ${unit}.service"

        if [[ -z "${SERVICE_SEEN[$unit]+x}" ]]; then

            SERVICE_SEEN["$unit"]=1

            SERVICE_UNITS+=("$unit")

        fi
    done

fi

###############################################################################
# Calculate BDP
#
# BDP:
#
# bandwidth(bits/sec) * RTT(seconds) / 8
#
# Example:
#
# 1 Gbit/s * 0.300 sec / 8
# = 37,500,000 bytes
# = 35.76 MiB
#
###############################################################################

BDP_BYTES="$(
    awk \
        -v gbps="$BANDWIDTH_GBPS" \
        -v ms="$RTT_MS" \
        'BEGIN { printf "%.0f", (gbps * 1000000000 / 8) * (ms / 1000) }'
)"

###############################################################################
# Calculate maximum TCP socket buffer
#
# Use approximately 2 x BDP.
###############################################################################

TARGET_BUFFER_BYTES=$((BDP_BYTES * 2))

MIN_BUFFER_BYTES=$((64 * 1024 * 1024))

BUFFER_STEP=$((16 * 1024 * 1024))

MAX_BUFFER_CAP=$((1024 * 1024 * 1024))

###############################################################################
# Minimum 64 MiB
###############################################################################

if (( TARGET_BUFFER_BYTES < MIN_BUFFER_BYTES )); then

    TARGET_BUFFER_BYTES=$MIN_BUFFER_BYTES

fi

###############################################################################
# Round upward to nearest 16 MiB
###############################################################################

SOCKET_MAX=$(( \
    ((TARGET_BUFFER_BYTES + BUFFER_STEP - 1) / BUFFER_STEP) \
    * BUFFER_STEP \
))

###############################################################################
# Maximum 1 GiB safety limit
###############################################################################

if (( SOCKET_MAX > MAX_BUFFER_CAP )); then

    SOCKET_MAX=$MAX_BUFFER_CAP

fi

if (( TARGET_BUFFER_BYTES > MAX_BUFFER_CAP )); then

    warn "Calculated 2x BDP exceeds the 1 GiB global buffer safety cap."

    warn "The script will use a maximum of 1 GiB."

fi

###############################################################################
# Human-readable values
###############################################################################

BDP_MIB="$(
    awk \
        -v n="$BDP_BYTES" \
        'BEGIN { printf "%.1f", n / 1048576 }'
)"

SOCKET_MAX_MIB="$(
    awk \
        -v n="$SOCKET_MAX" \
        'BEGIN { printf "%.0f", n / 1048576 }'
)"

###############################################################################
# Summary
###############################################################################

printf '\n'

log "OS: ${PRETTY_NAME:-$ID}"

log "Kernel: $(uname -r)"

log "Profile: $PROFILE"

log "Interface: $IFACE"

log "Target: ${BANDWIDTH_GBPS} Gbit/s at ${RTT_MS} ms RTT"

log "Calculated BDP: ${BDP_MIB} MiB"

log "TCP socket buffer ceiling: ${SOCKET_MAX_MIB} MiB"

log "Forwarding mode: $FORWARDING"

log "Initial cwnd: $INIT_CWND"

log "Per-service NOFILE: $NOFILE"

###############################################################################
# BBR support
###############################################################################

modprobe tcp_bbr >/dev/null 2>&1 ||
    true

modprobe sch_fq >/dev/null 2>&1 ||
    true

AVAILABLE_CC="$(
    sysctl \
        -n \
        net.ipv4.tcp_available_congestion_control \
        2>/dev/null ||
        true
)"

grep -qw bbr <<<"$AVAILABLE_CC" ||
    die \
        "BBR is unavailable. Available congestion controls: ${AVAILABLE_CC:-unknown}"

###############################################################################
# Install optional tools
###############################################################################

if [[ "$INSTALL_TOOLS" == "yes" ]]; then

    command -v apt-get >/dev/null 2>&1 ||
        die "apt-get not found."

    command -v dpkg-query >/dev/null 2>&1 ||
        die "dpkg-query not found."

    declare -a missing_pkgs=()

    for pkg in \
        vnstat \
        ethtool \
        irqbalance
    do

        if ! dpkg-query \
            -W \
            -f='${Status}' \
            "$pkg" \
            2>/dev/null |
            grep -q '^install ok installed$'
        then

            missing_pkgs+=("$pkg")

        fi

    done

    if ((${#missing_pkgs[@]} > 0)); then

        log "Installing packages: ${missing_pkgs[*]}"

        export DEBIAN_FRONTEND=noninteractive

        apt-get update

        apt-get install \
            -y \
            --no-install-recommends \
            "${missing_pkgs[@]}"

    fi

    if unit_exists vnstat; then

        systemctl \
            enable \
            --now \
            vnstat.service \
            >/dev/null

    fi

    if (( $(nproc) > 1 )) &&
       unit_exists irqbalance
    then

        systemctl \
            enable \
            --now \
            irqbalance.service \
            >/dev/null

    fi

fi

###############################################################################
# Persist BBR modules
###############################################################################

if write_if_changed \
    "$MODULES_FILE" \
    0644 \
    <<'EOF'
# Managed by network-node-optimizer.
tcp_bbr
sch_fq
EOF
then

    log "Updated ${MODULES_FILE}"

fi

###############################################################################
# Generate sysctl configuration
###############################################################################

SYSCTL_TMP="$(mktemp)"

cat >"$SYSCTL_TMP" <<EOF
# Managed by network-node-optimizer ${VERSION}.
#
# Do not manually edit this file.
# Re-run the optimizer instead.

###############################################################################
# Congestion control and pacing
###############################################################################

net.core.default_qdisc = fq

net.ipv4.tcp_congestion_control = bbr

###############################################################################
# High-BDP TCP socket buffers
#
# Maximum values are calculated dynamically according to requested
# bandwidth and RTT.
###############################################################################

net.core.rmem_max = ${SOCKET_MAX}

net.core.wmem_max = ${SOCKET_MAX}

net.ipv4.tcp_rmem = 4096 131072 ${SOCKET_MAX}

net.ipv4.tcp_wmem = 4096 16384 ${SOCKET_MAX}

net.ipv4.tcp_moderate_rcvbuf = 1

net.ipv4.tcp_window_scaling = 1

###############################################################################
# Packet-loss recovery
###############################################################################

net.ipv4.tcp_sack = 1

net.ipv4.tcp_dsack = 1

###############################################################################
# Path MTU handling
###############################################################################

net.ipv4.tcp_mtu_probing = 1

###############################################################################
# SYN flood protection
###############################################################################

net.ipv4.tcp_syncookies = 1

###############################################################################
# Busy CDN / proxy listener queues
###############################################################################

net.core.somaxconn = 65535

net.ipv4.tcp_max_syn_backlog = 65536

###############################################################################
# Kernel receive backlog
###############################################################################

net.core.netdev_max_backlog = 32768

###############################################################################
# TCP Fast Open
###############################################################################

net.ipv4.tcp_fastopen = 3

###############################################################################
# Ephemeral source port range
###############################################################################

net.ipv4.ip_local_port_range = 1024 65535
EOF

###############################################################################
# Forwarding configuration
###############################################################################

case "$FORWARDING" in

    keep)
        ;;

    off)

        cat >>"$SYSCTL_TMP" <<'EOF'

###############################################################################
# IP forwarding
###############################################################################

net.ipv4.ip_forward = 0

net.ipv6.conf.all.forwarding = 0

net.ipv6.conf.default.forwarding = 0
EOF
        ;;

    ipv4)

        cat >>"$SYSCTL_TMP" <<'EOF'

###############################################################################
# IP forwarding
###############################################################################

net.ipv4.ip_forward = 1

net.ipv6.conf.all.forwarding = 0

net.ipv6.conf.default.forwarding = 0
EOF
        ;;

    dual)

        cat >>"$SYSCTL_TMP" <<'EOF'

###############################################################################
# IP forwarding
###############################################################################

net.ipv4.ip_forward = 1

net.ipv6.conf.all.forwarding = 1

net.ipv6.conf.default.forwarding = 1
EOF
        ;;

esac

###############################################################################
# Ensure fs.nr_open is large enough
###############################################################################

CURRENT_NR_OPEN="$(
    sysctl \
        -n \
        fs.nr_open \
        2>/dev/null ||
        printf '1048576'
)"

if [[ "$CURRENT_NR_OPEN" =~ ^[0-9]+$ ]] &&
   (( CURRENT_NR_OPEN < NOFILE ))
then

    cat >>"$SYSCTL_TMP" <<EOF

###############################################################################
# Maximum number of file descriptors per process
###############################################################################

fs.nr_open = ${NOFILE}
EOF

fi

###############################################################################
# Install sysctl configuration
###############################################################################

if write_if_changed \
    "$SYSCTL_FILE" \
    0644 \
    <"$SYSCTL_TMP"
then

    log "Updated ${SYSCTL_FILE}"

fi

rm -f "$SYSCTL_TMP"

###############################################################################
# Apply sysctl
###############################################################################

log "Applying network sysctl settings."

sysctl \
    -p \
    "$SYSCTL_FILE" \
    >/dev/null

###############################################################################
# systemd NOFILE configuration
###############################################################################

install \
    -d \
    -m 0755 \
    "$STATE_DIR"

SYSTEMD_CHANGED=0

###############################################################################
# Remove stale service drop-ins
###############################################################################

if [[ -f "$STATE_SERVICES" ]]; then

    while IFS= read -r old_unit; do

        [[ -n "$old_unit" ]] ||
            continue

        [[ "$old_unit" =~ ^[A-Za-z0-9_.@-]+$ ]] ||
            continue

        if [[ -z "${SERVICE_SEEN[$old_unit]+x}" ]]; then

            old_dir="/etc/systemd/system/${old_unit}.service.d"

            old_file="${old_dir}/${NOFILE_DROPIN}"

            if [[ -f "$old_file" ]]; then

                rm -f "$old_file"

                SYSTEMD_CHANGED=1

                log \
                    "Removed stale NOFILE configuration for ${old_unit}.service"

            fi

            rmdir "$old_dir" \
                2>/dev/null ||
                true

        fi

    done <"$STATE_SERVICES"

fi

###############################################################################
# Create service NOFILE drop-ins
###############################################################################

for unit in "${SERVICE_UNITS[@]}"; do

    dropin_dir="/etc/systemd/system/${unit}.service.d"

    dropin_file="${dropin_dir}/${NOFILE_DROPIN}"

    install \
        -d \
        -m 0755 \
        "$dropin_dir"

    if write_if_changed \
        "$dropin_file" \
        0644 \
        <<EOF
[Service]
LimitNOFILE=${NOFILE}
EOF
    then

        SERVICE_CHANGED["$unit"]=1

        SYSTEMD_CHANGED=1

        log \
            "Updated NOFILE configuration for ${unit}.service"

    else

        SERVICE_CHANGED["$unit"]=0

    fi

done

###############################################################################
# Save service state
###############################################################################

SERVICE_STATE_TMP="$(mktemp)"

if ((${#SERVICE_UNITS[@]} > 0)); then

    printf \
        '%s\n' \
        "${SERVICE_UNITS[@]}" |
        sort \
            -u \
            >"$SERVICE_STATE_TMP"

else

    : >"$SERVICE_STATE_TMP"

fi

write_if_changed \
    "$STATE_SERVICES" \
    0644 \
    <"$SERVICE_STATE_TMP" ||
    true

rm -f "$SERVICE_STATE_TMP"

###############################################################################
# Initial cwnd / rwnd route helper
###############################################################################

if (( INIT_CWND > 0 )); then

    if write_if_changed \
        "$ROUTE_HELPER" \
        0755 \
        <<EOF
#!/usr/bin/env bash

set -Eeuo pipefail

IFACE="${IFACE}"

CWND="${INIT_CWND}"

apply_family() {

    local family="\$1"

    local line
    local token

    local i

    local -a raw_args
    local -a route_args

    while IFS= read -r line; do

        [[ -n "\$line" ]] ||
            continue

        read -r -a raw_args <<<"\$line"

        route_args=()

        i=0

        while (( i < \${#raw_args[@]} )); do

            token="\${raw_args[\$i]}"

            case "\$token" in

                initcwnd|initrwnd)

                    i=\$((i + 2))

                    ;;

                *)

                    route_args+=("\$token")

                    i=\$((i + 1))

                    ;;

            esac

        done

        ip \
            "\$family" \
            route \
            change \
            "\${route_args[@]}" \
            initcwnd "\$CWND" \
            initrwnd "\$CWND"

    done < <(
        ip \
            "\$family" \
            route \
            show \
            table main \
            default \
            dev "\$IFACE" \
            2>/dev/null ||
            true
    )

}

apply_family -4

apply_family -6
EOF
    then

        SYSTEMD_CHANGED=1

        log "Updated ${ROUTE_HELPER}"

    fi

    if write_if_changed \
        "$ROUTE_UNIT" \
        0644 \
        <<EOF
[Unit]
Description=TCP Initial Congestion Window Tuning
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${ROUTE_HELPER}

[Install]
WantedBy=multi-user.target
EOF
    then

        SYSTEMD_CHANGED=1

        log "Updated ${ROUTE_UNIT}"

    fi

else

    if [[ -f "$ROUTE_UNIT" ]]; then

        systemctl \
            disable \
            network-node-route-tune.service \
            >/dev/null 2>&1 ||
            true

        rm -f "$ROUTE_UNIT"

        SYSTEMD_CHANGED=1

    fi

    rm -f "$ROUTE_HELPER"

fi

###############################################################################
# Reload systemd
###############################################################################

if (( SYSTEMD_CHANGED == 1 )); then

    systemctl daemon-reload

fi

###############################################################################
# Enable and apply initcwnd
###############################################################################

if (( INIT_CWND > 0 )); then

    systemctl \
        enable \
        network-node-route-tune.service \
        >/dev/null

    log \
        "Applying initcwnd/initrwnd=${INIT_CWND}"

    "$ROUTE_HELPER"

fi

###############################################################################
# Restart affected services when requested
###############################################################################

if ((${#SERVICE_UNITS[@]} > 0)); then

    for unit in "${SERVICE_UNITS[@]}"; do

        changed="${SERVICE_CHANGED[$unit]:-0}"

        if (( changed == 1 )); then

            if [[ "$RESTART_SERVICES" == "yes" ]]; then

                if systemctl \
                    is-active \
                    --quiet \
                    "${unit}.service"
                then

                    log \
                        "Restarting ${unit}.service"

                    systemctl \
                        restart \
                        "${unit}.service"

                else

                    warn \
                        "${unit}.service is not active; it was not started automatically."

                fi

            else

                if systemctl \
                    is-active \
                    --quiet \
                    "${unit}.service"
                then

                    warn \
                        "${unit}.service is running. Restart it later to apply the new LimitNOFILE."

                fi

            fi

        fi

    done

fi

###############################################################################
# Apply fq to current interface when safe
###############################################################################

apply_fq_live() {

    local root_kind=""

    local kind=""

    local parent=""

    local changed=0

    root_kind="$(
        tc \
            qdisc \
            show \
            dev "$IFACE" \
            2>/dev/null |
            awk \
                '$4 == "root" {
                    print $2
                    exit
                }'
    )"

    case "$root_kind" in

        fq)
            ;;

        mq)

            while read -r kind parent; do

                [[ -n "$kind" &&
                   -n "$parent" ]] ||
                    continue

                case "$kind" in

                    fq)
                        ;;

                    fq_codel|pfifo_fast|pfifo|bfifo)

                        if tc \
                            qdisc \
                            replace \
                            dev "$IFACE" \
                            parent "$parent" \
                            fq \
                            2>/dev/null
                        then

                            changed=1

                        else

                            warn \
                                "Could not replace qdisc under ${parent} with fq."

                        fi
                        ;;

                    *)

                        warn \
                            "Leaving custom leaf qdisc '${kind}' on ${IFACE} unchanged."

                        ;;

                esac

            done < <(
                tc \
                    qdisc \
                    show \
                    dev "$IFACE" \
                    2>/dev/null |
                    awk \
                        '$4 == "parent" && $5 ~ /^:/ {
                            print $2, $5
                        }'
            )

            ;;

        fq_codel|pfifo_fast|pfifo|bfifo)

            if tc \
                qdisc \
                replace \
                dev "$IFACE" \
                root \
                fq \
                2>/dev/null
            then

                changed=1

            else

                warn \
                    "Could not replace root qdisc with fq on ${IFACE}."

            fi

            ;;

        noqueue|"")

            warn \
                "${IFACE} has no replaceable root qdisc. net.core.default_qdisc=fq remains configured."

            ;;

        *)

            warn \
                "Leaving custom root qdisc '${root_kind}' on ${IFACE} unchanged."

            ;;

    esac

    if (( changed == 1 )); then

        log \
            "Applied fq to the existing qdisc hierarchy on ${IFACE}."

    fi
}

apply_fq_live

###############################################################################
# Detect TuneD conflicts
###############################################################################

if command -v tuned-adm >/dev/null 2>&1; then

    TUNED_ACTIVE="$(
        tuned-adm \
            active \
            2>/dev/null ||
            true
    )"

    if [[ -n "$TUNED_ACTIVE" &&
          "$TUNED_ACTIVE" != *"No current active profile"* ]]
    then

        warn "TuneD appears to be active:"

        warn "$TUNED_ACTIVE"

        warn \
            "Verify that TuneD does not override these sysctl/qdisc settings."

    fi

fi

###############################################################################
# Verification output
###############################################################################

printf '\n'

printf '============================================================\n'

printf ' Network optimization completed\n'

printf '============================================================\n'

printf '\n'

printf 'Configuration:\n'

printf \
    '  Profile:               %s\n' \
    "$PROFILE"

printf \
    '  Interface:             %s\n' \
    "$IFACE"

printf \
    '  Target bandwidth:      %s Gbit/s\n' \
    "$BANDWIDTH_GBPS"

printf \
    '  Target RTT:            %s ms\n' \
    "$RTT_MS"

printf \
    '  Calculated BDP:        %s MiB\n' \
    "$BDP_MIB"

printf \
    '  TCP buffer maximum:    %s MiB\n' \
    "$SOCKET_MAX_MIB"

printf \
    '  initcwnd/initrwnd:     %s\n' \
    "$INIT_CWND"

printf \
    '  Forwarding:            %s\n' \
    "$FORWARDING"

###############################################################################
# TCP state
###############################################################################

printf '\n'

printf 'TCP state:\n'

printf \
    '  Congestion control:   %s\n' \
    "$(
        sysctl \
            -n \
            net.ipv4.tcp_congestion_control
    )"

printf \
    '  Default qdisc:        %s\n' \
    "$(
        sysctl \
            -n \
            net.core.default_qdisc
    )"

printf \
    '  tcp_rmem:             %s\n' \
    "$(
        sysctl \
            -n \
            net.ipv4.tcp_rmem
    )"

printf \
    '  tcp_wmem:             %s\n' \
    "$(
        sysctl \
            -n \
            net.ipv4.tcp_wmem
    )"

printf \
    '  rmem_max:             %s\n' \
    "$(
        sysctl \
            -n \
            net.core.rmem_max
    )"

printf \
    '  wmem_max:             %s\n' \
    "$(
        sysctl \
            -n \
            net.core.wmem_max
    )"

printf \
    '  somaxconn:            %s\n' \
    "$(
        sysctl \
            -n \
            net.core.somaxconn
    )"

printf \
    '  SYN backlog:          %s\n' \
    "$(
        sysctl \
            -n \
            net.ipv4.tcp_max_syn_backlog
    )"

###############################################################################
# qdisc state
###############################################################################

printf '\n'

printf \
    'Current qdisc on %s:\n' \
    "$IFACE"

tc \
    qdisc \
    show \
    dev "$IFACE" |
    sed 's/^/  /'

###############################################################################
# Route state
###############################################################################

if (( INIT_CWND > 0 )); then

    printf '\n'

    printf \
        'Default route TCP initial-window settings:\n'

    ip \
        -4 \
        route \
        show \
        default \
        dev "$IFACE" \
        2>/dev/null |
        sed 's/^/  IPv4: /' ||
        true

    ip \
        -6 \
        route \
        show \
        default \
        dev "$IFACE" \
        2>/dev/null |
        sed 's/^/  IPv6: /' ||
        true

fi

###############################################################################
# Service limits
###############################################################################

if ((${#SERVICE_UNITS[@]} > 0)); then

    printf '\n'

    printf \
        'systemd service NOFILE limits:\n'

    for unit in "${SERVICE_UNITS[@]}"; do

        limit="$(
            systemctl \
                show \
                "${unit}.service" \
                -p LimitNOFILE \
                --value \
                2>/dev/null ||
                printf 'unknown'
        )"

        printf \
            '  %-28s %s\n' \
            "${unit}.service" \
            "$limit"

    done

fi

###############################################################################
# Useful diagnostic commands
###############################################################################

printf '\n'

printf 'Useful verification commands:\n'

printf '\n'

printf \
    '  ss -tin\n'

printf '\n'

printf \
    '  tc qdisc show dev %s\n' \
    "$IFACE"

printf '\n'

printf \
    '  ip -s link show dev %s\n' \
    "$IFACE"

printf '\n'

printf \
    '  cat /proc/net/softnet_stat\n'

printf '\n'

if command -v ethtool >/dev/null 2>&1; then

    printf \
        '  ethtool -k %s\n' \
        "$IFACE"

    printf '\n'

    printf \
        '  ethtool -S %s\n' \
        "$IFACE"

    printf '\n'

    printf \
        '  ethtool -l %s\n' \
        "$IFACE"

    printf '\n'

fi

printf '============================================================\n'
