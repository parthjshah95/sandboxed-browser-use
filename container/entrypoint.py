"""
Ephemeral browser agent entrypoint.

Reads task from /task/task.json, executes browser-use agent,
writes results to /task/result.json, then exits.

Environment variables:
  ANTHROPIC_API_KEY or GEMINI_API_KEY or OPENAI_API_KEY — LLM for browser-use
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


def write_status(state: str, step: int = 0, max_steps: int = 0, url: str = "") -> None:
    """Write current agent status to /task/status.json for external polling."""
    status = {
        "state": state,
        "step": step,
        "max_steps": max_steps,
        "current_url": url,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    (TASK_DIR / "status.json").write_text(json.dumps(status, indent=2))


def write_result(
    status: str,
    output: str = "",
    steps: int = 0,
    error: str | None = None,
    screenshots: list[str] | None = None,
) -> None:
    """Write final result to /task/result.json."""
    result = {
        "status": status,
        "output": output,
        "steps_taken": steps,
        "error": error,
        "screenshots": screenshots or [],
    }
    (TASK_DIR / "result.json").write_text(json.dumps(result, indent=2))


def _get_llm():
    """Instantiate the appropriate LLM based on available API keys."""
    if os.environ.get("ANTHROPIC_API_KEY"):
        from langchain_anthropic import ChatAnthropic

        return ChatAnthropic(model="claude-sonnet-4-0", temperature=0.0)
    elif os.environ.get("GEMINI_API_KEY"):
        from langchain_google_genai import ChatGoogleGenerativeAI

        return ChatGoogleGenerativeAI(
            model="gemini-2.0-flash",
            google_api_key=os.environ["GEMINI_API_KEY"],
        )
    elif os.environ.get("OPENAI_API_KEY"):
        from langchain_openai import ChatOpenAI

        return ChatOpenAI(model="gpt-4.1-mini", temperature=0.0)
    else:
        return None


async def run() -> None:
    """Main agent execution loop."""
    # ------------------------------------------------------------------
    # 1. Read task
    # ------------------------------------------------------------------
    task_file = TASK_DIR / "task.json"
    if not task_file.exists():
        write_result("error", error="No task.json found in /task")
        write_status("error")
        return

    try:
        task = json.loads(task_file.read_text())
    except json.JSONDecodeError as exc:
        write_result("error", error=f"Invalid task.json: {exc}")
        write_status("error")
        return

    instruction = task.get("instruction", "")
    start_url = task.get("url")
    max_steps = task.get("max_steps", 50)
    timeout = task.get("timeout_seconds", 600)

    if not instruction:
        write_result("error", error="Empty instruction in task.json")
        write_status("error")
        return

    write_status("running", 0, max_steps)

    # ------------------------------------------------------------------
    # 2. Initialise LLM
    # ------------------------------------------------------------------
    llm = _get_llm()
    if llm is None:
        write_result(
            "error",
            error="No LLM API key provided. Set ANTHROPIC_API_KEY, GEMINI_API_KEY, or OPENAI_API_KEY.",
        )
        write_status("error")
        return

    # ------------------------------------------------------------------
    # 3. Run the browser-use agent
    # ------------------------------------------------------------------
    try:
        from browser_use import Agent, Browser, BrowserConfig

        # Configure headless Chromium
        browser = Browser(config=BrowserConfig(headless=True))

        # Optionally include a starting URL in the task description
        full_instruction = instruction
        if start_url:
            full_instruction = f"Navigate to {start_url} and then: {instruction}"

        agent = Agent(
            task=full_instruction,
            llm=llm,
            browser=browser,
        )

        # Run with a hard timeout
        history = await asyncio.wait_for(
            agent.run(max_steps=max_steps),
            timeout=timeout,
        )

        # Extract result
        final_result = (
            history.final_result() if hasattr(history, "final_result") else str(history)
        )
        steps_taken = (
            history.number_of_steps() if hasattr(history, "number_of_steps") else 0
        )

        write_result("success", output=str(final_result), steps=steps_taken)
        write_status("completed", steps_taken, max_steps)

    except asyncio.TimeoutError:
        write_result("timeout", error=f"Task exceeded {timeout}s timeout")
        write_status("error")
    except Exception as exc:
        tb = traceback.format_exc()
        write_result("error", error=f"{type(exc).__name__}: {exc}\n{tb}")
        write_status("error")


# ------------------------------------------------------------------
# Graceful shutdown on SIGTERM / SIGINT
# ------------------------------------------------------------------
_shutdown_event = asyncio.Event() if hasattr(asyncio, "Event") else None


def _handle_signal(sig, frame):
    """Handle termination signals gracefully."""
    write_status("error")
    write_result("error", error=f"Terminated by signal {sig}")
    sys.exit(1)


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)


if __name__ == "__main__":
    asyncio.run(run())
