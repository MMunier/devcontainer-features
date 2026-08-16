#!/usr/bin/env bash
# Runs as root at IMAGE BUILD time. Installs krew and a given list of plugins into a shared
# KREW_ROOT, owned by the remote user, and puts that root on PATH for login shells.
#
# kubectl itself is NOT installed here — the official kubectl-helm-minikube feature does that,
# and is declared as a dependency. krew is a kubectl plugin manager, not a kubectl installer.
set -euo pipefail

# Option values arrive as uppercased env vars; _REMOTE_USER / _REMOTE_USER_HOME are injected
# by the devcontainer feature installer.
PLUGINS="${PLUGINS:-}"
VERSION="${VERSION:-latest}"
KREW_ROOT="${KREWROOT:-/usr/local/krew}"
FAIL_ON_PLUGIN_ERROR="${FAILONPLUGINERROR:-false}"

USER_NAME="${_REMOTE_USER:-vscode}"
# Don't assume the primary group is named after the user — true for vscode, not in general.
USER_GROUP="$(id -gn "${USER_NAME}" 2>/dev/null || echo "${USER_NAME}")"

# KREW_ROOT is written into a profile snippet and used as a path; a relative path would
# resolve differently depending on the caller's cwd.
case "${KREW_ROOT}" in
  /*) ;;
  *)
    echo "krew: ERROR krewRoot must be an absolute path, got '${KREW_ROOT}'" >&2
    exit 1 ;;
esac

# curl, tar and git are needed: git because krew's plugin index is a git clone, which is not
# obvious from the download alone and fails later with a confusing error if missing.
install_prereqs() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v tar  >/dev/null 2>&1 || missing+=(tar)
  command -v git  >/dev/null 2>&1 || missing+=(git)
  [ -e /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)
  [ ${#missing[@]} -eq 0 ] && return 0

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    rm -rf /var/lib/apt/lists/*
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${missing[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${missing[@]}"
  elif command -v microdnf >/dev/null 2>&1; then
    microdnf install -y "${missing[@]}"
  else
    echo "krew: ERROR need ${missing[*]} but no supported package manager was found" >&2
    exit 1
  fi
}
install_prereqs

# krew names its release assets by GOARCH.
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64)  KREW_ARCH="amd64" ;;
  aarch64|arm64) KREW_ARCH="arm64" ;;
  armv7l|armv6l) KREW_ARCH="arm" ;;
  ppc64le)       KREW_ARCH="ppc64le" ;;
  *)
    echo "krew: ERROR unsupported architecture '${ARCH}'." \
         "Upstream ships linux binaries for amd64, arm64, arm and ppc64le." >&2
    exit 1 ;;
esac

RELEASES="https://api.github.com/repos/kubernetes-sigs/krew/releases"
DOWNLOAD="https://github.com/kubernetes-sigs/krew/releases/download"

if [ "${VERSION}" = "latest" ]; then
  TAG="$(curl -fsSL "${RELEASES}/latest" \
         | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -n1)"
  if [ -z "${TAG}" ]; then
    echo "krew: ERROR could not resolve the latest release tag from ${RELEASES}" >&2
    exit 1
  fi
else
  # Accept '0.5.0' or 'v0.5.0'; upstream tags carry the v.
  TAG="v${VERSION#v}"
fi

TARBALL="krew-linux_${KREW_ARCH}.tar.gz"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "krew: downloading ${TAG} (linux_${KREW_ARCH})"
if ! curl -fsSL --retry 3 --retry-delay 2 -o "${TMP_DIR}/${TARBALL}" \
     "${DOWNLOAD}/${TAG}/${TARBALL}"; then
  echo "krew: ERROR failed to download ${DOWNLOAD}/${TAG}/${TARBALL}." \
       "Check that release ${TAG} exists and ships a linux_${KREW_ARCH} build." >&2
  exit 1
fi

# Upstream publishes a .sha256 next to each asset. Verifying it costs one small request and
# turns a corrupted or tampered download into a build failure rather than a mystery later.
if curl -fsSL --retry 3 -o "${TMP_DIR}/${TARBALL}.sha256" \
   "${DOWNLOAD}/${TAG}/${TARBALL}.sha256" 2>/dev/null; then
  EXPECTED="$(tr -d '[:space:]' < "${TMP_DIR}/${TARBALL}.sha256")"
  ACTUAL="$(sha256sum "${TMP_DIR}/${TARBALL}" | cut -d' ' -f1)"
  if [ "${EXPECTED}" != "${ACTUAL}" ]; then
    echo "krew: ERROR checksum mismatch for ${TARBALL}" >&2
    echo "krew:   expected ${EXPECTED}" >&2
    echo "krew:   actual   ${ACTUAL}" >&2
    exit 1
  fi
  echo "krew: checksum verified"
else
  echo "krew: WARNING no .sha256 published for ${TARBALL}; skipping checksum verification" >&2
fi

tar -xzf "${TMP_DIR}/${TARBALL}" -C "${TMP_DIR}"
KREW_BIN="${TMP_DIR}/krew-linux_${KREW_ARCH}"
if [ ! -x "${KREW_BIN}" ]; then
  echo "krew: ERROR the release tarball did not contain krew-linux_${KREW_ARCH}" >&2
  exit 1
fi

# krew defaults to a PER-USER root at $HOME/.krew. This script runs as root, so that default
# would put everything in /root/.krew — invisible to the remote user, who is who actually runs
# kubectl. A shared KREW_ROOT outside any home directory avoids that, and also survives a
# volume being mounted over the remote user's home.
export KREW_ROOT
mkdir -p "${KREW_ROOT}"

echo "krew: installing krew into ${KREW_ROOT}"
"${KREW_BIN}" install krew

# Put krew on PATH for login shells. /etc/profile.d applies to every user rather than only the
# one whose dotfiles we happened to edit. KREW_ROOT must be exported too, not just the bin
# dir: without it a later `kubectl krew install` would fall back to the per-user default and
# quietly create a second, private ~/.krew.
cat > /etc/profile.d/krew.sh <<EOF
# Installed by the krew devcontainer feature.
export KREW_ROOT="${KREW_ROOT}"
export PATH="${KREW_ROOT}/bin:\$PATH"
EOF
chmod 644 /etc/profile.d/krew.sh

# zsh does not read /etc/profile.d on its own in these images, and the devcontainer base image
# defaults the remote user to zsh — so wire it up there too, or an interactive terminal would
# not find kubectl-krew even though bash does.
if [ -d /etc/zsh ]; then
  if ! grep -q 'profile.d/krew.sh' /etc/zsh/zshenv 2>/dev/null; then
    printf '\n# Added by the krew devcontainer feature.\n[ -f /etc/profile.d/krew.sh ] && . /etc/profile.d/krew.sh\n' \
      >> /etc/zsh/zshenv
  fi
fi

export PATH="${KREW_ROOT}/bin:${PATH}"

# Install the requested plugins. Commas or whitespace both separate, since a JSON string
# option invites either.
FAILED_PLUGINS=""
if [ -n "${PLUGINS}" ]; then
  # Refresh the index once up front rather than once per plugin: `krew install` updates it
  # every time otherwise, which is a git fetch per plugin for no benefit.
  kubectl-krew update || true

  # shellcheck disable=SC2086
  set -- $(printf '%s' "${PLUGINS}" | tr ',' ' ')
  for plugin in "$@"; do
    [ -z "${plugin}" ] && continue
    echo "krew: installing plugin '${plugin}'"
    # Installed ONE AT A TIME on purpose. Given several names, krew aborts the entire batch on
    # the first one it cannot resolve — so a single typo would silently cost every plugin
    # after it, with the build still reporting success.
    if ! kubectl-krew install "${plugin}"; then
      echo "krew: WARNING could not install plugin '${plugin}' —" \
           "check the name against 'kubectl krew search'." >&2
      FAILED_PLUGINS="${FAILED_PLUGINS} ${plugin}"
    fi
  done
fi

# The remote user must be able to add plugins later without sudo, so hand them the whole tree.
chown -R "${USER_NAME}:${USER_GROUP}" "${KREW_ROOT}"

if [ -n "${FAILED_PLUGINS}" ]; then
  echo "krew: WARNING these plugins were NOT installed:${FAILED_PLUGINS}" >&2
  if [ "${FAIL_ON_PLUGIN_ERROR}" = "true" ]; then
    echo "krew: failing the build because failOnPluginError is set." >&2
    exit 1
  fi
fi

echo "krew: installed ${TAG} into ${KREW_ROOT}, owned by ${USER_NAME}"
