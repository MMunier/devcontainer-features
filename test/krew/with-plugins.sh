#!/usr/bin/env bash
#
# Test for the krew feature with a plugin list — the case the feature exists for.
#
set -e
source dev-container-features-test-lib

KREW_ROOT="/usr/local/krew"

check "krew installed"        test -x "${KREW_ROOT}/bin/kubectl-krew"
check "ctx plugin installed"  bash -lc "kubectl krew list | grep -qx ctx"
check "ns plugin installed"   bash -lc "kubectl krew list | grep -qx ns"

# A krew plugin is only useful if kubectl can actually dispatch to it, which needs the
# plugin's shim on PATH — not merely a receipt in krew's store.
check "ctx shim on PATH"          bash -lc "command -v kubectl-ctx"
check "ns shim on PATH"           bash -lc "command -v kubectl-ns"
check "kubectl dispatches to ctx" bash -lc "kubectl plugin list 2>&1 | grep -q kubectl-ctx"

# Plugins are baked into the image at build time, so they must work with no network at all.
# That is the reason for build-time installation over an attach hook.
check "plugins are on disk, not fetched at runtime" bash -c "
  test -d ${KREW_ROOT}/store/ctx && test -d ${KREW_ROOT}/store/ns"

# Everything, plugins included, must stay writable by the remote user so more can be added
# later without sudo.
check "plugin tree owned by vscode" bash -c "
  [ \"\$(stat -c %U ${KREW_ROOT}/store/ctx)\" = vscode ]"

reportResults
