#!/usr/bin/env bash
# Runs ON THE VPS, invoked over SSH by .github/workflows/deploy.yml, which
# fires when a `v*` tag is pushed (ADR-0008) or when someone dispatches it
# with a tag by hand. This file does not live on the host: the workflow copies
# it there out of the release being deployed, immediately before running it
# (ADR-0011). The directory is ~/apps/<slug> - every Project lives under
# ~/apps/ under the name its Manifest gives it - and holds this script and
# docker-compose.prod.yml and nothing else: no Project source, no `.git`, no
# deploy key. What the host does hold is a Doppler service token scoped to
# that directory (`doppler configure`), read-only, config `prd`.
#
# **deploy.yml copies this file in before invoking it, and this file fetches
# nothing.** It reads as a missing step and it is the opposite: a script
# cannot fetch a newer copy of itself. Bash reads a script incrementally by
# byte offset, so an old script that replaces its own file leaves bash reading
# the new bytes from the old offset - measured on this platform, and it
# produced a syntax error partway through a run. What is left here is a
# verification that this file and the Compose file beside it hash to what the
# release ships, which is also what keeps a hand-run honest.
#
# Nothing is built here. Images come from the registry, published by
# .github/workflows/build.yml on every push to `main` and tagged with the
# commit SHA. The host pulls; it does not compile. That is what keeps the
# previous release pullable, and therefore what makes a rollback possible.
#
# **Nothing here knows this Project's stack.** The Services to pull are the
# ones docker-compose.prod.yml names, and the migration is the `migrate`
# command platform.json declares in the database Add-on, forwarded by
# deploy.yml and run as the contract says (CONTRACT.md, "How the commands are
# run"): `sh -c '<command>'`, in place of the image's entrypoint, in a one-off
# container of the named Service's new image, before that image serves.
#
# **The database is not in this Stack.** Postgres is a Shared Platform Service
# (ADR-0005): one server for every Project, started by the platform's own stack
# at ~/infra/postgres and reached over the external `data` network. A Project
# owns a role and a database on it, nothing more. The pre-flight below is what
# replaces the `depends_on` that would otherwise guarantee a database was up -
# it fails before anything is pulled, migrated or restarted rather than in the
# middle of it.
#
# **Rolling back is running this again with an older RELEASE_TAG** - normally
# by dispatching deploy.yml with that tag. It restores behaviour, never data.
# Migrations only go forward, so an older image runs against the newer
# schema, which is why the database Add-on requires expand/contract
# (docs/addons/database.md). Nothing here can tell whether the schema in place
# is one the older image understands: that depends on the migration tool,
# which is this Project's choice and not this script's.
#
# No .env file is written or read anywhere in this script (ADR-0007): app
# secrets live only in Doppler and are injected with `doppler run --` around
# the specific commands below that need them, never exported into the shell of
# this script.
#
# Ambient env vars this script itself needs, forwarded by the SSH step of
# deploy.yml (not from Doppler): PROJECT_SLUG, APP_HOST, RELEASE_TAG,
# IMAGE_TAG, IMAGE_REPO_PREFIX, DATABASE_ADDON, COMPOSE_SHA256 and
# SCRIPT_SHA256, all required; MIGRATE_SERVICE and MIGRATE_COMMAND_B64,
# required when DATABASE_ADDON is true; and optionally GHCR_USERNAME,
# GHCR_TOKEN, TRAEFIK_CERT_RESOLVER, PSQL_IMAGE.
#
# **DATABASE_ADDON is how the database Add-on is guarded rather than injected.**
# deploy.yml reads `addons` out of platform.json on the runner and forwards the
# answer; this file carries both branches and takes neither on faith. That is
# what keeps it byte-identical across every Project - a file `project new`
# edits is a file drift can never be measured against again - and it is why
# the value is required rather than defaulted: a deploy that guesses whether a
# Project has a database will migrate the wrong one or skip the right one.
set -euo pipefail

# No apostrophe in any message below. Bash parses the word of ${VAR:?word}
# with its own quoting rules, so a single quote there opens one that never
# closes and the script dies at its far end with "unexpected EOF" - pointing
# at a line that is fine. scripts/check-shell.sh parses this file on every
# pull request for exactly that.

