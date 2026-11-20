#!/usr/bin/env bash
# Install the coding-agent CLIs and SDKs used by Zeus and harness2.
# Idempotent and non-interactive; safe to run from a cloud setup script.
# Logins (subscriptions) are NOT done here — see `scripts/agent-cli.sh login`.
set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
step() { printf '\n==> %s\n' "$*"; }

step "Node CLIs: Claude Code, Codex, Gemini"
have claude || npm install -g @anthropic-ai/claude-code
have codex  || npm install -g @openai/codex
have gemini || npm install -g @google/gemini-cli

step "Python SDKs: LiteLLM, Claude Agent SDK, OpenAI, Google GenAI, Ollama"
if have uv; then PIP="uv pip install --system"; else PIP="pip install"; fi
$PIP -q litellm claude-agent-sdk anthropic openai google-genai ollama || echo "warn: python SDK install failed"

step "TypeScript SDKs (global, for scripts): Vercel AI SDK + providers"
npm install -g ai @ai-sdk/anthropic @ai-sdk/openai @ai-sdk/google ollama-ai-provider-v2 >/dev/null 2>&1 \
  || echo "warn: TS SDK install failed"

step "Ollama"
if ! have ollama; then
  if curl -fsSL https://ollama.com/install.sh -o /tmp/ollama-install.sh; then
    sh /tmp/ollama-install.sh || echo "warn: ollama install failed"
  else
    echo "warn: ollama.com not reachable (allow ollama.com in the environment's network settings)"
  fi
fi

step "Versions"
for c in claude codex gemini ollama; do printf '%-7s ' "$c"; ($c --version 2>/dev/null || echo "not installed") | head -1; done
python3 -c "import litellm, claude_agent_sdk; print('python SDKs ok')" 2>/dev/null || echo "python SDKs missing"
