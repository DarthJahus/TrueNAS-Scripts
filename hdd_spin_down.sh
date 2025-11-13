#!/bin/bash

TMPDIR="/root/scripts/tmp"
mkdir -p "$TMPDIR"

LOGFILE="$TMPDIR/$(basename $0 .sh).log"

THRESHOLD="${1:-300}"  # 5 by default. For production, increase or use parameter
DISK_GROUPS_STR="${2:-"sda sdc sdd;sdb;sde"}"

IFS=';' read -ra DISK_GROUPS <<< "$DISK_GROUPS_STR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

log "===== Starting HDD spin down script ====="
log "Threshold: $THRESHOLD seconds"
log "Disk groups:"
for group in "${DISK_GROUPS[@]}"; do
    log "  - $group"
done

read_io() {
    local disk=$1
    if [ ! -b "/dev/$disk" ]; then
        log "WARNING: Disk /dev/$disk does not exist!"
        return 1
    fi
    awk '{print $1+$5}' /sys/block/${disk}/stat
}

for group in "${DISK_GROUPS[@]}"; do
    read -ra disks <<< "$group"
    valid_disks=()

    for d in "${disks[@]}"; do
        if [ -b "/dev/$d" ]; then
            valid_disks+=("$d")
        else
            log "Skipping non-existent disk: $d"
        fi
    done

    if [ ${#valid_disks[@]} -eq 0 ]; then
        log "No valid disks in group, skipping..."
        continue
    fi

    log "Checking group: ${valid_disks[*]}"

    disks_idle_ok=()
    for d in "${valid_disks[@]}"; do
        disk_statfile="$TMPDIR/${d}_io"

        io=$(read_io "$d")
        if [ $? -ne 0 ]; then
            continue
        fi

        prev=$(cat "$disk_statfile" 2>/dev/null || echo 0)
        log "Disk $d: current IO=$io, previous IO=$prev"

        if [ "$io" -ne "$prev" ]; then
            log "Disk $d has activity. Resetting idle."
            echo "$io" > "$disk_statfile"
            continue
        fi

        ts=$(stat -c %Y "$disk_statfile" 2>/dev/null || echo 0)
        idle=$(( $(date +%s) - ts ))
        log "Disk $d idle time: $idle s"

        if [ "$idle" -gt $THRESHOLD ]; then
            state=$(/usr/sbin/hdparm -C /dev/$d 2>/dev/null | awk '/drive state/ {print $NF}')
            if [ "$state" != "standby" ]; then
                disks_idle_ok+=("$d")
            else
                log "Disk $d already in STANDBY. Skipping."
            fi
        fi
    done

    if [ ${#disks_idle_ok[@]} -gt 0 ]; then
        cmd="/usr/sbin/hdparm -y $(printf '/dev/%s ' "${disks_idle_ok[@]}")"
        log "All idle disks > $THRESHOLD s. Running: $cmd"
        $cmd >>"$LOGFILE" 2>&1
        log "Spin down command sent for ${disks_idle_ok[*]}."

        for d in "${disks_idle_ok[@]}"; do
            disk_statfile="$TMPDIR/${d}_io"
            echo "$(read_io "$d")" > "$disk_statfile" 2>/dev/null
        done
    else
        log "At least one disk is ACTIVE or already in STANDBY. No spin down."
    fi
done

log "Script execution finished."