#!/usr/bin/env bash
#
# Test for the ssh-signing-key feature, default options.
#
# The harness does not run postAttachCommand, so the attach script is invoked
# directly — which is also the more precise test, since the interesting behaviour
# is all in how it reacts to the environment.
#
set -e
source dev-container-features-test-lib

ATTACH="/usr/local/share/ssh-signing-key-attach.sh"
PUBKEY="sk-ssh-ed25519@openssh.com AAAATESTKEY000 test@harness"

check "attach script installed"    test -x "$ATTACH"
check "attach script is valid sh"  bash -n "$ATTACH"
check "~/.ssh seeded 700"          bash -c "[ \"\$(stat -c %a /home/vscode/.ssh)\" = 700 ]"
check "~/.ssh owned by vscode"     bash -c "[ \"\$(stat -c %U /home/vscode/.ssh)\" = vscode ]"
check "default pubkey env baked in" grep -q 'PUBKEY_ENV="SSH_SIGNING_PUBKEY"' "$ATTACH"

# No key set must not fail the attach: an unsigned commit is a degraded container,
# not a broken one.
check "no key => exits 0" bash -c "unset SSH_SIGNING_PUBKEY; $ATTACH"
check "no key => names the var to set" bash -c "
  unset SSH_SIGNING_PUBKEY; $ATTACH 2>&1 | grep -q SSH_SIGNING_PUBKEY"
check "no key => git left unconfigured" bash -c "
  unset SSH_SIGNING_PUBKEY; $ATTACH >/dev/null 2>&1
  ! git config --global --get user.signingkey"

# The happy path.
check "installs the key and points git at it" bash -c "
  SSH_SIGNING_PUBKEY='$PUBKEY' $ATTACH >/dev/null 2>&1
  [ \"\$(git config --global --get gpg.format)\" = ssh ] &&
  [ \"\$(git config --global --get user.signingkey)\" = /home/vscode/.ssh/id_ed25519_sk.pub ]"
check "key file has the right contents" bash -c "
  grep -qxF '$PUBKEY' /home/vscode/.ssh/id_ed25519_sk.pub"
check "key file is 644"  bash -c "
  [ \"\$(stat -c %a /home/vscode/.ssh/id_ed25519_sk.pub)\" = 644 ]"
check "signAllCommits defaults on" bash -c "
  [ \"\$(git config --global --get commit.gpgsign)\" = true ]"

# Rerunning on every attach is the point — VS Code re-copies ~/.gitconfig from the
# host on each connect, so a one-shot setup gets clobbered. Simulate that and check
# the attach script wins.
check "reasserts config clobbered by the host gitconfig" bash -c "
  git config --global user.signingkey /host/only/path.pub
  SSH_SIGNING_PUBKEY='$PUBKEY' $ATTACH >/dev/null 2>&1
  [ \"\$(git config --global --get user.signingkey)\" = /home/vscode/.ssh/id_ed25519_sk.pub ]"

# A private key here would be written to disk and handed to git as if it were public.
check "refuses a private key" bash -c "
  ! SSH_SIGNING_PUBKEY='-----BEGIN OPENSSH PRIVATE KEY-----' $ATTACH >/dev/null 2>&1"
check "private key is not written to disk" bash -c "
  rm -f /home/vscode/.ssh/id_ed25519_sk.pub
  SSH_SIGNING_PUBKEY='-----BEGIN OPENSSH PRIVATE KEY-----' $ATTACH >/dev/null 2>&1 || true
  ! test -e /home/vscode/.ssh/id_ed25519_sk.pub"

# Without a forwarded agent there is no private half to sign with, and the failure
# would otherwise surface much later at commit time.
check "warns when no agent is forwarded" bash -c "
  unset SSH_AUTH_SOCK
  SSH_SIGNING_PUBKEY='$PUBKEY' $ATTACH 2>&1 | grep -qi 'ssh-agent'"

reportResults