: "${PROJECT_SLUG:?PROJECT_SLUG is not set - the slug from platform.json, which names the directory here, the Compose project and every Traefik router}"
: "${APP_HOST:?APP_HOST is not set - see the header of this script}"
: "${RELEASE_TAG:?RELEASE_TAG is not set - this script deploys a release tag, e.g. RELEASE_TAG=v0.1.0}"
: "${IMAGE_TAG:?IMAGE_TAG is not set - the commit RELEASE_TAG points at, resolved on the runner; images are addressed by commit, never by tag}"
: "${IMAGE_REPO_PREFIX:?IMAGE_REPO_PREFIX is not set - the registry path build.yml published under; the Compose file defaults it no longer, so without it the image reference starts with a hyphen}"
: "${COMPOSE_SHA256:?COMPOSE_SHA256 is not set - deploy.yml supplies what docker-compose.prod.yml hashes to in this release}"
: "${SCRIPT_SHA256:?SCRIPT_SHA256 is not set - deploy.yml supplies what this script hashes to in this release}"
: "${DATABASE_ADDON:?DATABASE_ADDON is not set - deploy.yml derives it from the addons in platform.json, and a deploy that guesses it migrates the wrong database or skips the right one}"

# Exactly true or false. Anything else is a derivation that went wrong on the
# runner, and treating an unexpected value as false would silently skip every
# migration for the rest of this Project's life.
case "${DATABASE_ADDON}" in
  true | false) ;;
  *)
    echo "ERROR: DATABASE_ADDON is '${DATABASE_ADDON}', which is neither true nor false." >&2
    echo "       deploy.yml derives it from platform.json; this value means that" >&2
    echo "       derivation failed rather than that this Project has no database." >&2
    exit 1
    ;;
esac

if [ "${DATABASE_ADDON}" = "true" ]; then
  : "${MIGRATE_SERVICE:?MIGRATE_SERVICE is not set - the Service platform.json names for the migrate command of the database Add-on}"
  : "${MIGRATE_COMMAND_B64:?MIGRATE_COMMAND_B64 is not set - the migrate command platform.json declares, base64-encoded by deploy.yml}"
  # Decoded here rather than forwarded as text: a command is free text, and
  # the SSH hop between the runner and this shell has quoting of its own.
  MIGRATE_COMMAND="$(printf '%s' "${MIGRATE_COMMAND_B64}" | base64 -d)"
  : "${MIGRATE_COMMAND:?MIGRATE_COMMAND_B64 decodes to nothing - deploy.yml encodes the migrate command of platform.json, which the contract requires to be non-empty}"
fi

# Must match the `data` network in docker-compose.prod.yml, and the network
# the shared Postgres stack creates. Named in one place here and one there;
# changing it is a two-file edit on purpose, because a Stack silently on the
# wrong network is a deploy that cannot reach its database.
DATA_NETWORK=data
# Only ever used for a throwaway `psql` - never to run a server. It is the
# same image the platform's Postgres stack runs, so the host already has it.
PSQL_IMAGE="${PSQL_IMAGE:-postgres:17-alpine}"

cd ~/apps/"${PROJECT_SLUG}"

# This script fetches nothing. deploy.yml copies both descriptors in before
# this file is read, and the header explains why. What is left here is the
# verification, because the guarantee still has to hold - the Compose file
# describing the Stack, and the script driving it, must come from the same
# release as the images they name, which is what makes redeploying an older
# tag the older release rather than today's Compose file pointed at an old
# image.
#
# The expected hashes come from the runner checkout of the release, which is
# the only copy of it in the chain. Hashing these files here and comparing
# them to themselves would prove nothing; comparing them to the release proves
# the thing that matters - so a copy that only half happened, new script and
# stale Compose file or the reverse, is a refusal instead of a deploy nobody
# can name afterwards.
#
# What this does not do, since a check is worth exactly what it claims: the
# hash of this script is checked by this script, so it catches the copy that
# did not land and not a script edited on the host - an edit can delete its
# own check. Tampering on the host is the other half of ADR-0011, which is to
# hold nothing there worth tampering with.
echo "==> Verifying the descriptors are ${RELEASE_TAG}"
verify_descriptor() {
  local file="$1" expected="$2" actual
  # Named before it is hashed: `sha256sum` on a missing file would abort the
  # script with its own message, which is true and says nothing about the copy
  # that should have put the file there - the case this function exists for.
  if [ ! -f "${file}" ]; then
    echo "ERROR: ${file} is not on this host at all." >&2
    echo "       deploy.yml copies both descriptors in from the release" >&2
    echo "       immediately before running this script, so this means the" >&2
    echo "       copy did not land. Re-run the deploy." >&2
    exit 1
  fi
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  if [ "${actual}" != "${expected}" ]; then
    echo "ERROR: ${file} is not the copy ${RELEASE_TAG} ships." >&2
    echo "       expected sha256 ${expected}" >&2
    echo "       found           ${actual}" >&2
    echo "       Both descriptors are copied in from the release by" >&2
    echo "       deploy.yml immediately before this script runs, so a" >&2
    echo "       mismatch means that copy did not land. Re-run the deploy" >&2
    echo "       rather than editing the file here." >&2
    echo "       Running by hand? Take both from the tag itself:" >&2
    echo "         git show ${RELEASE_TAG}:docker-compose.prod.yml" >&2
    echo "         git show ${RELEASE_TAG}:deploy/remote-deploy.sh" >&2
    exit 1
  fi
}
verify_descriptor docker-compose.prod.yml "${COMPOSE_SHA256}"
verify_descriptor deploy/remote-deploy.sh "${SCRIPT_SHA256}"
echo "    both are ${RELEASE_TAG}"

