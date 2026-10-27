# The CI runner

CI (`.github/workflows/ci.yml`) runs on a self-hosted GitHub Actions runner on
the house's CI box, named and labelled only `{{PROJECT}}-ci` — not on GitHub's
hosted runners. A deploy, if this project has one, keeps its own runner on the
prod box. **Nothing runs on GitHub's cloud runners — not even the PII scan.**

**Why, first:** the owner's rule (2026-10-24): the house has its own compute so
that its code and data are never checked on someone else's machine. **And:**
GitHub's hosted runners have two cores and a cold cache, so a run
takes minutes, and a timing test once failed that was really measuring the
runner (homecast, 2026-10-09). The CI box has the cores, keeps the build
cache, and is the same kind of Linux box that serves the house.

## The rules it keeps

- **It never deploys.** It is registered with `--no-default-labels` and the
  one label `{{PROJECT}}-ci`, so it never carries `self-hosted`: a deploy job
  with `runs-on: self-hosted` can then never be handed to it. A deploy job
  also refuses, first thing, any runner but prod's (the deploy guard, below).
- **Private repo only.** A self-hosted runner runs whatever a workflow says,
  and a fork's pull request writes its own workflow. A public repo never has a
  workflow that can reach a house runner; it is checked privately before it
  is published, so it needs none.
- **It is off when the box is off.** Jobs queue until it is back (GitHub drops
  a job after 24 hours queued; push again). There is no cloud fallback.
- **The logs still go to GitHub.** A self-hosted runner keeps the work on the
  house's box, but each step's output is uploaded to the run's log. Steps never
  print a key, an address or data — the same rule as tracked files.
- **What the box needs on the runner's PATH:** docker (the runner's user able
  to reach the daemon), git 2.40+, curl, python3, node 22, and bwrap 0.10+ (for
  `scripts/sandbox.sh`). The checks' linters run as Docker images pinned in
  `scripts/check-tools.env`, so they need docker, not an install of their own.
  Jobs get the PATH of the systemd user manager
  (`systemctl --user show-environment`), not your shell's;
  `add-runner.sh ci` warns about any of these it cannot find there. To add a
  folder, put a full `PATH=` line in the runner's own `.env` (in its folder)
  and restart the service.

## Adding the runner

One runner per repo (a personal account cannot share one across repos). The
kit lives in the template, never in a project. On the CI box, as the user the
runner runs as, in a terminal:

    ~/Projects/_template/runners/add-runner.sh ci {{PROJECT}}

It asks for a **registration token**: the repo on GitHub → Settings → Actions
→ Runners → New self-hosted runner, the value after `--token`. The token is
single-use and lasts an hour, and the owner gets it — a session's token
cannot. It is typed at the prompt, never passed as an argument, so it stays
out of `ps` and shell history.

The script then:

1. Downloads the runner version pinned at its top into
   `~/actions-runner/{{PROJECT}}-ci` and checks its sha256. A registered
   runner updates itself, so the pin only decides the first download.
2. Registers it as `{{PROJECT}}-ci`, with only the label `{{PROJECT}}-ci`.
3. Writes `~/.config/systemd/user/{{PROJECT}}-ci-runner.service`, enables
   and starts it, turns on linger so it runs with nobody logged in, and waits
   for it to stay up.

It refuses rather than overwrites: a runner already registered in that
folder, or a different unit file of the same name. A failed registration can
be re-run; the download is not repeated. Run without a terminal, it does the
download and stops at the prompt.

**Check it:** Settings → Actions → Runners lists `{{PROJECT}}-ci` Idle, with
the label `{{PROJECT}}-ci` only. A push to `dev` runs CI on it.

**Its name** is `{{PROJECT}}-ci`, the same as its label, with no box name in
it. GitHub shows a runner's name in every job log, and a name that ends up
quoted in a doc or a guard would put the box's name in a tracked file.
Runners registered before this kit carry the box's name; they keep working,
and keep it until they are re-registered.

## Removing a runner

Get a removal token: Settings → Actions → Runners → `{{PROJECT}}-ci` →
Remove (it lasts an hour). Then, on the CI box:

    systemctl --user disable --now {{PROJECT}}-ci-runner
    ~/actions-runner/{{PROJECT}}-ci/config.sh remove    # asks for the removal token
    rm ~/.config/systemd/user/{{PROJECT}}-ci-runner.service && systemctl --user daemon-reload

