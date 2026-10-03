#!/usr/bin/env bash
# Prints, as a JSON array, the images this repository publishes - one entry per
# Service of docker-compose.prod.yml whose image is under IMAGE_REPO_PREFIX:
#
#   [{"service": "app", "image": "ghcr.io/owner/repo-app:<sha>",
#     "context": "app", "dockerfile": "app/Dockerfile"}]
#
# .github/workflows/build.yml publishes exactly these, and test.yml builds
# them without publishing on every pull request. One list, so what is tested
# and what is published cannot be two different sets of images.
#
# Where each piece comes from, and why:
#   - **Which Services**, and the image each one is pulled as: the production
#     Compose file, rendered. It is what the deploy pulls, so it is the list.
#     A Service whose image is not under IMAGE_REPO_PREFIX - a third-party
#     image pinned by digest - is somebody else's to publish, and is skipped
#     with a note on stderr.
#   - **The build context and Dockerfile**: the `build:` key of the same
#     Service in docker-compose.yml, rendered with every Compose profile
#     enabled, so a Service kept out of a plain `docker compose up` by a
#     `profiles:` entry is still found. That key is the one place a Project
#     writes where its code is. `target:` and `args:` are deliberately not
#     read: see docker-compose.yml.
#
# The production file's identity variables are `${VAR:?}` and refuse to
# render without values, which is the point of them. So this script takes
# them from its caller and never defaults one (the contract's
# `identity-variables` rule): PROJECT_SLUG, APP_HOST, IMAGE_REPO_PREFIX and
# IMAGE_TAG. build.yml passes the Manifest's own values; test.yml, which
# publishes nothing, passes stand-ins.
#
# Exit 1 when the two files disagree - a published Service with no `build:`
# key, or nothing to publish at all. Exit 2 when it cannot run.
set -euo pipefail

: "${PROJECT_SLUG:?PROJECT_SLUG is not set - the slug the production Compose file is rendered with}"
: "${APP_HOST:?APP_HOST is not set - the host the production Compose file is rendered with}"
: "${IMAGE_REPO_PREFIX:?IMAGE_REPO_PREFIX is not set - ghcr.io/<owner>/<repository>, lowercased}"
: "${IMAGE_TAG:?IMAGE_TAG is not set - the commit the images are published under}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# python3 on Linux and macOS, python on Windows, where python3 is a Microsoft
# Store stub that exits without running anything. The platform's tooling, not
# this Project's stack: nothing here asks the Project for a language.
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
# An empty env file, so a developer's own .env cannot change the answer.
: > "${SCRATCH}/empty.env"

docker compose --env-file "${SCRATCH}/empty.env" -f docker-compose.prod.yml \
  config --format json > "${SCRATCH}/prod.json" ||
  { echo "cannot run: docker-compose.prod.yml did not render (above)" >&2; exit 2; }
docker compose --env-file "${SCRATCH}/empty.env" --profile '*' -f docker-compose.yml \
  config --format json > "${SCRATCH}/local.json" ||
  { echo "cannot run: docker-compose.yml did not render (above)" >&2; exit 2; }

"$PY" - "${SCRATCH}/prod.json" "${SCRATCH}/local.json" "${IMAGE_REPO_PREFIX}" <<'LIST_IMAGES'
import json, os, sys

prod_path, local_path, prefix = sys.argv[1:4]
# The repository root, as this interpreter spells it. Compose renders paths
# the way the platform does - D:\... on Windows - and the shell's `pwd` may
# not, so the two are never compared.
root = os.getcwd()
prod = json.load(open(prod_path, encoding="utf-8")).get("services") or {}
local = json.load(open(local_path, encoding="utf-8")).get("services") or {}

images, problems = [], []
for service in sorted(prod):
    image = prod[service].get("image") or ""
    if not image.startswith(prefix + "-") and not image.startswith(prefix + ":"):
        print(f"note: {service} runs {image}, which is not published from "
              "this repository, so it is not built here", file=sys.stderr)
        continue
    build = (local.get(service) or {}).get("build")
    if not build:
        problems.append(
            f"{service} is published as {image}, and docker-compose.yml gives "
            f"it no build: key. Add a Service named {service} there, with "
            "build: { context: <directory>, dockerfile: <file> } - that key "
            "is the one place this repository says where its code is.")
        continue
    if "dockerfile_inline" in build:
        problems.append(
            f"{service} builds from dockerfile_inline in docker-compose.yml. "
            "Give it a Dockerfile: the contract's multi-stage-dockerfiles rule "
            "reads Dockerfiles, and an inline one is invisible to it.")
        continue
    context = os.path.relpath(build["context"], root).replace(os.sep, "/")
    if context.startswith(".."):
        problems.append(
            f"{service} builds from {build['context']}, outside this "
            "repository. CI checks out this repository and nothing else.")
        continue
    dockerfile = build.get("dockerfile") or "Dockerfile"
    if not os.path.isabs(dockerfile):
        dockerfile = os.path.normpath(os.path.join(context, dockerfile))
    dockerfile = os.path.relpath(dockerfile, root) if os.path.isabs(dockerfile) else dockerfile
    images.append({
        "service": service,
        "image": image,
        "context": context,
        "dockerfile": dockerfile.replace(os.sep, "/"),
    })

if not images and not problems:
    problems.append(
        "docker-compose.prod.yml names no image under " + prefix + ", so this "
        "repository publishes nothing and the deploy would pull nothing of "
        "its own. Name each Service's image " + prefix + "-<service>:${IMAGE_TAG:?}.")

for problem in problems:
    print("ERROR: " + problem, file=sys.stderr)
if problems:
    sys.exit(1)
print(json.dumps(images))
LIST_IMAGES
