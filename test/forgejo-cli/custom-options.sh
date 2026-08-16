#!/usr/bin/env bash
#
# Test for the forgejo-cli feature with non-default options: a pinned version, a renamed
# token env var, and setDefaultHost turned off.
#
# As in defaults.sh: the harness runs this as the remote user, so the attach script is invoked
# directly, and the network-touching verification call is stubbed.
#
set -e
source dev-container-features-test-lib

ATTACH="/usr/local/share/forgejo-cli-attach.sh"
USER_HOME="/home/vscode"
KEYS="${USER_HOME}/.local/share/forgejo-cli/keys.json"

check "pinned version installed" bash -c "fj version | grep -q '0\.6\.0'"
check "custom token env baked in" grep -q 'TOKEN_ENV="CODEBERG_PAT"' "$ATTACH"

# setDefaultHost=false must leave the real binary in place, with no wrapper.
check "no wrapper installed"    bash -c "! test -e /usr/local/bin/fj.real"
check "fj is the real binary"   bash -c "! head -n1 /usr/local/bin/fj | grep -q bash"

# The renamed variable is the one that counts; the default name must be ignored.
#
# The stub shadows `fj` on PATH, so it needs its own copy of the real binary to delegate to —
# unlike the defaults scenario there is no fj.real here, and exec'ing /usr/local/bin/fj would
# just re-enter the stub.
STUB_DIR="$(mktemp -d)"
chmod 755 "$STUB_DIR"
cp /usr/local/bin/fj "$STUB_DIR/fj.orig"
cat > "$STUB_DIR/fj" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    auth)   exec "$STUB_DIR/fj.orig" "\$@" ;;
    whoami) echo "testuser"; exit 0 ;;
  esac
done
exec "$STUB_DIR/fj.orig" "\$@"
STUB
chmod 755 "$STUB_DIR/fj" "$STUB_DIR/fj.orig"
export PATH="$STUB_DIR:$PATH"

check "reads the renamed variable" bash -c "
  CODEBERG_PAT=tok_custom111 $ATTACH >/dev/null 2>&1
  grep -q tok_custom111 '$KEYS'"
check "ignores the default variable name" bash -c "
  rm -f '$KEYS'
  unset CODEBERG_PAT
  FORGEJO_TOKEN=tok_wrongvar $ATTACH >/dev/null 2>&1
  ! test -s '$KEYS'"
check "no token => message names the renamed var" bash -c "
  unset CODEBERG_PAT; $ATTACH 2>&1 | grep -q CODEBERG_PAT"

rm -rf "$STUB_DIR"

reportResults
