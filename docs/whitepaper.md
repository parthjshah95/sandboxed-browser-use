# Ephemeral Browser Agents: Secure Web Automation for AI Systems

## The Problem

AI agents increasingly need to browse the web — logging into services, filling forms, extracting data, interacting with web applications. But the open web is hostile territory for an AI agent.

**The core risk: prompt injection via web content.**

When a browsing agent loads a webpage, it processes that page's content to decide what to do next. A malicious (or compromised) website can embed instructions in its visible or hidden text that manipulate the agent into:

- Exfiltrating credentials the agent has access to
- Performing unintended actions on authenticated sites
- Leaking private data from the agent's memory or context
- Pivoting to attack internal infrastructure the agent can reach

This isn't theoretical. Any AI agent that processes untrusted text is vulnerable to prompt injection, and the open web is the largest source of untrusted text in existence.

### Why Traditional Sandboxing Isn't Enough

Running a browser agent in a sandboxed environment helps, but doesn't solve the fundamental problem if:

- The agent has long-lived credentials in memory
- The agent shares a context/workspace with other sensitive systems
- The agent can reach internal services or APIs
- The agent persists state between tasks (a compromise in one task leaks into the next)

---

## Threat Model

### Attack Surface

| Vector | Description | Severity |
|--------|-------------|----------|
| **Page content injection** | Malicious instructions embedded in visible/hidden page text | Critical |
| **Credential exfiltration** | Agent sends its API keys, passwords, or tokens to an attacker-controlled endpoint | Critical |
| **Lateral movement** | Compromised agent accesses internal services, databases, or other agents' data | High |
| **Persistent compromise** | Agent retains poisoned instructions across tasks | High |
| **Data exfiltration** | Agent leaks task context or private data to external sites | High |
| **Resource abuse** | Compromised agent runs up API costs | Medium |

### What We're Protecting

1. **Credentials** — API keys, passwords, session tokens used for tasks
2. **Infrastructure** — Internal services, databases, other agents
3. **Context** — Private data from other tasks, conversations, or agent memory
4. **API budgets** — LLM and service API spending

---

## Solution: Ephemeral Container Architecture

The core insight: **treat every browser task as a disposable, isolated unit of work.**

Instead of running a persistent browser agent with access to all credentials and systems, spin up a fresh container for each task that:

1. Receives only the credentials needed for that specific task
2. Has no access to the host filesystem, other agents, or internal network
3. Reports results through a constrained interface (mounted volume)
4. Self-destructs on completion — all state (credentials, cookies, browser data, agent memory) is destroyed
5. Is forcibly reaped after a maximum lifetime if it hangs

### Architecture

```
┌──────────────────────┐          docker run           ┌─────────────────────────┐
│   Orchestrator Agent │  ────────────────────────────► │  Ephemeral Container     │
│                       │   • task.json (mounted vol)   │                          │
│   • Holds all secrets │   • task-specific creds only  │  browser automation lib  │
│   • No browser access │     (env vars)                │  + headless chromium     │
│   • Creates tasks     │   • scoped LLM key            │                          │
│   • Reads results     │                               │  • Reads task.json       │
│   • Cleans up after   │  ◄──────────────────────────  │  • Executes browser task │
│                       │   • result.json on mount      │  • Writes result.json    │
└──────────────────────┘   • container exits            │  • Exits                 │
                                                        └─────────────────────────┘

         ┌──────────────┐
         │  Reaper Cron  │  Kills containers older than max lifetime
         └──────────────┘
```

### Isolation Boundaries

| Resource | Container CAN access | Container CANNOT access |
|----------|---------------------|------------------------|
| Credentials | Only env vars passed at `docker run` for this task | Host env, config files, other agents' secrets |
| Filesystem | Mounted `/task` volume only | Host filesystem, other workspaces |
| Network | Internet (outbound only) | Localhost, internal network, host services |
| LLM API | Scoped API key with spending cap | Primary API keys |
| Memory/CPU | Capped via Docker limits | Unlimited host resources |
| Duration | Max lifetime (e.g. 1 hour) enforced by reaper | Indefinite execution |
| State | None persists after exit | Previous task context, cookies, history |

### Workflow

