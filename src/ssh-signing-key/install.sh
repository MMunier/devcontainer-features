#!/usr/bin/env bash
# Runs as root at IMAGE BUILD time. Two jobs:
#
#   1. Pre-seed ~/.ssh owned by the remote user, so the attach script can write into it
#      without needing sudo at runtime.
#   2. Install that attach script, with the option values baked in.
#
# The public key itself is NOT baked in: it comes from a runtime env var (injected via an
# --env-file in the project's runArgs, or remoteEnv), so the same image works for any user and
# the launching shell never has to have sourced anything first.
set -euo pipefail

# Option values arrive as uppercased env vars; _REMOTE_USER / _REMOTE_USER_HOME are injected
# by the devcontainer feature installer.
PUBKEY_ENV="${PUBKEYENV:-SSH_SIGNING_PUBKEY}"
KEY_FILENAME="${KEYFILENAME:-id_ed25519_sk.pub}"
SIGN_ALL="${SIGNALLCOMMITS:-true}"

USER_NAME="${_REMOTE_USER:-vscode}"
USER_HOME="${_REMOTE_USER_HOME:-/home/${USER_NAME}}"
# Don't assume the primary group is named after the user — true for vscode, not in general.
USER_GROUP="$(id -gn "${USER_NAME}" 2>/dev/null || echo "${USER_NAME}")"

# A path separator here would write outside ~/.ssh; reject rather than silently obey.
case "${KEY_FILENAME}" in
  */*|"")
    echo "ssh-signing-key: ERROR keyFilename must be a bare filename, got '${KEY_FILENAME}'" >&2
    exit 1 ;;
esac

SSH_DIR="${USER_HOME}/.ssh"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chown -R "${USER_NAME}:${USER_GROUP}" "${SSH_DIR}"

ATTACH_SCRIPT="/usr/local/share/ssh-signing-key-attach.sh"

# Unquoted heredoc: the option values are baked in. None of them is a secret.
cat > "${ATTACH_SCRIPT}" <<EOF
#!/usr/bin/env bash
# Installed by the ssh-signing-key devcontainer feature. Runs as the REMOTE USER on every
# attach — not just on create — because VS Code re-copies ~/.gitconfig from the host on each
# connect, which would otherwise clobber user.signingkey with a host-only path that does not
# exist in this container.
PUBKEY_ENV="${PUBKEY_ENV}"
KEY_FILENAME="${KEY_FILENAME}"
SIGN_ALL="${SIGN_ALL}"
EOF

# Quoted heredoc: everything below is literal shell, expanded at attach time.
cat >> "${ATTACH_SCRIPT}" <<'EOF'

set -euo pipefail

PUBKEY="${!PUBKEY_ENV:-}"

# No key configured is a skip, not a failure: an unsigned commit is a degraded container, not
# a broken one, and attach must not fail because someone hasn't set this up yet.
if [ -z "$PUBKEY" ]; then
  echo "ssh-signing-key: \$$PUBKEY_ENV is not set — commit signing NOT configured." \
       "Put your PUBLIC key (one line from ~/.ssh/${KEY_FILENAME} on the HOST) in the env" \
       "file passed via runArgs, then reattach."
  exit 0
fi

# A private key here would be written to disk and pointed at by git as if it were public.
case "$PUBKEY" in
  *"PRIVATE KEY"*)
    echo "ssh-signing-key: refusing to install \$$PUBKEY_ENV — that is a PRIVATE key." \
         "This variable takes the PUBLIC key only (the .pub file)." >&2
    exit 1 ;;
esac

KEY_PATH="$HOME/.ssh/$KEY_FILENAME"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
printf '%s\n' "$PUBKEY" > "$KEY_PATH"
chmod 644 "$KEY_PATH"

git config --global gpg.format ssh
git config --global user.signingkey "$KEY_PATH"
if [ "$SIGN_ALL" = "true" ]; then
  git config --global commit.gpgsign true
fi

# The private half never enters the container: signing goes out through the host's ssh-agent
# over VS Code's automatic forwarding socket. If the agent has no keys, signing fails at
# commit time with a message that does not obviously point here — so check now.
if [ -n "${SSH_AUTH_SOCK:-}" ] && command -v ssh-add >/dev/null 2>&1; then
  if ! ssh-add -l >/dev/null 2>&1; then
    echo "ssh-signing-key: key installed, but the forwarded ssh-agent has no keys —" \
         "run 'ssh-add ~/.ssh/id_ed25519_sk' on the HOST or commits will fail to sign."
  fi
else
  echo "ssh-signing-key: key installed, but no ssh-agent is forwarded (SSH_AUTH_SOCK unset)" \
       "— signing needs the HOST agent; commits will fail to sign until it is available."
fi

echo "ssh-signing-key: git configured to sign with $KEY_PATH"
EOF

chmod 755 "${ATTACH_SCRIPT}"

echo "ssh-signing-key: seeded ${SSH_DIR} owned by ${USER_NAME}; will read \$${PUBKEY_ENV} at attach"
