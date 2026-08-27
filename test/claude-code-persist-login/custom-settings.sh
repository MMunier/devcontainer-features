#!/usr/bin/env bash
#
# Scenario: the `settings` option merges extra keys alongside the built-in
# remoteControlAtStartup default, producing ONE json object rather than two concatenated.
#
# Assertions use grep, not a JSON parser: this must also hold on images with no python3
# and no jq, which is exactly where the merge path is most fragile.
#
set -e
source dev-container-features-test-lib

SETTINGS="/home/vscode/.claude/settings.json"

check "settings.json exists" test -f "$SETTINGS"

# All three keys must be present together — the option default plus both custom keys.
check "custom model applied"   bash -c "grep -q '\"model\"' $SETTINGS"
check "custom verbose applied" bash -c "grep -q '\"verbose\"' $SETTINGS"
check "remote control still disabled" bash -c "
  grep -qE '\"remoteControlAtStartup\":[[:space:]]*false' $SETTINGS"

# A naive 'cat a b' style merge would yield '{...}{...}': valid-looking to grep, but not
# parseable. Exactly one opening and one closing brace at top level means a real merge.
check "single json object" bash -c "
  [ \"\$(grep -c '^{' $SETTINGS)\" = 1 ] && [ \"\$(grep -c '^}' $SETTINGS)\" = 1 ]"

reportResults
