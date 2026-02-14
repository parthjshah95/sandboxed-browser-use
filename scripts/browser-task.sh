#!/usr/bin/env bash
# =============================================================================
# browser-task.sh — Orchestrator wrapper for the Ephemeral Browser Agent
#
# Usage:
#   browser-task.sh run   <instruction> [options]
#   browser-task.sh status <task-id>
#   browser-task.sh result <task-id>
#   browser-task.sh cleanup <task-id>
#   browser-task.sh list
#
# Options (for "run"):
#   --url <url>                Starting URL for the browser
#   --max-steps <n>            Maximum agent steps (default: 50)
#   --timeout <seconds>        Task timeout in seconds (default: 600)
#   --llm-key <key>            LLM API key (or set via env var)
#   --llm-provider <provider>  anthropic | gemini | openai (default: auto-detect)
#   --env <KEY=VALUE>          Extra env var to pass to the container (repeatable)
#   --wait                     Block until the task completes
#   --poll-interval <seconds>  Seconds between polls when --wait (default: 5)
#   --image <image>            Docker image (default: medfinder/browser-agent:latest)
#   --memory <limit>           Memory limit (default: 2g)
#   --cpus <n>                 CPU limit (default: 1)
#
# Examples:
#   browser-task.sh run "Search for 'OpenAI GPT-5' on Google and return the top 3 results" --wait
#   browser-task.sh run "Log in and download the report" --url https://app.example.com --env "USER=foo" --env "PASS=bar"
#   browser-task.sh status abc123
#   browser-task.sh result abc123
#   browser-task.sh cleanup abc123
#   browser-task.sh list
# =============================================================================
set -euo pipefail

# ---- Defaults ---------------------------------------------------------------
IMAGE="medfinder/browser-agent:latest"
TASKS_BASE_DIR="/tmp/browser-tasks"
MAX_STEPS=50
TIMEOUT_SECONDS=600
MEMORY_LIMIT="2g"
CPU_LIMIT="1"
POLL_INTERVAL=5
WAIT=false
START_URL=""
LLM_KEY=""
LLM_PROVIDER=""
EXTRA_ENVS=()

# ---- Colours ----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color

# ---- Helpers ----------------------------------------------------------------
log()  { echo -e "${CYAN}[browser-task]${NC} $*"; }
warn() { echo -e "${YELLOW}[browser-task]${NC} $*" >&2; }
err()  { echo -e "${RED}[browser-task]${NC} $*" >&2; exit 1; }
ok()   { echo -e "${GREEN}[browser-task]${NC} $*"; }

generate_id() {
    # Use uuidgen if available, fall back to /proc/sys/kernel/random/uuid or date-based
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        date +%s%N | sha256sum | head -c 32
    fi
}

