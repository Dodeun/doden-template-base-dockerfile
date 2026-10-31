#!/usr/bin/env bash
# Runs ON THE GITHUB RUNNER, in a Prototype's push that deployed and is green
# everywhere, and says whether that is news (decision 60):
#
#   first      no earlier run of this workflow deployed: the link is new
#   after-red  the runs since the last deploy include a red one: green again
#   none       the last run that deployed was green, and nothing red since
#
# build.yml posts green to Discord on the first two, and on nothing else: a
# channel that speaks on every push is a channel nobody reads. Red is still
# posted at every red run, by lab-report.
#
# **No state is kept between runs.** The history is read from the Actions
# API, newest first: this workflow's completed runs on the same branch, older
# than this one, green or red. A cancelled run is neither, and is passed
# over. A run counts as having deployed when its job "Deploy to the lab" ran
# the step "Assert the commit is answering on the public URL" to success: the
# link answered. One that stepped aside for a newer push did not, and neither
# did one whose deploy failed. build.yml names both, and a rename there is a
# rename here.
#
# What it cannot see is a run still going: two pushes close together may
# both read the same history. The worst left is one green post too many, or
# one missing. A run red only for its own post, a webhook missing say, is
# red like any other, and the next green run posts again: the post that was
# lost.
#
# It never guesses: a history it cannot read exits 1, and nothing is posted.
#
# Inputs, from the environment: GH_TOKEN (Actions read), REPOSITORY, RUN_ID.
# Usage, from a checkout: bash deploy/lab-green.sh
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is not set - the job token, with Actions read, that reads this workflow history}"
: "${REPOSITORY:?REPOSITORY is not set - owner/name}"
: "${RUN_ID:?RUN_ID is not set - the run asking}"

DEPLOY_JOB="Deploy to the lab"
DEPLOY_STEP="Assert the commit is answering on the public URL"
PAGE=100

die() { echo "lab-green: $*" >&2; exit 1; }

# `tr`, because jq on Windows ends its output with a carriage return. On
# Linux it removes nothing.
run="$(gh api "repos/${REPOSITORY}/actions/runs/${RUN_ID}")" || die "could not read run ${RUN_ID}"
workflow="$(jq -r '.workflow_id' <<<"${run}" | tr -d '\r')"
number="$(jq -r '.run_number' <<<"${run}" | tr -d '\r')"
branch="$(jq -r '.head_branch' <<<"${run}" | tr -d '\r')"
case "${workflow}" in ''|*[!0-9]*) die "run ${RUN_ID} names no workflow: ${workflow}" ;; esac
case "${number}" in ''|*[!0-9]*) die "run ${RUN_ID} has no run number: ${number}" ;; esac
case "${branch}" in ''|null|*[!A-Za-z0-9._/-]*) die "run ${RUN_ID} names no branch this can ask about: ${branch}" ;; esac

runs="$(gh api "repos/${REPOSITORY}/actions/workflows/${workflow}/runs?branch=${branch}&status=completed&per_page=${PAGE}")" \
  || die "could not read the history of workflow ${workflow}"
# A list, or the end: no list would read as an empty history, and say first.
listed="$(jq -e '.workflow_runs | arrays | length' <<<"${runs}" | tr -d '\r')" \
  || die "the history of workflow ${workflow} holds no list of runs"

# 0 when run $1 deployed, 1 when it did not. A run whose jobs cannot be read
# is neither, and ends this.
deployed() {
  local jobs rc=0
  jobs="$(gh api "repos/${REPOSITORY}/actions/runs/$1/jobs?per_page=${PAGE}")" || die "could not read the jobs of run $1"
  jq -e --arg job "${DEPLOY_JOB}" --arg step "${DEPLOY_STEP}" '
    any(.jobs[]; .name == $job and any(.steps[]?; .name == $step and .conclusion == "success"))' \
    <<<"${jobs}" >/dev/null || rc=$?
  case "${rc}" in
    0|1) return "${rc}" ;;
    *) die "the jobs of run $1 are not what the Actions API returns" ;;
  esac
}

red=false
while IFS=' ' read -r id conclusion; do
  [ -n "${id}" ] || continue
  [ "${conclusion}" = "failure" ] && red=true
  if deployed "${id}"; then
    if ${red}; then echo after-red; else echo none; fi
    exit 0
  fi
done < <(jq -r --argjson n "${number}" '
  .workflow_runs
  | map(select(.run_number < $n and (.conclusion == "success" or .conclusion == "failure")))
  | sort_by(-.run_number)[]
  | "\(.id) \(.conclusion)"' <<<"${runs}" | tr -d '\r')

# Nothing earlier deployed. A full page may hide older runs that did, so
# "first" is said only when the page held the whole history.
if [ "${listed}" -lt "${PAGE}" ]; then
  echo first
elif ${red}; then
  echo after-red
else
  echo none
fi
