#!/usr/bin/env bash
# Runs as root at IMAGE BUILD time (the volume is NOT mounted yet, so we can't chown the
# volume itself here). Instead we pre-create the mount target owned by the remote user. When
# Docker first mounts the fresh named volume, it seeds the volume from this directory —
# copying its contents AND ownership — so the volume comes up owned by the remote user and
# Claude Code can write .credentials.json into it. No runtime chown / sudo required.
set -euo pipefail

# _REMOTE_USER / _REMOTE_USER_HOME are injected by the devcontainer feature installer.
USER_NAME="${_REMOTE_USER:-vscode}"
USER_HOME="${_REMOTE_USER_HOME:-/home/${USER_NAME}}"
# Don't assume the primary group is named after the user — true for vscode, not in general.
USER_GROUP="$(id -gn "${USER_NAME}" 2>/dev/null || echo "${USER_NAME}")"

CLAUDE_DIR="${USER_HOME}/.claude"

# The volume mount target in devcontainer-feature.json must be a literal path — the mounts
# block is resolved by the CLI before this script runs, so it cannot reference
# _REMOTE_USER_HOME. It is therefore hardcoded to /home/vscode/.claude. If the remote user
# lives elsewhere, the volume mounts over a directory this script never seeded: ownership is
# root:root and Claude Code cannot write its credentials. Say so at build time rather than
# letting it fail confusingly at first login.
if [ "${CLAUDE_DIR}" != "/home/vscode/.claude" ]; then
  echo "claude-code-persist-login: WARNING the volume mount target is hardcoded to" \
       "/home/vscode/.claude but this container's remote user (${USER_NAME}) has" \
       "${CLAUDE_DIR}. Edit the 'mounts' target in the feature's devcontainer-feature.json," \
       "or add your own mount, or the login will NOT persist." >&2
fi
CLAUDE_JSON="${USER_HOME}/.claude.json"
CLAUDE_JSON_TARGET="${CLAUDE_DIR}/.claude.json"

mkdir -p "${CLAUDE_DIR}"

# Claude Code's account/session config (oauthAccount, mcpServers, projects, ...) is written to
# ~/.claude.json, a FILE sitting directly in $HOME — outside the ~/.claude/ dir the volume
# above mounts over. Left alone it lives on the container's throwaway layer and resets on every
# rebuild even though ~/.claude/.credentials.json persists fine. Fix: store it inside the
# mounted dir and symlink $HOME/.claude.json to it, so both live on the same volume.
if [ -e "${CLAUDE_JSON}" ] && [ ! -L "${CLAUDE_JSON}" ]; then
  rm -f "${CLAUDE_JSON}"
fi
touch "${CLAUDE_JSON_TARGET}"
ln -sf "${CLAUDE_JSON_TARGET}" "${CLAUDE_JSON}"

chown -R "${USER_NAME}:${USER_GROUP}" "${CLAUDE_DIR}"
chown -h "${USER_NAME}:${USER_GROUP}" "${CLAUDE_JSON}"
chmod 700 "${CLAUDE_DIR}"

echo "claude-code-persist-login: seeded ${CLAUDE_DIR} (incl. symlinked .claude.json) owned by ${USER_NAME}"
