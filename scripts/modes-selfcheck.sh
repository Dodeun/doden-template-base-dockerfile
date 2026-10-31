#!/usr/bin/env bash
# Proves what the workflows decide by script rather than by YAML,
# in both modes, with no network and no credential. profile.yml runs it on
# every push and pull request, beside profile-selfcheck.sh.
#
#   1. **scripts/mode.sh** reads the mode from the committed Manifest: a
#      Manifest with a `prototype` block is a Prototype, one without is a
#      Project, and one that cannot be read is neither - it fails, so a broken
#      Manifest never falls through into one path or the other.
#
#   2. **deploy/lab-request.sh** builds what a Prototype's deploy sends the
#      control host. It is decoded back here, the way the host decodes it:
#      every file byte for byte, every hash the hash of those bytes, and the
#      registry token in the one place it belongs. Its refusals are run too:
#      a check that has only ever passed has not been tested.
#
#   3. **deploy/lab-newest.sh** says whether a push is still the newest.
#
#   4. **deploy/lab-green.sh** says whether a green push is news: a first
#      deploy, or green after red (decision 60). Against a stand-in for the
#      Actions API, from histories written here.
#
# What it does not do is deploy. The host side is in Dodeun/doden-control-host
# (ticket 42), and a Prototype's first real deploy is ticket 46's.
#
# Usage: bash scripts/modes-selfcheck.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

for tool in jq sha256sum base64; do
  command -v "$tool" >/dev/null || { echo "cannot run: $tool is not installed" >&2; exit 2; }
done

failures=0
fail() {
  echo "   FAIL: $*" >&2
  failures=$((failures + 1))
}

# A tree holding only what the two scripts read, under a Manifest given here.
tree() {
  local dir="${SCRATCH}/$1"
  mkdir -p "${dir}/scripts" "${dir}/deploy"
  cp "${ROOT}/scripts/mode.sh" "${dir}/scripts/"
  cp "${ROOT}/deploy/lab-request.sh" "${dir}/deploy/"
  cp "${ROOT}/docker-compose.prod.yml" "${dir}/"
  printf '%s\n' "$2" > "${dir}/platform.json"
  echo "${dir}"
}

PROJECT='{"slug": "modes-selfcheck", "appHost": "modes-selfcheck.example.test", "addons": {}}'
PROTOTYPE='{"slug": "modes-selfcheck", "appHost": "modes-selfcheck.lab.doden.dev", "addons": {}, "prototype": {"expires": "2026-11-15", "accessCode": "K7M2Q"}}'

