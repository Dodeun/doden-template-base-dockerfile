#!/usr/bin/env bash
# Runs the tier-1 Platform Contract checker against this repository three
# times, and asserts what each answer must be. It is what makes the claim
# "this Template produces Projects the platform will deploy" a measurement
# rather than a hope, and .github/workflows/profile.yml runs it on every push
# and pull request.
#
#   1. **This tree, as committed.** While platform.json is still the
#      placeholder the Template ships, the checker must **refuse** it, and the
#      refusal must be the Manifest and nothing else - every other rule has to
#      pass, or the Template is shipping a violation to every Project copied
#      from it. Once the Manifest has been filled in, the same run must come
#      back green.
#
#      A Template whose Manifest passed the check would be worse than one that
#      fails it: an uninitialised copy would deploy under the identity of the
#      Template, into the directory of the Template, answering for its
#      hostname. The placeholder is invalid on purpose, and this is where that
#      purpose is enforced rather than asserted in a comment.
#
#   2. **With the database Add-on declared** - a filled-in Manifest, the
#      Compose file untouched. Must pass.
#
#   3. **With the database Add-on switched off** - a filled-in Manifest
#      declaring no Add-ons, every `addon:database` region removed from every
#      file that carries one, and the Add-on's whole files removed with it,
#      from the list in scripts/addons.json. Must also pass.
#
# 2 and 3 are the same tree judged under both Manifests, which is the one
# thing the Compose file cannot express by itself: the contract renders it
# knowing only the Manifest and the release, so "joined because the Manifest
# says so" is not something interpolation can say. The regions are therefore
# removed rather than guarded - and this check is what keeps that honest, by
# proving the tree is correct in both states rather than in the one it happens
# to be in.
#
# **What it does not do**, because a check is worth exactly what it claims: it
# runs the tier-1 contract checker and nothing else. Nothing here compiles,
# boots or tests anything, so it will tell you that a Manifest and a Stack
# disagree about the database and it will not tell you that the application
# still builds without one. That is what the `test` job of test.yml is for:
# it runs the tests and builds every production image.
#
# Neither 2 nor 3 touches the working tree: each is a copy in a temporary
# directory, git-initialised and staged, because "no committed .env" is a
# question about the index rather than about the directory - and an unstaged
# copy would let every rule that reads the file list pass by finding nothing.
#
# Usage:
#   bash scripts/profile-selfcheck.sh [path-to-doden-contract]
#
# The checker is not vendored here: it is pinned and published, and a copy in
# a Project is a check deletable by the hand it is guarding. Clone it once -
#
#   git clone --depth 1 -b v3 https://github.com/Dodeun/doden-contract ~/.doden-contract
#
# - or point DODEN_CONTRACT at an existing checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="${1:-${DODEN_CONTRACT:-$HOME/.doden-contract}}"

# Exit 2 is reserved for this script being unable to run at all. Neither a
# missing checker nor a missing interpreter is a statement about this
# repository, and returning 1 for them would have somebody editing a Compose
# file to fix their laptop.
if [ ! -f "${CONTRACT}/check.py" ]; then
  echo "cannot run: no contract checker at ${CONTRACT}/check.py." >&2
  echo "  git clone --depth 1 -b v3 https://github.com/Dodeun/doden-contract ~/.doden-contract" >&2
  echo "or pass the path to an existing checkout as the first argument." >&2
  exit 2
fi

# python3 on Linux and macOS, python on Windows, where python3 is a Microsoft
# Store stub that exits without running anything.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys" >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "cannot run: no working Python 3 on PATH, and the contract checker is a Python program." >&2
  exit 2
fi

SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

# A filled-in Manifest, used for directions 2 and 3: a valid identity in
# place of this repository's own, whoever is running this and whatever state
# their Manifest is in. Everything else is this repository's own - the
# Profile, and the database Add-on's configuration with its commands - because
# those name things in this tree: a `migrate` naming a Service this Stack
# does not have is exactly what the contract would refuse.
#
# `database` is "yes" or "no". With "yes", this repository's Manifest has to
# declare the Add-on, or there is no configuration to judge the tree with.
write_manifest() {
  "$PY" - "${ROOT}/platform.json" "$1/platform.json" "$2" <<'WRITE_MANIFEST'
import json, sys
own = json.load(open(sys.argv[1], encoding="utf-8"))
database = (own.get("addons") or {}).get("database")
if sys.argv[3] == "yes" and database is None:
    sys.exit(
        "platform.json declares no database Add-on, and this tree still "
        "carries addon:database regions. Either the Add-on was removed from "
        "the Manifest and not from the files, or the reverse: a prune that "
        "half happened.")
manifest = {
    "$schema": "https://raw.githubusercontent.com/Dodeun/doden-contract/v3/platform.schema.json",
    "slug": "profile-selfcheck",
    "appName": "Profile Selfcheck",
    "appHost": "profile-selfcheck.example.test",
    "profile": own.get("profile"),
    "addons": {"database": database} if sys.argv[3] == "yes" else {},
    "contractVersion": "v3",
}
with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as out:
    out.write(json.dumps(manifest, indent=2) + "\n")
WRITE_MANIFEST
}

