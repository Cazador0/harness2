#!/usr/bin/env bash
# setup-agent-harness.sh — Unified setup and health check for Harness², Ollama, Zed, and Zeus.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> 1. Checking core prerequisites (uv, python, git)"
command -v git >/dev/null 2>&1 || { echo "error: git is required"; exit 1; }
command -v uv >/dev/null 2>&1 || {
  echo "Installing uv into ~/.local/bin..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
}

echo "==> 2. Verifying local Ollama daemon & models"
if ! curl -fsS -m 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  echo "Starting Ollama daemon in background..."
  nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
  sleep 2
fi
curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1 && echo "Ollama daemon: OK"

echo "==> 3. Configuring Zed editor for Zeus MCP context server"
mkdir -p .zed
cat << 'EOF' > .zed/settings.json
{
  "context_servers": {
    "zeus": {
      "command": "uv",
      "args": ["run", "--directory", "/home/antigravity/Cazador0/zeus", "zeus-mcp"]
    }
  }
}
EOF
echo "Zed MCP configuration: OK"

echo "==> 4. Verifying Harness2 unit test suite"
uv run pytest tests/test_file_editor.py tests/test_sandbox_guards.py tests/test_golden_pr.py -q
echo "Harness2 Agent environment setup completed successfully!"
