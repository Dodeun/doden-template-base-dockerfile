#!/usr/bin/env bash
# Parses every shell script this repository ships with `bash -n`: each tracked
# `.sh` file, and every `run:` block in .github/workflows/*.yml. Loading the
# workflows is also what catches one that is not valid YAML at all.
#
# Why it exists. A `run:` block is a shell script nothing on a laptop reads,
# and the first thing that parses it is a GitHub runner, mid-merge. This
# platform found that out when an apostrophe inside `${VAR:?word}` - which bash
# parses with its own quoting rules, even inside double quotes - killed two
# image builds nine seconds into a merge. And a deploy script with a syntax
# error is found by a Stack that is already half stopped.
#
# **It asks nothing of this Project's stack.** The workflows are parsed by
# `yq`, run from a pinned image, because a YAML parser is the one thing
# needed and Docker is already a requirement; the blocks are walked by the
# runner's own Python. No `package.json`, no `requirements.txt`. A line-based
# scan for `run:` is not an option: one once let through a `name:` that
# contained the characters `run: `, which GitHub refused the whole file for.
#
# Usage: bash scripts/check-shell.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# Pinned: a tag nobody moves must not be able to change this check's answer.
YQ_IMAGE="mikefarah/yq:4.54.1"

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys" >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
[ -n "$PY" ] || { echo "cannot run: no working Python 3 on PATH" >&2; exit 2; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

failures=0

# -- the .sh files ---------------------------------------------------------
while IFS= read -r -d '' file; do
  if bash -n "${file}" 2>"${SCRATCH}/err"; then
    echo "ok    ${file}"
  else
    echo "FAIL  ${file}" >&2
    sed 's/^/      /' "${SCRATCH}/err" >&2
    failures=$((failures + 1))
  fi
done < <(git ls-files -z -- '*.sh')

# -- the run: blocks -------------------------------------------------------
for workflow in .github/workflows/*.yml; do
  [ -f "${workflow}" ] || continue
  # As JSON, through stdin: the container sees no file system of ours.
  if ! docker run --rm -i "${YQ_IMAGE}" -o=json '.' < "${workflow}" > "${SCRATCH}/workflow.json" 2>"${SCRATCH}/err"; then
    echo "FAIL  ${workflow} is not valid YAML:" >&2
    sed 's/^/      /' "${SCRATCH}/err" >&2
    failures=$((failures + 1))
    continue
  fi

  # Each block becomes a file of its own, named after its job and step.
  rm -rf "${SCRATCH}/blocks" && mkdir "${SCRATCH}/blocks"
  "$PY" - "${SCRATCH}/workflow.json" "${SCRATCH}/blocks" <<'SPLIT_BLOCKS'
import json, os, re, sys

workflow = json.load(open(sys.argv[1], encoding="utf-8"))
out = sys.argv[2]

# A GitHub expression is substituted before the shell sees it, so it is
# replaced by what it becomes: one shell word. Lazy to the closing braces,
# because an expression may contain a single one.
expression = re.compile(r"\$\{\{[\s\S]*?\}\}")
default_shell = ((workflow.get("defaults") or {}).get("run") or {}).get("shell")

for job_id, job in (workflow.get("jobs") or {}).items():
    job_shell = ((job.get("defaults") or {}).get("run") or {}).get("shell")
    for index, step in enumerate(job.get("steps") or [], start=1):
        if "run" not in step:
            continue
        shell = step.get("shell") or job_shell or default_shell or "bash"
        label = f"{job_id} / step {index} ({step.get('name') or step['run'].splitlines()[0][:40]})"
        name = os.path.join(out, f"{job_id}-{index:02d}")
        if shell.split()[0] not in ("bash", "sh"):
            # Said out loud: a check that quietly skips what it does not
            # understand is a check that has stopped checking.
            open(name + ".skipped", "w", encoding="utf-8").write(label + " runs under " + shell)
            continue
        open(name + ".label", "w", encoding="utf-8").write(label)
        open(name + ".sh", "w", encoding="utf-8", newline="\n").write(
            expression.sub("GITHUB_EXPRESSION", step["run"]))
SPLIT_BLOCKS

  for skipped in "${SCRATCH}"/blocks/*.skipped; do
    [ -f "${skipped}" ] || continue
    echo "skip  ${workflow}: $(cat "${skipped}")"
  done
  for block in "${SCRATCH}"/blocks/*.sh; do
    [ -f "${block}" ] || continue
    label="$(cat "${block%.sh}.label")"
    if bash -n "${block}" 2>"${SCRATCH}/err"; then
      echo "ok    ${workflow}: ${label}"
    else
      echo "FAIL  ${workflow}: ${label}" >&2
      sed 's/^/      /' "${SCRATCH}/err" >&2
      failures=$((failures + 1))
    fi
  done
done

if [ "${failures}" -gt 0 ]; then
  echo "${failures} script(s) do not parse." >&2
  exit 1
fi
echo "every shell script parses"
