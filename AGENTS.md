# Instructions for an agent working in this repository

This repository is a Project of the `doden.dev` platform. The platform
deploys it, and judges it before it does.

## Read `CONTRACT.md` first

`CONTRACT.md` is the Platform Contract this Project is held to, at the
version `platform.json` names. It says what the repository must contain to be
deployable, and why each rule exists. CI runs the same check you can run
here:

```sh
git clone --depth 1 -b v3 https://github.com/Dodeun/doden-contract ~/.doden-contract   # once
python3 ~/.doden-contract/check.py .
```

If you declare the database Add-on, `docs/addons/database.md` says what that
commits you to.

## Write what you learn about the contract to `PLATFORM-FINDINGS.md`

If something you learn here would be true of any Project held to this
contract, write it in `PLATFORM-FINDINGS.md`: a rule that refused something it
should have allowed, a message that sent you the wrong way, or a step nothing
told you about. Something true only of this Project's code does not go there.
`CONTRACT.md`, "What deserves a finding", has the test.

## The application is there to be replaced

`app/` is a reference application: an nginx answering `GET /api/health`. It
proves the contract's obligations hold once the Project is created. It is
not a suggestion of a stack. This Project's stack is yours to choose:
language, framework, how many Services, and where the code lives.

What the platform needs, whatever you choose:

- **`docker-compose.prod.yml`** names every Service the Stack runs. Each
  image is `${IMAGE_REPO_PREFIX}-<service>:${IMAGE_TAG:?}`. The contract
  judges this file.
- **`docker-compose.yml`** gives each of those Services a `build:` key, with
  its `context:` and `dockerfile:`. That key is the only place the repository
  says where a Service's code is.
  - CI builds each Dockerfile's **last stage**. Any `target:` you write here
    is for your machine only.
  - Every image is built with one fixed list of build arguments, whatever
    `args:` says. Today the list is `APP_HOST`, the `appHost` of
    `platform.json`.
- **Every Dockerfile has at least two stages**: build in one, run in the
  next.
- **`GET /api/health`** answers `{"status":"ok","release":"<RELEASE>"}`.
  `RELEASE` is the environment variable `docker-compose.prod.yml` sets to the
  release tag. After every deploy, the platform reads this address and fails
  the deploy if the release is not the tag it shipped.
- **`docker-compose.test.yml`** has a `test` Service whose exit code is the
  verdict. CI runs `docker compose -f docker-compose.test.yml run --rm test`.
  Replace what it runs with this Project's own tests, in any language.

## `platform.json` has two halves, and only one of them is yours

- **Never edit the identity**: `slug`, `appName`, `appHost`, `profile`,
  `contractVersion`. They were written when the Project was created, and
  everything outside the repository is named after them.
- **The commands are yours**: `migrate` and `seed`, inside
  `addons.database`.
  - Each one names the Service whose image runs it.
  - Each one runs as `sh -c '<command>'`, in place of the image's
    entrypoint, with `DATABASE_URL` set. So the image needs `sh`.
  - The deploy runs `migrate` before a new release serves. `seed` writes
    synthetic data, never a copy of production.
  - When you change how the schema is migrated, change the command in the
    same pull request.
  - CI runs both against a throwaway database on every pull request.

## If you create a `CLAUDE.md`

Start it with this line, on its own:

```
@AGENTS.md
```

Claude Code reads a `CLAUDE.md` instead of this file unless the `CLAUDE.md`
imports it, and the contract check fails a `CLAUDE.md` without the import.
An import resolves from the file that writes it, so a `.claude/CLAUDE.md`
starts with `@../AGENTS.md` instead.

A `CLAUDE.local.md` silences this file in the same way, for whoever has one.
It is never committed, so no check can see it. If you keep one, put the same
line at its top.
