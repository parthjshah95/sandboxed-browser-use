# PRD: Ephemeral Browser Agent (Sandboxed)

**Author:** Codebot ⚡  
**Date:** 2026-02-14  
**Status:** Draft  

---

## Problem

We need agents (e.g. openclaw) to perform web browsing tasks — filling forms, scraping data, interacting with authenticated web apps — without exposing host secrets to prompt injection attacks embedded in web page content.

**Threat model:** A malicious website could inject instructions into visible page text that trick the browsing agent into exfiltrating credentials, API keys, or private data it has access to.

## Solution

An **ephemeral Docker container** running [browser-use](https://github.com/browser-use/browser-use) that:
- Receives a task + only the credentials needed for that task
- Executes the browser automation
- Reports results back via a mounted volume
- Self-destructs on completion (or is reaped by a cron job after 1 hour max)

No persistent state survives container teardown. Credentials exist only for the lifetime of the task.

---

## Architecture

```
┌──────────────────────┐          docker run           ┌─────────────────────────-┐
│   Orchestrator Agent │  ───────────────────────────► │  Ephemeral Container     │
│   (e.g. openclaw)    │   • task.json (mounted)       │                          │
│                      │   • creds via env vars        │  browser-use + chromium  │
│   • No browser access│   • result volume mount       │  Python 3.12             │
│   • Full secrets     │                               │                          │
│   • Reads results    │  ◄──────────────────────────  │  • Reads task.json       │
│     from mount       │   • writes result.json        │  • Runs browser agent    │
│   • Cleans up        │   • container exits           │  • Writes result.json    │
└──────────────────────┘                               │  • Exits (self-destruct) │
                                                       └─────────────────────────-┘

         ┌───────────-───┐
         │ Cron (hourly) │  docker rm --force containers older than 1hr
         └──────────-────┘
```

### Isolation Boundaries

| Resource | Container can access | Container cannot access |
|----------|---------------------|------------------------|
| Credentials | Only env vars passed at `docker run` | Host env vars, openclaw.json, other agent workspaces |
| Filesystem | Mounted `/task` volume only | Host filesystem |
| Network | Internet (outbound only) | Localhost, Tailscale, host services |
| LLM API | Its own API key (passed as env) | Other API keys |
| Duration | Max 1 hour (enforced by reaper) | N/A |

---

## Container Design

### Dockerfile

```dockerfile
FROM python:3.12-slim

# Install browser-use + chromium
RUN pip install uv && \
    uv venv --python 3.12 && \
    . .venv/bin/activate && \
    uv pip install browser-use && \
    uvx browser-use install

# Working directory
WORKDIR /app

# Copy entrypoint
COPY entrypoint.py /app/entrypoint.py

# Task mount point
VOLUME /task

# Entrypoint
ENTRYPOINT ["/app/.venv/bin/python", "/app/entrypoint.py"]
```

### Image: `medfinder/browser-agent:latest`

Built once, stored locally. Rebuild only when upgrading browser-use.

### Entrypoint (`entrypoint.py`)

```python
"""
Ephemeral browser agent entrypoint.

Reads task from /task/task.json, executes browser-use agent,
writes results to /task/result.json, then exits.

Environment variables:
  ANTHROPIC_API_KEY or GEMINI_API_KEY — LLM for browser-use
  (any task-specific credentials passed at docker run)

/task/task.json schema:
{
  "instruction": "string — what to do",
  "url": "string — starting URL (optional)",
  "max_steps": 50,
  "timeout_seconds": 600
}

/task/result.json schema:
{
  "status": "success" | "error" | "timeout",
  "output": "string — extracted data / task result",
  "steps_taken": 12,
  "error": "string — if status is error",
  "screenshots": ["base64 strings — final state (optional)"]
}

/task/status.json — written periodically for external polling:
{
  "state": "running" | "completed" | "error",
  "step": 5,
  "max_steps": 50,
  "current_url": "https://...",
  "updated_at": "ISO timestamp"
}
"""

import asyncio
import json
import os
import sys
import signal
import traceback
from datetime import datetime, timezone
from pathlib import Path

TASK_DIR = Path("/task")

def write_status(state, step=0, max_steps=0, url=""):
    status = {
        "state": state,
        "step": step,
        "max_steps": max_steps,
        "current_url": url,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    (TASK_DIR / "status.json").write_text(json.dumps(status, indent=2))

def write_result(status, output="", steps=0, error=None):
    result = {
        "status": status,
        "output": output,
        "steps_taken": steps,
        "error": error,
    }
    (TASK_DIR / "result.json").write_text(json.dumps(result, indent=2))

async def run():
    # Read task
    task_file = TASK_DIR / "task.json"
    if not task_file.exists():
        write_result("error", error="No task.json found in /task")
        return

    task = json.loads(task_file.read_text())
    instruction = task.get("instruction", "")
    start_url = task.get("url")
    max_steps = task.get("max_steps", 50)
    timeout = task.get("timeout_seconds", 600)

    if not instruction:
        write_result("error", error="Empty instruction in task.json")
        return

    write_status("running", 0, max_steps)

    try:
        # Import browser-use
        from browser_use import Agent, Browser, BrowserConfig
        # Use whichever LLM key is available
        if os.environ.get("ANTHROPIC_API_KEY"):
            from browser_use import ChatAnthropic
            llm = ChatAnthropic(model="claude-sonnet-4-0", temperature=0.0)
        elif os.environ.get("GEMINI_API_KEY"):
            from browser_use import ChatGoogle
            llm = ChatGoogle(model="gemini-flash-latest")
        elif os.environ.get("OPENAI_API_KEY"):
            from browser_use import ChatOpenAI
            llm = ChatOpenAI(model="gpt-4.1-mini")
        else:
            write_result("error", error="No LLM API key provided")
            return

        # Configure headless browser
        browser = Browser(config=BrowserConfig(headless=True))

        # Build agent
        agent = Agent(
            task=instruction,
            llm=llm,
            browser=browser,
        )

        # Run with timeout
        history = await asyncio.wait_for(
            agent.run(max_steps=max_steps),
            timeout=timeout,
        )

        # Extract result
        final_result = history.final_result() if hasattr(history, 'final_result') else str(history)
        steps = history.number_of_steps() if hasattr(history, 'number_of_steps') else 0

        write_result("success", output=str(final_result), steps=steps)
        write_status("completed", steps, max_steps)

    except asyncio.TimeoutError:
        write_result("timeout", error=f"Task exceeded {timeout}s timeout")
        write_status("error")
    except Exception as e:
        write_result("error", error=f"{type(e).__name__}: {str(e)}")
        write_status("error")

if __name__ == "__main__":
    asyncio.run(run())
```

---

## Orchestrator Workflow

The calling agent (Codebot/Medbot) follows this sequence:

### 1. Prepare Task

```bash
# Create temp directory for this task
TASK_ID=$(uuidgen)
TASK_DIR="/tmp/browser-tasks/${TASK_ID}"
mkdir -p "$TASK_DIR"

# Write task instructions
cat > "${TASK_DIR}/task.json" << 'EOF'
{
  "instruction": "Go to example.com, log in with the provided credentials, and extract the dashboard data.",
  "url": "https://example.com/login",
  "max_steps": 30,
  "timeout_seconds": 300
}
EOF
```

### 2. Launch Container

```bash
docker run -d \
  --name "browser-${TASK_ID}" \
  --network=bridge \
  --memory=2g \
  --cpus=1 \
  -v "${TASK_DIR}:/task" \
  -e "ANTHROPIC_API_KEY=sk-ant-xxx" \
  -e "LOGIN_USER=user@example.com" \
  -e "LOGIN_PASS=secretpassword" \
  --add-host=host.docker.internal:host-gateway \
  medfinder/browser-agent:latest
```

**Key flags:**
- `-d` — detached (async)
- `--memory=2g` — prevent runaway usage
- `--cpus=1` — limit CPU (server has 2)
- `-v` — mount only the task directory, nothing else
- `-e` — inject only the credentials needed for THIS task
- `--network=bridge` — internet access only, no host network

### 3. Poll for Status

```bash
# Check if still running
docker inspect --format='{{.State.Status}}' "browser-${TASK_ID}"

# Read status updates
cat "${TASK_DIR}/status.json"
```

### 4. Collect Results

```bash
# Read result
cat "${TASK_DIR}/result.json"
```

### 5. Cleanup

```bash
# Kill and remove container
docker rm -f "browser-${TASK_ID}" 2>/dev/null

# Delete task directory (credentials + results)
rm -rf "${TASK_DIR}"
```

---

## Container Reaper (Cron)

Hourly cron job to kill any containers that exceeded the 1-hour limit:

```bash
#!/bin/bash
# Reap browser agent containers older than 1 hour
for cid in $(docker ps -q --filter "name=browser-" --filter "status=running"); do
  started=$(docker inspect --format='{{.State.StartedAt}}' "$cid")
  started_epoch=$(date -d "$started" +%s)
  now_epoch=$(date +%s)
  age=$(( now_epoch - started_epoch ))
  if [ "$age" -gt 3600 ]; then
    echo "Reaping container $cid (age: ${age}s)"
    docker rm -f "$cid"
  fi
done

# Also clean up exited browser containers
docker rm $(docker ps -aq --filter "name=browser-" --filter "status=exited") 2>/dev/null
```

Registered as an OpenClaw cron job or system crontab.

---

## Security Controls

### What the container CAN do:
- Browse the internet
- Read task instructions from /task/task.json
- Read credentials from environment variables
- Write results to /task/result.json
- Make LLM API calls (with the provided key)

### What the container CANNOT do:
- Access host filesystem (only /task is mounted)
- Read openclaw.json or any agent configs
- Access other API keys, tokens, or secrets
- Reach host services (localhost, Tailscale network)
- Run longer than 1 hour
- Persist any state after termination

### Prompt Injection Mitigations:
1. **Minimal credential exposure** — container only gets the specific credentials for the current task
2. **No persistent memory** — even if compromised, learned secrets die with the container
3. **Network isolation** — can't phone home to attacker-controlled infrastructure on the internal network
4. **Time-boxed** — max 1 hour limits the window for any exfiltration
5. **Result validation** — orchestrator should treat result.json as untrusted external content

### Residual Risks:
- **LLM API key exposure** — a compromised container could exfiltrate the LLM API key passed to it. Mitigation: use a dedicated API key with spending limits for browser tasks only.
- **Task credential exfiltration** — the container has the credentials it needs, so it could send them to a malicious page. Mitigation: use short-lived tokens or rotate credentials after task completion.
- **Outbound data exfiltration** — a compromised agent could POST data to an external server. Mitigation: could add egress firewall rules (iptables or Docker network policy) to whitelist only specific domains if needed.

---

## Resource Requirements

| Resource | Requirement |
|----------|-------------|
| Docker | Must be installed on host |
| RAM | ~2GB per container (Chromium is hungry) |
| Disk | ~2GB for Docker image |
| CPU | 1 core per container |
| Host RAM | 7.6GB total — can run 1-2 containers alongside existing services |

**Recommendation:** Run max 1 concurrent browser container given server resources. Queue additional tasks.

---

## LLM Selection for Browser Agent

| Model | Pros | Cons |
|-------|------|------|
| Anthropic Claude Sonnet | High accuracy, good at following complex instructions | Higher cost |
| Gemini Flash | Fast, cheap, we already have the API key | Lower accuracy on complex tasks |
| ChatBrowserUse (built-in) | Optimized for browser-use, fastest | Requires separate API key + costs |

**Recommendation:** Start with Gemini (free key already configured) for cost efficiency. Upgrade to Claude Sonnet for high-stakes tasks. Pass the appropriate key per task.

---

## Implementation Phases

### Phase 1: Foundation (1-2 hours)
- Install Docker on server
- Build the Docker image (`Dockerfile` + `entrypoint.py`)
- Test manually: create task.json, run container, verify result.json

### Phase 2: Orchestrator Integration (2-3 hours)
- Build a shell script / Node wrapper that Codebot can call
- Create an OpenClaw skill for browser task delegation
- Implement the full prepare → launch → poll → collect → cleanup cycle

### Phase 3: Safety & Ops (1-2 hours)
- Set up the container reaper cron job
- Add Docker resource limits
- Test prompt injection scenarios
- Add logging / monitoring

### Phase 4: Advanced (future)
- Egress firewall rules (domain whitelisting)
- Screenshot capture for debugging
- Task queue for sequential execution
- Cookie/session persistence across tasks (for authenticated workflows)

---

## Open Questions

1. **Docker installation** — Should we install Docker now? Server has enough resources.
2. **LLM key strategy** — Dedicated browser-only API key with spending caps, or reuse existing Gemini key?
3. **Concurrent containers** — Hard limit to 1, or allow 2 with potential memory pressure?
4. **Egress filtering** — Worth the complexity now, or add later?
5. **Which tasks first?** — What's the first browser automation use case to validate with?
