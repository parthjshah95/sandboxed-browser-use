# Ephemeral Browser Agent (Sandboxed)

A sandboxed browser automation system that runs [browser-use](https://github.com/browser-use/browser-use) inside ephemeral Docker containers. Designed for agents that need to perform web browsing tasks without exposing host secrets to prompt injection attacks.

## Architecture

```
┌──────────────────────┐          docker run           ┌──────────────────────────┐
│   Orchestrator Agent │  ───────────────────────────► │  Ephemeral Container     │
│   (e.g. openclaw)    │   • task.json (mounted)       │                          │
│                      │   • creds via env vars        │  browser-use + chromium  │
│   • No browser access│   • result volume mount       │  Python 3.12             │
│   • Full secrets     │                               │                          │
│   • Reads results    │  ◄──────────────────────────  │  • Reads task.json       │
│     from mount       │   • writes result.json        │  • Runs browser agent    │
│   • Cleans up        │   • container exits           │  • Writes result.json    │
└──────────────────────┘                               │  • Exits (self-destruct) │
                                                       └──────────────────────────┘
```

## Quick Start

### 1. Prerequisites

- Docker installed and running
- Python 3.x (for json formatting in the orchestrator script)
- An LLM API key (Anthropic, Google Gemini, or OpenAI)

### 2. Build the Docker Image

```bash
./scripts/build.sh
```

This builds the `medfinder/browser-agent:latest` image containing Python 3.12, browser-use, and headless Chromium.

### 3. Run a Browser Task

```bash
# Quick run (blocks until complete)
export GEMINI_API_KEY="your-key-here"
./scripts/browser-task.sh run "Search Google for 'browser-use python' and return the top 3 results" --wait

# Async run (returns task ID immediately)
TASK_ID=$(./scripts/browser-task.sh run "Go to example.com and extract the page title")
./scripts/browser-task.sh status "$TASK_ID"
./scripts/browser-task.sh result "$TASK_ID"
./scripts/browser-task.sh cleanup "$TASK_ID"
```

### 4. Set Up the Container Reaper

Install the hourly cron job to kill containers that exceed the 1-hour limit:

```bash
(crontab -l 2>/dev/null; echo "0 * * * * $(pwd)/scripts/reaper.sh >> /var/log/browser-reaper.log 2>&1") | crontab -
```

## Project Structure

```
.
├── PRD.md                      # Product Requirements Document
├── README.md                   # This file
├── container/
│   ├── Dockerfile              # Browser agent container image
│   └── entrypoint.py           # Agent entrypoint (reads task, runs browser-use, writes result)
└── scripts/
    ├── build.sh                # Build the Docker image
    ├── browser-task.sh         # Orchestrator CLI (run/status/result/cleanup/list)
    └── reaper.sh               # Cron job to reap stale containers
```

## Usage Guide

### Orchestrator Script (`browser-task.sh`)

The main CLI for managing browser tasks.

#### Commands

| Command | Description |
|---------|-------------|
| `run <instruction> [options]` | Create and launch a new browser task |
| `status <task-id>` | Check the status of a running task |
| `result <task-id>` | Get the result of a completed task |
| `cleanup <task-id>` | Remove container and task files |
| `list` | List all browser containers and tasks |

#### Run Options

| Option | Default | Description |
|--------|---------|-------------|
| `--url <url>` | none | Starting URL for the browser |
| `--max-steps <n>` | 50 | Maximum agent steps |
| `--timeout <seconds>` | 600 | Task timeout in seconds |
| `--llm-key <key>` | from env | LLM API key |
| `--llm-provider <name>` | auto-detect | `anthropic`, `gemini`, or `openai` |
| `--env <KEY=VALUE>` | none | Extra env var for the container (repeatable) |
| `--wait` | false | Block until task completes |
| `--poll-interval <s>` | 5 | Seconds between status polls |
| `--image <image>` | `medfinder/browser-agent:latest` | Docker image to use |
| `--memory <limit>` | `2g` | Container memory limit |
| `--cpus <n>` | `1` | Container CPU limit |

#### Examples

```bash
# Simple search task
./scripts/browser-task.sh run "Search for 'AI news' on Google and return top 5 results" --wait

# Authenticated task with credentials
./scripts/browser-task.sh run "Log in and download the monthly report" \
  --url "https://app.example.com/login" \
  --env "LOGIN_USER=user@example.com" \
  --env "LOGIN_PASS=secretpassword" \
  --llm-provider anthropic \
  --llm-key "sk-ant-xxx" \
  --wait

# With custom resource limits
./scripts/browser-task.sh run "Scrape product prices from example.com" \
  --max-steps 100 \
  --timeout 900 \
  --memory 4g \
  --cpus 2 \
  --wait
```

### Task JSON Schema

**Input** (`/task/task.json`):
```json
{
  "instruction": "What to do (required)",
  "url": "Starting URL (optional)",
  "max_steps": 50,
  "timeout_seconds": 600
}
```

**Output** (`/task/result.json`):
```json
{
  "status": "success | error | timeout",
  "output": "Extracted data / task result",
  "steps_taken": 12,
  "error": "Error message (if status is error)",
  "screenshots": []
}
```

**Status** (`/task/status.json` — updated during execution):
```json
{
  "state": "running | completed | error",
  "step": 5,
  "max_steps": 50,
  "current_url": "https://...",
  "updated_at": "2026-02-14T12:00:00+00:00"
}
```

### Container Reaper (`reaper.sh`)

Automatically cleans up stale browser containers and orphaned task directories.

```bash
# Run manually
./scripts/reaper.sh

# Custom max age (30 minutes)
./scripts/reaper.sh --max-age 1800

# Dry run (show what would be cleaned up)
./scripts/reaper.sh --dry-run
```

## Security Model

### Isolation Boundaries

| Resource | Container CAN access | Container CANNOT access |
|----------|---------------------|------------------------|
| Credentials | Only env vars passed at `docker run` | Host env vars, agent configs |
| Filesystem | Mounted `/task` volume only | Host filesystem |
| Network | Internet (outbound only) | Localhost, host services |
| LLM API | Its own API key (passed as env) | Other API keys |
| Duration | Max 1 hour (enforced by reaper) | N/A |

### Prompt Injection Mitigations

1. **Minimal credential exposure** — container only gets the specific credentials for the current task
2. **No persistent memory** — secrets die with the container
3. **Network isolation** — bridge network only, no host network access
4. **Time-boxed** — max 1 hour enforced by the reaper cron job
5. **Result validation** — orchestrator should treat `result.json` as untrusted content

## Resource Requirements

| Resource | Requirement |
|----------|-------------|
| Docker | Must be installed on host |
| RAM | ~2GB per container (Chromium) |
| Disk | ~2GB for Docker image |
| CPU | 1 core per container |

**Recommendation:** Run max 1 concurrent browser container on resource-constrained hosts.

## LLM Configuration

The agent supports three LLM providers. Set the appropriate environment variable or pass via `--llm-key`:

| Provider | Env Variable | Model |
|----------|-------------|-------|
| Anthropic | `ANTHROPIC_API_KEY` | claude-sonnet-4-0 |
| Google Gemini | `GEMINI_API_KEY` | gemini-2.0-flash |
| OpenAI | `OPENAI_API_KEY` | gpt-4.1-mini |

Priority order: Anthropic > Gemini > OpenAI (first available key is used).
