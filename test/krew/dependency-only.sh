#!/usr/bin/env bash
#
# krew is the ONLY feature this scenario requests — kubectl arrives purely through
# dependsOn. That makes this the test of two things worth pinning down:
#
#   1. A user does not have to list kubectl themselves for krew to work.
#   2. The options given in dependsOn actually take effect. They do: the spec says
#      dependsOn elements follow the same semantics as the features object, so
#      helm/minikube default to "none" here and neither is installed.
#
# If a future spec change made dependsOn ignore options, this scenario is what catches
# it — minikube would silently appear in every image built on this feature.
#
set -e
source dev-container-features-test-lib

KREW_ROOT="/usr/local/krew"

# The dependency pulled kubectl in without the user asking for it.
check "kubectl installed via dependsOn" bash -c "command -v kubectl"

# ...but only kubectl. krew needs neither of these, and minikube especially is a heavy
# thing to inherit by accident.
check "minikube NOT installed" bash -c "! command -v minikube"
check "helm NOT installed"     bash -c "! command -v helm"

# krew itself still works, which is the point of the dependency being there at all.
check "krew installed"          test -x "${KREW_ROOT}/bin/kubectl-krew"
check "kubectl sees krew"       bash -lc "kubectl krew version | grep -q GitTag"
check "requested plugin present" bash -lc "kubectl krew list | grep -qx ctx"
check "plugin dispatches"       bash -lc "kubectl plugin list 2>&1 | grep -q kubectl-ctx"

reportResults
