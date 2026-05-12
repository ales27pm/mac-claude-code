# mac-claude-code

Local Claude Code stack for a macOS VM backed by an Ubuntu host running Ollama, Qwen2.5 Coder abliterated, and a LiteLLM proxy.

The goal is simple: keep VS Code and Claude Code inside the macOS VM, but run the actual model on the Ubuntu host where the NVIDIA GPU is available.

```text
macOS VM
  VS Code + Claude Code CLI
        ↓ ANTHROPIC_* env
Ubuntu host
  LiteLLM proxy
        ↓
  Ollama
        ↓
  dagbs/qwen2.5-coder-7b-instruct-abliterated:q4_k_m
```

## What this repository contains

```text
.
├── .env.example
├── .github/workflows/shellcheck.yml
├── .gitignore
├── README.md
└── scripts
    ├── macos-vm-claude-client.sh
    └── ubuntu-host-qwen-claude-stack.sh
```

## Default model

The default model is:

```text
dagbs/qwen2.5-coder-7b-instruct-abliterated:q4_k_m
```

This is the safe default for an RTX 2070 8 GB class machine. It keeps the model around 4.7 GB and leaves VRAM for KV cache. Start with `q4_k_m`, then test `q5_k_m` only after the stack is stable.

## Ubuntu host install

Run this on the real host machine, not inside the macOS VM.

```bash
git clone https://github.com/ales27pm/mac-claude-code.git
cd mac-claude-code
chmod +x scripts/ubuntu-host-qwen-claude-stack.sh
./scripts/ubuntu-host-qwen-claude-stack.sh install
```

The host script installs or validates:

- base Ubuntu packages
- NVIDIA visibility through `nvidia-smi`
- Ollama
- the Qwen Coder abliterated model
- a tuned Ollama wrapper model named `qwen-coder-ablit`
- LiteLLM in an isolated Python venv
- a user-level LiteLLM systemd service
- UFW rules if UFW is active
- structured logs and status JSON

### Host commands

```bash
./scripts/ubuntu-host-qwen-claude-stack.sh status
./scripts/ubuntu-host-qwen-claude-stack.sh env
./scripts/ubuntu-host-qwen-claude-stack.sh logs
./scripts/ubuntu-host-qwen-claude-stack.sh restart
./scripts/ubuntu-host-qwen-claude-stack.sh stop
./scripts/ubuntu-host-qwen-claude-stack.sh uninstall
```

### Host tuning

```bash
MODEL_SOURCE=dagbs/qwen2.5-coder-7b-instruct-abliterated:q5_k_m \
NUM_CTX=8192 \
./scripts/ubuntu-host-qwen-claude-stack.sh install
```

Useful options:

```bash
MODEL_SOURCE=dagbs/qwen2.5-coder-7b-instruct-abliterated:q4_k_m
MODEL_ALIAS=qwen-coder-ablit
NUM_CTX=8192
LITELLM_KEY=local-dev-key
OPEN_TO_LAN=1
SKIP_MODEL_PULL=1
FORCE_RECREATE_MODEL=1
FORCE_REINSTALL_LITELLM=1
```

## macOS VM install

Run this inside the macOS VM, from the project folder where you want Claude Code to operate.

```bash
git clone https://github.com/ales27pm/mac-claude-code.git
cd mac-claude-code
chmod +x scripts/macos-vm-claude-client.sh
HOST_IP=<ubuntu-host-ip> ./scripts/macos-vm-claude-client.sh install
```

The macOS script installs or validates:

- Homebrew, unless disabled
- Node.js and npm
- Claude Code CLI
- a project `.env` file using the host LiteLLM endpoint
- a `claude-local` wrapper that auto-loads `.env`
- a `qwen-stack-status` terminal health command
- structured logs under `~/Library/Logs/mac-claude-code`

### macOS commands

```bash
./scripts/macos-vm-claude-client.sh status
./scripts/macos-vm-claude-client.sh doctor
./scripts/macos-vm-claude-client.sh env
./scripts/macos-vm-claude-client.sh launch
./scripts/macos-vm-claude-client.sh uninstall
```

Once installed:

```bash
qwen-stack-status
claude-local
```

Inside Claude Code:

```text
/status
```

## Claude Code environment

The macOS script writes a project `.env` like this:

```env
ANTHROPIC_API_KEY=local-dev-key
ANTHROPIC_BASE_URL=http://<ubuntu-host-ip>:4000
ANTHROPIC_MODEL=qwen-coder-ablit
```

This matches Claude Code's custom backend pattern: Claude Code is the client; LiteLLM exposes an API endpoint; Ollama serves the model.

## Security notes

This stack is intended for a trusted local LAN or VM bridge.

- `.env` files are ignored by Git.
- LiteLLM uses a local master key.
- The host script binds Ollama and LiteLLM to LAN when `OPEN_TO_LAN=1`.
- Do not expose ports `11434` or `4000` to the public Internet.
- Use firewall rules if the host is on an untrusted network.
- Rotate `LITELLM_KEY` if the VM image is shared.

## Logs and state

Ubuntu host:

```text
~/.local/share/mac-claude-code/
~/.local/state/mac-claude-code/logs/
~/.local/state/mac-claude-code/status.json
```

macOS VM:

```text
~/Library/Application Support/mac-claude-code/status.json
~/Library/Logs/mac-claude-code/
~/.local/bin/claude-local
~/.local/bin/qwen-stack-status
```

## Troubleshooting

### macOS VM cannot reach host

On Ubuntu host:

```bash
hostname -I
./scripts/ubuntu-host-qwen-claude-stack.sh status
```

Inside macOS VM:

```bash
HOST_IP=<ubuntu-host-ip> ./scripts/macos-vm-claude-client.sh doctor
curl http://<ubuntu-host-ip>:4000/v1/models -H 'Authorization: Bearer local-dev-key'
```

### Ollama is CPU-only

On Ubuntu host:

```bash
nvidia-smi
systemctl status ollama --no-pager
journalctl -u ollama -n 120 --no-pager
```

If `nvidia-smi` is missing, fix the host NVIDIA driver first. Do not expect CUDA acceleration from inside the macOS VM.

### Claude Code asks for login

Make sure the project `.env` is loaded through `claude-local`:

```bash
cat .env
claude-local
```

If needed for first-run detection, temporarily test with:

```env
ANTHROPIC_AUTH_TOKEN=local-dev-key
```

Remove `ANTHROPIC_AUTH_TOKEN` after the first successful run to avoid conflicts.

## CI

The repository includes a GitHub Actions workflow that runs:

- `bash -n` syntax checks
- ShellCheck with selected ignores for generated environment-loader patterns

## One-shot run order

```bash
# Ubuntu host
chmod +x scripts/ubuntu-host-qwen-claude-stack.sh
./scripts/ubuntu-host-qwen-claude-stack.sh install

# macOS VM
chmod +x scripts/macos-vm-claude-client.sh
HOST_IP=<ubuntu-host-ip> ./scripts/macos-vm-claude-client.sh install
qwen-stack-status
claude-local
```