# Exported, not merely read: docker-compose.prod.yml interpolates them, and a
# variable this script only holds is a variable `docker compose` never sees.
# RELEASE_TAG becomes the RELEASE /api/health reports; PROJECT_SLUG is
# required by the Compose file, so an unexported one is not a Stack with the
# wrong name but a `docker compose` that refuses to render. appleboy/ssh-action
# already exports what it forwards - this line is for the hand-run, which
# otherwise sets them for this script alone.
export PROJECT_SLUG IMAGE_TAG APP_HOST RELEASE_TAG IMAGE_REPO_PREFIX
echo "==> Deploying ${RELEASE_TAG} (images tagged ${IMAGE_TAG})"

# One `psql` against the Project's own database, from a throwaway container on
# the shared network. Not `docker compose exec postgres`: there is no postgres
# service in this Stack, and reaching into the platform container would mean
# knowing its name and using its superuser. Every connection detail comes from
# DATABASE_URL instead, so what is tested here is exactly what the Stack will
# use - right down to the role and the database name.
psql_prd() {
  doppler run -- docker run --rm --network "${DATA_NETWORK}" -e DATABASE_URL \
    "${PSQL_IMAGE}" sh -c 'psql -v ON_ERROR_STOP=1 -tAc "$1" "$DATABASE_URL"' _ "$1"
}

if [ "${DATABASE_ADDON}" = "true" ]; then
  # The check that replaces `depends_on`. It runs before the pull because
  # every later step needs the database, and because the three ways this fails
  # on a first deploy - network missing, server down, role or database never
  # created - are all quicker to read here than as a migration crash. It also
  # proves the credential in Doppler, which `pg_isready` would not: a server
  # accepts a connection attempt long before it accepts *this* role.
  echo "==> Checking the shared Postgres is reachable"
  if ! docker network inspect "${DATA_NETWORK}" >/dev/null 2>&1; then
    echo "ERROR: this host has no Docker network '${DATA_NETWORK}'." >&2
    echo "       It belongs to the shared Postgres stack, not to this Project." >&2
    echo "       Start it: docker compose -f ~/infra/postgres/docker-compose.yml up -d" >&2
    exit 1
  fi
  # Retried inside the container so a server still starting up (a deploy right
  # after a host reboot) is waited for rather than failed on. The last attempt
  # runs unredirected, so whatever psql actually objects to is what gets
  # printed.
  if ! psql_prd "select 1" >/dev/null 2>&1; then
    echo "    not answering yet, retrying for ~20s"
    doppler run -- docker run --rm --network "${DATA_NETWORK}" -e DATABASE_URL \
      "${PSQL_IMAGE}" sh -c '
        for _ in 1 2 3 4 5 6 7 8 9; do
          sleep 2
          psql -v ON_ERROR_STOP=1 -tAc "select 1" "$DATABASE_URL" >/dev/null 2>&1 && exit 0
        done
        psql -v ON_ERROR_STOP=1 -tAc "select 1" "$DATABASE_URL"
      ' || {
      echo "ERROR: could not connect with the DATABASE_URL held in Doppler." >&2
      echo "       Host must be 'postgres' (the platform container, resolved on" >&2
      echo "       the '${DATA_NETWORK}' network), and the role and database it" >&2
      echo "       names must exist on the shared server." >&2
      echo "       The complaint from psql is immediately above. It decides where" >&2
      echo "       to look, and only two of the three name themselves:" >&2
      echo "         'could not translate host name'  -> wrong host, or this" >&2
      echo "              container is not on the ${DATA_NETWORK} network" >&2
      echo "         'database \"...\" does not exist'  -> CREATE DATABASE never ran" >&2
      echo "         'password authentication failed' -> wrong password OR a role" >&2
      echo "              that was never created. Postgres reports both this way" >&2
      echo "              and will not tell you which, so check the role exists" >&2
      echo "              (docker exec postgres psql -U postgres -c '\\du')" >&2
      echo "              before assuming the password in Doppler is wrong." >&2
      exit 1
    }
  fi
  echo "    reachable, and the role in DATABASE_URL can log in"