# -- 1. the mode ------------------------------------------------------------
echo "1. scripts/mode.sh"
for case in "project:${PROJECT}" "prototype:${PROTOTYPE}"; do
  expected="${case%%:*}"
  dir="$(tree "mode-${expected}" "${case#*:}")"
  if ! found="$(cd "${dir}" && bash scripts/mode.sh)"; then
    fail "a ${expected} Manifest made mode.sh fail"
  elif [ "${found}" != "${expected}" ]; then
    fail "a ${expected} Manifest read as '${found}'"
  else
    echo "   a ${expected} Manifest reads as ${found}"
  fi
done

for case in "not-json:{ this is not json" "missing:"; do
  name="${case%%:*}"
  dir="$(tree "mode-${name}" "${case#*:}")"
  [ "${name}" = "missing" ] && rm "${dir}/platform.json"
  if found="$(cd "${dir}" && bash scripts/mode.sh 2>/dev/null)"; then
    fail "a Manifest that is ${name} read as '${found}' instead of failing"
  else
    echo "   a Manifest that is ${name} fails, and reads as neither"
  fi
done
echo

# -- 2. the request a Prototype's deploy sends ------------------------------
echo "2. deploy/lab-request.sh"
dir="$(tree request "${PROTOTYPE}")"
SHA="0123456789abcdef0123456789abcdef01234567"
request_env=(
  PROJECT_SLUG=modes-selfcheck
  IMAGE_TAG="${SHA}"
  IMAGE_REPO_PREFIX=ghcr.io/owner/modes-selfcheck
  GHCR_USERNAME=someone
  GHCR_TOKEN=token-for-the-selfcheck
)
if ! (cd "${dir}" && env "${request_env[@]}" bash deploy/lab-request.sh) > "${SCRATCH}/request.json"; then
  fail "it refused a well-formed Prototype"
else
  request="${SCRATCH}/request.json"
  [ "$(jq -r '.request' "${request}")" = "deploy" ] || fail "the request does not say it is a deploy"
  [ "$(jq -r '.version' "${request}")" = "1" ] || fail "the request does not carry version 1"
  [ "$(jq -r '.slug' "${request}")" = "modes-selfcheck" ] || fail "the request names the wrong slug"
  [ "$(jq -r '.commit' "${request}")" = "${SHA}" ] || fail "the request names the wrong commit"
  [ "$(jq -r '.imageRepoPrefix' "${request}")" = "ghcr.io/owner/modes-selfcheck" ] || fail "the request names the wrong registry path"
  [ "$(jq -r '.registry.username' "${request}")" = "someone" ] || fail "the request names the wrong registry user"
  [ "$(jq -r '.registry.token' "${request}")" = "token-for-the-selfcheck" ] || fail "the request carries the wrong token"
  # The token belongs in one place. Anywhere else - a file, a log line - it
  # would travel further than the pull it exists for.
  [ "$(grep -o token-for-the-selfcheck "${request}" | wc -l)" -eq 1 ] || fail "the token appears more than once in the request"

  files="$(jq -r '.files | keys | join(" ")' "${request}")"
  [ "${files}" = "docker-compose.prod.yml platform.json" ] || fail "the request carries '${files}', not the Compose file and the Manifest alone"
  for file in docker-compose.prod.yml platform.json; do
    # `tr`, because jq on Windows ends its output with a carriage return,
    # which base64 refuses. On Linux it removes nothing.
    jq -r --arg f "${file}" '.files[$f].base64' "${request}" | tr -d '\r' | base64 -d > "${SCRATCH}/decoded"
    cmp -s "${SCRATCH}/decoded" "${dir}/${file}" || fail "${file} does not decode to the bytes it was built from"
    expected="$(sha256sum "${dir}/${file}" | cut -d' ' -f1)"
    [ "$(jq -r --arg f "${file}" '.files[$f].sha256' "${request}")" = "${expected}" ] || fail "${file}'s hash is not the hash of its bytes"
  done
  echo "   a Prototype's request decodes back to its Compose file and its Manifest"
fi

# Each refusal is matched to its own message, so a case cannot pass because
# some other check happened to refuse first.
refuse() {
  local why="$1" says="$2"; shift 2
  if (cd "${dir}" && env "${request_env[@]}" "$@" bash deploy/lab-request.sh) > /dev/null 2> "${SCRATCH}/refusal"; then
    fail "it built a request ${why}"
  elif ! grep -q -- "${says}" "${SCRATCH}/refusal"; then
    fail "it refused ${why}, but not for that reason: $(cat "${SCRATCH}/refusal")"
  else
    echo "   it refuses ${why}"
  fi
}
refuse "for a commit that is not hexadecimal" "not a commit" IMAGE_TAG=v1.0.0
refuse "for a commit that is a short SHA" "not a full 40-character" IMAGE_TAG=0123456
refuse "for a slug that is not the Manifest's" "carry the Manifest of another" PROJECT_SLUG=another-prototype
refuse "with no registry token" "GHCR_TOKEN is not set" GHCR_TOKEN=
rm "${dir}/docker-compose.prod.yml"
refuse "with no production Compose file" "docker-compose.prod.yml is missing"
dir="$(tree request-project "${PROJECT}")"
refuse "for a Project, which never deploys to the lab" "never deploys to the lab"
echo

# -- 3. which push is the newest --------------------------------------------
# Against a real remote - a bare repository on disk - because the question is
# asked of `git ls-remote`, and a stub would only be asked of itself.
echo "3. deploy/lab-newest.sh"
remote="${SCRATCH}/remote.git"
work="${SCRATCH}/work"
git init -q --bare "${remote}"
git init -q "${work}"
git -C "${work}" -c user.name=selfcheck -c user.email=selfcheck@example.test \
  commit -q --allow-empty -m older
older="$(git -C "${work}" rev-parse HEAD)"
git -C "${work}" -c user.name=selfcheck -c user.email=selfcheck@example.test \
  commit -q --allow-empty -m newer
newer="$(git -C "${work}" rev-parse HEAD)"
git -C "${work}" remote add origin "${remote}"
git -C "${work}" push -q origin HEAD:refs/heads/main
mkdir -p "${work}/deploy"
cp "${ROOT}/deploy/lab-newest.sh" "${work}/deploy/"

newest() {
  (cd "${work}" && GITHUB_SHA="$1" DEFAULT_BRANCH="$2" bash deploy/lab-newest.sh 2>/dev/null)
}
[ "$(newest "${newer}" main)" = "true" ] && echo "   the tip of main deploys" || fail "the tip of main did not read as the newest"
[ "$(newest "${older}" main)" = "false" ] && echo "   an older push steps aside" || fail "an older push did not step aside"
if newest "${newer}" no-such-branch > /dev/null; then
  fail "a tip it could not read answered instead of failing"
else
  echo "   a tip it cannot read fails, and does not read as an older push"
fi
echo

# -- 4. whether a green push is news ----------------------------------------
# Against a stand-in for `gh api`, which answers from files in the shapes the
# Actions API returns: a real history would need a repository with runs, and
# a token. Each case is a history, newest first, then the answer it must give.
echo "4. deploy/lab-green.sh"
green_dir="${SCRATCH}/green"
mkdir -p "${green_dir}/bin" "${green_dir}/deploy"
cp "${ROOT}/deploy/lab-green.sh" "${green_dir}/deploy/"
cat > "${green_dir}/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# `gh api <path>`: the file named after the path, or a failure, as gh fails.
[ "$1" = api ] || { echo "the stand-in answers gh api only" >&2; exit 2; }
file="${FAKE_GH_DIR}/$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_').json"
[ -f "${file}" ] || { echo "HTTP 404: Not Found ($2)" >&2; exit 1; }
cat "${file}"
FAKE_GH
chmod +x "${green_dir}/bin/gh"

# history <case> <run number asking> <run>... where a run is
# <number>:<conclusion>:<the link check's conclusion, or "none" for no deploy job>
history() {
  local case_dir="${green_dir}/$1" asking="$2" spec number conclusion step runs="[]"
  shift 2
  rm -rf "${case_dir}" && mkdir -p "${case_dir}"
  api_file() { printf '%s/%s.json' "${case_dir}" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }
  jq -n --argjson n "${asking}" '{id: 9000, workflow_id: 77, run_number: $n, head_branch: "main"}' \
    > "$(api_file "repos/owner/proto/actions/runs/9000")"
  for spec in "$@"; do
    IFS=: read -r number conclusion step <<<"${spec}"
    runs="$(jq -c --argjson n "${number}" --arg c "${conclusion}" \
      '. + [{id: (1000 + $n), run_number: $n, conclusion: $c}]' <<<"${runs}")"
    if [ "${step}" = none ]; then
      jq -n '{jobs: [{name: "Read the mode from the Manifest", steps: [{name: "Project or Prototype?", conclusion: "success"}]}]}'
    else
      jq -n --arg s "${step}" '{jobs: [{name: "Deploy to the lab", steps: [
        {name: "Still the newest push, now that it is our turn?", conclusion: "success"},
        {name: "Assert the commit is answering on the public URL", conclusion: $s}]}]}'
    fi > "$(api_file "repos/owner/proto/actions/runs/$((1000 + number))/jobs?per_page=100")"
  done
  jq -n --argjson r "${runs}" '{total_count: ($r | length), workflow_runs: $r}' \
    > "$(api_file "repos/owner/proto/actions/workflows/77/runs?branch=main&status=completed&per_page=100")"
}

