#!/usr/bin/env bash
# CML editor entrypoint: sync Claude + CAII from project env, then start code-server.
set -Eeuo pipefail

if [[ -x /usr/local/bin/configure-claude-from-env ]]; then
  # shellcheck source=/dev/null
  source /usr/local/bin/configure-claude-from-env
fi

CODE_SERVER_BIND="${CODE_SERVER_BIND:-127.0.0.1:8090}"
exec /usr/bin/code-server --auth=none --bind-addr="${CODE_SERVER_BIND}" --disable-telemetry "$@"
