#!/usr/bin/env bash
# Runs ON THE GITHUB RUNNER, in a Project's deploy (.github/workflows/deploy.yml),
# and prints on stdout the one document that deploy sends production. Nothing
# else crosses: the job pipes it into `ssh` with the Project's own key, and
# the host reads it on stdin (ADR-0016, decisions 61 and 66).
#
# **Why a document, and not files and a script.** The Project's key is pinned
# in `~deploy/.ssh/authorized_keys` to one forced command,
# `prod-deploy <slug> <appHost>`, which replaces whatever command the client
# asks for, scp's included. A deploy that ran a script out of the repository
# would hand back everything the pin takes away: the script would be whatever
# the last push said. So the host runs the platform's own script, prod-deploy
# in Dodeun/doden-infra, and this repository sends it data, as a Prototype's
# deploy/lab-request.sh does for the lab.
#
# The request, version 1. prod-deploy (ticket 76) is written against exactly
# this, and its header is the other half of the format:
#
#   {
#     "request": "deploy",
#     "version": 1,
#     "slug": "<the Manifest's slug>",
#     "release": "<the tag, v...>",
#     "commit": "<40 hex characters: the commit the tag points at>",
#     "imageRepoPrefix": "ghcr.io/<owner>/<slug>",
#     "registry": { "username": "<github.actor>", "token": "<GITHUB_TOKEN>" },
#     "files": {
#       "docker-compose.prod.yml": { "sha256": "<hex>", "base64": "<bytes>" },
#       "platform.json":           { "sha256": "<hex>", "base64": "<bytes>" }
#     }
#   }
#
# - **`slug`** is the Manifest's, sent so the host can refuse a request for
#   another Project than its key's before decoding anything. The host trusts
#   its own pin, never this field, and the hostname is the pin's too.
# - **`release`** is what /api/health reports; **`commit`** names the images,
#   which build.yml tags with the commit they were built from.
# - **`imageRepoPrefix`** is where build.yml published, the repository's own
#   path. The host derives its own from the pin and refuses any other, so a
#   repository that is not named after its slug is refused here first.
# - **`registry.token`** is the job's own GITHUB_TOKEN, read-only on packages
#   and expiring when the job ends. It appears once in the document, is read
#   by jq from the environment and never from an argument list, and is never
#   printed, a refusal of its shape included.
# - **`files`** are the descriptors the host deploys from (ADR-0011), from the
#   checkout of the Release, each with the sha256 of its bytes, which the host
#   checks after decoding. A rollback sends the old Release's own pair.
#
# It refuses rather than sends anything malformed, and on a refusal writes
# nothing on stdout: a value the host would refuse, a Manifest that is a
# Prototype's or lacks what the host reads, and a request larger than the
# host's cap. It reads nothing of the Release but the two descriptors, so it
# works on a Release older than itself, which is what a rollback is.
#
# Inputs, from the environment, none defaulted:
#   RELEASE_TAG, IMAGE_TAG, IMAGE_REPO_PREFIX, GHCR_USERNAME, GHCR_TOKEN
# and one argument, the directory of the Release's checkout (default: .).
#
# Usage:
#   bash deploy/prod-request.sh release > request.json
set -euo pipefail

# No apostrophe in any word below: bash parses ${VAR:?word} with its own
# quoting rules (scripts/check-shell.sh).
: "${RELEASE_TAG:?RELEASE_TAG is not set - the release tag being deployed, such as v1.4.0}"
: "${IMAGE_TAG:?IMAGE_TAG is not set - the commit the tag points at, which names the images}"
: "${IMAGE_REPO_PREFIX:?IMAGE_REPO_PREFIX is not set - ghcr.io/owner/repository, lowercased, where build.yml published}"
: "${GHCR_USERNAME:?GHCR_USERNAME is not set - who the registry token belongs to}"
: "${GHCR_TOKEN:?GHCR_TOKEN is not set - the token production pulls the images with}"

RELEASE="${1:-.}"
# The host reads at most this many bytes. One less, for the newline the
# workflow adds when it sends the document.
MAX_REQUEST=262143

refuse() { echo "ERROR: $*" >&2; exit 1; }
# shown <value> - a value that is not secret, quoted so a newline shows, and cut short.
shown() { local cut; cut="$(printf '%.80s' "$1")"; printf '%q' "${cut}"; }

for file in docker-compose.prod.yml platform.json; do
  [ -f "${RELEASE}/${file}" ] || refuse "${file} is missing from ${RELEASE}, and production deploys from it."
done

# The host's own patterns, so that a value it would refuse is refused here,
# before a connection is opened. Kept in variables: a regular expression
# written inline after =~ is subject to the shell's quoting.
tag_re='^v[0-9][A-Za-z0-9.+_-]{0,62}$'
commit_re='^[0-9a-f]{40}$'
login_re='^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$'
token_re='^[A-Za-z0-9_.-]+$'
slug_re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
host_re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'

[[ "${RELEASE_TAG}" =~ $tag_re ]] \
  || refuse "RELEASE_TAG is $(shown "${RELEASE_TAG}"), not a release tag: v, a digit, then at most 62 of A-Z a-z 0-9 . + _ -"
[[ "${IMAGE_TAG}" =~ $commit_re ]] \
  || refuse "IMAGE_TAG is $(shown "${IMAGE_TAG}"), not a full 40-character commit SHA in lower case. Images are tagged with the commit they were built from."