green() {
  (cd "${green_dir}" && PATH="${green_dir}/bin:${PATH}" FAKE_GH_DIR="${green_dir}/$1" \
    GH_TOKEN=token REPOSITORY=owner/proto RUN_ID=9000 bash deploy/lab-green.sh 2>/dev/null) | tr -d '\r'
}

says() {
  local case="$1" expected="$2" why="$3" found
  if ! found="$(green "${case}")"; then
    fail "${why}: it failed instead of answering ${expected}"
  elif [ "${found}" != "${expected}" ]; then
    fail "${why}: it answered '${found}', not ${expected}"
  else
    echo "   ${why}: ${found}"
  fi
}

history creation 2 1:success:none
says creation first "the push of prototype new, after the Template's own run"
history again 5 4:success:success 3:failure:success
says again none "a green push after a green deploy"
history recovered 5 4:failure:success 3:success:success
says recovered after-red "a green push after a red one that deployed"
history stepped 6 5:success:skipped 4:failure:none 3:success:success
says stepped after-red "a red build, then a push that stepped aside"
history cancelled 5 4:cancelled:none 3:success:success
says cancelled none "a cancelled run, passed over"
history newer 5 7:failure:success 4:success:success
says newer none "a newer run, not history yet"
history never 4 3:failure:failure 2:failure:none 1:success:none
says never first "a first deploy after two red tries"

full=()
for n in $(seq 1 100); do full+=("${n}:success:none"); done
history full 101 "${full[@]}"
says full none "a full page with no deploy on it, which may hide one"

history unreadable 5 4:success:success
rm "${green_dir}/unreadable/repos_owner_proto_actions_runs_1004_jobs_per_page_100.json"
if green unreadable > /dev/null; then
  fail "jobs it could not read gave an answer instead of failing"
else
  echo "   jobs it cannot read fail, and nothing is posted"
fi
echo

if [ "${failures}" -gt 0 ]; then
  echo "${failures} check(s) failed." >&2
  exit 1
fi
echo "Both modes hold."
