#!/usr/bin/env bash
# Proves the two things the workflows decide by script rather than by YAML,
# in both modes, with no network and no credential. profile.yml runs it on
# every push and pull request, beside profile-selfcheck.sh.
#
#   1. **scripts/mode.sh** reads the mode from the committed Manifest: a
#      Manifest with a `prototype` block is a Prototype, one without is a
#      Project, and one that cannot be read is neither - it fails, so a broken
#      Manifest never falls through into one path or the other.
#
#   2. **deploy/lab-request.sh** builds what a Prototype's deploy sends the
#      control host. It is decoded back here, the way the host decodes it:
#      every file byte for byte, every hash the hash of those bytes, and the
#      registry token in the one place it belongs. Its refusals are run too:
#      a check that has only ever passed has not been tested.
#
# What it does not do is deploy. The host side is in Dodeun/doden-control-host
# (ticket 42), and a Prototype's first real deploy is ticket 46's.
#
# Usage: bash scripts/modes-selfcheck.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

for tool in jq sha256sum base64; do
  command -v "$tool" >/dev/null || { echo "cannot run: $tool is not installed" >&2; exit 2; }
done

failures=0
fail() {
  echo "   FAIL: $*" >&2
  failures=$((failures + 1))
}

# A tree holding only what the two scripts read, under a Manifest given here.
tree() {
  local dir="${SCRATCH}/$1"
  mkdir -p "${dir}/scripts" "${dir}/deploy"
  cp "${ROOT}/scripts/mode.sh" "${dir}/scripts/"
  cp "${ROOT}/deploy/lab-request.sh" "${dir}/deploy/"
  cp "${ROOT}/docker-compose.prod.yml" "${dir}/"
  printf '%s\n' "$2" > "${dir}/platform.json"
  echo "${dir}"
}

PROJECT='{"slug": "modes-selfcheck", "appHost": "modes-selfcheck.example.test", "addons": {}}'
PROTOTYPE='{"slug": "modes-selfcheck", "appHost": "modes-selfcheck.lab.doden.dev", "addons": {}, "prototype": {"expires": "2026-11-15", "accessCode": "K7M2Q"}}'

# -- 1. the mode ------------------------------------------------------------
echo "1. scripts/mode.sh"
for case in "project:${PROJECT}" "prototype:${PROTOTYPE}"; do
  expected="${case%%:*}"
  dir="$(tree "mode-${expected}" "${case#*:}")"
  if ! found="$(cd "${dir}" && bash scripts/mode.sh)"; then
    fail "a ${expected} Manifest made mode.sh fail"
  elif [ "${found}" != "${expected}" ]; then
    fail "a ${expected} Manifest read as '${found}'"
  else
    echo "   a ${expected} Manifest reads as ${found}"
  fi
done

for case in "not-json:{ this is not json" "missing:"; do
  name="${case%%:*}"
  dir="$(tree "mode-${name}" "${case#*:}")"
  [ "${name}" = "missing" ] && rm "${dir}/platform.json"
  if found="$(cd "${dir}" && bash scripts/mode.sh 2>/dev/null)"; then
    fail "a Manifest that is ${name} read as '${found}' instead of failing"
  else
    echo "   a Manifest that is ${name} fails, and reads as neither"
  fi
done
echo

# -- 2. the request a Prototype's deploy sends ------------------------------
echo "2. deploy/lab-request.sh"
dir="$(tree request "${PROTOTYPE}")"
SHA="0123456789abcdef0123456789abcdef01234567"
request_env=(
  PROJECT_SLUG=modes-selfcheck
  IMAGE_TAG="${SHA}"
  IMAGE_REPO_PREFIX=ghcr.io/owner/modes-selfcheck
  GHCR_USERNAME=someone
  GHCR_TOKEN=token-for-the-selfcheck
)
if ! (cd "${dir}" && env "${request_env[@]}" bash deploy/lab-request.sh) > "${SCRATCH}/request.json"; then
  fail "it refused a well-formed Prototype"
else
  request="${SCRATCH}/request.json"
  [ "$(jq -r '.request' "${request}")" = "deploy" ] || fail "the request does not say it is a deploy"
  [ "$(jq -r '.version' "${request}")" = "1" ] || fail "the request does not carry version 1"
  [ "$(jq -r '.slug' "${request}")" = "modes-selfcheck" ] || fail "the request names the wrong slug"
  [ "$(jq -r '.commit' "${request}")" = "${SHA}" ] || fail "the request names the wrong commit"
  [ "$(jq -r '.imageRepoPrefix' "${request}")" = "ghcr.io/owner/modes-selfcheck" ] || fail "the request names the wrong registry path"
  [ "$(jq -r '.registry.username' "${request}")" = "someone" ] || fail "the request names the wrong registry user"
  [ "$(jq -r '.registry.token' "${request}")" = "token-for-the-selfcheck" ] || fail "the request carries the wrong token"
  # The token belongs in one place. Anywhere else - a file, a log line - it
  # would travel further than the pull it exists for.
  [ "$(grep -o token-for-the-selfcheck "${request}" | wc -l)" -eq 1 ] || fail "the token appears more than once in the request"

  files="$(jq -r '.files | keys | join(" ")' "${request}")"
  [ "${files}" = "docker-compose.prod.yml platform.json" ] || fail "the request carries '${files}', not the Compose file and the Manifest alone"
  for file in docker-compose.prod.yml platform.json; do
    # `tr`, because jq on Windows ends its output with a carriage return,
    # which base64 refuses. On Linux it removes nothing.
    jq -r --arg f "${file}" '.files[$f].base64' "${request}" | tr -d '\r' | base64 -d > "${SCRATCH}/decoded"
    cmp -s "${SCRATCH}/decoded" "${dir}/${file}" || fail "${file} does not decode to the bytes it was built from"
    expected="$(sha256sum "${dir}/${file}" | cut -d' ' -f1)"
    [ "$(jq -r --arg f "${file}" '.files[$f].sha256' "${request}")" = "${expected}" ] || fail "${file}'s hash is not the hash of its bytes"
  done
  echo "   a Prototype's request decodes back to its Compose file and its Manifest"
fi

refuse() {
  local why="$1"; shift
  if (cd "${dir}" && env "${request_env[@]}" "$@" bash deploy/lab-request.sh) > /dev/null 2>&1; then
    fail "it built a request ${why}"
  else
    echo "   it refuses ${why}"
  fi
}
refuse "for a commit that is not a full SHA" IMAGE_TAG=v1.0.0
refuse "for a slug that is not the Manifest's" PROJECT_SLUG=another-prototype
refuse "with no registry token" GHCR_TOKEN=
dir="$(tree request-project "${PROJECT}")"
refuse "for a Project, which never deploys to the lab"
echo

if [ "${failures}" -gt 0 ]; then
  echo "${failures} check(s) failed." >&2
  exit 1
fi
echo "Both modes hold."
