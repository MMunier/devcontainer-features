#!/usr/bin/env bash
#
# authorized-key devcontainer feature — install script.
#
# Runs as ROOT at image-build time. Option values are exposed as uppercased
# env vars (PUBLICKEY, TARGETUSER). The devcontainer's remote user is provided
# as _REMOTE_USER by the build.
#
set -euo pipefail

PUBLIC_KEY="${PUBLICKEY:-}"
TARGET_USER="${TARGETUSER:-automatic}"

# Resolve 'automatic' to the devcontainer remote user, falling back sensibly.
if [ "$TARGET_USER" = "automatic" ]; then
  TARGET_USER="${_REMOTE_USER:-}"
  if [ -z "$TARGET_USER" ]; then
    # Fall back to the first common non-root user, else root.
    for u in vscode node codespace ubuntu; do
      if id "$u" >/dev/null 2>&1; then TARGET_USER="$u"; break; fi
    done
    TARGET_USER="${TARGET_USER:-root}"
  fi
fi

if [ -z "$PUBLIC_KEY" ]; then
  echo "authorized-key: no publicKey provided — nothing to do."
  exit 0
fi

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "authorized-key: ERROR target user '$TARGET_USER' does not exist" >&2
  exit 1
fi

# Resolve the user's home from the passwd DB (don't assume /home/<user>).
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
USER_GROUP="$(id -gn "$TARGET_USER")"
if [ -z "$USER_HOME" ]; then
  echo "authorized-key: ERROR could not determine home for '$TARGET_USER'" >&2
  exit 1
fi

SSH_DIR="${USER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

install -d -m 700 -o "$TARGET_USER" -g "$USER_GROUP" "$SSH_DIR"

# Append the key(s) if not already present (idempotent across rebuilds/layers).
# `printf %b` expands any \n the user used to separate multiple keys.
touch "$AUTH_KEYS"
printf '%b\n' "$PUBLIC_KEY" | while IFS= read -r key; do
  [ -z "$key" ] && continue
  if ! grep -qxF "$key" "$AUTH_KEYS" 2>/dev/null; then
    printf '%s\n' "$key" >> "$AUTH_KEYS"
  fi
done

chown "$TARGET_USER":"$USER_GROUP" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

echo "authorized-key: wrote $(grep -c . "$AUTH_KEYS") key line(s) to ${AUTH_KEYS} (user ${TARGET_USER})"
