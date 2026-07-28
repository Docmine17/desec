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
    IP_TYPE="any"

    while read -r iface tok type _; do
        [[ -z "$iface" || "$iface" =~ ^[[:space:]]*# ]] && continue

        INTERFACE="$iface"
        TOKEN="$tok"
        [[ -n "$type" ]] && IP_TYPE="$type"
        break
    done < "$file"
}

update_ip() {
    local ZONE=$1
    local TOKEN=$2
    local IP=$3

    log "[$ZONE] Sending update ($IP)..."

    response=$(curl -s -w "%{http_code}" --connect-timeout 10 -m 30 \
        -H "Authorization: Token $TOKEN" \
        "https://update6.dedyn.io/?hostname=$ZONE&myip=$IP")

    local curl_exit=$?

    if [ $curl_exit -ne 0 ]; then
        log "[$ZONE] Error: Connection to deSEC failed (curl exit: $curl_exit)."
        return 1
    fi

    local http_code=${response: -3}

    if [[ "$http_code" =~ 20[01] ]]; then
        log "[$ZONE] Success: Address updated (HTTP $http_code)."
        return 0
    elif [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        log "[$ZONE] Critical Error: Authentication failed (HTTP $http_code). Please verify your TOKEN."
        return 2
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
        --zone)
            if [[ -z "$2" || "$2" =~ ^-- ]]; then
                log "Error: Option --zone requires a valid directory argument."
                usage
            fi
            CONFIG_DIR="$2"
            shift
            ;;
        --interval)
            if [[ -z "$2" || ! "$2" =~ ^[0-9]+$ || "$2" -le 0 ]]; then
                log "Error: Option --interval requires a positive integer."
                usage
            fi
            CHECK_INTERVAL="$2"
            shift
            ;;
        -h|--help) usage ;;
        *) log "Unknown parameter: $1"; usage ;;
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

        current_ip=$(awk -v iface="$INTERFACE" -v mode="$IP_TYPE" '
            $6 == iface && $4 == "00" && $1 ~ /^[23]/ {
                if (mode == "temporary" && $5 != "01") next
                if (mode == "stable" && $5 !~ /^(00|80)$/) next
                if (mode == "any" && $5 !~ /^(00|01|80)$/) next

                addr = $1; gsub(/..../, "&:", addr); sub(/:$/, "", addr)
                print addr; exit
            }
        ' /proc/net/if_inet6)

        if [ -n "$current_ip" ]; then
            if [ "$current_ip" != "${previous_ips[$ZONE_NAME]}" ]; then
                log "[$ZONE_NAME] IP change detected on $INTERFACE ($current_ip). Updating..."
                update_ip "$ZONE_NAME" "$TOKEN" "$current_ip"
                update_res=$?
                if [ $update_res -eq 0 ]; then
                    previous_ips[$ZONE_NAME]="$current_ip"
                elif [ $update_res -eq 2 ]; then
                    previous_ips[$ZONE_NAME]="$current_ip"
                    log "[$ZONE_NAME] Suppressing retries until IP changes or TOKEN is fixed."
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
