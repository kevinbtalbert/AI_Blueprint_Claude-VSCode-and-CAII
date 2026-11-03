# syntax=docker/dockerfile:1
# Cloudera ML workbench + VS Code (code-server) + Claude Code CLI → LiteLLM → Cloudera AI Inference
FROM --platform=linux/amd64 docker.repository.cloudera.com/cloudera/cdsw/ml-runtime-pbj-workbench-python3.13-standard:2026.08.1-b5

ARG CODE_SERVER_VERSION=4.141.0

USER root

# ── System dependencies (agent tooling) ────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        vim nano \
        tmux screen \
        curl wget less tree jq unzip zip \
        ripgrep fd-find bat \
        netcat-openbsd dnsutils iputils-ping \
        pciutils htop procps lsof strace \
        ssh-client rsync socat ca-certificates git \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat

# ── code-server (browser VS Code) ───────────────────────────────────────────
# Pattern from https://github.com/cloudera/community-ml-runtimes/tree/main/vscode
RUN curl -fsSL https://code-server.dev/install.sh | sh -s -- --version "${CODE_SERVER_VERSION}"

# ── Node.js 22.23.4+ (Oct 2026 security release; claude-code requires node >= 22) ─
# Not the Node bundled in CDH parcels (e.g. SMM UI on DL nodes) — this runtime uses its own Node under /usr/local.
ARG NODE_VERSION=22.23.4
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    | tar -xJ -C /usr/local --strip-components=1 \
    && node --version \
    && python3 -c "import subprocess; v=subprocess.check_output(['node','--version'], text=True).strip().lstrip('v'); p=tuple(map(int,(v.split('.')+['0','0','0'])[:3])); assert p>=(22,23,4), f'Node {v} < 22.23.4 (required security baseline)'"

COPY scripts/lib/resolve-claude-model-aliases.py /opt/cai-claude/lib/resolve-claude-model-aliases.py

# ── Claude Code CLI ──────────────────────────────────────────────────────────
# Optional: --build-arg CLAUDE_CLI_VERSION=<semver> pins the npm package (recommended with -t :<same-semver>).
# If unset, the build resolves @anthropic-ai/claude-code "latest" from the npm registry and pins to that version.
ARG CLAUDE_CLI_VERSION
RUN bash -euo pipefail -c '\
    mkdir -p /opt/cai-claude; \
    if [ -z "${CLAUDE_CLI_VERSION:-}" ]; then \
        CLAUDE_CLI_VERSION="$(curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest \
            | python3 -c "import json,sys; print(json.load(sys.stdin)[\"version\"])")"; \
    fi; \
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CLI_VERSION}"; \
    command -v claude >/dev/null; \
    command -v claude > /opt/cai-claude/claude-cli-bin; \
    claude --version 2>/dev/null | grep -oE "[0-9]+(\.[0-9]+)*" | head -1 > /opt/cai-claude/claude-cli-version; \
    python3 /opt/cai-claude/lib/resolve-claude-model-aliases.py "$(cat /opt/cai-claude/claude-cli-bin)" > /opt/cai-claude/claude-model-aliases.env; \
    grep -E "^CLAUDE_(OPUS|SONNET|HAIKU)_ALIAS=." /opt/cai-claude/claude-model-aliases.env >/dev/null \
    '

# ── LiteLLM proxy (Anthropic API → OpenAI-compatible CAI Inference) ──────────
COPY requirements-litellm.txt /opt/cai-claude/requirements-litellm.txt
COPY scripts/verify-litellm-install.sh /opt/cai-claude/verify-litellm-install.sh
RUN chmod +x /opt/cai-claude/verify-litellm-install.sh && \
    python3 -m venv /opt/cai-claude/venv && \
    /opt/cai-claude/venv/bin/pip install --no-cache-dir --upgrade pip wheel packaging && \
    /opt/cai-claude/venv/bin/pip install --no-cache-dir -r /opt/cai-claude/requirements-litellm.txt && \
    SKIP_LITELLM_SMOKE=1 /opt/cai-claude/verify-litellm-install.sh /opt/cai-claude/venv

# ── Runtime directories ──────────────────────────────────────────────────────
RUN mkdir -p /home/cdsw/.claude/cai-inference /opt/cai-claude/lib && \
    chown -R cdsw:cdsw /home/cdsw/.claude

