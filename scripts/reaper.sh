#!/usr/bin/env bash
# =============================================================================
# reaper.sh — Container Reaper for Ephemeral Browser Agents
#
# Kills browser agent containers that have been running for more than 1 hour,
# and removes exited browser containers.
#
# Install as a cron job (hourly):
#   echo "0 * * * * /path/to/reaper.sh >> /var/log/browser-reaper.log 2>&1" | crontab -
#
# Or run manually:
#   ./reaper.sh
#   ./reaper.sh --max-age 1800   # custom max age in seconds (30 min)
#   ./reaper.sh --dry-run         # show what would be reaped without doing it
# =============================================================================
set -euo pipefail

MAX_AGE=3600   # 1 hour in seconds
DRY_RUN=false
TASKS_BASE_DIR="/tmp/browser-tasks"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-age)   MAX_AGE="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        *)           echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
}

reaped=0

# ---- Reap running containers older than MAX_AGE ----------------------------
log "Checking for browser containers older than ${MAX_AGE}s..."

for cid in $(docker ps -q --filter "name=browser-" --filter "status=running" 2>/dev/null); do
    started=$(docker inspect --format='{{.State.StartedAt}}' "$cid" 2>/dev/null)
    if [[ -z "$started" ]]; then
        continue
    fi

    started_epoch=$(date -d "$started" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    age=$(( now_epoch - started_epoch ))

    container_name=$(docker inspect --format='{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')

    if [[ "$age" -gt "$MAX_AGE" ]]; then
        log "Reaping container ${container_name} (${cid:0:12}) — age: ${age}s (limit: ${MAX_AGE}s)"
        if [[ "$DRY_RUN" == false ]]; then
            docker rm -f "$cid" 2>/dev/null && log "  Removed." || log "  Failed to remove."
            ((reaped++))
        else
            log "  [DRY RUN] Would remove."
        fi
    else
        log "Container ${container_name} (${cid:0:12}) — age: ${age}s — OK"
    fi
done

# ---- Clean up exited browser containers ------------------------------------
log "Cleaning up exited browser containers..."

exited_containers=$(docker ps -aq --filter "name=browser-" --filter "status=exited" 2>/dev/null || true)
if [[ -n "$exited_containers" ]]; then
    for cid in $exited_containers; do
        container_name=$(docker inspect --format='{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
        log "Removing exited container ${container_name} (${cid:0:12})"
        if [[ "$DRY_RUN" == false ]]; then
            docker rm "$cid" 2>/dev/null && log "  Removed." || log "  Failed to remove."
            ((reaped++))
        else
            log "  [DRY RUN] Would remove."
        fi
    done
else
    log "No exited browser containers found."
fi

# ---- Clean up orphaned task directories (older than 2 hours) ----------------
log "Checking for orphaned task directories..."

if [[ -d "$TASKS_BASE_DIR" ]]; then
    now_epoch=$(date +%s)
    for dir in "${TASKS_BASE_DIR}"/*/; do
        if [[ ! -d "$dir" ]]; then
            continue
        fi

        task_id=$(basename "$dir")
        container_name="browser-${task_id}"

        # Check if container exists
        container_exists=$(docker ps -aq --filter "name=${container_name}" 2>/dev/null || true)

        if [[ -z "$container_exists" ]]; then
            # Container doesn't exist — check directory age
            dir_age=$(( now_epoch - $(stat -c %Y "$dir" 2>/dev/null || echo "$now_epoch") ))
            if [[ "$dir_age" -gt $(( MAX_AGE * 2 )) ]]; then
                log "Removing orphaned task directory: ${dir} (age: ${dir_age}s)"
                if [[ "$DRY_RUN" == false ]]; then
                    rm -rf "$dir"
                    log "  Removed."
                else
                    log "  [DRY RUN] Would remove."
                fi
            fi
        fi
    done
fi

log "Reaper complete. Reaped ${reaped} container(s)."