```
1. PREPARE    Orchestrator writes task.json with instructions
              Orchestrator selects which credentials to inject

2. LAUNCH     docker run --detach with:
              • mounted task directory
              • task-specific credentials as env vars
              • scoped LLM API key
              • resource limits (memory, CPU, timeout)
              • network restrictions

3. EXECUTE    Container reads task.json
              Browser agent navigates, interacts, extracts
              Writes status.json periodically (for polling)
              Writes result.json on completion

4. COLLECT    Orchestrator reads result.json from mount
              Treats result content as UNTRUSTED

5. DESTROY    Container is removed (docker rm -f)
              Task directory is deleted
              All credentials, cookies, state are gone
```

### Container Interface

**Input: `/task/task.json`**
```json
{
  "instruction": "Navigate to example.com, log in, and extract the dashboard metrics",
  "url": "https://example.com/login",
  "max_steps": 30,
  "timeout_seconds": 300
}
```

**Output: `/task/result.json`**
```json
{
  "status": "success | error | timeout",
  "output": "Extracted data or task result as text",
  "steps_taken": 12,
  "error": "Error message if status is error or timeout"
}
```

**Status: `/task/status.json`** (written periodically for external polling)
```json
{
  "state": "running | completed | error",
  "step": 5,
  "max_steps": 30,
  "current_url": "https://example.com/dashboard",
  "updated_at": "2026-02-14T01:00:00Z"
}
```

### Container Reaper

A scheduled job (cron, systemd timer, or equivalent) that runs periodically and kills any browser containers exceeding the maximum allowed lifetime:

```bash
# Kill containers named browser-* running longer than MAX_AGE
for cid in $(docker ps -q --filter "name=browser-" --filter "status=running"); do
  started=$(docker inspect --format='{{.State.StartedAt}}' "$cid")
  age=$(( $(date +%s) - $(date -d "$started" +%s) ))
  [ "$age" -gt "$MAX_AGE_SECONDS" ] && docker rm -f "$cid"
done

# Clean up exited containers
docker rm $(docker ps -aq --filter "name=browser-" --filter "status=exited") 2>/dev/null
```

---

## The LLM API Key Problem

The one secret you **cannot withhold** from the browser agent is the LLM API key. The agent needs it to reason about what it sees on screen. If a malicious page tricks the agent into exfiltrating its environment variables, this key is exposed.

This is the hardest problem in this architecture. Below are the mitigation strategies, ordered from simplest to most robust.

### Strategy 1: Dedicated Key with Spending Cap

**How it works:** Create a separate API key used exclusively for browser tasks, with a low monthly budget.

**Provider support:**

| Provider | Per-key budget cap | Mechanism |
|----------|-------------------|-----------|
| OpenAI | ✅ Per-project budgets | Create a separate project, set a monthly limit, generate a key scoped to that project |
| Anthropic | ❌ Org-level only | Monthly spend limit applies to all keys; no per-key granularity |
| Google Gemini (AI Studio) | ⚠️ Rate limits only | Per-key requests-per-minute limits, but no spending caps |
| Google Gemini (GCP) | ✅ Per-project budgets | GCP billing budgets with alerts and enforcement |

**Blast radius if compromised:** Attacker gets limited API access capped at the budget. Your primary keys are never exposed. For OpenAI, a project-scoped key with a $5-10/month cap is the sweet spot.

**Limitations:** Doesn't prevent exfiltration, just limits the value of what's exfiltrated.

### Strategy 2: Egress Filtering

**How it works:** Restrict the container's outbound network to only the domains it needs — the target website and the LLM provider's API endpoint.

```bash
docker run \
  --network=browser-agent-net \
  ...

# Docker network with iptables rules that only allow:
# - LLM API endpoint (e.g. api.openai.com, api.anthropic.com)
# - The specific target domain for the task
# - DNS resolution
# All other outbound traffic is dropped
```

**Blast radius if compromised:** Even if the agent tries to exfiltrate the key, it can only talk to the LLM provider (which already has the key) and the target site. It cannot POST data to an attacker-controlled server.

**Limitations:** Complex to set up per-task (target domain changes). The target site itself could be the attacker. Does not protect against exfiltration to the target domain.

### Strategy 3: Temporary Credentials (STS / Short-Lived Tokens)

**How it works:** Instead of passing a permanent API key, generate a short-lived credential that expires automatically.

**Provider support:**

| Provider | Temporary credentials | Mechanism |
|----------|----------------------|-----------|
| AWS Bedrock | ✅ Native | `aws sts assume-role` generates credentials valid for 15-60 minutes |
| Google Vertex AI | ✅ Native | Service account with short-lived OAuth tokens |
| OpenAI | ❌ | No temporary token mechanism |
| Anthropic | ❌ | No temporary token mechanism |

