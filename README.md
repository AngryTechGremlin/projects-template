# _template — the shape every project here starts in

Five projects on this machine converged on the same skeleton by hand. This is
that skeleton, extracted once so the sixth does not have to rediscover it — and
so a fix to the shared machinery is written in one place.

```bash
~/Projects/_template/new-project.sh my-thing          # -> ~/Projects/my-thing
~/Projects/_template/new-project.sh --adopt ~/Projects/existing   # add what's missing
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
| `.githooks/pre-push` | The same scan, wired so forgetting is not an option (`core.hooksPath`). |
| `scripts/git-credential-github.sh` | Answers git's HTTPS prompt from the same gitignored `mcp/.env` the MCP server reads, so a push needs no second copy of the token and none lands in `.git/config`. It reads the host git asks about and answers **only** `https://github.com` — a helper that skips that check hands the token to any remote, rewrite or submodule URL. MCP projects only; `new-project.sh` wires it. |
| `.github/workflows/ci.yml` | CI on the project's own runner on the house's CI box (`docs/ci-runner.md`): the scan always, a stack-specific job to fill in, and a push to `main` of a commit already green skips the checks. |
| `docs/ci-runner.md` | How to register that runner so it can never be handed a deploy, and why. |
| `mcp/` + `.mcp.json` + `.vscode/mcp.json` + `.claude/settings.json` | The lean 5-tool GitHub MCP server, project-scoped, token in `mcp/.env` only: a fine-grained token scoped to the one repo, with the permissions `skel/mcp/README.md` lists. |
| `docs/adr/` | ADR-lite. One screen per trade-off, superseded rather than rewritten. |
| `.gitignore` | The PII trio, MCP build output, and a commented deny-all variant for repos that describe homelab topology. |

Every generic decision the scaffold could not make for you is left as
`TODO(<project>)`. `grep -rn 'TODO(<project>)' .` is the punch list.

## The PII scan, and why it is trusted

`scripts/pii-scan.sh` runs in two tiers, because a scanner that cries wolf gets
disabled:

- **Hard** — credential shapes that are never a coincidence (GitHub, OpenAI,
  Anthropic, AWS, Google keys; JWTs, which is what a Home Assistant token is;
  Tailscale keys; PEM private key blocks). Scanned everywhere, including test
  paths. A hit is real: fix the file *and* rotate the key.
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

## `--adopt`, for projects that already exist

Adds only what is missing and never overwrites: existing `agent.md`,
`README.md`, `ci.yml` and `mcp/` are left alone, the ignore rules the tooling
needs are appended under a dated marker, and the hook path is set. Use
`--dry-run` first.

## Putting a project on GitHub — the normal pattern

Every project gets its own **private** repo and its own **fine-grained token**,
scoped to that one repo. The token lives only in the project's gitignored
`mcp/.env` and does both jobs: the MCP server reads it, and
`scripts/git-credential-github.sh` hands it to `git push`. A leaked token
reaches one repo, not the account. (hallpass went first, 2026-09-27.)

1. On github.com, create `AngryTechGremlin/<name>`: **private**, and **empty**
   — no README, `.gitignore` or license, or the first push conflicts with them.
   Create it before the token: a fine-grained token can only name a repo that
   exists.
2. Create a fine-grained token: resource owner `AngryTechGremlin`, repository
   access **Only select repositories** → that repo alone, the permissions
   `skel/mcp/README.md` lists, and an expiry with a reminder on the date.
   **For the first push, also Workflows: Read and write**: the first commit
   carries `.github/workflows/ci.yml`, and GitHub refuses a push that creates
   a workflow file without it.
3. Put it in `<project>/mcp/.env` as the one `GITHUB_PERSONAL_ACCESS_TOKEN=`
   line — no quotes, no second copy; the helper reads the value raw.
4. `new-project.sh --adopt <project>` wires the helper and the pre-push hook (a
   fresh scaffold already has both), then:

   ```bash
   git remote add origin https://github.com/AngryTechGremlin/<name>.git
   git ls-remote origin      # exit 0 (silent on an empty repo): token and helper work
   git push -u origin dev    # the pre-push PII scan runs first
   ```

5. Set Workflows back to **No access**. From then on a session can push code
   but not change CI: a workflow change is pushed by a person, or with the
   grant given back for that one push.
6. Record the remote in the project table in `~/Projects/CLAUDE.md`.
7. Give it a CI runner on the CI box (`docs/ci-runner.md`): the owner gets a
   registration token from the repo's Settings → Actions → Runners, and the
   runner is registered with `--no-default-labels --labels <name>-ci`. Until
   it is, CI queues — there is no cloud fallback (workspace rule: no GitHub-hosted runners).
   Any deploy workflow refuses every runner but prod's by `RUNNER_NAME`.

## Changing the template

The MCP server here is the canonical copy — `~/Projects/_template/skel/mcp`.
Fix a bug in a project's copy and fix it here too, or the next project inherits
it. When three projects have made the same edit to a scaffolded file, that edit
belongs in `skel/`.
