#!/usr/bin/env bash
# Runs the commands platform.json declares for the database Add-on - `migrate`,
# then `seed` - against the throwaway Postgres of docker-compose.test.yml,
# exactly as the platform runs them (CONTRACT.md, "How the commands are run"):
#
#   sh -c '<command>', in place of the image's entrypoint, in a one-off
#   container of the Service the command names, with DATABASE_URL in its
#   environment.
#
# The `test` job of .github/workflows/test.yml runs this before the tests, on
# every pull request. A declared command nobody has run is a Manifest field
# that is false, and the first to find out would otherwise be a deploy -
# `migrate` - or a Preview - `seed`.
#
# The Service a command names is the one of that name in
# docker-compose.test.yml, built from the same `build:` key as production's;
# the contract's `addon-commands` rule already holds it to the production
# file. Its dependencies start first, so the database it points at is up.
#
# Usage, from anywhere:
#   bash scripts/addon-commands.sh
# It leaves the test Stack running for the tests; CI takes it down afterwards
# with `docker compose -f docker-compose.test.yml down -v`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys" >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
[ -n "$PY" ] || { echo "cannot run: no working Python 3 on PATH" >&2; exit 2; }

# One `<name> <service> <base64 command>` line per declared command. Base64,
# because a command is free text - quotes, `$`, spaces - and it has to cross
# a `read` without the shell having an opinion about it.
commands="$("$PY" - <<'READ_COMMANDS'
import base64, json
manifest = json.load(open("platform.json", encoding="utf-8"))
database = (manifest.get("addons") or {}).get("database")
for name in ("migrate", "seed"):
    if database is None:
        break
    declared = database.get(name) or {}
    if "service" not in declared or "command" not in declared:
        raise SystemExit(
            "platform.json declares the database Add-on without a complete "
            + name + " - { \"service\": ..., \"command\": ... }. The contract "
            "check says the same, in more words.")
    print(name, declared["service"],
          base64.b64encode(declared["command"].encode("utf-8")).decode("ascii"))
READ_COMMANDS
)"
# A Windows Python ends its lines with a carriage return, and one left on the
# end of the base64 would decode into a command nobody wrote.
commands="$(printf '%s' "${commands}" | tr -d '\r')"

if [ -z "${commands}" ]; then
  echo "platform.json declares no database Add-on, so there is no command to run."
  exit 0
fi

while read -r name service encoded; do
  command="$(printf '%s' "${encoded}" | base64 -d)"
  echo "==> ${name}, in ${service}: ${command}"
  # -T: the output is a log, not a terminal. --rm: one-off, as on the host.
  # `-e DATABASE_URL` is not passed: the Service's own environment in
  # docker-compose.test.yml carries it, pointing at the throwaway database.
  #
  # `< /dev/null` is load-bearing. `compose run` reads its standard input,
  # which here is the rest of this loop's list: without it, `migrate` runs and
  # swallows the `seed` line, and the loop ends green having run one command
  # of two. Measured.
  if ! docker compose -f docker-compose.test.yml run --rm -T \
      --entrypoint sh "${service}" -c "${command}" < /dev/null; then
    echo "ERROR: the ${name} command platform.json declares failed, above." >&2
    echo "       The deploy runs it the same way against production, so it" >&2
    echo "       has to work here first. It belongs to this Project: fix the" >&2
    echo "       command or the image of ${service}, in the same pull request." >&2
    exit 1
  fi
done <<< "${commands}"
