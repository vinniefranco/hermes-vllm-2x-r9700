# Multica / Mika host integration

Host-side wiring that lets **Mika** — the Hermes agent runtime spawned per-task by the
Multica desktop daemon (profile `desktop-api.multica.ai`) — actually work on this box.
This is separate from the compose stack in this repo: Mika's Hermes runs on the host,
launched by the Multica AppImage daemon, with its terminal backend in throwaway podman
sandboxes.

## The problems this solves

Every one of these was hit in sequence getting Mika from "spins forever" to green E2E:

1. **`podman run` exit 125** — Hermes' default sandbox image is the *short* name
   `nikolaik/python-nodejs:python3.11-nodejs20`; Fedora lists three
   unqualified-search registries, podman can't prompt without a TTY, and the Hermes
   harness swallows stderr. Fix: registry-qualified `docker_image` + pre-pull.
2. **`multica: command not found`** — the CLI lives inside the AppImage's ephemeral
   `/tmp/.mount_*` and the daemon's env (`MULTICA_TOKEN`, task identity, …) is not
   inherited by the sandbox. Fix: stable CLI copy at `~/.local/bin/multica`, mounted
   read-only + `docker_forward_env`.
3. **`Permission denied` on the sandbox's own `$HOME`/`/workspace`** — SELinux:
   Hermes doesn't `:z`-label its bind mounts (`user_home_t`). Fix:
   `--security-opt label=disable` via `docker_extra_args`.
4. **`No server configured`** — the daemon is loopback-only and per-task
   `config.json` is never materialized for container use; the CLI honors
   `MULTICA_SERVER_URL`, so it is injected via `docker_env`.
5. **`repo checkout` needs the daemon** — pasta tunnel
   `--network pasta:-T,19681` maps the container's loopback :19681 to the host's.
6. **Task outputs trapped in the container overlay** —
   `docker_mount_cwd_to_workspace: true` mounts the per-task workdir at `/workspace`.
7. **`browser-harness: chrome-not-running`** — the Playwright cache was a binary-less
   stub; there was no browser on the host at all. Fix: `headless-chromium.service`
   (persistent headless Chrome, CDP on loopback :9222) + `browser.cdp_url`.

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

Then merge `hermes-terminal-seed.yaml` into `~/.hermes/config.yaml`.

## Gotchas

- **Persistent sandbox containers outlive config changes.** After editing the
  `terminal:` config, run
  `podman rm -f $(podman ps -aq --filter label=hermes-agent=1)` — otherwise the old
  container (old mounts, old security opts) is silently reused across tasks.
- The headless Chromium profile (`~/.local/share/headless-chromium`) is shared
  across tasks — cookies/logins persist between them.
- `label=disable` turns off SELinux separation for the sandboxes (cap-drop and
  no-new-privileges still apply), and the `hermes-egress=off` label is only a
  label — the sandbox has unrestricted egress via pasta.
- Sandbox terminal timeout is 180 s (`terminal.timeout`) — raise it before heavy
  builds.
