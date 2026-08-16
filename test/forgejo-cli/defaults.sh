#!/usr/bin/env bash
#
# Test for the forgejo-cli feature, default options.
#
# The harness does not run postAttachCommand, so the attach script is invoked directly —
# which is also the more precise test, since the interesting behaviour is all in how it
# reacts to the environment.
#
# The harness runs these as the remote user (vscode) — the same user the attach script runs
# as — so the attach script can be invoked directly. Paths are still written out rather than
# taken from $HOME, so a failure names the path it actually looked at.
#
# Nothing here talks to a real Forgejo instance: the token-storing path is exercised for real
# (it is purely local), while the verification call that would hit the network is stubbed, so
# the suite passes on an isolated build agent with no credentials.
#
set -e
source dev-container-features-test-lib

ATTACH="/usr/local/share/forgejo-cli-attach.sh"
USER_HOME="/home/vscode"
KEYS="${USER_HOME}/.local/share/forgejo-cli/keys.json"

check "fj on PATH"                 bash -c "command -v fj"
check "fj runs"                    bash -c "fj version | grep -qi '^fj v'"
check "attach script installed"    test -x "$ATTACH"
check "attach script is valid sh"  bash -n "$ATTACH"
check "default token env baked in" grep -q 'TOKEN_ENV="FORGEJO_TOKEN"' "$ATTACH"
check "default host baked in"      grep -q 'HOST="codeberg.org"' "$ATTACH"

# fj stores an API token here, so the directory must not be world-readable, and the remote
# user must be able to write it at attach time without escalating.
check "data dir owned by vscode" bash -c "
  [ \"\$(stat -c %U ${USER_HOME}/.local/share/forgejo-cli)\" = vscode ]"
check "data dir is 700" bash -c "
  [ \"\$(stat -c %a ${USER_HOME}/.local/share/forgejo-cli)\" = 700 ]"
check "~/.local not left root-owned" bash -c "
  [ \"\$(stat -c %U ${USER_HOME}/.local)\" = vscode ]"

# setDefaultHost defaults on: `fj` must work outside a checkout of a repo on the instance,
# where it would otherwise fail with "could not find host".
check "wrapper installed"      test -x /usr/local/bin/fj.real
check "wrapper injects --host" grep -q 'FJ_DEFAULT_HOST="\${FJ_HOST:-codeberg.org}"' /usr/local/bin/fj
check "usage still says fj, not fj.real" bash -c "! fj --help 2>&1 | grep -q 'fj\.real'"

# No token configured must not fail the attach: fj is still usable against public repos and
# after a manual `fj auth login`.
check "no token => exits 0" bash -c "unset FORGEJO_TOKEN; $ATTACH"
check "no token => names the var to set" bash -c "
  unset FORGEJO_TOKEN; $ATTACH 2>&1 | grep -q FORGEJO_TOKEN"
check "no token => nothing stored" bash -c "
  unset FORGEJO_TOKEN; $ATTACH >/dev/null 2>&1; ! test -s '$KEYS'"

# The happy path. Stub the verification call so the test does not need the network; the
# add-token path underneath is the real binary writing the real keys file.
#
# The stub is put on PATH once, here, rather than as a `PATH=... ` prefix inside each check
# string — quoting that correctly through two levels of shell is easy to get wrong in a way
# that silently empties PATH, which makes every command "fail" for the wrong reason.
STUB_DIR="$(mktemp -d)"
chmod 755 "$STUB_DIR"
REAL_PATH="$PATH"
export PATH="$STUB_DIR:$PATH"
cat > "$STUB_DIR/fj" <<'STUB'
#!/usr/bin/env bash
# Pass `auth` through to the real binary, answer `whoami` locally.
for arg in "$@"; do
  case "$arg" in
    auth)   exec /usr/local/bin/fj.real "$@" ;;
    whoami) echo "testuser"; exit 0 ;;
  esac
done
exec /usr/local/bin/fj.real "$@"
STUB
chmod 755 "$STUB_DIR/fj"

check "stores the token" bash -c "
  FORGEJO_TOKEN=tok_abc123 $ATTACH >/dev/null 2>&1
  grep -q tok_abc123 '$KEYS'"
check "keys file is 600" bash -c "
  [ \"\$(stat -c %a '$KEYS')\" = 600 ]"
check "stores it under the configured host" bash -c "
  grep -q codeberg.org '$KEYS'"
check "reports the authenticated user" bash -c "
  FORGEJO_TOKEN=tok_abc123 $ATTACH 2>&1 | grep -q testuser"

# An env file trivially leaves a trailing newline or stray space on the value, which would be
# stored verbatim and produce 401s that look nothing like a whitespace problem.
check "strips surrounding whitespace" bash -c "
  FORGEJO_TOKEN='  tok_ws456
' $ATTACH >/dev/null 2>&1
  grep -q '\"tok_ws456\"' '$KEYS'"

# Rerunning on every attach is the point: it is what makes the login survive a rebuild and
# lets a rotated token take effect on reconnect. `fj auth add-token` refuses to replace an
# existing entry AND still exits 0, so without an explicit logout first this silently keeps
# serving the stale token forever.
check "rerun replaces a rotated token" bash -c "
  FORGEJO_TOKEN=tok_rotated789 $ATTACH >/dev/null 2>&1
  grep -q tok_rotated789 '$KEYS' && ! grep -q tok_ws456 '$KEYS'"

# A token the instance rejects must be called out at attach, not left to surface later as a
# confusing failure on the first real command.
cat > "$STUB_DIR/fj" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    auth)   exec /usr/local/bin/fj.real "$@" ;;
    whoami) echo "Error: unauthorized: token is malformed" >&2; exit 1 ;;
  esac
done
exec /usr/local/bin/fj.real "$@"
STUB
chmod 755 "$STUB_DIR/fj"

check "warns on a rejected token" bash -c "
  FORGEJO_TOKEN=tok_bad $ATTACH 2>&1 | grep -qi 'rejected the token'"
check "a rejected token does not fail the attach" bash -c "
  FORGEJO_TOKEN=tok_bad $ATTACH >/dev/null 2>&1"

# Being offline at attach is not a broken setup, and must read differently from a bad token.
cat > "$STUB_DIR/fj" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    auth)   exec /usr/local/bin/fj.real "$@" ;;
    whoami) echo "error sending request: connection refused" >&2; exit 1 ;;
  esac
done
exec /usr/local/bin/fj.real "$@"
STUB
chmod 755 "$STUB_DIR/fj"

bash -c "FORGEJO_TOKEN=tok_offline $ATTACH" \
  > /tmp/offline.out 2>&1 || true
check "unreachable instance says so"            grep -qi 'could not reach' /tmp/offline.out
check "unreachable is not blamed on the token"  bash -c "! grep -qi 'rejected' /tmp/offline.out"

export PATH="$REAL_PATH"

rm -rf "$STUB_DIR"

reportResults
