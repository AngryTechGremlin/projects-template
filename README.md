# _template — the shape every project here starts in

Five projects on this machine converged on the same skeleton by hand. This is
that skeleton, extracted once so the sixth does not have to rediscover it — and
so a fix to the shared machinery is written in one place.

```bash
~/Projects/_template/new-project.sh my-thing          # -> ~/Projects/my-thing
~/Projects/_template/new-project.sh --adopt ~/Projects/existing             # add what's missing
~/Projects/_template/new-project.sh --adopt ~/Projects/existing --refresh   # bring the shared scripts up to date
~/Projects/_template/new-project.sh my-thing --publish                      # also the public-mirror kit
```

The leading underscore is deliberate: it sorts above the projects and marks
this directory as *not one of them*.

## What a scaffolded project gets

| File | Why it exists |
|---|---|
| `agent.md` | The engineering contract — principles, topology, secrets rule, bootstrap, branching, testing, MCP, ADRs. Committed, shared, the thing an agent reads first. |
| `CLAUDE.md` | Thin: `@agent.md`, the pointer to `pi.md`, and the handful of rules true only here. |
| `README.md` | Human-facing: install, configure, and a "why it works this way" section, because code explains *how* and docs explain *why*. |
| `.env.example` → `.env` | Placeholders committed, real values gitignored. Every knob carries the reason it exists. |
| `pi.md` | Gitignored narrative context — whose device is whose, what is undecided. Never duplicates `.env`. |
| `scripts/pii-scan.sh` | The "grep before every push" rule, made executable. |
| `scripts/check.sh` + `scripts/check-tools.env` | The house checks, one entry point for agents, the pre-push hook and CI (below). `check-tools.env` holds the tools' digest pins, not settings or secrets. |
| `.githooks/pre-push` | Refuses a push to any URL but origin's, then runs `scripts/check.sh fast` on exactly the commits being pushed, so forgetting is not an option (`core.hooksPath`). |
| `scripts/git-credential-github.sh` | Answers git's HTTPS prompt from the same gitignored `mcp/.env` the MCP server reads, so a push needs no second copy of the token and none lands in `.git/config`. It reads the host git asks about and answers **only** `https://github.com` — a helper that skips that check hands the token to any remote, rewrite or submodule URL. MCP projects only; `new-project.sh` wires it. |
| `.github/workflows/ci.yml` | CI on the project's own runner on the house's CI box (`docs/ci-runner.md`): `scripts/check.sh full` always, a stack-specific job to fill in, and a push to `main` of a commit already green skips the checks. Every `uses:` pinned to a full commit SHA. |
| `.github/workflows/weekly.yml` | `scripts/check.sh vuln` every Monday and on demand: a new advisory arrives without any commit. |
| `docs/ci-runner.md` | How to add and remove the project's runner, why it can never be handed a deploy, and the deploy guard. |
| `mcp/` + `.mcp.json` + `.vscode/mcp.json` + `.claude/settings.json` | The lean 5-tool GitHub MCP server, project-scoped, token in `mcp/.env` only: a fine-grained token scoped to the one repo (permissions below). |
| `docs/adr/` | ADR-lite. One screen per trade-off, superseded rather than rewritten. |
| `.gitignore` | The PII trio, MCP build output, and a commented deny-all variant for repos that describe homelab topology. |
| `PUBLISH`, `scripts/mirror.sh`, `scripts/sandbox.sh`, `.github/workflows/publish.yml`, `docs/publishing.md` | `--publish` only: the public-mirror kit (below). |

Every generic decision the scaffold could not make for you is left as
`TODO(<project>)`. `grep -rn 'TODO(<project>)' .` is the punch list.

## The checks, and why they run locally

`scripts/check.sh` is the one place the house's checks live. An agent runs it
before pushing, the pre-push hook runs it, CI runs it: the same script, the
same pinned tools, so a red CI run is never news.

| Tier | Run by | What it checks |
|---|---|---|
| `fast` | the pre-push hook, and every agent before every push | the PII scan; on the commits being pushed, commit identity (author, committer and `Co-authored-by` must be a GitHub handle at its `@users.noreply.github.com` address), the PII scan over their messages, and secrets (gitleaks); no tool config that differs from its committed copy; workflows (actionlint, and zizmor `--offline` for unpinned actions, persisted credentials, injection, risky triggers); every shell script (shellcheck) |
| `full` | CI's `hygiene` job, every push and PR | `fast`, but gitleaks over **all** of history, plus Dockerfiles (hadolint) |
| `vuln` | `weekly.yml`, Mondays and on demand | known vulnerabilities in lockfiles, and in the images named in `CHECK_IMAGES` (Trivy); fails only on HIGH/CRITICAL that have a fix |

