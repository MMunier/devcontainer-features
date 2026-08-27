#!/usr/bin/env bash
#
# Scenario: remoteControlAtStartup=unset writes no settings.json at all, so an existing
# volume's file is left exactly as the user had it. The seed here has no other settings
# to write, so the correct result is no file.
#
set -e
source dev-container-features-test-lib

CLAUDE_DIR="/home/vscode/.claude"

# The volume mount target must still be seeded — 'unset' only opts out of settings.
check "mount target still seeded" test -d "$CLAUDE_DIR"
check "~/.claude.json still symlinked" test -L "/home/vscode/.claude.json"

check "no settings.json written" bash -c "! test -e $CLAUDE_DIR/settings.json"

reportResults