# The files an Add-on brings with it, from scripts/addons.json - the one place
# that list lives. `new.sh` in Dodeun/doden-project-control reads the same
# file to prune a fresh copy, so a fourth entry is added once rather than in
# however many places happen to know about the third.
addon_files() {
  "$PY" - "${ROOT}/scripts/addons.json" "$1" <<'READ_ADDON_FILES'
import json, sys
catalogue = json.load(open(sys.argv[1], encoding="utf-8"))
addon = catalogue["addons"].get(sys.argv[2])
if addon is None:
    sys.exit("scripts/addons.json does not describe the " + sys.argv[2] + " Add-on")
print("\n".join(addon["files"]))
READ_ADDON_FILES
}

# A copy of the tracked working tree, staged in a repository of its own.
copy_tree() {
  local target="$1"
  mkdir -p "${target}"
  # `git ls-files` rather than `cp -r`: it is the same definition of "in this
  # repository" the checker itself uses, and it leaves every ignored file and
  # build output behind without a list of exclusions to keep up to date.
  ( cd "${ROOT}" && git ls-files -z ) | while IFS= read -r -d '' file; do
    mkdir -p "${target}/$(dirname "${file}")"
    cp "${ROOT}/${file}" "${target}/${file}"
  done
  git -C "${target}" init -q
  git -C "${target}" add -A
}

# Removes every `>>> addon:<name>` ... `<<< addon:<name>` region from every
# file in a tree that carries one, and refuses to pretend it did anything when
# there was nothing to remove. A silent no-op here would make direction 3 a
# second copy of direction 2, and the check would stay green while testing
# half of what it claims.
#
# The marker is matched without its comment character, so the same pair works
# in YAML, in a Dockerfile and in any language. Every file is swept rather than
# a list of filenames kept here: a list goes stale the first time somebody
# marks a region in a file this script has not heard of, and the failure is
# this check passing on a tree nobody produces.
#
# `sed` writes to a new file rather than `sed -i`, which takes an argument on
# BSD and none on GNU - and this script already goes out of its way to run on
# whatever the operator has.
strip_addon() {
  local tree="$1" addon="$2" files total=0 count
  files="$(grep -rl ">>> addon:${addon}\$" "${tree}" --exclude-dir=.git || true)"
  if [ -z "${files}" ]; then
    echo "ERROR: nothing in ${tree} carries an 'addon:${addon}' region." >&2
    echo "       Either the markers were edited away, or this script is" >&2
    echo "       checking something it cannot check. Not treated as nothing" >&2
    echo "       to do: that would make this direction a duplicate of the" >&2
    echo "       previous one and the check would stay green testing half of" >&2
    echo "       what it says it tests." >&2
    exit 1
  fi
  while IFS= read -r file; do
    count="$(grep -c ">>> addon:${addon}\$" "${file}")"
    total=$((total + count))
    sed "/>>> addon:${addon}\$/,/<<< addon:${addon}\$/d" "${file}" > "${file}.stripped"
    mv "${file}.stripped" "${file}"
    echo "    removed ${count} addon:${addon} region(s) from ${file#${tree}/}"
  done <<< "${files}"
  echo "    ${total} region(s) in total"
}

# Runs the checker and hands the verdict to the caller as JSON.
verdict() {
  local tree="$1" out="$2"
  set +e
  "$PY" "${CONTRACT}/check.py" --json "${tree}" > "${out}"
  local status=$?
  set -e
  if [ "${status}" -eq 2 ]; then
    echo "cannot run: the contract checker could not run against ${tree}." >&2
    cat "${out}" >&2
    exit 2
  fi
  echo "${status}"
}

# The rules that failed, one per line, deduplicated - the report prints a
# violation per problem and several can belong to one rule.
failed_rules() {
  "$PY" - "$1" <<'PY'
import json, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
seen = []
for violation in result["violations"]:
    if violation["rule"] not in seen:
        seen.append(violation["rule"])
print("\n".join(seen))
PY
}

messages() {
  "$PY" - "$1" <<'PY'
import json, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
for violation in result["violations"]:
    print("      " + violation["rule"] + ": " + violation["message"])
PY
}