`rm -rf ~/actions-runner/{{PROJECT}}-ci` afterwards if it is not coming back.
If the folder is already gone, force-remove the runner on that GitHub page
instead.

## The deploy guard

A deploy job runs on prod's runner, and its first step refuses every other
runner. It is the same line in every repo:

```yaml
      - name: Only prod's runner deploys
        run: |
          case "$GITHUB_WORKSPACE/" in "/opt/actions-runners/${GITHUB_REPOSITORY#*/}/"*) ;; *) echo "::error::deploy runs only on prod's runner, not on $RUNNER_NAME"; exit 1;; esac
```

**Why the folder, not the runner's name:** prod's runner lives in
`/opt/actions-runners/{{PROJECT}}/`, so every job it runs has its workspace
under that folder. Making anything in `/opt` needs root, and CI runners live
in their user's home, so a CI runner's workspace never matches. A check on
`$RUNNER_NAME` would have to spell out prod's runner's name, and prod's
runners can be named after their host, which must never be in a tracked
file. The folder check names no host, and the repo part
(`${GITHUB_REPOSITORY#*/}`) plus the trailing `/` stop one repo's runner from
passing another's guard (`x` against `xy`).

It fails closed: if prod's runner is ever somewhere else, the deploy refuses
and nothing runs, and the first deploy proves the layout.

**A deploy started by `workflow_run`** (deploy when CI on `main` went green)
is what zizmor calls `dangerous-triggers`, an error, because on a public repo
a fork's run can start it. Here every repo is private and the guard pins the
job to prod's runner, so mark it reviewed, with the reason, on the line
above the trigger; `scripts/check.sh` fails on it until then:

```yaml
on:
  # zizmor: ignore[dangerous-triggers] private repo; runs only after ci on main, on the sha ci passed, on prod's runner (the guard)
  workflow_run:
```

The labels already keep a deploy off the CI box; the guard is the second
lock, because a deploy that syncs with `rsync --delete` into
`~/Projects/{{PROJECT}}` would wipe the working checkout there.

## Leaving the box as you found it

A house runner keeps its workspace and tool cache between runs, unlike a cloud
one, so a step has to clean up after itself:

- **Containers run as you.** `docker run -v "$PWD:/io" <image>` with no
  `--user` writes root-owned files (a `.ruff_cache`, build output) that the next
  checkout cannot delete: pass `--user "$(id -u):$(id -g)"` (recess, 2026-10).
- **A fresh venv per run** (`python -m venv .venv` in the checkout), never
  `pip install` into setup-python's interpreter, which outlives the run.
- **Service containers take a free port** (`ports: ["5432"]` plus
  `job.services.<name>.ports`), since the box runs the house's own databases;
  it is reachable from the LAN for the length of the job, so it holds
  throwaway test data and a CI-only password, nothing else.
- **A test stack takes a project name and ports of its own**, set by CI, so a
  run never shares a stack with someone running the same tier by hand, nor
  `docker compose down -v` theirs (hallpass e9c9f80).

## Outside code, and the runner's user

The runner runs as the CI box's login user, which is in the `docker`, `lxd`
and `sudo` groups. That is effectively root: a test that runs
`docker run -v /:/host` can read every repo's token, `~/.ssh` and the publish
blocklist, and change other runners. That is acceptable only while every
line the runner executes was written in the house.

- **A repo that takes outside pull requests** (one with a public mirror,
  `docs/publishing.md`) runs every CI step that executes repo code through
  `scripts/sandbox.sh`: no network, an empty `$HOME`, `/run` and `/tmp`, no
  docker or lxd socket, no environment tokens, and a throwaway copy of the
  checkout, so nothing the code writes there outlives the call. A session
  never runs code from an imported PR outside it, either. The box needs
  bwrap 0.10 or later for the throwaway copy.
- **Before the first outside PR is taken in,** the runners move to a
  dedicated unprivileged user in none of those groups (rootless podman for
  containers). That takes the owner's sudo once; `add-runner.sh` is then
  run as that user.

## A release does not test twice

A push to `main` of a commit CI already passed (a release fast-forwards `main`
to a tested `dev` commit) skips the checks: `ci.yml`'s first job, `seen`,
asks the Actions API for a green CI run of that exact commit, and if there is
one the other jobs are skipped and the run still ends green — what a deploy
triggered by CI waits for. Anything else runs everything: a push to any other
branch, a PR, a commit not yet green (a merge or squash on `main` makes one),
or the API not answering. `scripts/release.sh` releases by that fast-forward,
so the skip applies; a merge button never does.
