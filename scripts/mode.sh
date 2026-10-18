#!/usr/bin/env bash
# Prints the mode this repository is in, read from the committed Manifest:
#
#   project    platform.json has no `prototype` block
#   prototype  platform.json has one
#
# One Template, read two ways (ADR-0015). A Prototype is copied from the same
# files as a Project and says what it is in its Manifest, so the mode is read
# from there and from nowhere else - never from a repository setting, which an
# agent whose scope is this repository cannot see (ADR-0010).
#
# The block's presence is all this asks. Whether the block is *valid* is the
# contract's question, answered by `contract / tier-1`; a second answer here
# would drift from that one.
#
# A Manifest that is missing or is not JSON is neither mode, and this exits 1
# rather than guessing: a guess of "project" would send a Prototype's push down
# the path that waits for tests, and a guess of "prototype" would deploy a
# Project to the lab.
#
# Usage, from the repository root: bash scripts/mode.sh
set -euo pipefail

if [ ! -f platform.json ]; then
  echo "ERROR: there is no platform.json here, so this repository says neither that it is a Project nor that it is a Prototype." >&2
  exit 1
fi
if ! jq -e 'type == "object"' platform.json > /dev/null 2>&1; then
  echo "ERROR: platform.json is not a JSON object, so its mode cannot be read. The contract check says what is wrong with it." >&2
  exit 1
fi

if jq -e 'has("prototype")' platform.json > /dev/null; then
  echo prototype
else
  echo project
fi
