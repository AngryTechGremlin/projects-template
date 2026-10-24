# The CI runner

CI (`.github/workflows/ci.yml`) runs on a self-hosted GitHub Actions runner on
the house's CI box, labelled only `{{PROJECT}}-ci` — not on GitHub's hosted
runners. A deploy, if this project has one, keeps its own runner on the prod
box. **Nothing runs on GitHub's cloud runners — not even the PII scan.**

**Why, first:** the owner's rule (2026-10-24): the house has its own compute so
that its code and data are never checked on someone else's machine. **And:**
GitHub's hosted runners have two cores and a cold cache, so a run
takes minutes, and a timing test once failed that was really measuring the
runner (homecast, 2026-10-09). The CI box has the cores, keeps the build
cache, and is the same kind of Linux box that serves the house.

## The rules it keeps

- **It never deploys.** Register it with `--no-default-labels` and the one
  label `{{PROJECT}}-ci`, so it never carries `self-hosted`: a deploy job
  with `runs-on: self-hosted` can then never be handed to it. A deploy job
  must also refuse any runner but prod's, first thing:

      - name: Only prod's runner deploys
        run: |
          [ "$RUNNER_NAME" = "<prod runner's name>" ] \
            || { echo "::error::deploy runs only on prod's runner, not on $RUNNER_NAME"; exit 1; }

  A deploy that syncs with `rsync --delete` into `~/Projects/{{PROJECT}}`
  would otherwise wipe the working checkout on the CI box.
- **Private repo only.** A self-hosted runner runs whatever a workflow says,
  and a fork's pull request writes its own workflow. A public repo never has a
  workflow that can reach a house runner; it is checked privately before it
  is published, so it needs none.
- **It is off when the box is off.** Jobs queue until it is back (GitHub drops
  a job after 24 hours queued; push again). There is no cloud fallback.
- **The logs still go to GitHub.** A self-hosted runner keeps the work on the
  house's box, but each step's output is uploaded to the run's log. Steps never
  print a key, an address or data — the same rule as tracked files.
- **What the box needs on the runner's PATH:** docker (the runner's user in
  the `docker` group), git, curl, python3, node 22, shellcheck. A systemd user
  service does not read `~/.local/bin` from your shell: put a `PATH=` line in
  the runner's own `.env` (in its folder) if a tool lives there.

## Setting it up on the CI box

One runner per repo (a personal account cannot share one across repos).

1. Download and unpack the runner (pin the version, check its sha256 against
   the release notes) into `~/actions-runner/{{PROJECT}}-ci`.
2. Get a registration token: the repo on GitHub → Settings → Actions →
   Runners → New self-hosted runner. It is single-use and lasts an hour; the
   owner does this — a session's token cannot.
3. Register:

       cd ~/actions-runner/{{PROJECT}}-ci
       ./config.sh --unattended --url https://github.com/{{OWNER}}/{{PROJECT}} \
         --token <token> --name <box>-{{PROJECT}}-ci \
         --no-default-labels --labels {{PROJECT}}-ci --work _work

4. Run it as a user service that survives logout:

       # ~/.config/systemd/user/{{PROJECT}}-ci-runner.service
       [Unit]
       Description=GitHub Actions runner for {{PROJECT}} CI
       After=network-online.target
       [Service]
       WorkingDirectory=%h/actions-runner/{{PROJECT}}-ci
       ExecStart=%h/actions-runner/{{PROJECT}}-ci/run.sh
       Restart=always
       RestartSec=10
       [Install]
       WantedBy=default.target

       systemctl --user daemon-reload
       systemctl --user enable --now {{PROJECT}}-ci-runner
       loginctl enable-linger "$USER"

5. Check it: Settings → Actions → Runners lists it Idle, with the label
   `{{PROJECT}}-ci` only. A push to `dev` runs CI on it.

## A release does not test twice

A push to `main` of a commit CI already passed (a release fast-forwards `main`
to a tested `dev` commit) skips the checks: `ci.yml`'s first job, `seen`,
asks the Actions API for a green CI run of that exact commit, and if there is
one the other jobs are skipped and the run still ends green — what a deploy
triggered by CI waits for. Anything else runs everything: a push to any other
branch, a PR, a commit not yet green (a merge or squash on `main` makes one),
or the API not answering. Releases should fast-forward `main` to the tested
commit so the skip applies.
