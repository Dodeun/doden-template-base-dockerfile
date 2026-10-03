#!/usr/bin/env bash
# Runs ON THE GITHUB RUNNER, as the last step of .github/workflows/deploy.yml,
# and never on the production host - which is the whole point of it. It asks
# `https://${APP_HOST}/api/health` over the public internet and requires the
# release the deploy just shipped, so what it tests is the path a user takes:
# DNS, Traefik, the router rule, into the Service that answers it. Asked
# from the host, the same request would depend on hairpin NAT and would prove
# less than it looks like it does.
#
# A file rather than ten lines of inline YAML, for one reason: a check that has
# only ever passed has not been tested. As a file it can be pointed at a host
# that should fail it -
#
#   APP_HOST=example.com RELEASE_TAG=v0.1.0 bash deploy/assert-release.sh
#
# - which names a host serving something this release was not built for, and
# that is the failure worth catching. A router that sends /api/health to the
# wrong Service can answer HTTP 200 with a page where JSON was expected, and
# `curl -f` alone would call that a successful deploy, so the body is read
# rather than the status line.
#
# It is also what a hand-run deploy on the host has instead of nothing. Only
# the workflow runs it by itself.
set -euo pipefail

: "${APP_HOST:?APP_HOST is not set - the public hostname to ask, from the appHost in platform.json}"
: "${RELEASE_TAG:?RELEASE_TAG is not set - the release /api/health is expected to report}"
# Checked rather than assumed: every GitHub-hosted runner has jq, a laptop may
# not, and without this the JSON check below would fail as "not ok" and blame
# the deploy for a missing tool.
command -v jq >/dev/null || {
  echo "ERROR: jq is not installed, and this script parses JSON with it." >&2
  exit 1
}

# Retried briefly: `up -d --wait` returns once the containers are healthy,
# which is a moment before Traefik has finished swapping the old containers
# out of its load balancer. A check that flakes is a check people learn to ignore.
#
# `-f` means an HTTP error arrives here as no body at all, with curl's own
# complaint on stderr. That is why the two failures below are reported
# separately rather than by one message that would be false for whichever of
# them it was not written for.
for attempt in 1 2 3 4 5; do
  body="$(curl -fsS --max-time 10 "https://${APP_HOST}/api/health")" && break
  echo "    no answer from ${APP_HOST} yet (attempt ${attempt}/5)"
  sleep 3
done

if [ -z "${body:-}" ]; then
  echo "::error::https://${APP_HOST}/api/health never answered. curl's own complaint is in the log above. The deploy is not verified."
  exit 1
fi

if [ "$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null)" != "ok" ]; then
  echo "::error::https://${APP_HOST}/api/health answered, but not with JSON saying status ok. The deploy is not verified."
  echo "What it answered instead, first 200 bytes:"
  printf '%.200s\n' "$body"
  exit 1
fi

release="$(printf '%s' "$body" | jq -r '.release // empty')"
if [ "${release}" != "${RELEASE_TAG}" ]; then
  echo "::error::/api/health reports '${release}', but this deploy shipped ${RELEASE_TAG}. Either the deploy did not take, or Traefik is still answering from the previous containers."
  exit 1
fi

echo "https://${APP_HOST}/api/health reports ${release}"