COPY scripts/lib/cai-common.sh /opt/cai-claude/lib/cai-common.sh
COPY scripts/lib/ml-runtime-version-from-claude.sh /opt/cai-claude/lib/ml-runtime-version-from-claude.sh
COPY scripts/lib/finalize-ml-runtime-build.sh /opt/cai-claude/lib/finalize-ml-runtime-build.sh
COPY scripts/cai-runtime-startup.sh /etc/profile.d/claude-caii.sh
COPY scripts/vscode-launch.sh /usr/local/bin/vscode
COPY scripts/configure-claude-from-env.sh /usr/local/bin/configure-claude-from-env

RUN chmod +x /etc/profile.d/claude-caii.sh /opt/cai-claude/lib/cai-common.sh \
        /opt/cai-claude/lib/ml-runtime-version-from-claude.sh \
        /opt/cai-claude/lib/finalize-ml-runtime-build.sh \
        /usr/local/bin/vscode /usr/local/bin/configure-claude-from-env && \
    ln -sf /usr/local/bin/vscode /usr/local/bin/ml-runtime-editor && \
    /opt/cai-claude/lib/finalize-ml-runtime-build.sh /opt/cai-claude/claude-cli-version && \
    echo '[ -f /etc/profile.d/claude-caii.sh ] && source /etc/profile.d/claude-caii.sh' \
        >> /etc/bash.bashrc && \
    grep -q 'claude-caii.sh' /home/cdsw/.bashrc 2>/dev/null || \
      printf '%s\n' '[ -f /etc/profile.d/claude-caii.sh ] && . /etc/profile.d/claude-caii.sh' >> /home/cdsw/.bashrc && \
    chown cdsw:cdsw /home/cdsw/.bashrc && \
    mkdir -p /home/cdsw/.local/share/code-server/User && \
    chown -R cdsw:cdsw /home/cdsw/.local

# ── Default environment (override in CML project / session settings) ─────────
ENV CAI_HOME="/home/cdsw/.claude/cai-inference" \
    CAI_VENV_BIN="/opt/cai-claude/venv/bin" \
    CAII_OPENAI_BASE_URL="" \
    CAII_API_TOKEN="" \
    CAII_MODEL="" \
    CAII_LITELLM_PORT="${CAII_LITELLM_PORT:-4000}" \
    CAII_MAX_OUTPUT_TOKENS="8192" \
    CAII_MAX_INPUT_TOKENS="57344" \
    LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES="true" \
    CODE_SERVER_BIND="127.0.0.1:8090"

WORKDIR /home/cdsw

# Cloudera ML runtime metadata (image config). For catalog registration, pass the same semver as
# CLAUDE_CLI_VERSION / -t :<semver> using the Option B docker build one-liner in README.md.
ARG ML_RUNTIME_SHORT_VERSION
ARG ML_RUNTIME_MAINTENANCE_VERSION
ARG ML_RUNTIME_FULL_VERSION
ARG ML_RUNTIME_DESCRIPTION

ENV ML_RUNTIME_EDITION="VS Code + Claude Code with CAI Inference" \
    ML_RUNTIME_EDITOR="VsCode" \
    ML_RUNTIME_KERNEL="Python 3.13" \
    ML_RUNTIME_SHORT_VERSION=${ML_RUNTIME_SHORT_VERSION} \
    ML_RUNTIME_MAINTENANCE_VERSION=${ML_RUNTIME_MAINTENANCE_VERSION} \
    ML_RUNTIME_FULL_VERSION=${ML_RUNTIME_FULL_VERSION} \
    ML_RUNTIME_DESCRIPTION=${ML_RUNTIME_DESCRIPTION}

LABEL com.cloudera.ml.runtime.edition=$ML_RUNTIME_EDITION \
    com.cloudera.ml.runtime.full-version=$ML_RUNTIME_FULL_VERSION \
    com.cloudera.ml.runtime.short-version=$ML_RUNTIME_SHORT_VERSION \
    com.cloudera.ml.runtime.maintenance-version=$ML_RUNTIME_MAINTENANCE_VERSION \
    com.cloudera.ml.runtime.description=$ML_RUNTIME_DESCRIPTION \
    com.cloudera.ml.runtime.editor=$ML_RUNTIME_EDITOR \
    com.cloudera.ml.runtime.claude-cli-version=$ML_RUNTIME_FULL_VERSION

USER cdsw

# ── Claude Code VS Code extension (Visual Studio Marketplace) ────────────────
# https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code
RUN code-server --install-extension anthropic.claude-code

RUN printf '%s\n' \
      '{' \
      '  "extensions.recommendations": ["anthropic.claude-code"]' \
      '}' \
      > /home/cdsw/.local/share/code-server/User/settings.json
