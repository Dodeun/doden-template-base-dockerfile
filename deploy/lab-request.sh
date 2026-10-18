#!/usr/bin/env bash
# Runs ON THE GITHUB RUNNER, in a Prototype's deploy (the `lab-deploy` job of
# .github/workflows/build.yml), and prints on stdout the one document that
# deploy sends the control host. Nothing else crosses: the job pipes this into
# `ssh` with the Prototype's own key, and the host reads it on stdin.
#
# **Why a document on stdin, and not files and a script.** Production copies
# two descriptors with scp and then runs the release's own deploy script over
# SSH. A Prototype's key cannot do either: it is pinned in `authorized_keys`
# to one forced command, "deploy this Prototype" (ticket 42), which replaces
# whatever command the client asks for, scp's included. That pin is what makes
# a Prototype's key unable to touch another Prototype or reach anything else,
# and a deploy that ran a script out of the repository would hand all of it
# back: the script would be whatever the last push said. So the host runs the
# platform's own deploy script, and this repository sends it data.
#
# The request, version 1. The host side (Dodeun/doden-control-host, ticket 42)
# is written against exactly this:
#
#   {
#     "request": "deploy",
#     "version": 1,
#     "slug": "<the Manifest's slug>",
#     "commit": "<40 hex characters>",
#     "imageRepoPrefix": "ghcr.io/<owner>/<repository>, lowercased",
#     "registry": { "username": "<github.actor>", "token": "<GITHUB_TOKEN>" },
#     "files": {
#       "docker-compose.prod.yml": { "sha256": "<hex>", "base64": "<bytes>" },
#       "platform.json":           { "sha256": "<hex>", "base64": "<bytes>" }
#     }
#   }
#
# - **`slug`** is the Manifest's, sent so the host can refuse a request for a
#   Prototype that is not the one its key is pinned to, before decoding
#   anything. The host trusts its own pin, never this field.
# - **`commit`** names the images: every image is tagged with the commit it was
#   built from (build.yml). It is also the release `/api/health` must report,
#   because a Prototype has no tags: the deploy's last step asks for it.
# - **`registry.token`** is the job's own GITHUB_TOKEN, read-only on packages
#   and expiring when the job ends, as production forwards it. Nothing
#   registry-shaped is stored on the host. It appears once in the document, and
#   this script never prints it anywhere else.
# - **`files`** are the descriptors the host deploys from (ADR-0011): the
#   production Compose file, and the Manifest, which carries what production's
#   deploy is handed as variables - the hostname, the database Add-on and its
#   migrate command - and the Prototype's settings, its expiry date and its
#   access code, which the control host reads from there (tickets 43 and 45).
#   Each carries the sha256 of its bytes, which the host checks after decoding.
#
# It refuses rather than sends anything malformed: a commit that is not a full
# SHA, a slug that is not the Manifest's, a missing value, and a Manifest that
# is not a Prototype's - a Project never deploys to the lab.
#
# Inputs, all from the environment, none defaulted:
#   PROJECT_SLUG, IMAGE_TAG, IMAGE_REPO_PREFIX, GHCR_USERNAME, GHCR_TOKEN
#
# Usage, from the repository root:
#   bash deploy/lab-request.sh > request.json
set -euo pipefail

# No apostrophe in any word below: bash parses ${VAR:?word} with its own
# quoting rules (scripts/check-shell.sh).
: "${PROJECT_SLUG:?PROJECT_SLUG is not set - the slug of platform.json}"
: "${IMAGE_TAG:?IMAGE_TAG is not set - the commit the images were published under}"
: "${IMAGE_REPO_PREFIX:?IMAGE_REPO_PREFIX is not set - ghcr.io/owner/repository, lowercased}"
: "${GHCR_USERNAME:?GHCR_USERNAME is not set - who the registry token belongs to}"
: "${GHCR_TOKEN:?GHCR_TOKEN is not set - the token the host pulls the images with}"

for file in docker-compose.prod.yml platform.json; do
  [ -f "${file}" ] || { echo "ERROR: ${file} is missing, and a Prototype deploys from it." >&2; exit 1; }
done

case "${IMAGE_TAG}" in
  *[!0-9a-f]*|"")
    echo "ERROR: IMAGE_TAG is ${IMAGE_TAG}, not a commit. Images are tagged with the full SHA they were built from." >&2
    exit 1 ;;
esac
if [ "${#IMAGE_TAG}" -ne 40 ]; then
  echo "ERROR: IMAGE_TAG is ${IMAGE_TAG}, not a full 40-character commit SHA." >&2
  exit 1
fi

if [ "$(bash scripts/mode.sh)" != "prototype" ]; then
  echo "ERROR: platform.json declares no prototype block, so this is a Project, and a Project never deploys to the lab. It deploys to production on a release tag (deploy.yml)." >&2
  exit 1
fi

manifest_slug="$(jq -r '.slug // empty' platform.json)"
if [ "${manifest_slug}" != "${PROJECT_SLUG}" ]; then
  echo "ERROR: PROJECT_SLUG is ${PROJECT_SLUG}, and platform.json says ${manifest_slug}. The request would name one Prototype and carry the Manifest of another." >&2
  exit 1
fi

# The descriptor of one file: its bytes, and the hash of those bytes. Both
# from the file itself, never from a string jq has read, which could change a
# line ending or an invalid byte on the way.
descriptor() {
  jq -n --arg sha256 "$(sha256sum "$1" | cut -d' ' -f1)" \
        --arg base64 "$(base64 -w0 < "$1")" \
        '{sha256: $sha256, base64: $base64}'
}
compose="$(descriptor docker-compose.prod.yml)"
manifest="$(descriptor platform.json)"

# The token is read by jq from its environment, never passed as an argument,
# where any process on the runner could read it from the process list.
jq -n \
  --arg slug "${PROJECT_SLUG}" \
  --arg commit "${IMAGE_TAG}" \
  --arg prefix "${IMAGE_REPO_PREFIX}" \
  --arg username "${GHCR_USERNAME}" \
  --argjson compose "${compose}" \
  --argjson manifest "${manifest}" \
  '{
    request: "deploy",
    version: 1,
    slug: $slug,
    commit: $commit,
    imageRepoPrefix: $prefix,
    registry: { username: $username, token: env.GHCR_TOKEN },
    files: { "docker-compose.prod.yml": $compose, "platform.json": $manifest }
  }'
