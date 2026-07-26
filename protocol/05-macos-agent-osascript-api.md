# 🍎 AppleScript API — Removed

> **Status:** Removed by the macOS-agent guardrails rollout.

`osascript.run` is no longer a macOS-agent protocol action and is intentionally absent from `agent.status → capabilities`. Calls to it return the normal `unknown_action` error.

The agent may still use `/usr/bin/osascript` internally for a small number of **fixed, curated function templates**. Remote clients can no longer submit arbitrary AppleScript or JXA source. Use the named `functions.list` and `functions.run` actions, or submit a reviewed template proposal through `functions.propose`.

See [`protocol/07-macos-agent-guardrails-and-functions.md`](07-macos-agent-guardrails-and-functions.md) for the supported catalog, permissions, approval flow, and proposal rules.
