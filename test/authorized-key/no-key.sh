#!/usr/bin/env bash
#
# No publicKey given. The build must succeed and simply do nothing — the feature
# may be present in a shared base config where only some users supply a key.
#
set -e
source dev-container-features-test-lib

# Reaching this point at all is the headline assertion: the image built.
check "build succeeded with no key"   true

# Doing nothing means NOT leaving an empty authorized_keys behind that would look
# like a configured-but-broken login.
check "no empty authorized_keys"      bash -c "
  ! test -s /home/vscode/.ssh/authorized_keys"

reportResults
