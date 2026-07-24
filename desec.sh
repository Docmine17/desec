#!/bin/bash

# ==============================================================================
# Default Configuration
# ==============================================================================
CHECK_INTERVAL=20
CONFIG_DIR=""
RUNNING=true

# ==============================================================================
# Functions
# ==============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
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
        # Skip empty lines and comments
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue

        # Strip surrounding quotes and whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | sed 's/^["'\''"]*//;s/["'\''"]*$//' | xargs)

        case "$key" in
            TOKEN)     TOKEN="$value" ;;
            INTERFACE) INTERFACE="$value" ;;
            *)         log "Warning: Unknown key '$key' in $file" ;;
        esac
    done < "$file"
}

cleanup() {
    log "Signal received. Shutting down gracefully..."
    RUNNING=false
    # Kill background sleep if running
    [[ -n "$SLEEP_PID" ]] && kill "$SLEEP_PID" 2>/dev/null
}

trap cleanup SIGTERM SIGINT

update_ip() {
    local ZONE=$1
    local TOKEN=$2
    
    log "[$ZONE] Sending update..."
    
    # deSEC Update API (--connect-timeout handles unreachable server)
    response=$(curl -s -w "%{http_code}" --connect-timeout 10 -m 30 \
        -H "Authorization: Token $TOKEN" \
        "https://update6.dedyn.io/?hostname=$ZONE")
    
    local curl_exit=$?
    
    if [ $curl_exit -ne 0 ]; then
        log "[$ZONE] Error: Connection to deSEC failed (curl exit: $curl_exit)."
        return 1
    fi
    
    http_code=${response: -3}
    
    if [[ "$http_code" =~ 20[01] ]]; then
        log "[$ZONE] Success: Address updated (HTTP $http_code)."
        return 0
    else
        log "[$ZONE] Error: Update failed (HTTP $http_code). Response: ${response:0:-3}"
        return 1
    fi
}

# ==============================================================================
# Argument Parsing
# ==============================================================================

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --zone) CONFIG_DIR="$2"; shift ;;
        --interval) CHECK_INTERVAL="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter: $1"; usage ;;
    esac
    shift
done

# Default path if not specified
if [ -z "$CONFIG_DIR" ]; then
    SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
    CONFIG_DIR="$SCRIPT_DIR/zones"
fi

if [ ! -d "$CONFIG_DIR" ]; then
    log "Error: Configuration directory not found: $CONFIG_DIR"
    exit 1
fi

# ==============================================================================
# Main Execution
# ==============================================================================

log "Starting deSEC multi-zone script. Config dir: $CONFIG_DIR"

# State management for IP per interface (simplified for multi-zone)
declare -A previous_ips

while $RUNNING; do
  for zone_conf in "$CONFIG_DIR"/*.conf; do
    $RUNNING || break
    [ -e "$zone_conf" ] || { log "No .conf files found in $CONFIG_DIR"; break; }
    
    # Load zone configuration (safe parsing, no source)
    ZONE_NAME=$(basename "$zone_conf" .conf)
    parse_config "$zone_conf"
    
    # Validation
    if [ -z "$TOKEN" ] || [ -z "$INTERFACE" ]; then
        log "[$ZONE_NAME] Skip: Missing TOKEN or INTERFACE in $zone_conf"
        continue
    fi

    # Extracts the dynamic IPv6 address from the interface
    current_ip=$(ip -6 addr show dev "$INTERFACE" dynamic 2>/dev/null | awk '/inet6/ {print $2; exit}')
    
    if [ -n "$current_ip" ]; then
        # Check if IP changed for THIS zone
        if [ "$current_ip" != "${previous_ips[$ZONE_NAME]}" ]; then
            log "[$ZONE_NAME] IP change detected on $INTERFACE ($current_ip). Updating..."
            if update_ip "$ZONE_NAME" "$TOKEN"; then
                previous_ips[$ZONE_NAME]="$current_ip"
            fi
            # Rate limiting: avoid flooding the deSEC API
            sleep 1
        fi
    else
        log "[$ZONE_NAME] Warning: No valid IP found on interface $INTERFACE."
    fi
  done
  
  # Interruptible sleep: allows immediate response to signals
  sleep "$CHECK_INTERVAL" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
done

log "Stopped."
