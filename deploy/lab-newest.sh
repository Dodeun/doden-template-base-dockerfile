#!/usr/bin/env bash
# Runs ON THE GITHUB RUNNER, in a Prototype's deploy, and prints `true` when
# the commit being deployed is still the tip of the default branch, `false`
# when a newer push has landed since.
#
# A Prototype deploys on every push, and two pushes close together build side
# by side, so the older one can reach the deploy after the newer one.
# build.yml asks this twice: before a deploy joins the queue of deploys,
# so that an older push never replaces a newer one waiting there, and again
# once it is its turn, because the queue may have been long.
#
# It never guesses. A tip it cannot read - no network, no access, no such
# branch - exits 1, rather than reading as "not the newest" and ending a
# deploy green with nothing deployed.
#
# Inputs, from the environment: GITHUB_SHA, DEFAULT_BRANCH.
# Usage, from a checkout: bash deploy/lab-newest.sh
set -euo pipefail

: "${GITHUB_SHA:?GITHUB_SHA is not set - the commit being deployed}"
: "${DEFAULT_BRANCH:?DEFAULT_BRANCH is not set - the branch whose tip is the newest push}"

tip="$(git ls-remote origin "refs/heads/${DEFAULT_BRANCH}" | cut -f1)"
: "${tip:?the tip of the default branch could not be read, so this cannot say whether the commit is the newest}"

if [ "${tip}" = "${GITHUB_SHA}" ]; then
  echo true
else
  # On stderr, because stdout is the answer the workflow captures.
  echo "${DEFAULT_BRANCH} is at ${tip} now, not at ${GITHUB_SHA}. The newer push deploys itself; this one steps aside rather than put older code back." >&2
  echo false
fi
