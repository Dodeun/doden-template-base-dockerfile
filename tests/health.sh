#!/bin/sh
# The reference application's whole test suite, run as the `test` Service of
# docker-compose.test.yml, whose exit code is the verdict. It asks the
# application what deploy/assert-release.sh asks it after every deploy, so a
# change that would fail that check fails here first.
#
# POSIX sh, run in a plain alpine image. This Project's own tests replace it,
# in whatever language the Project is written in.
set -eu

: "${EXPECTED_RELEASE:?EXPECTED_RELEASE is not set - docker-compose.test.yml gives the application a release and this script the same one}"

body="$(wget -q -O - http://app/api/health)"
expected='{"status":"ok","release":"'"${EXPECTED_RELEASE}"'"}'

if [ "${body}" != "${expected}" ]; then
  echo "FAIL: GET /api/health answered" >&2
  echo "        ${body}" >&2
  echo "      where this was expected:" >&2
  echo "        ${expected}" >&2
  exit 1
fi

echo "ok: GET /api/health reports release ${EXPECTED_RELEASE}"
