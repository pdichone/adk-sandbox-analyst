"""Pick the code executor for where the agent is running.

On Cloud Run (the platform sets K_SERVICE) the agent's Python runs inside a
Cloud Run sandbox: no parent env vars, no secrets, no metadata server, no
network egress, read-only filesystem. Anywhere else it runs on your machine,
unsandboxed, which is fine for a local smoke test and nothing more.
"""
import os

from google.adk.code_executors import UnsafeLocalCodeExecutor


def pick_executor():
    if os.environ.get("K_SERVICE"):
        from google.adk.integrations.cloud_run import CloudRunSandboxCodeExecutor
        return CloudRunSandboxCodeExecutor(timeout_seconds=120)
    return UnsafeLocalCodeExecutor()
