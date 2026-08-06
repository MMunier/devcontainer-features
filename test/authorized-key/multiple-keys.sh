#!/usr/bin/env bash
#
# Multiple keys separated by \n, and targetUser left at its 'automatic' default
# (which must resolve to _REMOTE_USER, i.e. vscode).
#
set -e
source dev-container-features-test-lib

AUTH="/home/vscode/.ssh/authorized_keys"
KEY_ONE="ssh-ed25519 AAAAKEYONE first@harness"
KEY_TWO="ssh-ed25519 AAAAKEYTWO second@harness"

# 'automatic' must land on the devcontainer's remote user, not root — getting this
# wrong writes a perfectly valid authorized_keys that nobody logs in as.
check "automatic resolved to vscode"  test -f "$AUTH"
check "not written to root instead"   bash -c "! sudo test -s /root/.ssh/authorized_keys"

check "first key present"             grep -qxF "$KEY_ONE" "$AUTH"
check "second key present"            grep -qxF "$KEY_TWO" "$AUTH"
check "\\n was expanded, not literal"  bash -c "! grep -q '\\\\n' $AUTH"
check "exactly two key lines"         bash -c "[ \"\$(grep -c . $AUTH)\" = 2 ]"

check "perms still 600"               bash -c "[ \"\$(stat -c %a $AUTH)\" = 600 ]"
check "owned by vscode"               bash -c "[ \"\$(stat -c %U $AUTH)\" = vscode ]"

reportResults