else
  echo "==> No database Add-on declared in platform.json - skipping the Postgres pre-flight"
fi

# The packages are private when the repository is. The credential is the
# workflow's own GITHUB_TOKEN, forwarded over SSH: it expires when the job
# ends, so there is no registry secret stored on this host and none to rotate.
# Log out on the way out regardless of how we leave.
if [ -n "${GHCR_TOKEN:-}" ]; then
  echo "==> Logging in to ghcr.io"
  trap 'docker logout ghcr.io >/dev/null 2>&1 || true' EXIT
  printf '%s' "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USERNAME:-x-access-token}" --password-stdin
else
  # Not an error, and not anonymous: a private package could never be pulled
  # anonymously. This is the hand-run path - someone on the host who has
  # already done `docker login ghcr.io` themselves. The pull below uses that
  # stored credential, and says so plainly if there is not one.
  echo "==> No GHCR_TOKEN set, relying on an existing docker login on this host"
fi

# Every Service docker-compose.prod.yml names, so a Service added to the
# Stack is pulled without this file knowing its name. Explicit rather than
# left to `up -d`, so a tag that was never published fails here, before
# anything is stopped or migrated. Expect this to fail if the build workflow
# has not finished for this commit yet - or if the tag was pushed to a commit
# that never reached `main`, which is the one way to name a release with no
# images behind it.
echo "==> Pulling images"
docker compose -f docker-compose.prod.yml pull

if [ "${DATABASE_ADDON}" = "true" ]; then
  echo "==> Running the migrate command, in ${MIGRATE_SERVICE}"
  echo "    ${MIGRATE_COMMAND}"
  # In the image just pulled, before it serves: a migration that fails stops
  # here, and the previous release goes on serving.
  #
  # --no-deps: a dependency of the Service would otherwise start - from the
  # new release - before the schema it expects exists.
  #
  # -e DATABASE_URL: the contract promises the command DATABASE_URL in its
  # environment, whichever Service it names, so it is passed rather than left
  # to whether that Service's own entry in the Compose file asks for it.
  #
  # --label traefik.enable=false is not cosmetic. Measured on this platform:
  # `compose run` copies the service's labels onto the one-off container,
  # Traefik's Docker provider included, so for as long as the migration runs
  # a second container carrying `traefik.enable=true` and the Service's
  # router rule sits on the `web` network. Traefik adds it as a second server
  # and round-robins real requests to a container with nothing listening.
  # Invisible on a first deploy - there is no traffic yet - which is how it
  # would have shipped.
  if ! doppler run -- docker compose -f docker-compose.prod.yml run --rm -T --no-deps \
      --label traefik.enable=false -e DATABASE_URL \
      --entrypoint sh "${MIGRATE_SERVICE}" -c "${MIGRATE_COMMAND}"; then
    echo "ERROR: the migrate command of ${RELEASE_TAG} failed, above." >&2
    echo "       Nothing was restarted: the previous release is still serving." >&2
    echo "       What the migration did before it failed is for the migration" >&2
    echo "       tool to say - it is this Project's, not the platform's." >&2
    exit 1
  fi
else
  echo "==> No database Add-on declared in platform.json - no migration to run"
fi

# --wait: without it `up -d` returns as soon as the containers are created, so
# a release that crash-loops on boot reports a green deploy. Every service in
# the Stack declares a healthcheck, so this waits for the real thing.
echo "==> Starting the full stack"
doppler run -- docker compose -f docker-compose.prod.yml up -d --wait

echo "==> Done. ${RELEASE_TAG} is live (images ${IMAGE_TAG})."
# Deliberately not a curl printed for the operator to maybe run:
# deploy/assert-release.sh does it as the last step of deploy.yml, from the
# runner, which is where the path a user actually takes begins. Run from this
# host the same request would depend on hairpin NAT, so a green answer here
# would prove less than it looks like it does. After a hand-run, run that
# script from anywhere but here.
docker compose -f docker-compose.prod.yml ps
