#!/usr/bin/env bash
#
# Test for the krew feature with default options: krew itself, no plugins.
#
# The harness runs this AS the remote user (vscode), which is the interesting case — krew is
# a per-user tool by default, and the whole point of the shared KREW_ROOT is that a build
# running as root still produces something this user can run and extend.
#
set -e
source dev-container-features-test-lib

KREW_ROOT="/usr/local/krew"

check "kubectl installed by the dependency" bash -c "command -v kubectl"
check "krew binary installed"               test -x "${KREW_ROOT}/bin/kubectl-krew"
check "profile snippet installed"           test -f /etc/profile.d/krew.sh

# Without KREW_ROOT exported, a later `kubectl krew install` silently falls back to the
# per-user default and builds a second, private ~/.krew — so both vars must be set, not just
# the bin dir on PATH.
check "snippet exports KREW_ROOT" bash -c "
  grep -q 'export KREW_ROOT=\"${KREW_ROOT}\"' /etc/profile.d/krew.sh"
check "snippet puts krew on PATH" bash -c "
  grep -q '${KREW_ROOT}/bin' /etc/profile.d/krew.sh"

# A login shell is what a terminal actually gets, so assert through one rather than by
# sourcing the file directly.
check "login shell finds kubectl-krew" bash -lc "command -v kubectl-krew"
check "login shell has KREW_ROOT set"  bash -lc "[ \"\$KREW_ROOT\" = '${KREW_ROOT}' ]"

# The base image defaults the remote user to zsh, which does not read /etc/profile.d on its
# own — an interactive terminal would otherwise not find krew even though bash does.
check "zsh also gets krew on PATH" bash -c "
  ! command -v zsh >/dev/null 2>&1 || zsh -lc 'command -v kubectl-krew'"

# krew must be usable as a kubectl plugin, which is the entire point of installing it.
check "kubectl sees krew as a plugin" bash -lc "kubectl krew version | grep -q GitTag"
check "krew reports the shared root"  bash -lc "
  kubectl krew version | grep -q '${KREW_ROOT}'"

# The remote user must be able to add plugins later WITHOUT sudo. This is what the chown at
# the end of the install is for, and it is easy to get wrong by leaving the tree root-owned.
check "krew root owned by vscode" bash -c "
  [ \"\$(stat -c %U ${KREW_ROOT})\" = vscode ]"
check "remote user can write the bin dir" bash -c "
  touch ${KREW_ROOT}/bin/.write-probe && rm ${KREW_ROOT}/bin/.write-probe"

# With no plugins requested, only krew itself should be present.
check "krew lists itself"      bash -lc "kubectl krew list | grep -q krew"
check "no extra plugins added" bash -lc "
  [ \"\$(kubectl krew list | grep -cv '^$')\" -eq 1 ]"

reportResults
