# doden-template-base-dockerfile

The repository every **Project** of the `doden.dev` platform is copied from
(ADR-0015). Its Profile, `base-dockerfile`, names no language. The Template
keeps only what makes a Project one of the platform's: the shape the VPS
expects, a deployment that happens only on a pushed tag, the checks a pull
request must pass, and access to the Shared Platform Services. The rest is
the Project's choice: language, framework, how many Services, and where its
code lives.

The rules it satisfies are in [`CONTRACT.md`](./CONTRACT.md), beside this
file, at the version this repository pins. [`AGENTS.md`](./AGENTS.md) is what
an agent working in a copy reads first. It says what a Project must keep,
whatever stack it chooses.

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
git clone --depth 1 -b v3 https://github.com/Dodeun/doden-contract ~/.doden-contract   # once
python3 ~/.doden-contract/check.py .
```

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
| `.github/workflows/build.yml` | Publishes SHA-tagged images on every merge. Publishing is not deploying. |
| `.github/workflows/deploy.yml` | Runs on a `v*` tag. An older tag is a rollback. |
| `.github/workflows/profile.yml` | This repository judging itself (below). |
| `scripts/images.sh` | Lists the images to build and publish, from the two Compose files. Both `build.yml` and `test.yml` use it. |
| `scripts/addon-commands.sh` | Runs the Manifest's `migrate` and `seed` against the test Stack, the way the platform runs them. |
| `scripts/check-shell.sh` | Runs `bash -n` on every `.sh` file and every `run:` block. |
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

## Why this repository judges itself

`profile.yml` runs `scripts/profile-selfcheck.sh`, which asserts three
things:

1. **The placeholder Manifest is refused**, for the Manifest and *nothing
   else*. A violation of any other rule here would be inherited by every
   Project copied from this Template. Once a copy has filled its Manifest in,
   the same run must come back green.
2. **The tree passes with the database Add-on declared**, using this
   repository's own Add-on configuration, commands included.
3. **And with it switched off**: the same tree, every marked region and every
   file in `scripts/addons.json` removed, the Manifest changed.

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
bash scripts/profile-selfcheck.sh                          # the contract checker, three ways
```

Those are the commands `test.yml` and `profile.yml` run.
