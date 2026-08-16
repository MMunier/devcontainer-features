#!/usr/bin/env bash
#
# Test for the github-cli-auth feature, default options.
#
# The harness does not run postAttachCommand, so the attach script is invoked directly —
# which is also the more precise test, since the interesting behaviour is all in how it
# reacts to the environment. The harness runs this AS the remote user (vscode), the same
# user the attach script runs as, so no privilege juggling is needed.
#
# Nothing here talks to github.com. `gh` is stubbed for the calls that would go out over the
# network, so the suite passes on an isolated build agent with no credentials.
#
set -e
source dev-container-features-test-lib

ATTACH="/usr/local/share/github-cli-auth-attach.sh"
SNIPPET="$HOME/.github-cli-auth.sh"

check "gh installed by the dependency" bash -c "command -v gh"
check "attach script installed"        test -x "$ATTACH"
check "attach script is valid sh"      bash -n "$ATTACH"
check "default token env baked in"     grep -q 'TOKEN_ENV="GH_TOKEN"' "$ATTACH"
check "default host baked in"          grep -q 'HOST="github.com"' "$ATTACH"

# No token configured must not fail the attach: gh is still usable for public read-only
# calls, and a container that merely lacks a token is not broken.
check "no token => exits 0" bash -c "unset GH_TOKEN; $ATTACH"
check "no token => names the var to set" bash -c "
  unset GH_TOKEN; $ATTACH 2>&1 | grep -q GH_TOKEN"
check "no token => writes no snippet" bash -c "
  rm -f '$SNIPPET'
  unset GH_TOKEN; $ATTACH >/dev/null 2>&1
  ! test -e '$SNIPPET'"

# Stub gh so nothing leaves the machine. The stub is put on PATH once, here, rather than as a
# `PATH=... ` prefix inside each check string — quoting that through two levels of shell is
# easy to get wrong in a way that silently empties PATH.
STUB_DIR="$(mktemp -d)"
chmod 755 "$STUB_DIR"
REAL_PATH="$PATH"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth setup-git") echo "setup-git $*" >> /tmp/gh-calls.log; exit 0 ;;
  "auth status")    echo "  - Active account: true"; echo "  - Account testuser (keyring)"; exit 0 ;;
esac
exit 0
STUB
chmod 755 "$STUB_DIR/gh"
export PATH="$STUB_DIR:$PATH"

# gh reads GH_TOKEN natively, so the feature's job is to make it reach interactive shells
# under the name gh expects — not to store a credential anywhere.
rm -f /tmp/gh-calls.log
check "token => exits 0" bash -c "GH_TOKEN=ghp_test123 $ATTACH >/dev/null 2>&1"
check "writes the profile snippet" bash -c "
  GH_TOKEN=ghp_test123 $ATTACH >/dev/null 2>&1; test -f '$SNIPPET'"
check "snippet is 600" bash -c "
  [ \"\$(stat -c %a '$SNIPPET')\" = 600 ]"
check "snippet exports GH_TOKEN" bash -c "
  grep -q 'export GH_TOKEN=' '$SNIPPET'"

# The snippet must export the token by REFERENCE to the source variable, never the literal
# value — writing the secret into a file on disk is exactly what this design avoids.
check "snippet does not contain the literal token" bash -c "
  ! grep -q ghp_test123 '$SNIPPET'"
check "sourcing the snippet sets GH_TOKEN" bash -c "
  GH_TOKEN=ghp_test123; . '$SNIPPET'; [ \"\$GH_TOKEN\" = ghp_test123 ]"

# git must authenticate over HTTPS with the same token, and this has to be reasserted on
# every attach because VS Code re-copies ~/.gitconfig from the host on each connect.
check "runs gh auth setup-git" bash -c "
  grep -q 'setup-git' /tmp/gh-calls.log"
check "setup-git targets the configured host" bash -c "
  grep -q 'github.com' /tmp/gh-calls.log"

# Re-attaching must not append the rc hook again, or the file grows without bound.
check "rc hook added once" bash -c "
  GH_TOKEN=ghp_test123 $ATTACH >/dev/null 2>&1
  GH_TOKEN=ghp_test123 $ATTACH >/dev/null 2>&1
  [ \"\$(grep -c 'github-cli-auth.sh' \$HOME/.bashrc)\" -eq 1 ]"

check "reports the authenticated user" bash -c "
  GH_TOKEN=ghp_test123 $ATTACH 2>&1 | grep -q testuser"

# Whitespace around a token survives an env file easily and would otherwise go out in the
# Authorization header verbatim. The trimmed value is what gh is called with, so assert on
# the argument the stub actually received rather than on the snippet (which by design holds
# a reference to the source variable, not the value).
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth setup-git") exit 0 ;;
  "auth status")    printf '%s' "${GH_TOKEN}" > /tmp/gh-seen-token; echo "  - Account testuser"; exit 0 ;;
esac
exit 0
STUB
chmod 755 "$STUB_DIR/gh"

check "strips surrounding whitespace" bash -c "
  rm -f /tmp/gh-seen-token
  GH_TOKEN='  ghp_ws456
' $ATTACH >/dev/null 2>&1
  [ \"\$(cat /tmp/gh-seen-token)\" = ghp_ws456 ]"

# A token the host rejects must be called out at attach, not left to surface later.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth setup-git") exit 0 ;;
  "auth status")    echo "The token in GH_TOKEN is invalid." >&2; exit 1 ;;
esac
exit 0
STUB
chmod 755 "$STUB_DIR/gh"

check "warns on a rejected token" bash -c "
  GH_TOKEN=ghp_bad $ATTACH 2>&1 | grep -qi 'rejected the token'"
check "a rejected token does not fail the attach" bash -c "
  GH_TOKEN=ghp_bad $ATTACH >/dev/null 2>&1"

# Being offline at attach is not a broken setup, and must read differently from a bad token.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth setup-git") exit 0 ;;
  "auth status")    echo "dial tcp: lookup github.com: no such host" >&2; exit 1 ;;
esac
exit 0
STUB
chmod 755 "$STUB_DIR/gh"

bash -c "GH_TOKEN=ghp_offline $ATTACH" > /tmp/offline.out 2>&1 || true
check "unreachable host says so"           grep -qi 'could not reach' /tmp/offline.out
check "unreachable is not blamed on token" bash -c "! grep -qi 'rejected' /tmp/offline.out"

export PATH="$REAL_PATH"
rm -rf "$STUB_DIR"

reportResults
