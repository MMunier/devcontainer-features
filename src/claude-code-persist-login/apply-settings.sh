#!/usr/bin/env bash
# Writes ~/.claude/settings.json from the feature's options.
#
# Run TWICE, deliberately:
#   1. at image build time, from install.sh, so the values land in the seed Docker copies
#      into a *fresh* named volume;
#   2. at postCreate, because the volume mounts OVER ~/.claude — on any container whose
#      volume already exists, the build-time copy is invisible and only this run is seen.
#
# Build-time config is baked in below by install.sh; at postCreate that file is the only
# record of what the options were, since feature option env vars do not survive the build.
set -euo pipefail

CONF="/usr/local/share/claude-code-persist-login/settings.conf"
if [ -r "${CONF}" ]; then
  # shellcheck disable=SC1090
  . "${CONF}"
fi

REMOTE_CONTROL="${REMOTECONTROLATSTARTUP:-false}"
EXTRA_SETTINGS="${SETTINGS:-}"
OVERWRITE="${OVERWRITEEXISTINGSETTINGS:-false}"

# At build time install.sh passes the target explicitly (it runs as root, for another user's
# home). At postCreate we are already the remote user, so $HOME is right.
CLAUDE_DIR="${1:-${HOME}/.claude}"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"

# Build the object this run wants to apply. Nothing to do if it would be empty and we are
# not overwriting — bail before touching a file we have no changes for.
DESIRED="{}"
if [ "${REMOTE_CONTROL}" != "unset" ]; then
  DESIRED="{\"remoteControlAtStartup\": ${REMOTE_CONTROL}}"
fi
if [ "${DESIRED}" = "{}" ] && [ -z "${EXTRA_SETTINGS}" ] && [ "${OVERWRITE}" != "true" ]; then
  exit 0
fi

mkdir -p "${CLAUDE_DIR}"

# Merging needs a JSON parser. jq is the usual one but is not in every base image; python3 is
# in most, and one of the two is nearly always present. With neither, a merge is impossible
# without silently corrupting the file, so refuse to merge and say why — except when there is
# no existing file to preserve, where a plain write IS the correct result.
merge_json() {
  # $1 base JSON, $2..$n objects applied in order, one level deep. Prints the result.
  local base="$1"; shift
  if command -v jq >/dev/null 2>&1; then
    local out="${base}" overlay
    for overlay in "$@"; do
      out="$(printf '%s\n%s\n' "${out}" "${overlay}" | jq -s '.[0] * .[1]')"
    done
    printf '%s\n' "${out}"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
out = json.loads(sys.argv[1])
for overlay in sys.argv[2:]:
    out.update(json.loads(overlay))
print(json.dumps(out, indent=2))
' "${base}" "$@"
  else
    return 1
  fi
}

# The devcontainer CLI passes option values through a shell context that STRIPS double
# quotes, so a JSON object given as {"model":"opus"} arrives here as {model:opus} — not
# valid JSON, and silently corrupting if written out. Repair that by re-quoting bare keys
# and bare string values; anything already quoted, and true/false/null/numbers, is left
# alone. This is why `settings` is documented as accepting the unquoted form.
repair_json() {
  # Re-quote bare object keys:      {model:  -> {"model":
  # and bare scalar string values:  :opus,   -> :"opus",
  printf '%s' "$1" | sed -E '
    s/([{,][[:space:]]*)([A-Za-z_][A-Za-z0-9_]*)([[:space:]]*:)/\1"\2"\3/g
    s/(:[[:space:]]*)([A-Za-z_][A-Za-z0-9_-]*)([[:space:]]*[,}])/\1"\2"\3/g
  ' | sed -E '
    s/"(true|false|null)"/\1/g
  '
}

validate_json() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -e . >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1
  else
    return 0  # no parser available; cannot check, proceed
  fi
}

if [ -n "${EXTRA_SETTINGS}" ] && ! validate_json "${EXTRA_SETTINGS}"; then
  REPAIRED="$(repair_json "${EXTRA_SETTINGS}")"
  if validate_json "${REPAIRED}"; then
    echo "claude-code-persist-login: note the 'settings' value lost its double quotes in" \
         "transit (the devcontainer CLI strips them); read it as ${REPAIRED}" >&2
    EXTRA_SETTINGS="${REPAIRED}"
  else
    echo "claude-code-persist-login: ERROR the 'settings' option is not valid JSON and could" \
         "not be repaired: ${EXTRA_SETTINGS}" >&2
    echo "claude-code-persist-login: give it as an object without double quotes, e.g." \
         "settings: '{model:opus,verbose:true}' — the CLI strips quotes either way." >&2
    exit 1
  fi
fi

# The build-time run records a copy of exactly what it wrote. If the file still matches that
# copy byte for byte, it is our own seed and holds nothing of the user's — so it can be
# rewritten wholesale. This matters on images with no jq and no python3: without it, the
# postCreate run would refuse to merge into a file the feature itself had just created.
SEED_COPY="/usr/local/share/claude-code-persist-login/settings.seed.json"

EXISTING="{}"
if [ "${OVERWRITE}" != "true" ] && [ -s "${SETTINGS_FILE}" ]; then
  if [ -r "${SEED_COPY}" ] && cmp -s "${SETTINGS_FILE}" "${SEED_COPY}"; then
    : # untouched feature seed — treat as absent
  else
    EXISTING="$(cat "${SETTINGS_FILE}")"
  fi
fi

# `settings` is applied last so it wins over remoteControlAtStartup if it names that key.
set -- "${DESIRED}"
[ -n "${EXTRA_SETTINGS}" ] && set -- "$@" "${EXTRA_SETTINGS}"

if ! RESULT="$(merge_json "${EXISTING}" "$@" 2>&1)"; then
  if [ "${EXISTING}" = "{}" ] && [ -z "${EXTRA_SETTINGS}" ]; then
    # Only our own single generated key to write, and nothing to preserve — safe by hand.
    RESULT="${DESIRED}"
  else
    echo "claude-code-persist-login: ERROR could not merge into ${SETTINGS_FILE} — needs jq" \
         "or python3, and neither is installed. Install one, or set 'overwriteExistingSettings'" \
         "to true to replace the file instead of merging. Leaving the existing file untouched." >&2
    [ -n "${RESULT}" ] && echo "claude-code-persist-login: (merge said: ${RESULT})" >&2
    exit 1
  fi
fi

# Write via a temp file in the same dir so a failed/interrupted write cannot leave a
# half-written settings.json that Claude Code then refuses to parse.
TMP="${SETTINGS_FILE}.tmp.$$"
printf '%s\n' "${RESULT}" > "${TMP}"
mv -f "${TMP}" "${SETTINGS_FILE}"
chmod 600 "${SETTINGS_FILE}"

# Only the build-time run (given an explicit target dir, as root) records the seed; a
# postCreate run must not, or a later run would mistake the user's edits for the seed.
if [ -n "${1:-}" ] && [ -w "$(dirname "${SEED_COPY}")" ]; then
  cp -f "${SETTINGS_FILE}" "${SEED_COPY}" && chmod 0644 "${SEED_COPY}"
fi

echo "claude-code-persist-login: applied settings to ${SETTINGS_FILE}"
