#!/usr/bin/env bash
# Map Cloudera AI project CAII_* env into LiteLLM + Claude Code settings before VS Code starts.
set -Eeuo pipefail

export CAI_HOME="${CAI_HOME:-${HOME}/.claude/cai-inference}"
export CAI_VENV_BIN="${CAI_VENV_BIN:-/opt/cai-claude/venv/bin}"
export CAII_LITELLM_PORT="${CAII_LITELLM_PORT:-4000}"
export LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES="${LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES:-true}"

# shellcheck disable=SC1091
source /opt/cai-claude/lib/cai-common.sh

if cai_caii_env_ready; then
  cai_sync_config 0 || true
  cai_export_claude_env || true
fi
