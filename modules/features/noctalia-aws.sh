#!/usr/bin/env bash

# --- CONFIGURATION ---
INSTANCE_ID="i-07f875a0b9cf40d98" # Replace with your AWS Instance ID
REGION="ap-southeast-1"               # Replace with your AWS Region
STATE_FILE="/tmp/noctalia_aws_state"
# ---------------------

get_status() {
    # Query AWS for the current state code and name
    status_info=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" \
        --query "Reservations[0].Instances[0].State.[Code,Name]" \
        --output text 2>/dev/null)
    
    echo "$status_info"

    if [ -z "$status_info" ]; then
        echo "UNKNOWN" > "$STATE_FILE"
        echo "󰔜" # Icon for offline/error
        return
    fi

    read -r _ name <<< "$status_info"
    echo "$name" > "$STATE_FILE"

    # Map states to Nerd Font icons
    case "$name" in
        "running")    echo "󰐊" ;; # Play/Running icon
        "stopped")    echo "󰓛" ;; # Stop/Stopped icon
        "pending")    echo "󱖐" ;; # Spinning/Pending icon
        "stopping")   echo "󱎫" ;; # Hourglass/Stopping icon
        *)            echo "󰔜" ;;
    esac
}

toggle_state() {
    current_state=$(cat "$STATE_FILE" 2>/dev/null || echo "stopped")

    case "$current_state" in
        "stopped")
            notify-send "AWS Box" "Starting developer box..." -i network-server
            aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null &
            ;;
        "running")
            notify-send "AWS Box" "Stopping developer box..." -i network-server
            aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" >/dev/null &
            ;;
        *)
            notify-send "AWS Box" "Instance is currently $current_state. Please wait." -i dialog-warning
            ;;
    esac
}

case "${1:-}" in
    "toggle") toggle_state ;;
    *) get_status ;;
esac