usage() {
    head -30 "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

# ---- Command: run -----------------------------------------------------------
cmd_run() {
    if [[ $# -lt 1 ]]; then
        err "Usage: browser-task.sh run <instruction> [options]"
    fi

    local instruction="$1"
    shift

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)           START_URL="$2"; shift 2 ;;
            --max-steps)     MAX_STEPS="$2"; shift 2 ;;
            --timeout)       TIMEOUT_SECONDS="$2"; shift 2 ;;
            --llm-key)       LLM_KEY="$2"; shift 2 ;;
            --llm-provider)  LLM_PROVIDER="$2"; shift 2 ;;
            --env)           EXTRA_ENVS+=("$2"); shift 2 ;;
            --wait)          WAIT=true; shift ;;
            --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
            --image)         IMAGE="$2"; shift 2 ;;
            --memory)        MEMORY_LIMIT="$2"; shift 2 ;;
            --cpus)          CPU_LIMIT="$2"; shift 2 ;;
            *)               err "Unknown option: $1" ;;
        esac
    done

    # Generate task ID
    local task_id
    task_id=$(generate_id)
    local task_dir="${TASKS_BASE_DIR}/${task_id}"

    # Create task directory
    mkdir -p "$task_dir"

    # Write task.json
    local task_json
    task_json=$(cat <<EOF
{
  "instruction": $(printf '%s' "$instruction" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
  "url": $(if [[ -n "$START_URL" ]]; then printf '%s' "$START_URL" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'; else echo 'null'; fi),
  "max_steps": ${MAX_STEPS},
  "timeout_seconds": ${TIMEOUT_SECONDS}
}
EOF
)
    echo "$task_json" > "${task_dir}/task.json"
    log "Task ID: ${task_id}"
    log "Task dir: ${task_dir}"

    # Build docker run arguments
    local docker_args=(
        "run" "-d"
        "--name" "browser-${task_id}"
        "--network=bridge"
        "--memory=${MEMORY_LIMIT}"
        "--cpus=${CPU_LIMIT}"
        "-v" "${task_dir}:/task"
    )

    # Add LLM key
    if [[ -n "$LLM_KEY" ]]; then
        case "$LLM_PROVIDER" in
            anthropic) docker_args+=("-e" "ANTHROPIC_API_KEY=${LLM_KEY}") ;;
            gemini)    docker_args+=("-e" "GEMINI_API_KEY=${LLM_KEY}") ;;
            openai)    docker_args+=("-e" "OPENAI_API_KEY=${LLM_KEY}") ;;
            *)
                # Auto-detect by key prefix
                if [[ "$LLM_KEY" == sk-ant-* ]]; then
                    docker_args+=("-e" "ANTHROPIC_API_KEY=${LLM_KEY}")
                elif [[ "$LLM_KEY" == sk-* ]]; then
                    docker_args+=("-e" "OPENAI_API_KEY=${LLM_KEY}")
                else
                    docker_args+=("-e" "GEMINI_API_KEY=${LLM_KEY}")
                fi
                ;;
        esac
    else
        # Pass through any LLM key from host environment
        [[ -n "${ANTHROPIC_API_KEY:-}" ]] && docker_args+=("-e" "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
        [[ -n "${GEMINI_API_KEY:-}" ]]    && docker_args+=("-e" "GEMINI_API_KEY=${GEMINI_API_KEY}")
        [[ -n "${OPENAI_API_KEY:-}" ]]    && docker_args+=("-e" "OPENAI_API_KEY=${OPENAI_API_KEY}")
    fi

    # Add extra environment variables
    for env_var in "${EXTRA_ENVS[@]+"${EXTRA_ENVS[@]}"}"; do
        docker_args+=("-e" "$env_var")
    done

    # Add image
    docker_args+=("$IMAGE")

    # Launch container
    log "Launching container..."
    local container_id
    container_id=$(docker "${docker_args[@]}")
    ok "Container started: browser-${task_id}"
    echo ""
    echo "  Task ID:    ${task_id}"
    echo "  Container:  browser-${task_id}"
    echo "  Task dir:   ${task_dir}"
    echo ""

    # Optionally wait for completion
    if [[ "$WAIT" == true ]]; then
        cmd_wait "$task_id"
    else
        log "Use 'browser-task.sh status ${task_id}' to check progress"
        log "Use 'browser-task.sh result ${task_id}' to get results"
        log "Use 'browser-task.sh cleanup ${task_id}' to clean up"
    fi

    echo "$task_id"
}

# ---- Command: wait ----------------------------------------------------------
cmd_wait() {
    local task_id="$1"
    local task_dir="${TASKS_BASE_DIR}/${task_id}"
    local container_name="browser-${task_id}"

    log "Waiting for task ${task_id} to complete (poll interval: ${POLL_INTERVAL}s)..."

    while true; do
        # Check if container is still running
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || echo "removed")

        if [[ "$status" == "exited" || "$status" == "removed" ]]; then
            break
        fi

        # Show status if available
        if [[ -f "${task_dir}/status.json" ]]; then
            local state step max_s
            state=$(python3 -c "import json; d=json.load(open('${task_dir}/status.json')); print(d.get('state','unknown'))" 2>/dev/null || echo "unknown")
            step=$(python3 -c "import json; d=json.load(open('${task_dir}/status.json')); print(d.get('step',0))" 2>/dev/null || echo "?")
            max_s=$(python3 -c "import json; d=json.load(open('${task_dir}/status.json')); print(d.get('max_steps',0))" 2>/dev/null || echo "?")
            log "Status: ${state} — step ${step}/${max_s}"
        fi

        sleep "$POLL_INTERVAL"
    done

    # Show result
    ok "Task completed."
    cmd_result "$task_id"
}

