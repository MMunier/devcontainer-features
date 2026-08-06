#!/usr/bin/env bash
#
# Test for the ssh-signing-key feature with a custom pubkeyEnv, keyFilename and
# signAllCommits=false.
#
set -e
source dev-container-features-test-lib

ATTACH="/usr/local/share/ssh-signing-key-attach.sh"
PUBKEY="sk-ssh-ed25519@openssh.com AAAATESTKEY111 test@harness"

check "custom pubkey env baked in"  grep -q 'PUBKEY_ENV="MY_SIGNING_KEY"' "$ATTACH"
check "custom filename baked in"    grep -q 'KEY_FILENAME="yubikey.pub"' "$ATTACH"

# The guidance must name the variable the user actually configured, or they set the
# wrong one and nothing happens.
check "guidance names the custom var" bash -c "
  unset MY_SIGNING_KEY; $ATTACH 2>&1 | grep -q MY_SIGNING_KEY"

check "writes to the custom filename" bash -c "
  MY_SIGNING_KEY='$PUBKEY' $ATTACH >/dev/null 2>&1
  grep -qxF '$PUBKEY' /home/vscode/.ssh/yubikey.pub &&
  [ \"\$(git config --global --get user.signingkey)\" = /home/vscode/.ssh/yubikey.pub ]"

check "ignores the default env var name" bash -c "
  rm -f /home/vscode/.ssh/yubikey.pub
  SSH_SIGNING_PUBKEY='$PUBKEY' $ATTACH >/dev/null 2>&1
  ! test -e /home/vscode/.ssh/yubikey.pub"

# signAllCommits=false wires the key up but leaves signing opt-in per commit.
check "signAllCommits=false leaves gpgsign unset" bash -c "
  git config --global --unset commit.gpgsign || true
  MY_SIGNING_KEY='$PUBKEY' $ATTACH >/dev/null 2>&1
  ! git config --global --get commit.gpgsign"
check "but still points git at the key" bash -c "
  [ \"\$(git config --global --get gpg.format)\" = ssh ]"

reportResults
