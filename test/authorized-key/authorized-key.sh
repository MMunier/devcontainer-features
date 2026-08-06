#!/usr/bin/env bash
#
# Test for the authorized-key feature. Run by the devcontainers/action test
# harness (`devcontainer features test`). The scenario in scenarios.json sets
# the option values; here we assert the outcome.
#
set -e
source dev-container-features-test-lib

# The scenario installs a known key for the 'vscode' user.
EXPECTED_KEY="sk-ssh-ed25519@openssh.com AAAATESTKEY000 test@harness"
AUTH="/home/vscode/.ssh/authorized_keys"

check "authorized_keys exists"        test -f "$AUTH"
check "dir perms are 700"             bash -c "[ \"\$(stat -c %a /home/vscode/.ssh)\" = 700 ]"
check "file perms are 600"            bash -c "[ \"\$(stat -c %a $AUTH)\" = 600 ]"
check "owned by vscode"               bash -c "[ \"\$(stat -c %U $AUTH)\" = vscode ]"
check "contains the expected key"     grep -qxF "$EXPECTED_KEY" "$AUTH"

# Idempotency is a design property — rebuilds and layer caching re-run install.sh —
# so pin the observable form of it: the key appears exactly once, not appended twice.
check "key appears exactly once"      bash -c "[ \"\$(grep -cxF \"$EXPECTED_KEY\" $AUTH)\" = 1 ]"
check "no blank lines appended"       bash -c "! grep -qx '' $AUTH"

reportResults
