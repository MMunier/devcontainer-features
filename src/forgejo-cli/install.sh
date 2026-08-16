#!/usr/bin/env bash
# Runs as root at IMAGE BUILD time. Two jobs:
#
#   1. Install the `fj` binary from an upstream release tarball.
#   2. Install an attach script that writes the API token into fj's keys file, with the
#      non-secret option values baked in.
#
# The token itself is NOT baked in: it comes from a runtime env var (injected via an
# --env-file in the project's runArgs, or remoteEnv), so the same image works for any user,
# no secret ends up in an image layer, and the launching shell never has to have sourced
# anything first.
set -euo pipefail

# Option values arrive as uppercased env vars; _REMOTE_USER / _REMOTE_USER_HOME are injected
# by the devcontainer feature installer.
VERSION="${VERSION:-latest}"
TOKEN_ENV="${TOKENENV:-FORGEJO_TOKEN}"
HOST="${HOST:-codeberg.org}"
SET_DEFAULT_HOST="${SETDEFAULTHOST:-true}"

USER_NAME="${_REMOTE_USER:-vscode}"
USER_HOME="${_REMOTE_USER_HOME:-/home/${USER_NAME}}"
# Don't assume the primary group is named after the user — true for vscode, not in general.
USER_GROUP="$(id -gn "${USER_NAME}" 2>/dev/null || echo "${USER_NAME}")"

REPO="https://codeberg.org/forgejo-contrib/forgejo-cli"
API="https://codeberg.org/api/v1/repos/Forgejo-contrib/forgejo-cli"

# The env var name is expanded into the attach script and dereferenced there; anything that
# isn't a valid shell identifier would be a syntax error at attach time instead of a clear
# error now.
case "${TOKEN_ENV}" in
  [!A-Za-z_]*|*[!A-Za-z0-9_]*|"")
    echo "forgejo-cli: ERROR tokenEnv must be a valid shell identifier, got '${TOKEN_ENV}'" >&2
    exit 1 ;;
esac

# `fj` takes a bare hostname. A scheme or path here would be accepted at build time and only
# fail later, at the point where the API call is made.
case "${HOST}" in
  *://*|*/*|"")
    echo "forgejo-cli: ERROR host must be a bare hostname (no scheme, no path), got '${HOST}'" >&2
    exit 1 ;;
esac

# curl and tar are needed to fetch the release; ca-certificates so the TLS handshake to
# codeberg.org verifies. Slim base images ship with none of them.
install_prereqs() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v tar  >/dev/null 2>&1 || missing+=(tar)
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
    echo "forgejo-cli: ERROR need ${missing[*]} but no supported package manager was found" >&2
    exit 1
  fi
}
install_prereqs

# Upstream publishes one Linux tarball per arch. Anything else has no binary to install, and
# building from source would need a Rust toolchain — out of scope for a feature.
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64)  ASSET_ARCH="x86_64" ;;
  aarch64|arm64) ASSET_ARCH="aarch64" ;;
  *)
    echo "forgejo-cli: ERROR unsupported architecture '${ARCH}'." \
         "Upstream ships Linux binaries for x86_64 and aarch64 only;" \
         "install with 'cargo install forgejo-cli --locked' instead." >&2
    exit 1 ;;
esac

if [ "${VERSION}" = "latest" ]; then
  # Resolve via the releases API rather than hitting /releases/latest and following the
  # redirect, so a failure here is a clear error instead of a 404 on the download.
  TAG="$(curl -fsSL "${API}/releases/latest" \
         | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -n1)"
  if [ -z "${TAG}" ]; then
    echo "forgejo-cli: ERROR could not resolve the latest release tag from ${API}" >&2
    exit 1
  fi
else
  # Accept '0.6.0' or 'v0.6.0'; upstream tags carry the v.
  TAG="v${VERSION#v}"
fi

TARBALL="forgejo-cli-${ASSET_ARCH}-linux.tar.gz"
URL="${REPO}/releases/download/${TAG}/${TARBALL}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "forgejo-cli: downloading ${TAG} (${ASSET_ARCH}) from ${URL}"
if ! curl -fsSL --retry 3 --retry-delay 2 -o "${TMP_DIR}/${TARBALL}" "${URL}"; then
  echo "forgejo-cli: ERROR failed to download ${URL}." \
       "Check that release ${TAG} exists and ships a ${ASSET_ARCH} Linux build." >&2
  exit 1
fi

tar -xzf "${TMP_DIR}/${TARBALL}" -C "${TMP_DIR}"
if [ ! -f "${TMP_DIR}/fj" ]; then
  echo "forgejo-cli: ERROR the release tarball did not contain an 'fj' binary" >&2
  exit 1
fi
install -m 755 -o root -g root "${TMP_DIR}/fj" /usr/local/bin/fj

# `fj` writes its keys file here. Pre-seed it owned by the remote user so the attach script
# can write without sudo, and 700 because the file inside holds an API token.
DATA_DIR="${USER_HOME}/.local/share/forgejo-cli"
install -d -m 700 -o "${USER_NAME}" -g "${USER_GROUP}" "${DATA_DIR}"
# ~/.local and ~/.local/share may not exist yet; created above by -d, but they'd be root-owned
# if this feature made them, which breaks anything else the user writes there later.
chown "${USER_NAME}:${USER_GROUP}" "${USER_HOME}/.local" "${USER_HOME}/.local/share"

