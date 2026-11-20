#!/usr/bin/env bash
# One front door for CLI coding agents (Claude, Codex, Gemini, Ollama).
#
#   scripts/agent-cli.sh status                 # which CLIs are installed / logged in
#   scripts/agent-cli.sh login <agent>          # subscription login (headless / device flow)
#   scripts/agent-cli.sh run <agent> "<prompt>" # one non-interactive session
#   scripts/agent-cli.sh review [base]          # independent review: codex -> gemini -> ollama
#
# Env: OLLAMA_MODEL (default glm-4.6:cloud), REVIEW_ORDER (default "codex gemini ollama")
set -uo pipefail
OLLAMA_MODEL="${OLLAMA_MODEL:-glm-4.6:cloud}"
REVIEW_ORDER="${REVIEW_ORDER:-codex gemini ollama}"
have() { command -v "$1" >/dev/null 2>&1; }

# Cloud containers have no systemd; start the server on demand.
ollama_up() {
  curl -fsS -m 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && return 0
  nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS -m 1 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && return 0
    read -r -t 1 _ </dev/null || true
  done
  return 1
}

status() {
  for a in claude codex gemini ollama; do
    if have "$a"; then printf '%-7s installed  %s\n' "$a" "$($a --version 2>/dev/null | head -1)"
    else printf '%-7s MISSING (run scripts/install-agent-clis.sh)\n' "$a"; fi
  done
  have codex && { codex login status >/dev/null 2>&1 && echo "codex: logged in" || echo "codex: not logged in"; }
  [ -f "$HOME/.gemini/oauth_creds.json" ] && echo "gemini: logged in" || echo "gemini: not logged in"
  have ollama && { ollama_up; ollama signin 2>&1 | grep -qi 'need to be signed in' && echo "ollama: not signed in" || echo "ollama: signed in"; }
}

login() {
  case "${1:-}" in
    claude) claude setup-token ;;                       # Claude Pro/Max subscription token
    codex)  codex login --device-auth ;;                # ChatGPT Plus/Pro subscription, device code
    gemini) NO_BROWSER=true gemini ;;                   # Google account OAuth, paste-back code
    ollama) ollama_up; ollama signin ;;                            # ollama.com account (cloud models)
    *) echo "usage: login claude|codex|gemini|ollama"; return 2 ;;
  esac
}

run() {
  local agent="$1"; shift; local prompt="$*"
  case "$agent" in
    claude) claude -p "$prompt" ;;
    codex)  codex exec "$prompt" ;;
    gemini) gemini -p "$prompt" ;;
    ollama) ollama_up; ollama run "$OLLAMA_MODEL" "$prompt" ;;
    *) echo "unknown agent: $agent"; return 2 ;;
  esac
}

review() {
  local base="${1:-origin/main}"
  local diff; diff="$(git diff "$base"...HEAD)"
  [ -z "$diff" ] && { echo "no diff vs $base"; return 0; }
  local ask="You are an independent senior reviewer. Review this diff for correctness bugs, security issues (especially leaked secrets), and violations of .specify/memory/constitution.md. List findings by severity with file:line. Diff:"
  for a in $REVIEW_ORDER; do
    have "$a" || { echo "skip $a: not installed"; continue; }
    echo "==> independent review by $a"
    case "$a" in
      codex)  codex exec review --base "${base#origin/}" 2>/dev/null || printf '%s\n%s' "$ask" "$diff" | codex exec - ;;
      gemini) printf '%s\n%s' "$ask" "$diff" | gemini -p "review" ;;
      ollama) ollama_up; printf '%s\n%s' "$ask" "$diff" | ollama run "$OLLAMA_MODEL" ;;
    esac && return 0
    echo "warn: $a review failed, falling back"
  done
  echo "error: no reviewer succeeded"; return 1
}

cmd="${1:-status}"; shift || true
case "$cmd" in status|login|run|review) "$cmd" "$@";; *) sed -n '2,9p' "$0";; esac