[[ "${GHCR_USERNAME}" =~ $login_re ]] \
  || refuse "GHCR_USERNAME is $(shown "${GHCR_USERNAME}"), not a GitHub login"
# Its value is never shown, even refused.
[[ "${GHCR_TOKEN}" =~ $token_re ]] \
  || refuse "GHCR_TOKEN is not a token: it has characters a GitHub token has not. Its value is not shown."

# ---- The Manifest of the Release ------------------------------------------

manifest="${RELEASE}/platform.json"
jq -e 'type == "object"' "${manifest}" >/dev/null 2>&1 || refuse "platform.json is not a JSON object"
# mstring <jq path> - a string of the Manifest, or empty whatever its shape.
mstring() { jq -r "try ($1 | if type == \"string\" then . else empty end) catch empty" "${manifest}" | tr -d '\r'; }

jq -e 'has("prototype") | not' "${manifest}" >/dev/null \
  || refuse "platform.json has a prototype block, so this is a Prototype, and a Prototype never deploys to production. It deploys to the lab on every push (build.yml)."
slug="$(mstring .slug)"
[ -n "${slug}" ] || refuse "platform.json declares no slug - the Project this deploy names, and the one its key is pinned to"
[[ "${slug}" =~ $slug_re ]] || refuse "platform.json gives the slug $(shown "${slug}"), which is not a slug"
app_host="$(mstring .appHost)"
[ -n "${app_host}" ] || refuse "platform.json declares no appHost - the hostname the key of this Project is pinned to"
[ "${#app_host}" -le 253 ] && [[ "${app_host}" =~ $host_re ]] \
  || refuse "platform.json gives the appHost $(shown "${app_host}"), which is not a hostname"
jq -e '(.addons // {}) | type == "object"' "${manifest}" >/dev/null || refuse "platform.json: addons is not an object"
# As the host reads it: the Add-on is declared when it is not null.
if jq -e '.addons.database != null' "${manifest}" >/dev/null; then
  [ -n "$(mstring .addons.database.migrate.service)" ] && [ -n "$(mstring .addons.database.migrate.command)" ] \
    || refuse "platform.json declares the database Add-on with no migrate service and command, and production migrates before a release serves"
fi

# The slug has only [a-z0-9-], so it is safe inside the pattern.
prefix_re="^ghcr\\.io/[a-z0-9][a-z0-9-]*/${slug}\$"
[[ "${IMAGE_REPO_PREFIX}" =~ $prefix_re ]] \
  || refuse "IMAGE_REPO_PREFIX is $(shown "${IMAGE_REPO_PREFIX}"), and production runs only the images of ${slug}, under ghcr.io/<owner>/${slug}: build.yml publishes under the repository name, lowercased, so the repository is named after its slug"

# ---- The document ---------------------------------------------------------

# The descriptor of one file: its bytes, and the hash of those bytes. Both
# from the file itself, never from a string jq has read, which could change a
# line ending or an invalid byte on the way.
#
# Each value is assigned before it is used, so a failing `sha256sum` or
# `base64` stops the script: substituted straight into jq's arguments, it
# would be exempt from `set -e` and leave an empty field. The encoded bytes go
# to jq through files rather than arguments, which the kernel caps at 128 KiB
# each.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT
descriptor() {
  local sha256
  sha256="$(sha256sum "$1" | cut -d' ' -f1)"
  : "${sha256:?the hash of a descriptor came out empty}"
  base64 -w0 < "$1" > "${SCRATCH}/encoded"
  jq -n --arg sha256 "${sha256}" --rawfile base64 "${SCRATCH}/encoded" \
    '{sha256: $sha256, base64: $base64}'
}
descriptor "${RELEASE}/docker-compose.prod.yml" > "${SCRATCH}/compose.json"
descriptor "${RELEASE}/platform.json" > "${SCRATCH}/manifest.json"

# Held in a variable, not a file, because it carries the token, and printed
# only once it is whole and within the cap: a refusal sends nothing. The
# token is read by jq from its environment, never passed as an argument,
# where any process on the runner could read it from the process list.
request="$(jq -cn \
  --arg slug "${slug}" \
  --arg release "${RELEASE_TAG}" \
  --arg commit "${IMAGE_TAG}" \
  --arg prefix "${IMAGE_REPO_PREFIX}" \
  --arg username "${GHCR_USERNAME}" \
  --slurpfile compose "${SCRATCH}/compose.json" \
  --slurpfile manifest "${SCRATCH}/manifest.json" \
  '{
    request: "deploy",
    version: 1,
    slug: $slug,
    release: $release,
    commit: $commit,
    imageRepoPrefix: $prefix,
    registry: { username: $username, token: env.GHCR_TOKEN },
    files: { "docker-compose.prod.yml": $compose[0], "platform.json": $manifest[0] }
  }' | tr -d '\r')"
# printf is a builtin: the document reaches no argument list here either.
size="$(printf '%s\n' "${request}" | wc -c | tr -d ' ')"
[ "${size}" -le "${MAX_REQUEST}" ] \
  || refuse "the request is ${size} bytes, larger than the ${MAX_REQUEST} production reads: the Compose file or the Manifest has grown far past what a deploy needs"
printf '%s\n' "${request}"
