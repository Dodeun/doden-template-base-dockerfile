# doden-template-base-dockerfile

The repository every **Project** of the `doden.dev` platform is copied from
(ADR-0015). Its Profile, `base-dockerfile`, names no language. The Template
keeps only what makes a Project one of the platform's: the shape the VPS
expects, a deployment that happens only on a pushed tag, the checks a pull
request must pass, and access to the Shared Platform Services. The rest is
the Project's choice: language, framework, how many Services, and where its
code lives.

**Prototypes are copied from it too**, and read it differently because their
Manifest says so: see [A Prototype](#a-prototype), below.

The rules it satisfies are in [`CONTRACT.md`](./CONTRACT.md), beside this
file, at the version this repository pins. [`AGENTS.md`](./AGENTS.md) is what
an agent working in a copy reads first. It says what a Project must keep,
whatever stack it chooses.

## Why the Template is public

`Dodeun/doden-template-base-dockerfile` is public, and a copy of it is not:
**a Project is private**, and this section does not apply to it.

The Template holds no secret and asks for none. Its workflows name the
secrets a copy will need (`VPS_*` for a Project, `LAB_*` for a Prototype) and
hold no value for any of them, and its Manifest is a placeholder. Its whole history
was read for keys, tokens, `.env` files and real hostnames before the switch
(ticket `35`, 2026-10-04).

Public is what lets the Prototypes' GitHub App (ADR-0012) generate a
repository from it **without being given any access to it**. A private
Template would have to be in that App's installation, and an App holds the
same permissions on every repository it is installed on: Administration
write, here, on the repository every Project is copied from (ADR-0004). The
reasoning is the one that made `doden-contract` public (ADR-0010).

---

## A template copies files, and nothing else

**This is the one thing to know before the first copy.** `gh repo create
--template` copies the files in this repository. It copies no ruleset, no
required status check, no repository secret and no repository setting of any
kind. A fresh copy looks finished and is completely unguarded. `project new`
in `Dodeun/doden-project-control` exists to close that gap, and tier 2 of the
contract is audited centrally to keep it closed.

## What a copy still needs

### 1. Fill in the Manifest's identity

`platform.json` ships as a placeholder that **fails the contract check on
purpose**:

```json
{ "slug": "FILL-ME-IN", "appName": "FILL ME IN", "appHost": "FILL-ME-IN.doden.dev" }
```

`slug` and `appHost` are **invalid**, not merely wrong: the schema gives both
patterns a placeholder cannot satisfy. So the contract check refuses an
uninitialised copy instead of letting it deploy under the Template's identity.
`appName` is a name a person reads, so the schema can only require that it is
not empty. `test.yml`'s `identity` job closes that gap. Until all three are
filled in, the contract check does not run, `build.yml` publishes nothing,
and that job prints what is still missing.

Set `addons` to what this Project has: `{}` if it has no database, with the
Add-on's files and regions removed (below). `project new` does both.

Then check it with the same command CI runs:

```sh
rm -rf ~/.doden-contract && git clone -q --depth 1 -b v3 https://github.com/Dodeun/doden-contract ~/.doden-contract
python3 ~/.doden-contract/check.py .
```

Both lines, every time: `v3` moves with every release, and a clone made once
drifts from the one CI uses (`CONTRACT.md`, "Running the check").

### 2. Repository settings, which did not travel

`project new` writes them. `docs/runbooks/new-project.md` in the platform
repository is the hand-run version.

| | |
| --- | --- |
| `protect-main` ruleset on `~DEFAULT_BRANCH` | pull request required, no force-push, no deletion, **empty bypass list** |
| required status checks | `test`, `contract / tier-1` **and** `selfcheck`, strict. These are the same three in every Project, whatever its stack. `selfcheck` is the only one that runs while the Manifest is still a placeholder. |
| `protect-releases` ruleset on `refs/tags/v*` | `update`, `deletion`, `non_fast_forward`. A tag is what deploys, and without `update` a release tag can still be moved forward onto any descendant commit. |
| secrets `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY` | for `deploy.yml` |
| repository variables | **none.** Configuration is the committed Manifest (ADR-0010). |

### 3. Host and account facts, which are outside the contract

A green tier-1 check says the files are in order, not that the Project is
deployable. `project new` provisions these, and the pre-flight in
`deploy/remote-deploy.sh` checks the database half:

- `~/apps/<slug>` on the VPS: a directory, **not** a clone (ADR-0011).
- A Doppler project `<slug>` with a `prd` config, and a read-only service
  token registered against that directory.
- With the database Add-on: a Postgres role that **owns** a database of the
  same name on the shared server, and `DATABASE_URL` in Doppler.

### 4. Replace the reference application

`app/` is an nginx answering `GET /api/health`, and `tests/health.sh` is its
test. They prove the contract's obligations hold for a fresh copy, and they
suggest no stack. Replace them with the Project, and keep what `AGENTS.md`
lists.

## The tree

| | |
| --- | --- |
| `platform.json` | The **Manifest**. Its identity is written once by `project new`. Its commands (`migrate` and `seed`, in the database Add-on) belong to the Project. |
| `AGENTS.md` | What an agent working in a copy must know: read the contract, where findings go, what to keep, and the `CLAUDE.md` import. The contract requires it. |
| `CONTRACT.md` | The rules, in prose, copied unedited from `doden-contract` at the pinned version. |
| `PLATFORM-FINDINGS.md` | What this Project learned that would be true of any Project. It ships empty, and the contract requires it to exist. |
| `docs/addons/database.md` | What declaring the database Add-on commits a Project to. Copied unedited from `doden-contract`, and deleted with the Add-on. |
| `docker-compose.prod.yml` | The production **Stack**, the file the contract judges. It names no Project: everything is interpolated from the Manifest and the release. |
| `docker-compose.yml` | The Project on a laptop. Each Service's `build:` key is the one place the repository says where its code is. |
| `docker-compose.test.yml` | The tests, as a Stack. The `test` Service's exit code is the verdict. |
| `app/`, `tests/` | The reference application and its test. They are there to be replaced. |
| `deploy/remote-deploy.sh` | Runs on the VPS. `deploy.yml` copies it in from the release right before running it. |
| `deploy/assert-release.sh` | Runs on the **runner** after the deploy, and asks the public URL which release it serves. |
| `.github/workflows/test.yml` | The tests, the declared commands, the production images built without publishing, and the call to the pinned tier-1 checker. |
| `.github/workflows/build.yml` | A Project: publishes SHA-tagged images on every merge, and publishing is not deploying. A Prototype: publishes and deploys to the lab on every push, with the tests beside. |
| `.github/workflows/deploy.yml` | Runs on a `v*` tag. An older tag is a rollback. |
| `deploy/lab-request.sh` | Runs on the **runner**, for a Prototype: the one document its deploy sends the control host. Its header is the format. |
| `.github/workflows/lab-redeploy.yml` | A Prototype: deploys the head of `main` again, **without a build**, when `prototype revive` asks with a `repository_dispatch`. A Project ignores it. |
| `deploy/lab-newest.sh` | Runs on the **runner**, for a Prototype: whether the commit is still the tip of `main`, so a late, older push does not deploy. |
| `deploy/lab-green.sh` | Runs on the **runner**, for a Prototype: whether a green deploy is news, a first deploy or green after red, read from the Actions history. |
| `scripts/mode.sh` | Reads the mode from the Manifest: `project` or `prototype`. |
| `scripts/modes-selfcheck.sh` | Proves both modes, and the deploy request, with no network. `profile.yml` runs it. |
| `.github/workflows/profile.yml` | This repository judging itself (below). |
| `scripts/images.sh` | Lists the images to build and publish, from the two Compose files. Both `build.yml` and `test.yml` use it. |
| `scripts/addon-commands.sh` | Runs the Manifest's `migrate` and `seed` against the test Stack, the way the platform runs them. |
| `scripts/check-shell.sh` | Runs `bash -n` on every `.sh` file and every `run:` block. Without Docker, it parses the `.sh` files and says it skipped the workflows; on a CI runner, no Docker fails. |
| `scripts/profile-selfcheck.sh` | What `profile.yml` runs. A human gets the same answer by running it. |
| `scripts/addons.json` | The files each Add-on brings. `profile-selfcheck.sh` and `project new` both read this one list. |

**The platform's own tooling uses Python 3, Docker and `jq`**, which every
GitHub runner has. That is the platform's tooling, not the Project's stack,
so a Project needs no `package.json` and no `requirements.txt` for it.

## Add-ons

There is one, `database`. Its document,
[`docs/addons/database.md`](./docs/addons/database.md), says what declaring
it commits a Project to. Its configuration carries the two commands the
platform runs: `migrate`, run by the deploy before a new release serves, and
`seed`, which writes synthetic data for a Preview. Each names the Service
whose image runs it, and runs as `sh -c '<command>'` (CONTRACT.md, "How the
commands are run"). In the reference application, both are connection
checks, `psql "$DATABASE_URL" -c 'select 1'`. They prove the network, the
credentials and the address, write nothing, and suggest no migration tool.

**Guarded at run time**, from `platform.json`: `deploy.yml` and
`deploy/remote-deploy.sh` (the Postgres pre-flight and the migration),
`scripts/addon-commands.sh`.

**Removed rather than guarded**: the regions marked `>>> addon:database`, in
the three Compose files and in `app/Dockerfile`. The production Compose file
forces it: the contract renders that file knowing only the Manifest and the
release, so "joined because the Manifest says so" cannot be interpolated. The
contract checks both directions, so the removal cannot be half-done
silently. The Add-on's whole files are listed in
[`scripts/addons.json`](./scripts/addons.json).

### Switching the database Add-on off

1. `platform.json`: `"addons": {}`.
2. Delete every `>>> addon:database … <<< addon:database` region.
   `git grep -l '>>> addon:database'` finds them.
3. Delete every path `scripts/addons.json` lists under `database`.
4. `bash scripts/profile-selfcheck.sh` says whether the Manifest and the
   Stack agree. It runs the contract checker and nothing else, so the `test`
   job is what says the application still builds and passes.

## A Prototype

A Prototype is a copy whose `platform.json` carries a `prototype` block, and
an `appHost` of `<slug>.lab.doden.dev` (CONTRACT.md, "A Prototype").
`prototype new` in `Dodeun/doden-project-control` makes one. The files are
the same; the workflows read the block and take another path.

| | A Project | A Prototype |
| --- | --- | --- |
| A push to `main` | arrives by a pull request; runs the tests, then publishes images | pushed directly; publishes images and deploys at once, tests beside |
| A red suite or contract check | blocks the merge | is posted to Discord, and blocks nothing |
| A green run | posts nothing | posts to Discord, with the link, at the first deploy and at the first green deploy after a red run; at no other |
| A deploy | on a `v*` tag, to production | on every push, to the lab |
| `/api/health` reports | the release tag | the commit |
| Rulesets, tier-2 audit | yes | no (decision 39) |
| Secrets | `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY` | `LAB_HOST`, `LAB_SSH_KEY`, `LAB_KNOWN_HOSTS`, `LAB_DISCORD_WEBHOOK`, all set by `prototype new` |

**The mode is read from the committed Manifest, never from a repository
setting** (ADR-0010), by `scripts/mode.sh`. A Manifest that cannot be read is
neither mode, and the run fails rather than guessing.

**A Prototype's deploy sends data, never a script.** Its key is pinned on the
control host to one forced command, "deploy this Prototype", and the
workflow pipes it one document on stdin: the Compose file and the Manifest,
the commit, and the job's read-only registry token. `deploy/lab-request.sh`
builds it, and its header is the format the host side is written against.
Production runs the release's own `deploy/remote-deploy.sh`; the lab runs the
platform's, so a push cannot change what the key is able to do.

**Green is posted only when it is news** (decision 60): the first deploy,
with the link and the access code, and the first green deploy after a red
run. `deploy/lab-green.sh` reads the earlier runs of `build.yml` from the
Actions API, so nothing is kept between runs.

**Two pushes close together.** One lab deploy runs at a time, and is never
cancelled halfway. A push joins the queue only while its commit is still the
tip of `main`, and asks again when its turn comes, so a late, older push does
not put older code back (`build.yml` says what race of seconds is left).

**A deleted Prototype comes back without a build.** `prototype delete`
archives the repository and leaves the images in GHCR; `prototype revive`
unarchives it and sends a `repository_dispatch` that
`.github/workflows/lab-redeploy.yml` answers with build.yml's deploy step
alone, for the head of `main` and nothing older (ticket 45).

**`deploy.yml` is unchanged, and a Prototype never reaches it.** A tag pushed
to a Prototype would start it, and it would fail at the copy: the repository
holds no production key. Production's deploy path is byte for byte what it
was before Prototypes existed.

## Why this repository judges itself

`profile.yml` runs `scripts/profile-selfcheck.sh`, which asserts four
things:

1. **The placeholder Manifest is refused**, for the Manifest and *nothing
   else*. A violation of any other rule here would be inherited by every
   Project copied from this Template. Once a copy has filled its Manifest in,
   the same run must come back green.
2. **The tree passes with the database Add-on declared**, using this
   repository's own Add-on configuration, commands included.
3. **And with it switched off**: the same tree, every marked region and every
   file in `scripts/addons.json` removed, the Manifest changed.
4. **And as a Prototype**: the same tree under a Manifest with a `prototype`
   block and a lab hostname.

Then `scripts/modes-selfcheck.sh` reads the mode from a Project's Manifest
and from a Prototype's, and builds a Prototype's deploy request and decodes
it back, as the host would.

`test.yml` skips the contract job while the Manifest is the placeholder,
because an uninitialised copy is *supposed* to be refused. This file keeps
that from being a hole.

## Running it

```sh
docker compose up --build                                  # http://localhost:8080/api/health

bash scripts/addon-commands.sh                             # the Manifest's migrate and seed, against a throwaway database
docker compose -f docker-compose.test.yml run --rm test    # the tests
docker compose -f docker-compose.test.yml down -v

bash scripts/check-shell.sh                                # bash -n over every .sh file and run: block
bash scripts/profile-selfcheck.sh                          # the contract checker, four ways
bash scripts/modes-selfcheck.sh                            # both modes, and a Prototype's deploy request
```

Those are the commands `test.yml` and `profile.yml` run.
