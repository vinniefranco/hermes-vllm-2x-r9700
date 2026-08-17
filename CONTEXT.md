# CONTEXT

Glossary for the Hermes/Multica agent stack. Terms only — no implementation details.

## Glossary

- **Gateway Hermes** — the always-on Hermes instance in the compose stack (`hermes` service), reached via Telegram and the dashboard. Distinct from Mika's Hermes.
- **Mika** — the Multica project-lead agent persona. Mika runs the *host* Hermes install (`~/.hermes`), which sandboxes each task in its own podman container. "Mika" is a name in this project, not a Multica product concept.
- **Multica** — the host-native agent-team orchestrator. Assigns board issues to agent CLIs (claude, omp, hermes) spawned as processes of the host user. Provides no sandbox of its own.
- **Host agents** — agent CLIs that run directly as the host user with full host visibility: `claude` (Claude Code) and `omp` (Oh-My-Pi, colloquially "ohmypi").
- **Workbench** — the SSH sidecar container where Gateway Hermes's shell commands actually execute. The gateway container itself never runs agent shells.
- **`/opt/data`** — Gateway Hermes's own state directory (config, secrets, sessions), backed by `./hermes-data`. It is the agent's *cage*, never its *workspace*. Agents should not be pointed at it.
- **Workspace** — where an agent is meant to do task work. For Gateway Hermes: `/projects`. For Mika's task sandboxes: the per-task workdir mounted at `/workspace`.
- **Handoff hub** — `~/agents/repos`: bare git repos mounted at the same absolute path on the host, in workbench, and in Mika sandboxes. A handoff is a repo path plus a commit SHA (see `~/agents/HANDOFF.md`).
