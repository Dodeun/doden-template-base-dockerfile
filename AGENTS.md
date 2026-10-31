# Instructions for an agent working in this repository

This repository is a Project of the `doden.dev` platform. The platform
deploys it, and judges it before it does.

## Read `CONTRACT.md` first

`CONTRACT.md` is the Platform Contract this Project is held to, at the
version `platform.json` names. It says what the repository must contain to be
deployable, and why each rule exists. CI runs the same check you can run
here:

```sh
rm -rf ~/.doden-contract && git clone -q --depth 1 -b v3 https://github.com/Dodeun/doden-contract ~/.doden-contract
python3 ~/.doden-contract/check.py .
```

Both lines, every time. `v3` moves with every release, and a clone made once
drifts from the one CI uses: it refuses what CI accepts, or accepts what CI
refuses. The check judges the files git tracks and the ones it would add, so
a run before a commit judges what that commit makes.

If you declare the database Add-on, `docs/addons/database.md` says what that
commits you to.

## Write what you learn about the contract to `PLATFORM-FINDINGS.md`

If something you learn here would be true of any Project held to this
contract, write it in `PLATFORM-FINDINGS.md`: a rule that refused something it
should have allowed, a message that sent you the wrong way, or a step nothing
told you about. Something true only of this Project's code does not go there.
`CONTRACT.md`, "What deserves a finding", has the test.

## Write the repository in English

Code, comments, the README, and commit messages, which also title the runs
on GitHub's Actions tab, are in English, unless the request asks for another
language. The slug is English too. The application's interface is in the
language the request asks for: a French request gets a French site, written
by English code. `git log` reads "Add the booking form", and the page reads
"Réserver".

`README.md` says what this application is, its link, and how to run its
tests, and you keep it true. When `TEMPLATE.md` is beside it, that file is
the Template's own README, kept for reference.

## Cut the work into Vertical Slices

A slice crosses every layer the work needs, its migration, its routes and its
screens, and leaves the application working when it is committed. A ski
rental shop that adds snowboards gets one slice, renting snowboards, and not
a backend ticket followed by a frontend ticket: neither half could ship
without the other. An application built from nothing grows the same way,
skis first, then snowboards, rather than all of its backend and then all of
its frontend. The API contract between the Services, when there are several,
comes before the first slice.

## A reminder that needs no thought belongs to the application

A job that runs at a set time and needs no judgement, a reminder sent at 8,
a nightly cleanup, a weekly digest, is a scheduled job of the application's
own backend, not a coding agent's scheduled task. It costs nothing to run,
and it runs while the agent cannot. An agent's task is for work that needs a
model.

A Service that schedules anything has `TZ: Europe/Paris` under
`environment:` in the three Compose files, so "every day at 8" is 8 in
Paris, summer time included. A time nobody waits for may stay in UTC.

## The application's API key comes from `APP_API_KEY`

If the application has an API that another program calls with a key, a
scheduled task for instance, it reads that key from the environment variable
`APP_API_KEY`. Nothing in the application
makes, shows or changes a key: no "new key" button, no key in the database.
The platform issues it and replaces it (`prototype key` for a Prototype),
and the Service `app` already names it under `environment:` in the Compose
files. Another Service that checks the key names it the same way. So the same
code runs in the lab and in production.

## The application is there to be replaced

`app/` is a reference application: an nginx answering `GET /api/health`. It
proves the contract's obligations hold once the Project is created. It is
not a suggestion of a stack. This Project's stack is yours to choose:
language, framework, how many Services, and where the code lives.

**Replace its code, and keep the name `app`** for the Service Traefik routes
to, the one a visitor reaches. A second Service takes a name of its own:
`app` and `backend`, not `frontend` and `backend`. The first push of a
Prototype publishes an image named after `app`, and renaming the Service
would leave that image in the registry with nothing to run it.

What the platform needs, whatever you choose:

- **`docker-compose.prod.yml`** names every Service the Stack runs. Each
  image is `${IMAGE_REPO_PREFIX}-<service>:${IMAGE_TAG:?}`. The contract
  judges this file.
- **A Service Traefik does not route to stays off `web`.** A backend that
  only the frontend calls joins a network of the Stack's own, shared with
  the frontend, and `data` if it reads the database. The frontend calls it by
  its Service's name, `http://backend:3000`. `CONTRACT.md`, rule `networks`,
  shows the shape. On `web`, a name answers for every Project on it.
  - Leave that network without a `name:`, and not external. Add no aliases
    either. The contract and the lab refuse all three.
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

## If `platform.json` has a `prototype` block, this is a Prototype

`CONTRACT.md`, "A Prototype", says what that means. What changes for you:

- **Every push to `main` deploys**, at once, to `<slug>.lab.doden.dev`. The
  tests and the contract check run beside the deploy, not before it, and a red
  one is posted to Discord rather than blocking anything. The platform asks
  for one push at the end of a task, not one after every commit: each push
  is a deploy, and costs Actions minutes.
- **There are no pull requests and no release tags.** You push straight to
  `main`. Do not push a tag: `deploy.yml` would try production, and fail
  for want of a key this repository does not hold.
- **`/api/health` reports the commit**, the full SHA, in place of a release
  tag. The deploy checks it.
- **The block is not yours to remove.** Removing it is a promotion, which is
  the operator's decision. Its settings, `expires` and `accessCode`, change by
  a commit like any other file.

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