- **Each tool is a Docker image pinned by digest** in `scripts/check-tools.env`,
  with its version and the reason beside it: a tag can be moved upstream, a
  digest cannot, so what checks the house's code changes only when that file
  does. It runs as the calling user with no network, no capabilities and the
  repo mounted read-only. Trivy's database (about 1.6 GB, cached in
  `~/.cache/trivy`) is fetched by a container that never sees the repo; the
  scan itself has no network. Tools are *downloaded*; code is never uploaded.
- **A check that did not run is not a pass.** Exit 0 clean, 1 a check found
  something, 2 setup (no docker, a missing pin or file, a bad range). Each
  failure prints the fix under it.
- **Speed:** `fast` takes about 2 s once the images are pulled (about
  150 MB, once per box), so nobody is tempted to skip the hook.
- **Which commits:** `CHECK_RANGE` (git rev-list arguments). The hook sets it
  to what is being pushed and CI to what the event brings; unset, it is the
  commits on no remote yet.
- **Commit identity:** the house commits as
  `AngryTechGremlin <AngryTechGremlin@users.noreply.github.com>` (`git config
  user.name` / `user.email` in each repo, or globally). A commit's name and
  address are published with it for good, and a real name beside a noreply
  address is still a real name, so the name must be the handle the address
  carries. GitHub's own `GitHub <noreply@github.com>` is accepted as
  committer, for merges made in the browser; a `Co-authored-by` may also be
  a tool's `noreply@` address. Messages get the PII scan too.
- **Tool configs are read as committed.** An uncommitted `.gitleaksignore`,
  `.github/zizmor.yml`, `scripts/pii-scan.exclude` and the like would make
  the hook pass where CI, which reads the committed copy, fails.
- **`.gitattributes` is not consulted.** One line (`* -diff`) makes git call
  every file binary, which would blind both the PII scan and gitleaks; both
  read attributes from the empty tree instead (`GIT_ATTR_SOURCE`, git 2.40 or
  later, which the PII scan insists on).
- **A deploy started by `workflow_run`** is a zizmor `dangerous-triggers`
  error until marked reviewed; `skel/docs/ci-runner.md` (the deploy guard)
  has the line.
- **A reviewed exception** is written where the finding is, with the reason:
  `.gitleaksignore` (by fingerprint), `.trivyignore.yaml`, `# zizmor: ignore[...]`,
  `# shellcheck disable=...`, `# hadolint ignore=...`. Never a weaker pin or a
  skipped check.
- **A trivy exception names the one file it excuses.** In `.trivyignore.yaml`
  each entry gives the CVE `id`, `paths` (the binary inside the image, e.g.
  `usr/local/bin/gosu`), `expired_at` and a `statement` saying why; `check.sh`
  refuses an entry without the last two. A plain `.trivyignore` would excuse
  the ID everywhere: Go CVEs repeat across binaries, so excusing an
  unreachable one in postgres's `gosu` would also hide a reachable one in
  Caddy (hallpass, 2026-10-25). After `expired_at`, trivy reports it again.
- A project's own lint and tests (ruff, pytest, playwright, ...) stay in its
  `ci.yml` `check` job; `check.sh` is only what every repo shares.

**Rejected, and why** — each sends the house's code or its dependency list to
someone else's service:

- **Snyk.** Snyk Code uploads the source to Snyk's cloud to analyse it; Snyk
  Open Source and Container send the dependency and package lists. Trivy does
  the dependency and image job locally.
- **`pip-audit` and `npm audit`.** Both send the full dependency list to a
  remote API. Trivy reads the same lockfiles offline.
- **Semgrep with registry rules** (`--config auto`, `p/...`): it fetches rules
  from Semgrep's registry and reports metrics back. It would only be
  acceptable with local rules and `--metrics=off`, and nothing needs it yet.

## The PII scan, and why it is trusted

`scripts/pii-scan.sh` runs in two tiers, because a scanner that cries wolf gets
disabled:

