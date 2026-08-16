#!/usr/bin/env bash
# Runs as root at IMAGE BUILD time. Installs an attach script that wires up `gh` auth from a
# token supplied at runtime, with the non-secret option values baked in.
#
# `gh` itself is NOT installed here — the official github-cli feature does that well
# (GPG-verified apt repo, extension support), and is declared as a dependency. Duplicating it
# would mean a second, worse installer racing the first.
#
# The token is NOT baked in: it comes from a runtime env var (injected via an --env-file in
# the project's runArgs, or remoteEnv), so no secret ends up in an image layer, and the same
# image works for any user.
set -euo pipefail

# Option values arrive as uppercased env vars; _REMOTE_USER is injected by the devcontainer
# feature installer.
TOKEN_ENV="${TOKENENV:-GH_TOKEN}"
HOST="${HOST:-github.com}"
SETUP_GIT="${SETUPGIT:-true}"

# The env var name is expanded into the attach script and dereferenced there; anything that
# isn't a valid shell identifier would be a syntax error at attach time instead of a clear
# error now.
case "${TOKEN_ENV}" in
  [!A-Za-z_]*|*[!A-Za-z0-9_]*|"")
    echo "github-cli-auth: ERROR tokenEnv must be a valid shell identifier, got '${TOKEN_ENV}'" >&2
    exit 1 ;;
esac

# `gh` takes a bare hostname. A scheme or path here would be accepted at build time and only
# fail later, at the point where the API call is made.
case "${HOST}" in
  *://*|*/*|"")
    echo "github-cli-auth: ERROR host must be a bare hostname (no scheme, no path), got '${HOST}'" >&2
    exit 1 ;;
esac

ATTACH_SCRIPT="/usr/local/share/github-cli-auth-attach.sh"

# Unquoted heredoc: the option values are baked in. None of them is the token.
cat > "${ATTACH_SCRIPT}" <<EOF
#!/usr/bin/env bash
# Installed by the github-cli-auth devcontainer feature. Runs as the REMOTE USER on every
# attach. Reading the token here rather than at build time keeps the secret out of the image
# layers and makes rotation a matter of editing the env file and reconnecting.
TOKEN_ENV="${TOKEN_ENV}"
HOST="${HOST}"
SETUP_GIT="${SETUP_GIT}"
EOF

# Quoted heredoc: everything below is literal shell, expanded at attach time.
cat >> "${ATTACH_SCRIPT}" <<'EOF'

set -euo pipefail

TOKEN="${!TOKEN_ENV:-}"

# No token configured is a skip, not a failure: `gh` still works for public read-only calls,
# and attach must not break because someone hasn't set this up yet.
if [ -z "$TOKEN" ]; then
  echo "github-cli-auth: \$$TOKEN_ENV is not set — gh is NOT authenticated to ${HOST}." \
       "Create a token at https://${HOST}/settings/tokens (scopes: repo, read:org, and gist" \
       "for the full gh feature set), put it in the env file passed via runArgs, then" \
       "reattach. Or run 'gh auth login' by hand."
  exit 0
fi

# A leading/trailing newline or space survives an env file and would be sent verbatim in the
# Authorization header, producing 401s that look nothing like a whitespace problem.
TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"

if ! command -v gh >/dev/null 2>&1; then
  echo "github-cli-auth: ERROR gh is not installed. This feature only wires up auth;" \
       "add 'ghcr.io/devcontainers/features/github-cli:1' to your features." >&2
  exit 1
fi

# `gh` reads GH_TOKEN from the environment natively, so unlike a CLI that needs a stored
# credential there is nothing to write to disk — which also means nothing to leak into an
# image layer or a volume. When the token arrives under a different variable name, re-export
# it under the name gh actually reads.
#
# Non-github.com hosts read GH_ENTERPRISE_TOKEN instead, so both are written. These go into a
# profile.d snippet rather than being exported here: this script's own environment dies with
# it, and what matters is the interactive shells opened later.
PROFILE_SNIPPET="$HOME/.github-cli-auth.sh"
{
  echo "# Written by the github-cli-auth devcontainer feature on attach. Do not edit."
  echo "# Re-exports the token under the names gh reads, for interactive shells."
  if [ "$HOST" = "github.com" ]; then
    echo "export GH_TOKEN=\"\${${TOKEN_ENV}:-}\""
  else
    echo "export GH_HOST=\"${HOST}\""
    echo "export GH_ENTERPRISE_TOKEN=\"\${${TOKEN_ENV}:-}\""
  fi
} > "$PROFILE_SNIPPET"
chmod 600 "$PROFILE_SNIPPET"

# Source it from the shell rc if not already wired. Appending once, guarded by a grep, keeps
# repeated attaches from growing the file without bound.
for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$RC" ] || continue
  if ! grep -q '.github-cli-auth.sh' "$RC" 2>/dev/null; then
    printf '\n# Added by the github-cli-auth devcontainer feature.\n[ -f "$HOME/.github-cli-auth.sh" ] && . "$HOME/.github-cli-auth.sh"\n' >> "$RC"
  fi
done

# Make the token visible to THIS script's remaining commands too.
if [ "$HOST" = "github.com" ]; then
  export GH_TOKEN="$TOKEN"
else
  export GH_HOST="$HOST"
  export GH_ENTERPRISE_TOKEN="$TOKEN"
fi

# Teach git to authenticate over HTTPS with the same token, so `git push` works without a
# separate credential. This writes into ~/.gitconfig — which VS Code re-copies from the host
# on EVERY attach, silently dropping the helper — so it must be reasserted each time, not
# just on create. `gh auth setup-git` is idempotent.
if [ "$SETUP_GIT" = "true" ]; then
  if ! gh auth setup-git --hostname "$HOST" >/dev/null 2>&1; then
    echo "github-cli-auth: WARNING could not configure git as a credential helper for ${HOST}." \
         "gh itself is still authenticated; git push over HTTPS may prompt." >&2
  fi
fi

# gh only validates the token when it makes a call, so a typo'd or revoked one looks identical
# to a good one until some later command fails confusingly. Check now, but treat an
# unreachable host as a warning: being offline at attach is not a broken setup.
if OUT="$(gh auth status --hostname "$HOST" 2>&1)"; then
  # Prefer the account line, which names the authenticated user.
  WHO="$(printf '%s\n' "$OUT" | sed -n 's/.*[Aa]ccount \([^ ]*\).*/\1/p' | head -n1)"
  echo "github-cli-auth: authenticated to ${HOST}${WHO:+ as ${WHO}}"
else
  case "$OUT" in
    *invalid*|*[Uu]nauthorized*|*401*|*"Bad credentials"*)
      echo "github-cli-auth: WARNING ${HOST} rejected the token —" \
           "check \$$TOKEN_ENV is current and has the scopes you need." >&2 ;;
    *)
      echo "github-cli-auth: token configured for ${HOST}; could not reach the host to verify it." ;;
  esac
fi
EOF

chmod 755 "${ATTACH_SCRIPT}"

echo "github-cli-auth: installed ${ATTACH_SCRIPT}; will read \$${TOKEN_ENV} at attach"
