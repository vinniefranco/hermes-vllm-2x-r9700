# Multica host integration

Host-side wiring for running Hermes under the Multica desktop daemon on this
box. This is separate from the compose stack: the Multica AppImage daemon
launches a Hermes per task on the host (profile `desktop-api.multica.ai`), with
its terminal backend in throwaway podman sandboxes. In Multica I named that
agent "Mika"; it's the same Hermes, and the name is just what shows in the app.

## Why the seed config looks the way it does

`hermes-terminal-seed.yaml` is mostly workarounds for how the sandbox differs
from the daemon's own environment:

- `docker_image` is registry-qualified (and pre-pulled at install). With a
  short name, Fedora's multiple search registries make podman try to prompt,
  which fails without a TTY and exits 125.
- The `multica` CLI is mounted read-only from a stable copy in `~/.local/bin`,
  because the AppImage's own copy lives in an ephemeral `/tmp/.mount_*` path.
  `docker_forward_env` passes `MULTICA_TOKEN` and the task identity through;
  the sandbox doesn't inherit the daemon's env.
- `docker_extra_args` sets `--security-opt label=disable`. Hermes doesn't
  `:z`-label its bind mounts, so SELinux would deny the sandbox its own `$HOME`
  and `/workspace`.
- `docker_env` injects `MULTICA_SERVER_URL`. The daemon never writes a per-task
  `config.json` the container could read, but the CLI honors the env var.
- `--network pasta:-T,19681` maps the container's loopback :19681 to the
  host's, so `repo checkout` can reach the loopback-only daemon.
- `docker_mount_cwd_to_workspace: true` puts the per-task workdir at
  `/workspace`, so task outputs land on the host instead of the container
  overlay.
- `browser.cdp_url` points at `headless-chromium.service`: persistent headless
  Chromium with CDP on loopback :9222 (Playwright's cache alone has no browser
  binary).

## Files

| file | installs to | purpose |
|---|---|---|
| `hermes-terminal-seed.yaml` | `terminal:` section of `~/.hermes/config.yaml` | seed config for every per-task hermes-home (each task copies it) |
| `multica-sync` | `~/.local/bin/` | re-copies the CLI out of the mounted AppImage when it changes |
| `multica-sync.service` / `.timer` | `~/.config/systemd/user/` | runs the sync every 15 min + on boot |
| `headless-chromium` | `~/.local/bin/` | launches Playwright Chromium headless with CDP :9222 (version-proof glob) |
| `headless-chromium.service` | `~/.config/systemd/user/` | keeps it running, `MemoryMax=2G` |

Browser config in `~/.hermes/config.yaml`:

```yaml
browser:
  backend: browser-use
  cdp_url: http://127.0.0.1:9222
```

## Install

```sh
install -m 0755 multica-sync headless-chromium ~/.local/bin/
install -m 0644 *.service *.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now multica-sync.timer headless-chromium.service
npx --yes playwright install chromium   # one-time: the actual browser bundle
podman pull docker.io/nikolaik/python-nodejs:python3.11-nodejs20
```

Then merge `hermes-terminal-seed.yaml` into `~/.hermes/config.yaml`. Keep the
two in byte-sync afterward: the seed is the committed record of what the live
config's `terminal:` section should say.

## Gotchas

- **Persistent sandbox containers outlive config changes.** After editing the
  `terminal:` config, run
  `podman rm -f $(podman ps -aq --filter label=hermes-agent=1)`, otherwise the
  old container (old mounts, old security opts) is silently reused across tasks.
- The headless Chromium profile (`~/.local/share/headless-chromium`) is shared
  across tasks, so cookies and logins persist between them.
- `label=disable` turns off SELinux separation for the sandboxes (cap-drop and
  no-new-privileges still apply), and the `hermes-egress=off` label is only a
  label. The sandbox has unrestricted egress via pasta.
- The sandbox terminal timeout (`terminal.timeout`) is seeded at 600 s, which
  covers most builds. Raise it further for anything longer-running.