**Blast radius if compromised:** The credential stops working after the timeout period, even if the container isn't reaped. The attacker has a narrow window of access.

**Limitations:** Only works with cloud-provider LLM services (Bedrock, Vertex AI), not direct API access to OpenAI/Anthropic. May incur different pricing than direct API access.

### Strategy 4: LLM Proxy with Per-Request Auth

**How it works:** Run a lightweight proxy on the host that holds the real API key. The container gets a proxy URL with a single-use or time-limited token.

```
Container → http://proxy:8080/v1/chat (with task-token) → api.openai.com (with real key)
```

The proxy:
- Validates the task token (one token per container, expires with the task)
- Forwards to the real LLM API with the actual key
- Rate-limits requests
- Logs all LLM calls for auditing
- Revokes the task token when the container is destroyed

**Blast radius if compromised:** The task token only works through the proxy. The real API key never enters the container. If the token leaks, the proxy can revoke it instantly.

**Limitations:** Adds a service to maintain. Requires the container to reach the host (breaks strict network isolation, though the proxy can be exposed on a Docker network rather than the host network). Adds latency to LLM calls.

### Strategy 5: Automated Key Rotation

**How it works:** Programmatically create a new API key before each task and delete it after the task completes.

**Provider support:**

| Provider | Programmatic key management | Mechanism |
|----------|----------------------------|-----------|
| Google (GCP) | ✅ | `gcloud services api-keys create/delete` |
| OpenAI | ❌ | No API for key management |
| Anthropic | ❌ | No API for key management |

**Blast radius if compromised:** The key is deleted before an attacker can use it (assuming the task completes normally). If the container hangs, the reaper triggers key deletion.

**Limitations:** Only works with Google/GCP. Key creation has latency and rate limits. Doesn't help if the key is exfiltrated while the container is still running.

### Recommended Approach

Combine strategies for defense in depth:

1. **Always:** Dedicated key with spending cap (Strategy 1) — cheap, easy, limits blast radius
2. **Recommended:** Egress filtering (Strategy 2) — blocks exfiltration to arbitrary endpoints
3. **If using AWS/GCP:** Temporary credentials (Strategy 3) — strongest protection, credentials self-destruct
4. **For high-security tasks:** LLM proxy (Strategy 4) — real key never enters the container

---

## Resource Considerations

Browser automation containers are resource-hungry due to headless Chromium:

| Resource | Per Container | Notes |
|----------|--------------|-------|
| RAM | 1-2 GB | Chromium baseline + page rendering |
| CPU | 0.5-1 core | Spiky during page loads |
| Disk | ~50 MB runtime | Temp files, browser cache |
| Image size | ~1-2 GB | Python + browser-use + Chromium |

**Concurrency:** On a typical 8GB server, run 1-2 containers max alongside other services. Queue additional tasks. On dedicated infrastructure, scale horizontally.

---

## Result Trust Model

**Critical: the orchestrator must treat all output from the container as untrusted external content.**

A compromised browser agent could inject prompt attacks into `result.json` in an attempt to manipulate the orchestrator. Defenses:

- Parse result.json as data, not instructions
- Validate the schema strictly
- Sanitize text content before injecting into orchestrator context
- Flag results from tasks that hit the timeout or error state for human review

---

## Summary

| Property | Traditional Browser Agent | Ephemeral Container Agent |
|----------|--------------------------|---------------------------|
| Credential exposure | All agent secrets | Only task-specific credentials |
| Persistence | Compromise persists across tasks | Wiped after every task |
| Blast radius | Full system access | Isolated container, capped API key |
| Network access | Host network | Internet only, optionally filtered |
| Memory/context | Shared with all tasks | Fresh per task |
| Max compromise duration | Until detected | Container lifetime (max 1 hour) |
| Complexity | Low | Medium (Docker + orchestration) |

The ephemeral container pattern doesn't eliminate prompt injection — no current technique does. What it does is **minimize the blast radius** of a successful attack by ensuring that a compromised agent has access to the least possible credentials for the shortest possible time, with no ability to persist or escalate.

---

## References

- [browser-use](https://github.com/browser-use/browser-use) — Python browser automation library
- [OWASP LLM Top 10](https://owasp.org/www-project-top-10-for-large-language-model-applications/) — Prompt injection risks
- [Docker Security Best Practices](https://docs.docker.com/engine/security/) — Container isolation
- [AWS STS Temporary Credentials](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp.html)
