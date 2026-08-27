#!/usr/bin/env bash
#
# Test for the claude-code-persist-login feature. Run by the devcontainers/action
# test harness (`devcontainer features test`).
#
# The feature's whole job is build-time seeding: create the mount target owned by the
# remote user so Docker's volume seeding gives a fresh volume the right ownership.
# The harness does not attach the named volume, so what is asserted here is the
# SEED — the directory and symlink as the image layer leaves them, which is exactly
# what Docker copies into the empty volume.
#
set -e
source dev-container-features-test-lib

CLAUDE_DIR="/home/vscode/.claude"
CLAUDE_JSON="/home/vscode/.claude.json"

check "mount target exists"        test -d "$CLAUDE_DIR"
check "target owned by vscode"     bash -c "[ \"\$(stat -c %U $CLAUDE_DIR)\" = vscode ]"
check "target perms are 700"       bash -c "[ \"\$(stat -c %a $CLAUDE_DIR)\" = 700 ]"

# ~/.claude.json lives in $HOME, OUTSIDE the mounted dir, so it must be relocated
# into the volume and symlinked back — otherwise MCP servers and project history
# reset on every rebuild even though the OAuth token survives.
check "~/.claude.json is a symlink" test -L "$CLAUDE_JSON"
check "symlink points into the volume" bash -c "
  [ \"\$(readlink $CLAUDE_JSON)\" = $CLAUDE_DIR/.claude.json ]"
check "symlink target exists"      test -f "$CLAUDE_DIR/.claude.json"
check "symlink owned by vscode"    bash -c "[ \"\$(stat -c %U $CLAUDE_JSON)\" = vscode ]"

# The seeded target must be writable BY THE REMOTE USER without sudo — that is the
# entire point of seeding at build time instead of chowning in postCreate.
#
# The harness already runs this script AS the remote user, so the writes below are made
# directly. Going through `su vscode` would prompt for a password and fail — su needs root
# to switch without one, and we are not root here.
check "tests run as the remote user" bash -c "[ \"\$(id -un)\" = vscode ]"
check "remote user can write it"   bash -c "
  touch $CLAUDE_DIR/.write-probe && rm $CLAUDE_DIR/.write-probe"

# Whatever the symlink resolves to must be writable too, since that is where Claude
# Code actually writes its config.
check "remote user can write .claude.json" bash -c "
  printf {} > $CLAUDE_JSON && test -s $CLAUDE_DIR/.claude.json"

# settings.json carries the feature's defaults. Asserted on the SEED for the same reason as
# above: the harness attaches no volume, so this is the build-time copy. On a container whose
# volume already exists this file comes from the postCreateCommand run instead.
SETTINGS="$CLAUDE_DIR/settings.json"
check "settings.json exists"       test -f "$SETTINGS"
check "settings owned by vscode"   bash -c "[ \"\$(stat -c %U $SETTINGS)\" = vscode ]"
# Remote Control is on by default in newer Claude Code; the feature turns it off.
check "remote control disabled"    bash -c "
  grep -q '\"remoteControlAtStartup\": *false' $SETTINGS"
# grep rather than a JSON parser: the harness's default base image has neither python3
# nor jq, and this assertion must hold there too.
check "single json object"         bash -c "
  [ \"\$(grep -c '^{' $SETTINGS)\" = 1 ] && [ \"\$(grep -c '^}' $SETTINGS)\" = 1 ]"

reportResults
