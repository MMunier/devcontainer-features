#!/usr/bin/env bash
#
# Test the failure mode this feature is shaped around.
#
# Given several plugin names at once, `krew install` aborts the WHOLE batch on the first name
# it cannot resolve — so a single typo would silently cost every plugin listed after it, while
# the image build still reported success. The feature therefore installs plugins one at a
# time. This scenario puts a bad name in the MIDDLE of the list and asserts that the plugin
# after it survives.
#
# It also covers a custom krewRoot, since that is the same code path as the default and a
# hardcoded /usr/local/krew would slip through unnoticed.
#
set -e
source dev-container-features-test-lib

KREW_ROOT="/opt/krew"

check "custom krewRoot honoured"   test -x "${KREW_ROOT}/bin/kubectl-krew"
check "default root NOT created"   bash -c "! test -e /usr/local/krew"
check "snippet points at the custom root" bash -c "
  grep -q 'export KREW_ROOT=\"${KREW_ROOT}\"' /etc/profile.d/krew.sh"

# The plugin BEFORE the bad name.
check "plugin listed before the bad name installed" bash -lc "kubectl krew list | grep -qx ctx"

# The one that matters: the plugin AFTER the bad name. A batch install would have skipped it.
check "plugin listed after the bad name still installed" bash -lc "kubectl krew list | grep -qx ns"

# The bad name itself must simply be absent.
check "bad plugin not installed" bash -lc "
  ! kubectl krew list | grep -q definitely-not-a-real-plugin"

# failOnPluginError defaults to false, so a bad name must not fail the build — proven by the
# fact that this container exists at all, but assert the surviving plugins are usable.
check "good plugins are usable despite the bad one" bash -lc "
  command -v kubectl-ctx && command -v kubectl-ns"

# Whitespace after the commas in the option value must not be taken as part of a plugin name.
check "space-separated names parsed correctly" bash -lc "
  [ \"\$(kubectl krew list | grep -cv '^$')\" -eq 3 ]"

reportResults
