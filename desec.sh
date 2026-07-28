#!/bin/bash

CHECK_INTERVAL=20
CONFIG_DIR=""
RUNNING=true

log() {
    echo "$1"
}

usage() {
    echo "Usage: $0 [--zone /path/to/zones/] [--interval SECONDS]"
    echo "  --zone:     Directory containing .conf files for each zone."
    echo "              Default: <script_dir>/zones/"
    echo "  --interval: Check interval in seconds (default: $CHECK_INTERVAL)."
    exit 1
}

parse_config() {
    local file=$1
    TOKEN=""
    INTERFACE=""

    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue

        key=$(echo "$key" | xargs)
        value=$(echo "$value" | sed 's/^["'\''\"]*//;s/["'\''\"]*$//' | xargs)

        case "$key" in
            TOKEN)     TOKEN="$value" ;;
            INTERFACE) INTERFACE="$value" ;;
            *)         log "Warning: Unknown key '$key' in $file" ;;
        esac
    done < "$file"
}

update_ip() {
    local ZONE=$1
    local TOKEN=$2

    log "[$ZONE] Sending update..."

    response=$(curl -s -w "%{http_code}" --connect-timeout 10 -m 30 \
        -H "Authorization: Token $TOKEN" \
        "https://update6.dedyn.io/?hostname=$ZONE")

    local curl_exit=$?

    if [ $curl_exit -ne 0 ]; then
        log "[$ZONE] Error: Connection to deSEC failed (curl exit: $curl_exit)."
        return 1
    fi

    local http_code=${response: -3}

    if [[ "$http_code" =~ 20[01] ]]; then
        log "[$ZONE] Success: Address updated (HTTP $http_code)."
        return 0
    else
        log "[$ZONE] Error: Update failed (HTTP $http_code). Response: ${response:0:-3}"
        return 1
    fi
}

cleanup() {
    log "Signal received. Shutting down gracefully..."
    RUNNING=false
    [[ -n "$SLEEP_PID" ]] && kill "$SLEEP_PID" 2>/dev/null
}

trap cleanup SIGTERM SIGINT

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --zone) CONFIG_DIR="$2"; shift ;;
        --interval) CHECK_INTERVAL="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter: $1"; usage ;;
    esac
    shift
done

if [ -z "$CONFIG_DIR" ]; then
    SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
    CONFIG_DIR="$SCRIPT_DIR/zones"
fi

if [ ! -d "$CONFIG_DIR" ]; then
    log "Error: Configuration directory not found: $CONFIG_DIR"
    exit 1
fi

log "Starting deSEC multi-zone script. Config dir: $CONFIG_DIR"

declare -A previous_ips

while $RUNNING; do
    for zone_conf in "$CONFIG_DIR"/*.conf; do
        $RUNNING || break
        [ -e "$zone_conf" ] || { log "No .conf files found in $CONFIG_DIR"; break; }

        ZONE_NAME=$(basename "$zone_conf" .conf)
        parse_config "$zone_conf"

        if [ -z "$TOKEN" ] || [ -z "$INTERFACE" ]; then
            log "[$ZONE_NAME] Skip: Missing TOKEN or INTERFACE in $zone_conf"
            continue
        fi

        current_ip=$(awk -v iface="$INTERFACE" '
            $6 == iface && $4 == "00" && $5 == "00" && $1 ~ /^[23]/ {
                addr = $1; gsub(/..../, "&:", addr); sub(/:$/, "", addr)
                print addr; exit
            }
        ' /proc/net/if_inet6)

        if [ -n "$current_ip" ]; then
            if [ "$current_ip" != "${previous_ips[$ZONE_NAME]}" ]; then
                log "[$ZONE_NAME] IP change detected on $INTERFACE ($current_ip). Updating..."
                if update_ip "$ZONE_NAME" "$TOKEN"; then
                    previous_ips[$ZONE_NAME]="$current_ip"
                fi
                sleep 1
            fi
        else
            log "[$ZONE_NAME] Warning: No valid IP found on interface $INTERFACE."
        fi
    done

    sleep "$CHECK_INTERVAL" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
done

log "Stopped."