placeholder_manifest() {
  "$PY" - "${ROOT}/platform.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
print("yes" if manifest.get("slug") == "FILL-ME-IN" else "no")
PY
}

echo "profile self-check, using the contract checker at ${CONTRACT}"
echo

# ---------------------------------------------------------------------------
# 1. This tree, as committed.
# ---------------------------------------------------------------------------
UNINITIALISED="$(placeholder_manifest)"
TREE_JSON="${SCRATCH}/tree.json"
STATUS="$(verdict "${ROOT}" "${TREE_JSON}")"

if [ "${UNINITIALISED}" = "yes" ]; then
  echo "1. this tree, with the placeholder Manifest the Template ships"
  if [ "${STATUS}" -eq 0 ]; then
    echo "   FAIL: the checker accepted it. The placeholder has to be refused, or" >&2
    echo "         an uninitialised copy deploys under the identity of the Template." >&2
    exit 1
  fi
  RULES="$(failed_rules "${TREE_JSON}")"
  if [ "${RULES}" != "manifest" ]; then
    echo "   FAIL: refused, but not only for its Manifest. Rules that failed:" >&2
    echo "${RULES}" | sed 's/^/      /' >&2
    messages "${TREE_JSON}" >&2
    echo "         Everything but the Manifest has to pass: a violation here is a" >&2
    echo "         violation every Project copied from this Template inherits." >&2
    exit 1
  fi
  echo "   refused, for its Manifest and nothing else:"
  messages "${TREE_JSON}"
else
  echo "1. this tree, with a filled-in Manifest"
  if [ "${STATUS}" -ne 0 ]; then
    echo "   FAIL: the checker refused this Project." >&2
    messages "${TREE_JSON}" >&2
    exit 1
  fi
  echo "   accepted"
fi
echo

# Whether this repository still carries the database Add-on at all. A Project
# that switched it off removed those regions, and direction 2 is then not a
# thing this script can construct - re-adding a removed region would be
# inventing a Stack nobody wrote. Said out loud rather than quietly skipped,
# because a check that silently halves itself is worse than one that is not
# there.
REGIONS="$(cd "${ROOT}" && git grep -l '>>> addon:database$' | wc -l)"

# ---------------------------------------------------------------------------
# 2. The Profile with the database Add-on declared.
# ---------------------------------------------------------------------------
if [ "${REGIONS}" -gt 0 ]; then
  echo "2. the Profile with the database Add-on declared"
  ON="${SCRATCH}/with-database"
  copy_tree "${ON}"
  write_manifest "${ON}" yes
  git -C "${ON}" add -A
  ON_JSON="${SCRATCH}/with-database.json"
  STATUS="$(verdict "${ON}" "${ON_JSON}")"
  if [ "${STATUS}" -ne 0 ]; then
    echo "   FAIL: a Project of this Profile with a database does not satisfy the contract." >&2
    messages "${ON_JSON}" >&2
    exit 1
  fi
  echo "   accepted"
else
  echo "2. the Profile with the database Add-on declared - not applicable"
  echo "   Nothing in this repository carries an addon:database region, so this"
  echo "   Project has switched the Add-on off. There is nothing here to judge"
  echo "   with a database, and re-adding the regions would be inventing a Stack"
  echo "   nobody wrote."
fi
echo

# ---------------------------------------------------------------------------
# 3. The same Profile with the database Add-on switched off.
# ---------------------------------------------------------------------------
echo "3. the Profile with the database Add-on switched off"
OFF="${SCRATCH}/without-database"
copy_tree "${OFF}"
write_manifest "${OFF}" no
if [ "${REGIONS}" -gt 0 ]; then
  strip_addon "${OFF}" database
fi
# The Add-on's whole files, from the one list. Removed here as well as the
# marked regions, because a document is not a region: a Project without a
# database that still carries docs/addons/database.md is describing a
# capability it has not got.
while IFS= read -r removable; do
  [ -n "${removable}" ] || continue
  rm -rf "${OFF:?}/${removable}"
  echo "    removed ${removable}"
# `tr`, because a Windows Python ends each line with a carriage return, and
# a path with one on the end names nothing: `rm -rf` would remove nothing
# and say so to nobody.
done < <(addon_files database | tr -d '\r')
git -C "${OFF}" add -A
OFF_JSON="${SCRATCH}/without-database.json"
STATUS="$(verdict "${OFF}" "${OFF_JSON}")"
if [ "${STATUS}" -ne 0 ]; then
  echo "   FAIL: a Project of this Profile without a database does not satisfy the contract." >&2
  messages "${OFF_JSON}" >&2
  exit 1
fi
echo "   accepted"
echo

echo "All three directions hold."