ATTACH_SCRIPT="/usr/local/share/forgejo-cli-attach.sh"

# Unquoted heredoc: the option values are baked in. None of them is the token.
cat > "${ATTACH_SCRIPT}" <<EOF
#!/usr/bin/env bash
# Installed by the forgejo-cli devcontainer feature. Runs as the REMOTE USER on every attach.
# Reading the token here rather than at build time keeps the secret out of the image layers,
# lets one image serve any user, and makes rotation a matter of editing the env file and
# reconnecting.
TOKEN_ENV="${TOKEN_ENV}"
HOST="${HOST}"
SET_DEFAULT_HOST="${SET_DEFAULT_HOST}"
EOF

# Quoted heredoc: everything below is literal shell, expanded at attach time.
cat >> "${ATTACH_SCRIPT}" <<'EOF'

set -euo pipefail

TOKEN="${!TOKEN_ENV:-}"

# No token configured is a skip, not a failure: `fj` still works against public repos and
# after a manual `fj auth login`, and attach must not break because someone hasn't set this
# up yet.
if [ -z "$TOKEN" ]; then
  echo "forgejo-cli: \$$TOKEN_ENV is not set — not authenticated to ${HOST}." \
       "Create a token at https://${HOST}/user/settings/applications (scopes: read:user," \
       "write:issue, and write:repository if you also want to open PRs), put it in the env" \
       "file passed via runArgs, then reattach. Or run 'fj auth login' by hand."
  exit 0
fi

# A leading/trailing newline or space survives an env file and would be stored verbatim,
# producing 401s that look nothing like a whitespace problem.
TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"

# `add-token` refuses to replace an existing entry ("key for <host> already exists") and STILL
# exits 0 — so on the second and every later attach a rotated token would be silently ignored
# while this script reported success. Drop any existing entry first to make the write actually
# take effect. `logout` fails harmlessly when there is nothing stored, which is the first-run
# case, so its status is deliberately ignored.
fj auth logout "$HOST" >/dev/null 2>&1 || true

# The token is passed on stdin, not as an argv element: an argument would be visible in
# /proc to every process in the container for as long as the call runs.
if ! printf '%s' "$TOKEN" | fj auth add-token --host "$HOST" >/dev/null 2>&1; then
  echo "forgejo-cli: ERROR failed to store the token for ${HOST}." >&2
  exit 1
fi

# add-token only writes the file — it never contacts the instance, so a typo'd or revoked
# token looks identical to a good one until the first real command fails. Verify now, but
# treat an unreachable instance as a warning: being offline at attach is not a broken setup.
if OUT="$(fj --host "$HOST" whoami 2>&1)"; then
  echo "forgejo-cli: authenticated to ${HOST} as $(printf '%s' "$OUT" | head -n1)"
else
  case "$OUT" in
    *[Uu]nauthorized*|*401*|*403*|*token*)
      echo "forgejo-cli: WARNING the instance rejected the token for ${HOST} —" \
           "check \$$TOKEN_ENV is current and has the scopes you need." >&2 ;;
    *)
      echo "forgejo-cli: token stored for ${HOST}; could not reach the instance to verify it." ;;
  esac
fi
EOF

chmod 755 "${ATTACH_SCRIPT}"

# Outside a checkout of a repo on the instance, `fj` has no way to know which host to talk to
# and fails with "could not find host, try specifying with --host". It reads no environment
# variable for this and stores no default in its config, so the only way to supply one is on
# the command line. Install a wrapper ahead of the binary on PATH that inserts --host when the
# caller didn't pass one, leaving explicit --host and in-repo detection untouched.
if [ "${SET_DEFAULT_HOST}" = "true" ]; then
  mv /usr/local/bin/fj /usr/local/bin/fj.real
  cat > /usr/local/bin/fj <<EOF
#!/usr/bin/env bash
# Installed by the forgejo-cli devcontainer feature: supplies a default --host so \`fj\` works
# outside a checkout of a repo on the instance. The real binary is fj.real.
FJ_DEFAULT_HOST="\${FJ_HOST:-${HOST}}"
EOF
  cat >> /usr/local/bin/fj <<'EOF'

# -a fj keeps the binary's own usage text saying `fj`, not `fj.real`.
run() { exec -a fj /usr/local/bin/fj.real "$@"; }

# Only the global --host counts. A bare `fj` (no subcommand) is left alone so `fj --help` and
# `fj version` still print what they should, and `auth` is skipped because `fj auth login`
# takes its own host argument and prompts when it needs one.
for arg in "$@"; do
  case "$arg" in
    -H|--host|--host=*) run "$@" ;;
    -h|--help|-V|--version) run "$@" ;;
    auth|version|completion|help) run "$@" ;;
  esac
done

[ $# -eq 0 ] && run
run --host "$FJ_DEFAULT_HOST" "$@"
EOF
  chmod 755 /usr/local/bin/fj
fi

echo "forgejo-cli: installed fj ${TAG} to /usr/local/bin/fj; will read \$${TOKEN_ENV} at attach"
