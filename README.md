# Local LLM + Hermes Agent stack

This runs Qwen3.8-27B on two AMD Radeon AI PRO R9700 cards with vLLM, and runs
the Nous Research Hermes agent on top of it. Everything is one `compose.yaml`
that podman brings up. The model is served over TLS in both OpenAI and Anthropic
API formats so you can point coding tools at it, and the Hermes agent is
sandboxed so it can write code but can't touch the host or scan the LAN.

Built and running on `studio-lin` (Fedora, rootless podman). If you're setting it
up somewhere else, read the Requirements and the gotchas at the bottom — a few
host-specific things (GPU arch, group IDs, firewall, DNS) will differ.

## What's in the box

- **vLLM** serving `Qwen/Qwen3.8-27B-FP8`, tensor-parallel across both R9700s.
  The image is built from source (`build/Containerfile`) because gfx1201 (RDNA4)
  needs a recent vLLM + AITER. It serves the OpenAI API (`/v1/chat/completions`,
  `/v1/models`, …) and the Anthropic API (`/v1/messages`) on the same port.
- **Hermes agent** — the gateway (OpenAI-compatible API + chat platforms), the web
  dashboard, and the backend the Hermes Desktop app connects to.
- **Caddy** — terminates TLS with its own internal CA. Nothing is exposed in
  plaintext. It's the only thing published to the network.
- **Squid** — an egress proxy. The agent is on an internal-only network and reaches
  the internet through Squid, which blocks all private/LAN addresses. So the agent
  can pip/git/curl the internet but can't reach anything on your LAN.

## How traffic flows

Everything comes in through Caddy on one hostname (`llm.home.vincentfranco.com`),
port 443, routed by path:

- `/v1/*` → vLLM (both OpenAI and Anthropic API formats live here)
- `/hermes/*` → the Hermes gateway API (needs a bearer key)
- everything else, including `/` → the Hermes dashboard (browser login)

The Hermes Desktop app connects separately to `https://<host>:9119` (also Caddy,
also TLS).

vLLM and Hermes don't publish any ports themselves — only Caddy does. So the only
way to the model is through TLS.

## Requirements

- podman + podman-compose, running rootless.
- Two GPUs vLLM can use. This build targets gfx1201 (R9700). Different card =
  change `GPU_ARCH` and the ROCm/torch pins in `compose.yaml` under the vllm
  `build.args`.
- Enough disk for the weights (~28 GB) plus the build image (~30 GB).
- Rootless podman needs to bind port 443, which is privileged. Allow it:
  ```
  echo 'net.ipv4.ip_unprivileged_port_start=443' | sudo tee /etc/sysctl.d/50-unprivileged-ports.conf
  sudo sysctl --system
  ```
- The host firewall has to let 443 in. On Fedora Workstation the default zone
  blocks it (it only allows high ports), so:
  ```
  sudo firewall-cmd --add-service=https --permanent && sudo firewall-cmd --reload
  ```
- A DNS entry (or a hosts file line) pointing `llm.home.vincentfranco.com` at the
  host's IP. If you use a different name, change it in `configs/caddy/conf/Caddyfile`.
- Check the render group ID on your host (`getent group render`) — it's `105` here
  and is set in `compose.yaml` under the vllm `group_add`. If yours differs, fix it
  or vLLM can't reach the GPUs.

## How to set it up

1. **Seed the Hermes config.** The real config lives in `hermes-data/` and is
   gitignored because it holds secrets. Copy the example and fill in two things:
   ```
   mkdir -p hermes-data projects
   cp hermes-config.example.yaml hermes-data/config.yaml
   ```
   - Set a dashboard password hash:
     ```
     podman run --rm --entrypoint python docker.io/nousresearch/hermes-agent:latest \
       -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('your-password'))"
     ```
     Paste the result into `password_hash`.
   - Set a session secret (without this, every restart logs you out):
     ```
     openssl rand -hex 32
     ```
     Paste it into `secret`.

2. **Build the vLLM image.** This is a from-source build and takes a while (order
   of an hour on a cold cache):
   ```
   podman compose build vllm
   ```

3. **Bring it up.**
   ```
   podman compose up -d
   ```
   The first start downloads the ~28 GB of weights into `models/`, and Caddy
   generates its internal CA. Watch it come up with `podman logs -f vllm` — it's
   ready when the health check passes and Hermes starts.

4. **Trust the CA on your machines.** Caddy signs with its own CA, so browsers and
   apps will warn until you trust the root. It's at:
   ```
   configs/caddy/data/caddy/pki/authorities/local/root.crt
   ```
   - Linux: `sudo trust anchor root.crt`
   - macOS: add to Keychain, set to Always Trust
   - Windows: import into Trusted Root Certification Authorities

## Using it

**As a model endpoint** (coding tools, scripts):

- OpenAI: `OPENAI_BASE_URL=https://llm.home.vincentfranco.com/v1`
- Anthropic: `ANTHROPIC_BASE_URL=https://llm.home.vincentfranco.com`
- Model name is `qwen3.8-27b`.
- vLLM doesn't check the API key, but most clients require one — send any
  non-empty string.

**The dashboard**: open `https://llm.home.vincentfranco.com` in a browser and log
in with the username/password you set.

**The Hermes gateway API** (`/hermes/v1/...`) needs a bearer token. Hermes
generates one into `hermes-data/.env` as `API_SERVER_KEY` on first run — send it
as `Authorization: Bearer <key>`.

**The Hermes Desktop app** connects to `https://<host>:9119` in Remote Gateway
mode. One catch: Electron's Node backend doesn't use the OS cert store, so trusting
the CA system-wide isn't enough — launch the app with the CA pointed at explicitly:
```
NODE_EXTRA_CA_CERTS=/path/to/root.crt hermes desktop
```
Put that in your shell profile or the app's `.desktop` launcher so it sticks. The
agent runs in the container, not on your machine, and its shell is boxed into
`/projects` (which maps to `./projects` here). It can't see the host.

## Layout

- `compose.yaml` — the whole stack.
- `build/` — the vLLM image build (Containerfile + patches).
- `configs/caddy/conf/Caddyfile` — TLS + routing.
- `configs/squid/squid.conf` — the egress proxy rules (allow internet, deny LAN).
- `configs/env/`, `configs/fp8/`, `configs/fused_moe/`, `configs/patches/` — vLLM
  tuning for the R9700 (kernel configs, env, runtime patches). These come from
  the r9700-serving project and are what makes it fast on this card.
- `hermes-config.example.yaml` — seed for `hermes-data/config.yaml`.

Not committed (gitignored): `models/` (weights), `hermes-data/` (secrets + state),
`projects/` (agent workspace), `configs/caddy/data/` (the CA private keys).

## Things that bit us, so you don't have to

- **`api_key: none` breaks the desktop app.** Hermes reads the literal "none" as
  "no key" and the app fails credential resolution. Use any real non-empty string
  (the example uses `sk-local-vllm`).
- **No session `secret` = logged out on every restart** with a `session_expired`
  error. Set one (`openssl rand -hex 32`).
- **Port 443 needs both the sysctl and the firewall change** above. Testing from
  the host itself is misleading — it goes over loopback and skips the firewall.
  Only a real other machine (or your phone) proves it's reachable.
- **The dashboard/desktop app rewrites `config.yaml`** (adds `_config_version`, a
  `custom_providers` list). That's normal; it keeps your values.
- **vLLM needs internet on first run** to pull the model from HuggingFace. It's on
  the `egress` network for that. The agent (Hermes) is not — it only gets out
  through Squid.
