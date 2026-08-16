#!/usr/bin/env bash
#
# Test for the github-cli-auth feature against a GitHub Enterprise host, with a renamed token
# variable and setupGit turned off.
#
# The distinction that matters here: for non-github.com hosts `gh` reads GH_ENTERPRISE_TOKEN,
# not GH_TOKEN. Exporting the wrong one leaves the CLI silently unauthenticated.
#
set -e
source dev-container-features-test-lib

ATTACH="/usr/local/share/github-cli-auth-attach.sh"
SNIPPET="$HOME/.github-cli-auth.sh"

check "custom token env baked in" grep -q 'TOKEN_ENV="GHE_PAT"' "$ATTACH"
check "enterprise host baked in"  grep -q 'HOST="github.example.com"' "$ATTACH"

STUB_DIR="$(mktemp -d)"
chmod 755 "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth setup-git") echo "setup-git $*" >> /tmp/ghe-calls.log; exit 0 ;;
  "auth status")    echo "  - Account enterpriseuser"; exit 0 ;;
esac
exit 0
STUB
chmod 755 "$STUB_DIR/gh"
export PATH="$STUB_DIR:$PATH"

rm -f /tmp/ghe-calls.log
check "reads the renamed variable" bash -c "
  GHE_PAT=ghe_tok111 $ATTACH >/dev/null 2>&1; test -f '$SNIPPET'"

# The whole point of the host option: a non-github.com host needs GH_ENTERPRISE_TOKEN.
check "exports GH_ENTERPRISE_TOKEN, not GH_TOKEN" bash -c "
  grep -q 'export GH_ENTERPRISE_TOKEN=' '$SNIPPET' &&
  ! grep -q 'export GH_TOKEN=' '$SNIPPET'"
check "pins GH_HOST to the enterprise host" bash -c "
  grep -q 'export GH_HOST=\"github.example.com\"' '$SNIPPET'"
check "sourcing it sets the enterprise token" bash -c "
  GHE_PAT=ghe_tok111; . '$SNIPPET'
  [ \"\$GH_ENTERPRISE_TOKEN\" = ghe_tok111 ] && [ \"\$GH_HOST\" = github.example.com ]"

# setupGit=false must leave git alone entirely.
check "setupGit=false skips gh auth setup-git" bash -c "
  ! test -e /tmp/ghe-calls.log"

check "ignores the default variable name" bash -c "
  rm -f '$SNIPPET'
  unset GHE_PAT
  GH_TOKEN=wrong_var_token $ATTACH >/dev/null 2>&1
  ! test -e '$SNIPPET'"
check "no token => message names the renamed var" bash -c "
  unset GHE_PAT; $ATTACH 2>&1 | grep -q GHE_PAT"

rm -rf "$STUB_DIR"

reportResults