# ---- Command: status --------------------------------------------------------
cmd_status() {
    local task_id="$1"
    local task_dir="${TASKS_BASE_DIR}/${task_id}"
    local container_name="browser-${task_id}"

    if [[ ! -d "$task_dir" ]]; then
        err "Task directory not found: ${task_dir}"
    fi

    echo "=== Container Status ==="
    docker inspect --format='Status: {{.State.Status}} | Started: {{.State.StartedAt}}' "$container_name" 2>/dev/null || echo "Container not found (may have been cleaned up)"

    echo ""
    echo "=== Agent Status ==="
    if [[ -f "${task_dir}/status.json" ]]; then
        python3 -m json.tool "${task_dir}/status.json"
    else
        echo "No status.json yet (agent may still be initialising)"
    fi
}

# ---- Command: result --------------------------------------------------------
cmd_result() {
    local task_id="$1"
    local task_dir="${TASKS_BASE_DIR}/${task_id}"

    if [[ ! -d "$task_dir" ]]; then
        err "Task directory not found: ${task_dir}"
    fi

    if [[ -f "${task_dir}/result.json" ]]; then
        echo "=== Task Result ==="
        python3 -m json.tool "${task_dir}/result.json"
    else
        warn "No result.json yet — task may still be running."
        cmd_status "$task_id"
    fi
}

# ---- Command: cleanup -------------------------------------------------------
cmd_cleanup() {
    local task_id="$1"
    local task_dir="${TASKS_BASE_DIR}/${task_id}"
    local container_name="browser-${task_id}"

    log "Cleaning up task ${task_id}..."

    # Remove container
    docker rm -f "$container_name" 2>/dev/null && log "Container removed." || log "Container already removed."

    # Remove task directory
    if [[ -d "$task_dir" ]]; then
        rm -rf "$task_dir"
        log "Task directory removed: ${task_dir}"
    fi

    ok "Cleanup complete for ${task_id}"
}

# ---- Command: list ----------------------------------------------------------
cmd_list() {
    echo "=== Running Browser Containers ==="
    docker ps --filter "name=browser-" --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}" 2>/dev/null || echo "No running containers."

    echo ""
    echo "=== Task Directories ==="
    if [[ -d "$TASKS_BASE_DIR" ]]; then
        for dir in "${TASKS_BASE_DIR}"/*/; do
            if [[ -d "$dir" ]]; then
                local tid
                tid=$(basename "$dir")
                local state="unknown"
                if [[ -f "${dir}result.json" ]]; then
                    state=$(python3 -c "import json; d=json.load(open('${dir}result.json')); print(d.get('status','unknown'))" 2>/dev/null || echo "unknown")
                elif [[ -f "${dir}status.json" ]]; then
                    state=$(python3 -c "import json; d=json.load(open('${dir}status.json')); print(d.get('state','unknown'))" 2>/dev/null || echo "unknown")
                fi
                echo "  ${tid}  [${state}]"
            fi
        done
    else
        echo "  No tasks found."
    fi
}

# ---- Main dispatcher --------------------------------------------------------
if [[ $# -lt 1 ]]; then
    usage
fi

COMMAND="$1"
shift

case "$COMMAND" in
    run)     cmd_run "$@" ;;
    status)  cmd_status "$@" ;;
    result)  cmd_result "$@" ;;
    cleanup) cmd_cleanup "$@" ;;
    list)    cmd_list ;;
    wait)    cmd_wait "$@" ;;
    help)    usage ;;
    *)       err "Unknown command: ${COMMAND}. Use 'help' for usage." ;;
esac