- **Hard** — credential shapes that are never a coincidence (GitHub, OpenAI,
  Anthropic, AWS, Google, npm and Slack keys; JWTs, which is what a Home
  Assistant token is; Tailscale keys; PEM private key blocks). Scanned
  everywhere, including test paths and whatever `scripts/pii-scan.exclude`
  lists. A hit is real: fix the file *and* rotate the key.
- **Soft** — RFC1918 host addresses, MACs, passwords assigned a literal, GPS
  coordinates (four or more decimals: a home's coordinates are its address).
  Real leaks look exactly like fixtures, so these skip test paths and lines
  that say they are an example.

Exempt by construction, not by exception list: the documentation ranges
(`192.0.2.x`, `198.51.100.x`, `203.0.113.x` — use these in tests), `.0`/`.255`
host octets so CIDR blocks read as topology, `127.0.0.1`, and the all-zero /
all-ff / `aa:bb:cc:dd:ee:ff` MACs.

It was calibrated against every existing project here: all five come back clean,
and a token planted in `tests/fixtures.py` is still caught. The JWT, Tailscale
and coordinate patterns (added with house-manager, 2026-09-21) were checked the
same way against every sibling: no tracked file changed result. The coordinate
pair wants a space after the comma, which is how people write coordinates and
not how SVG path data is written. Real false positive?
Add a narrow pathspec to `scripts/pii-scan.exclude` with a comment saying why —
never widen a pattern to make a push go through.

Its last line counts the files it scanned once the exclude file has had its
say, and none at all is exit 2, never "clean": a lone `*` in the exclude
file cannot switch the scan off.

Two stricter modes exist for a tree about to go public, and only
`scripts/mirror.sh` needs them: `PII_SCAN_PUBLIC=1` drops the exclude file and
the test and placeholder exemptions (a fixture in a private repo harms no
one; published, it is just a leak) and adds shapes that only matter once
public (CGNAT and private IPv6 addresses, `.lan`/`.local`/`.internal`/
`.home.arpa` names, any email but GitHub's noreply ones and the example
domains, unquoted secret assignments), and `PII_SCAN_BLOCKLIST=<file>` also
refuses the house's own words, printing `file:line` only.

## `--adopt`, for projects that already exist

Adds only the shared tooling that is missing — the checks, the hook, the
workflows, `docs/ci-runner.md`, the MCP server — and never overwrites: an
existing `agent.md`, `README.md`, `ci.yml` or `mcp/` is left alone. The ignore
rules the tooling needs are appended under a dated marker, and the hook path
is set. Use `--dry-run` first.

A repo whose `.gitignore` has `*.env` also ignores `scripts/check-tools.env`,
and CI then has no pins and stops; `--adopt` appends
`!scripts/check-tools.env` to its block when git says the file is ignored,
and says so loudly if a folder rule still hides it. Where `ci.yml` has no
`scripts/check.sh full`, it says to port the skeleton's whole hygiene job:
a bare `run: scripts/check.sh full` would check the identity of no commit,
since a fresh CI checkout has none "not on a remote".

**`--adopt --refresh`** keeps a repo's copy of the shared machinery current,
since plain `--adopt` never overwrites. It splits the files in two:

- **Managed** — overwritten with the template's copy, each with its diff
  printed: `scripts/pii-scan.sh`, `scripts/check.sh`,
  `scripts/check-tools.env`, `.githooks/pre-push`, `docs/ci-runner.md`, and
  for a repo with the mirror kit `scripts/mirror.sh`, `scripts/sandbox.sh`,
  `docs/publishing.md`. No repo edits these; a fix to one goes in the template.
- **Customized** — never written; refresh prints how each differs from the
  template, to port by hand: `ci.yml`, `weekly.yml`, `agent.md`, `CLAUDE.md`,
  `README.md`, `scripts/pii-scan.exclude`, and with the kit `PUBLISH` and
  `publish.yml`. Workflows are here because each repo's `ci.yml` has its own
  `check` job, and because a workflow change needs the Workflows grant to
  push anyway.

It refuses while a managed file has uncommitted changes, so a refresh is
always one diff someone can review on its own: run it, read `git diff`, run
`scripts/check.sh fast`, commit as `chore: refresh shared tooling from the
template`.

## Putting a project on GitHub — the normal pattern

Every project gets its own **private** repo and its own **fine-grained token**,
scoped to that one repo. The token lives only in the project's gitignored
`mcp/.env` and does both jobs: the MCP server reads it, and
`scripts/git-credential-github.sh` hands it to `git push`. A leaked token
reaches one repo, not the account. (hallpass went first, 2026-09-27.) There is
no way to copy a sibling's token: each repo's `mcp/.env` starts as the
placeholder (`--reuse-token`, which copied one, is gone).

1. On github.com, create `AngryTechGremlin/<name>`: **private**, and **empty**
   — no README, `.gitignore` or license, or the first push conflicts with them.
   Create it before the token: a fine-grained token can only name a repo that
   exists.
2. Create a fine-grained token: resource owner `AngryTechGremlin`, repository
   access **Only select repositories** → that repo alone, an expiry with a
   reminder on the date, and these repository permissions:

   | Permission | Access | Why |
   |---|---|---|
   | Contents | Read and write | `git push` |
   | Issues, Pull requests, Metadata | as `skel/mcp/README.md` lists | the MCP tools |
   | Actions | **Read-only** | a session can see whether CI passed, and why not |
   | Workflows | **Read and write only for a push that changes a workflow**, then back to No access | the first push carries `.github/workflows/`, and GitHub refuses a push that creates or changes a workflow file without it |

   **Never Actions: Read and write.** It would let a session start a
   workflow, and publishing a public copy is a workflow the owner starts by
   hand (`publish.yml`). Without Workflows, a session cannot rewrite one to
   start itself either.
3. Put it in `<project>/mcp/.env` as the one `GITHUB_PERSONAL_ACCESS_TOKEN=`
   line — no quotes, no second copy; the helper reads the value raw.
4. `new-project.sh --adopt <project>` wires the helper and the pre-push hook (a
   fresh scaffold already has both). A fresh scaffold has no commit yet, and
   `dev` is the work branch, so first:

   ```bash
   git add -A && git commit -m 'chore: scaffold from the Projects template'
   git switch -c dev
   ```

   then, for every project:

   ```bash
   git remote add origin https://github.com/AngryTechGremlin/<name>.git
   git ls-remote origin      # exit 0 (silent on an empty repo): token and helper work
   scripts/check.sh fast     # what the hook is about to run; fix anything first
   git push -u origin dev    # the pre-push hook runs check.sh fast first
   ```

5. Set Workflows back to **No access**. From then on a session can push code
   but not change CI: a workflow change is pushed by a person, or with the
   grant given back for that one push.
6. Record the remote in the project table in `~/Projects/CLAUDE.md`.
7. Give it a CI runner on the CI box (`docs/ci-runner.md`). The owner gets a
   registration token from the repo's Settings → Actions → Runners → New
   self-hosted runner, and on the CI box, in a terminal, runs

   ```bash
   ~/Projects/_template/runners/add-runner.sh ci <name>   # asks for the token
   ```

   It downloads the pinned runner and checks its sha256, registers it as
   `<name>-ci` with `--no-default-labels --labels <name>-ci` (no box name),
   and starts it as a systemd user service. Until it is up, CI queues — there
   is no cloud fallback (workspace rule: no GitHub-hosted runners). Any deploy
   workflow refuses every runner but prod's by the folder its workspace is in
   (the guard below), never by a runner's name.

## The CI runner kit, and the deploy guard

`runners/add-runner.sh` lives here at the template root and is never copied
into a project: it is run once per repo, on the CI box, by the owner. It reads
the registration token at a prompt (never an argument, so it stays out of `ps`
and shell history), refuses rather than overwrites a runner or unit that is
already there, and is safe to re-run after a failure. `ACTIONS_RUNNER_DIR`
(default `~/actions-runner`) and `RUNNER_OWNER` (default `AngryTechGremlin`)
exist for its tests and for a repo under another account.
`skel/docs/ci-runner.md` has the steps, the removal, and the why.

The same script sets up a deploy runner on the prod box, with the same
paste-the-token prompt: `runners/add-runner.sh prod <name>` (copy the script
to the box; it needs nothing else from the template). It registers
`prod-<name>` in `/opt/actions-runners/<name>`, the folder the deploy guard
checks, with the default `self-hosted` label a deploy's `runs-on` asks for.
It never uses sudo: when that folder is missing or not the runner user's, it
prints the one `sudo mkdir … && sudo chown …` line and stops, and once
registered it prints the `sudo ./svc.sh install` line that installs the
system service. Both stay the owner's steps.

`publish/add-public-key.sh <repo>` is the public mirror's one-time link
between a private repo and its public copy, run once per repo by the owner:
it makes a deploy key for that repo alone and prints the two pastes (public
half on the public repo, private half as the `PUBLIC_DEPLOY_KEY` secret), and
`--done` proves GitHub took it before shredding the private half
(`skel/docs/publishing.md`, "The deploy key").

A deploy job runs on prod's runner, and its first step is the same line in
every repo:

```yaml
      - name: Only prod's runner deploys
        run: |
          case "$GITHUB_WORKSPACE/" in "/opt/actions-runners/${GITHUB_REPOSITORY#*/}/"*) ;; *) echo "::error::deploy runs only on prod's runner, not on $RUNNER_NAME"; exit 1;; esac
```

Prod's runners live in `/opt/actions-runners/<repo>/`, which only root can
make; CI runners live in their user's home. So the check names no host, which
a guard on `RUNNER_NAME` would have to, and the repo part plus the trailing
`/` keep `x`'s runner from passing `xy`'s guard. It fails closed: a prod
runner anywhere else refuses to deploy, and the first deploy proves the
layout. `tests/guard.sh` checks it against fake workspaces.

## A public copy, for the repos that want one: `--publish`

A few repos may be worth publishing. Making a private repo public, or
mirroring it, publishes all of its history; this publishes files instead.
`--publish` (new, or with `--adopt`) adds the mirror kit, and each release can
then put one fresh snapshot commit on `techthatworks/<name>` (`--public-owner`
or `PUBLIC_OWNER` for another org):

- `PUBLISH` lists the files that go out, one literal path per line. A file
  goes public only when someone adds its line.
- `scripts/mirror.sh` checks every gate — the strict scan, the owner's
  blocklist of house words (`~/.config/publish/blocklist` on the CI box,
  which no session ever reads), a hard deny list, no binaries, no history —
  and builds the snapshot in a scratch repo that never holds a private object.
- `publish.yml` previews on every push. Only the owner's click publishes
  (Actions → publish → Run workflow, on `main`): a publish cannot be taken
  back, and nothing protects `main` on a free private repo.
- Outside PRs come back with `scripts/mirror.sh pr <N>`, and their code runs
  only inside `scripts/sandbox.sh` (no network, no home folder, no docker
  socket, no tokens, and a throwaway copy of the checkout): a `--publish`
  scaffold's `ci.yml` runs its test commands that way. The public repo has
  no workflows and never reaches a house runner.
- `publish.yml` pins `scripts/mirror.sh` and `scripts/pii-scan.sh` by hash,
  so a session's change to the publisher stops the job until the owner pastes
  the new hashes; a refresh that changes either needs that edit too.

It is opt-in because an unused publisher in every repo is attack surface.
`skel/docs/publishing.md` has the gates, the owner's setup on GitHub and the
first-publish checklist; `tests/mirror-gates.sh` proves the gates on a
throwaway fixture.

## Changing the template

The MCP server here is the canonical copy — `~/Projects/_template/skel/mcp`.
Fix a bug in a project's copy and fix it here too, or the next project inherits
it. When three projects have made the same edit to a scaffolded file, that edit
belongs in `skel/`.

The template is itself a private repo (`AngryTechGremlin/projects-template`;
`dev` is the work branch), checked by the scripts it hands out:
`scripts/pii-scan.sh` and `scripts/check.sh` at the root are links into
`skel/scripts/`, and `scripts/pii-scan.exclude` is the template's own. Before
pushing a change:

```bash
scripts/check.sh fast   # what the hook runs
tests/run.sh            # the deploy guard, the mirror gates, and a scaffold smoke test
```

Its CI (`.github/workflows/ci.yml`, on the runner `projects-template-ci`) runs
`scripts/check.sh full` and `tests/run.sh`. The smoke test scaffolds into a
scratch folder (new with `--publish`, `--adopt`, `--adopt --refresh`), fails
on any `{{PLACEHOLDER}}` left behind, and runs the scaffold's own
`scripts/check.sh fast` and pre-push hook — which is where the skeleton's
workflows are linted, as a project gets them.

A pin bump (`skel/scripts/check-tools.env`, the runner version in
`runners/add-runner.sh`, an action SHA in the skeleton's workflows) says how
in the file. A change to `skel/scripts/mirror.sh` or `skel/scripts/pii-scan.sh`
also changes the two hashes `skel/.github/workflows/publish.yml` pins them by;
`tests/run.sh` fails until they match. It reaches existing repos through `--adopt --refresh`, one repo at
a time, in that repo's own session.
