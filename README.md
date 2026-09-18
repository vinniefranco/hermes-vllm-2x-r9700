# Local LLM + Hermes Agent stack

Qwen3.8-27B on two AMD Radeon AI PRO R9700 cards under vLLM, with the Nous
Research Hermes agent running on top of it. The whole thing is one
`compose.yaml` that podman brings up. The model is served over TLS in both the
OpenAI and Anthropic API formats so coding tools can point at it, and the agent
is sandboxed: it can write code but can't touch the host or scan the LAN.

Built and running on `studio-lin` (Fedora, rootless podman). If you're setting
it up somewhere else, read the Requirements and the gotchas at the bottom. A
few host details (GPU arch, group IDs, firewall, DNS) will differ.

## What's in the box

vLLM serves `Qwen/Qwen3.8-27B-FP8`, tensor-parallel across both R9700s. The
image is [vllm-radiance](https://codeberg.org/StillDeadcode/vllm-radiance), a
prebuilt gfx1201-only vLLM with the RDNA4 patches and hand-tuned kernels baked
in. It answers the OpenAI API (`/v1/chat/completions`, `/v1/models`, ...) and
the Anthropic API (`/v1/messages`) on the same port.

The Hermes agent container holds the gateway (OpenAI-compatible API plus the
chat platforms), the web dashboard, and the backend the Hermes Desktop app
connects to.

Caddy terminates TLS with its own internal CA. It's the only thing published to
the network, so nothing goes out in plaintext.

Squid is the egress proxy. The agent sits on an internal-only network and
reaches the internet through Squid, which blocks all private and LAN addresses.
The agent can pip, git and curl the internet but can't reach anything on your
LAN.

Honcho ([plastic-labs/honcho](https://github.com/plastic-labs/honcho)) is the
agent's self-hosted long-term memory: an API server, a background "deriver"
worker that turns conversations into a user model, a pgvector Postgres, and a
CPU embeddings server (TEI running `Qwen/Qwen3-Embedding-0.6B`, since the GPUs
are fully committed to vLLM). All of Honcho's LLM calls go to the local vLLM;
nothing reaches a cloud API. Hermes talks to it through its built-in `honcho`
memory plugin.

## How traffic flows

Everything comes in through Caddy on one hostname (`llm.home.vincentfranco.com`),
port 443, and is routed by path. `/v1/*` goes to vLLM, where both API formats
live. `/hermes/*` goes to the Hermes gateway API and needs a bearer key.
Everything else, including `/`, goes to the Hermes dashboard, which has a
browser login.

The Hermes Desktop app connects separately to `https://<host>:9119`, also
through Caddy, also TLS.

## Requirements

- podman + podman-compose, running rootless.
- Two GPUs vLLM can use. The vllm-radiance image is gfx1201-only (R9700);
  a different card means a different serving image, not a knob here.
- Enough disk for the weights (~28 GB) plus the serving image (~4 GB) and its
  JIT/kernel caches (`radiance-cache/`, ~2 GB).
- Rootless podman can't bind port 443 by default, since it's privileged.
  Allow it:
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
- Check the render group ID on your host (`getent group render`). It's `105` here,
  set in `compose.yaml` under the vllm `group_add`; if yours differs, fix it or
  vLLM can't reach the GPUs.

## How to set it up

1. Seed the Hermes config. The real config lives in `hermes-data/` and is
   gitignored because it holds secrets. Copy the example, generate the
   workbench SSH keypair, and fill in the dashboard login:
   ```
   mkdir -p hermes-data projects
   cp hermes-config.example.yaml hermes-data/config.yaml
   ```
   Then generate the SSH keypair the gateway uses to reach the workbench (agent
   shells run on the `workbench` sidecar; see the `terminal:` section of the
   example config). The hermes and workbench services map container uid 10000
   to your own user (`userns_mode: keep-id:uid=10000`), so plain files owned
   by you are what the containers expect:
   ```
   mkdir -p hermes-data/workbench-ssh hermes-data/plugins-dev configs/workbench/ssh/hostkeys
   ssh-keygen -t ed25519 -N "" -f hermes-data/workbench-ssh/id_ed25519
   chmod 700 hermes-data/workbench-ssh
   chmod 400 hermes-data/workbench-ssh/id_ed25519
   cp hermes-data/workbench-ssh/id_ed25519.pub configs/workbench/ssh/authorized_keys
   ```
   Set a dashboard password hash:
   ```
   podman run --rm --entrypoint python docker.io/nousresearch/hermes-agent:latest \
     -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('your-password'))"
   ```
   Paste the result into `password_hash`. Then set a session secret, or every
   restart logs you out:
   ```
   openssl rand -hex 32
   ```
   Paste it into `secret`.

2. Seed the Honcho secrets.
   ```
   mkdir -p honcho-data
   cp honcho-env.example honcho-data/.env
   # replace REPLACE_ME in both lines with: openssl rand -hex 24
   ```
   The non-secret Honcho settings (model routing to vLLM, embeddings, feature
   flags) live in `configs/env/honcho.common` and are committed.

   On first boot, Honcho's initial migration creates 1536-dim vector columns,
   but our embedding model is 1024-dim. If the API exits with
   `documents.embedding dim (1536) does not match EMBEDDING_VECTOR_DIMENSIONS`,
   resize the (empty) columns once:
   ```
   podman run --rm --network hermes_stack \
     --env-file configs/env/honcho.common --env-file honcho-data/.env \
     --entrypoint /app/.venv/bin/python ghcr.io/plastic-labs/honcho:latest \
     scripts/configure_embeddings.py --yes
   ```

3. Bring it up.
   ```
   podman compose up -d
   ```
   The first start pulls the serving image, downloads the ~28 GB of weights
   into `models/`, JIT-compiles the AITER kernels into `radiance-cache/`
   (~10 min; later starts reuse them and take ~90 s), and Caddy generates its
   internal CA. Watch it come up with `podman logs -f vllm`. It's ready when
   the health check passes and Hermes starts.

4. Point Hermes at Honcho. Hermes finds Honcho via `hermes-data/honcho.json`
   (baseUrl `http://honcho:8000`, workspace/peer names) and
   `memory.provider: honcho` in its config:
   ```
   tee hermes-data/honcho.json <<'EOF'
   {
     "baseUrl": "http://honcho:8000",
     "environment": "local",
     "apiKey": "local",
     "workspace": "hermes",
     "peerName": "vinnie",
     "aiPeer": "hermes"
   }
   EOF
   podman exec hermes hermes config set memory.provider honcho
   podman compose up -d hermes   # recreate so env/config take effect
   ```
   Check it with `podman exec hermes hermes memory status`. Honcho should show
   as the active provider.

5. Trust the CA on your machines. Caddy signs with its own CA, so browsers and
   apps will warn until you trust the root. It's at:
   ```
   configs/caddy/data/caddy/pki/authorities/local/root.crt
   ```
   On Linux, `sudo trust anchor root.crt`. On macOS, add it to Keychain and set
   it to Always Trust. On Windows, import it into Trusted Root Certification
   Authorities.

## Using it

For coding tools and scripts, the endpoints are:

- OpenAI: `OPENAI_BASE_URL=https://llm.home.vincentfranco.com/v1`
- Anthropic: `ANTHROPIC_BASE_URL=https://llm.home.vincentfranco.com`

The model name is `qwen3.8-27b`. vLLM doesn't check the API key, but most
clients require one, so send any non-empty string.

The dashboard is at `https://llm.home.vincentfranco.com`. Log in with the
username and password you set.

The Hermes gateway API (`/hermes/v1/...`) needs a bearer token. Hermes writes
one to `hermes-data/.env` as `API_SERVER_KEY` on first run. Send it as
`Authorization: Bearer <key>`.

The Hermes Desktop app connects to `https://<host>:9119` in Remote Gateway
mode. Electron's Node backend doesn't use the OS cert store, so trusting the
CA system-wide isn't enough. Launch the app with the CA path set explicitly:
```
NODE_EXTRA_CA_CERTS=/path/to/root.crt hermes desktop
```
Put that in your shell profile or the app's `.desktop` launcher.

The agent runs in containers, not on your machine. The gateway lives in the
`hermes` container, and every agent shell command is dispatched over SSH to the
`workbench` sidecar (`terminal.backend: ssh`, port 2222). The workbench's shared
mounts are `/projects` (this repo's `./projects`), the `~/agents/repos`
artifact hub, read-only views of `hermes-data/{plugins,skills,memories}` at
their `/opt/data` paths, and the writable plugin staging dir
`hermes-data/plugins-dev`. The agent can't see the host, and it can't read the
gateway's own secrets and state in `hermes-data/`. Because of the uid mapping,
everything the agent writes in those shared dirs lands owned by your own user,
so you (and any host-side tools) can read and edit agent output directly.

### Agent-authored plugins

Plugins are Python that the gateway imports into its own process, so whatever
can write `hermes-data/plugins/` can run code with every gateway secret in
reach. The agent therefore drafts plugins in `hermes-data/plugins-dev/`
(`/opt/data/plugins-dev` from both its shell and its file tools), which Hermes
never loads. Once you've read one over, promote it:

```
cp -r hermes-data/plugins-dev/<name> hermes-data/plugins/
podman restart hermes
```

## Switching models

Both cards are fully committed to the default vLLM service, so an alternate
model replaces it rather than running alongside. `./model` does the swap:

```
./model list              # default + the profiles you can switch to
./model status            # which model server is up
./model use <profile>     # stop vllm, bring up that profile's server
./model use default       # back to Qwen3.8-27B-FP8 on vLLM
```

Whatever is up takes the `vllm` network alias, so Caddy's `/v1/*` route and
every client URL above stay the same; only the model name in requests changes.
Hermes and Honcho keep pointing at `vllm:8180` too, which means they'll talk to
whatever you switched to (or fail while nothing is up). Stopped servers stay
stopped across reboots, so the last choice sticks.

To add a profile, copy the template in the `compose.yaml` "Alternate models"
comment. Non-vLLM servers just need the same devices, the `vllm` alias, port
8180 and a `/health` endpoint. `./model use <name>` picks it up with no script
changes.

### ParoQuant MXFP6 (`paro` profile)

[hugypufy/Swift-Qwen3.8-27B-PARO-MXFP6](https://huggingface.co/hugypufy/Swift-Qwen3.8-27B-PARO-MXFP6)
is the [Swift fine-tune](https://huggingface.co/ukisai/Swift-Qwen3.8-27b) of
Qwen3.8-27B (shorter reasoning traces, a few points down on AIME/HMMT) with
ParoQuant rotations on MXFP6 weights, served W6A8 through the kernels in
[hugypufy/radiance-vllm-mxfp4](https://codeberg.org/hugypufy/radiance-vllm-mxfp4)
on the same radiance image. The submodule tracks that fork until ggz14 merges
[PR #46](https://codeberg.org/ggz14/radiance-vllm-mxfp4/pulls/46). Upstream
drives it with two scripts and `podman run`; here that is the `vllm-paro`
service plus one setup script:

```
git submodule update --init      # fork sources -> build/radiance-vllm-mxfp4 (pinned)
./setup-paro                     # ~25 GiB checkpoint + 2 GiB DFlash2 drafter into ./models,
                                 # builds the patched libr4d into ./radiance-cache/libr4d
./model use paro                 # swap it in; first start compiles kernels (several minutes,
                                 # looks idle; cached under ./radiance-cache/paro-mxfp6 after)
./model use default              # back to FP8
```

Compared with upstream's `setup-paroquant.sh --mxfp6` and
`MODEL_DIR=… MODE=prod SPEC=7 paroquant/run_paroquant.sh`:

- The in-container prelude (source patches, `hipcc`, sitecustomize registration)
  is `configs/paro/prelude.sh`, the service's entrypoint. Idempotent, so compose
  restarts are fine.
- The `-e` block is `configs/env/paro.env`, at `MODE=prod` values. Model and
  drafter dir names live there too.
- The `vllm serve` flags are the service's `command:` (SPEC=7, R4D attention,
  fp8 KV, 262k ctx). Ports, networks, devices and caps come from the shared
  `x-vllm-base`; no `--privileged`, `--ipc=host` or host networking.
- The checkpoint ships no MTP head, so the external DFlash2-FP8 drafter is the
  speculative path. The image's own libr4d NaNs this model's gated-delta-net
  layers; `./setup-paro` builds the patched one.
- Serves as `qwen3.8-27b` (Hermes and Honcho need no change; that id is now the
  Swift fine-tune) and `swift-qwen3.8-27b-paro-mxfp6`. Upstream's `DRY_RUN=1` is
  `podman-compose --profile paro config`.

For int5 (`Launch80/Qwen3.8-27B-PARO-int5`) or int4 (`z-lab/Qwen3.8-27B-PARO`):
`./setup-paro --int5` / `--int4`, then in `configs/env/paro.env` set
`PARO_MODEL_DIR` and `RADIANCE_PQ_I8/PG/ZPE` (1 for int5, 0 for int4), and give
`/cache` a fresh dir.

## Layout

- `compose.yaml` is the whole stack; `model` switches which model server is up.
- `build/workbench/` builds the agent's SSH sandbox image; `build/radiance-vllm-mxfp4/`
  is the pinned upstream ParoQuant/MXFP4 sources (submodule), used by
  `configs/paro/prelude.sh` + `configs/env/paro.env` (the `paro` profile) and `setup-paro`.
- `bench/run-bench.sh` is the serving benchmark harness.
- `configs/caddy/conf/Caddyfile` does TLS + routing; `configs/squid/squid.conf`
  is the egress policy.
- `configs/env/radiance.env` is the serving env; `configs/patches/protocol.py`
  is the one runtime patch (empty-`tools` tolerance for Hermes).
- `configs/env/honcho.common` + `configs/honcho/init.sql` configure Honcho.
- `configs/multica/` is the host-side Multica integration (own README).
- `hermes-config.example.yaml` and `honcho-env.example` seed the gitignored
  `hermes-data/config.yaml` and `honcho-data/.env`.

Not committed (gitignored): `models/` (weights, embedding model cache),
`radiance-cache/` (compile caches, the built libr4d),
`hermes-data/` (secrets + state), `honcho-data/` (Postgres data + DB password),
`projects/` (agent workspace), `configs/caddy/data/` (the CA private keys).

## Gotchas

- `api_key: none` breaks the desktop app. Hermes reads the literal "none" as
  no key, and the app fails credential resolution. Use any real non-empty
  string; the example uses `sk-local-vllm`.
- Without a session `secret` you're logged out on every restart with a
  `session_expired` error. Set one with `openssl rand -hex 32`.
- Port 443 needs both the sysctl and the firewall change above. Testing from
  the host itself is misleading because it goes over loopback and skips the
  firewall. Only another machine (or your phone) proves it's reachable.
- The dashboard and desktop app rewrite `config.yaml`, adding `_config_version`
  and a `custom_providers` list. That's normal, and it keeps your values.
- vLLM needs internet on first run to pull the model from HuggingFace, which is
  why it's on the `egress` network.
- If you add a service to the `stack` network, add it to `NO_PROXY` too. Hermes
  and Honcho route outbound traffic through Squid, and Squid denies private
  addresses, so any in-cluster hostname missing from their `NO_PROXY` list is
  unreachable: calls silently go to the proxy and get refused. Env changes
  also need `podman compose up -d <svc>` (a recreate), not `podman restart`.
- Don't add `user:` or `userns_mode:` to the vLLM service. The radiance image
  has to run as container root because AITER JIT-writes kernels into
  site-packages at startup; a non-root user crash-loops with
  `ModuleNotFoundError: aiter.ops.triton.unified_attention`. Rootless podman
  maps container root to your own user, so files stay yours either way.
- The `protocol.py` overlay is version-locked. It's the stock v0.27.1 file plus
  the empty-`tools` tolerance. When bumping the vllm-radiance image tag, diff
  the shipped file to confirm it's still stock before carrying the overlay
  forward.
