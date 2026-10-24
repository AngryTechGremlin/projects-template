# {{PROJECT}}: Ways of Working

> TODO({{PROJECT}}): one paragraph — what this project is, who it is for, and
> the single rule it exists to enforce. Delete this line once written.

This document is the engineering contract for this repo. `CLAUDE.md` imports it
and adds only what is personal to this machine.

## 1. Core principles
- **Simplicity & minimalism.** Prefer deleting to adding. Write code that is
  easy to read, maintain and delete. A knob needs a concrete reason written
  next to it in `.env.example` and the README.
- **Isolation.** Components stay independent of each other's internals — share
  over a declared interface (HTTP, CLI, file format), never by importing another
  component's code or reaching into its files.
- **Code explains how; docs explain why.** Every behaviour change gets a "why"
  line in the README: what it fixes, what it trades off.

## 2. Repository topology
> TODO({{PROJECT}}): what lives where, and why it is one repo (or is not).
- Tracked at the root: `agent.md`, `README.md`, `.env.example`, `.gitignore`,
  `.mcp.json`, `.vscode/`, `.claude/settings.json`, `.githooks/`, `.github/`,
  `scripts/`, `docs/`, `mcp/`.
- Never tracked: `.env`, `pi.md`, `mcp/.env`, `mcp/node_modules/`, `mcp/build/`,
  any runtime `data/`. See §3.

## 3. Secrets & personal data (committed files)
- **Never commit personal data:** no passwords, tokens, usernames, real names,
  LAN IPs, MACs, serials or internal hostnames in any tracked file — including
  code defaults, docs, tests and examples. Masked placeholders only
  (`<server-ip>`, `<tv-ip>`, `http://<host>:<port>`). Where a test needs a
  literal address, use the documentation ranges (`192.0.2.x`, `198.51.100.x`,
  `203.0.113.x`) — they are reserved for exactly this and never route.
- **Runtime values live in ignored files.** Real IPs/URLs/credentials go in the
  gitignored `.env`, with a placeholder-only `.env.example` committed beside it.
  Code defaults must be generic (`127.0.0.1`, empty) — never a real address.
- **`pi.md` — narrative context only.** A gitignored file for context no machine
  consumes (which device belongs to whom, pending decisions, household notes).
  It points at `.env` for real values and never duplicates them.
- **Before every push:** `scripts/check.sh fast`, which runs
  `scripts/pii-scan.sh` with the other checks (§6). It is also the `pre-push`
  hook (`git config core.hooksPath .githooks`), and CI runs it as `full`, so
  the scan is three deep on purpose. Never weaken a pattern to make a push go
  through — fix the file, or add a narrow pathspec to
  `scripts/pii-scan.exclude` with a comment saying why.
- **Commit as `AngryTechGremlin <AngryTechGremlin@users.noreply.github.com>`.**
  A commit's name and email are published with it and kept forever;
  `check.sh` refuses any other address, and a name that is not the address's
  GitHub handle. Commit messages and `Co-authored-by` lines are held to the
  same rules as files.
- Files unrelated to this project never ride along in a commit.
- Keep the repo **private** by default; anything describing homelab topology
  stays private permanently.
- **The one exception: a public copy**, and only where a `PUBLISH` file exists
  (`docs/publishing.md`). Only the files `PUBLISH` lists go out, only through
  `scripts/mirror.sh`, and only on the owner's click (§5). A session never
  pushes anywhere but origin (the hook refuses any other URL) and never adds a
  public remote. **Never read the publish blocklist**
  (`~/.config/publish/blocklist`): a hit prints as `file:line` only, so open
  that line, and if the problem is not plain, ask the owner. Never paste house
  logs, hostnames, addresses or command output into a public issue or PR
  reply: nothing checks what is typed there.

## 4. New endpoint bootstrap (agent-runnable)
A working checkout is the clone **plus** the gitignored files git never carries.

1. `git clone https://github.com/{{OWNER}}/{{PROJECT}} ~/Projects/{{PROJECT}}`
2. `cd mcp && npm install && npm run build`, then `cp .env.example .env` and put
   a fine-grained GitHub token in it, scoped to `{{OWNER}}/{{PROJECT}}` alone,
   with the permissions `mcp/README.md` lists, plus Actions: Read-only so a
   session can see CI results (never Actions write; Workflows stays off).
   Create the repo on GitHub first: a fine-grained token can only name a repo
   that exists.
   Restart the agent session so `.mcp.json` is picked up.
3. `git config core.hooksPath .githooks` (enables the pre-push checks), and
   `git config credential.helper '!"$(git rev-parse --show-toplevel)"/scripts/git-credential-github.sh'`
   so pushes read the same token from `mcp/.env`. `new-project.sh` sets both;
   a fresh **clone** needs them again, because git config is not cloned.
4. `cp .env.example .env` at the root and fill in the real values.
5. Recreate `pi.md` — copy it from the old machine or ask the owner.
   **Do not guess values.**
6. Verify: `scripts/check.sh fast` passes (it needs docker), the test suite
   passes, and one MCP tool call answers (e.g. `list_repositories`).

Until `.env` and `pi.md` exist, an agent has no real endpoint and must ask
rather than assume.

## 5. Branching & release gate
> TODO({{PROJECT}}): pick one and delete the other.
- **Single-branch:** work on `main`, push freely — CI validates, nothing ships.
- **dev/main:** work on `dev`; **merging `main` is the release.** Only by PR,
  only with explicit per-release approval from the owner ("ready to release?" →
  wait). Approval for one release never carries over to the next.

**Publishing a public copy is not part of a release** (only where `PUBLISH`
exists). A push to `main` publishes nothing: the owner reads the publish check
job's list and clicks publish (Actions → publish → Run workflow, on `main`). A
session never starts it — its token has no Actions write — and never reads a
release approval as approval to publish.

## 6. Testing
> TODO({{PROJECT}}): the one command that runs the suite, and what each tier
> covers. Tests must not need a secret, a real device, or the LAN.
- **Before every push: `scripts/check.sh fast`** (the pre-push hook runs it
  too). Treat its output like a failing test: fix the cause, never skip the
  hook (`--no-verify`) or loosen a check to get a push through. A reviewed
  exception is written where the finding is, with the reason (the fix line
  under each failure says how).
- CI runs `scripts/check.sh full` (secrets across all of history,
  Dockerfiles) and `weekly.yml` runs `scripts/check.sh vuln` (known
  vulnerabilities in lockfiles): fix a weekly failure by upgrading.
- CI runs on the house's own CI runner, never GitHub's cloud runners
  (`docs/ci-runner.md`): "does it build, parse and pass unit tests", plus the
  house checks. No secrets, no real devices, nothing that reaches the house.
- A public copy has no CI of its own: the public repo has no workflows and
  never reaches a house runner. Outside PRs are tested here, privately.
- **Code from outside the house** (a PR taken in with `scripts/mirror.sh pr
  <N>`) runs only inside `scripts/sandbox.sh` — no network, no home folder, no
  docker socket — in CI and in a session alike, and only after the owner has
  read the diff.
- Anything that touches real hardware is on-demand only, gated on an identifier
  in a gitignored file, and never runs in CI.

## 7. Code style & commits
- **Conventional Commits** (`feat:`, `fix:`, `docs:`, `chore:`, `test:`), with
  narrative subjects that state the *why*, not the diff.
- Lean on the standard formatter/linter for the stack (Ruff, Prettier/ESLint,
  gofmt). Shell: `set -euo pipefail`, shellcheck-clean, no `sudo`.

## 8. Tooling: GitHub MCP
A lean, project-scoped GitHub MCP server lives in `mcp/` (5 tools: `get_issue`,
`list_pull_requests`, `search_code`, `create_comment`, `list_repositories`).

- **Wiring is project-scoped, never global.** `.mcp.json` at the root points at
  `mcp/build/index.js` (repo-relative, so it is portable); `.vscode/mcp.json`
  does the same for VS Code via `${workspaceFolder}`; `.claude/settings.json`
  pre-enables it so a fresh clone gets no approval prompt.
- **The token never appears in client config.** The server loads it from
  `mcp/.env` itself via dotenv.
- **Keep it lean.** Every connected server's tool definitions are loaded into
  the model's context every session — 5 small tools cost little, the official
  100+-tool GitHub MCP would burn thousands of tokens per session.
- The canonical copy of this server is `~/Projects/_template/skel/mcp`. Fix a
  bug there too, or the next project inherits it.
- Use these tools for context *before* proposing changes: `get_issue` when an
  issue number is mentioned, `list_pull_requests` to avoid duplicating in-flight
  work, `search_code` before writing something that may already exist. Confirm
  the `owner/repo` before any write. This project's is
  `{{OWNER}}/{{PROJECT}}`.

## 9. Decision log — ADR-lite
Every trade-off against a principle in §1 gets an ADR in `docs/adr/NNNN-title.md`,
one screen maximum. `docs/adr/README.md` is the index. Supersede, never rewrite.

## 10. Lessons learned (keep short; details live in the README)
> TODO({{PROJECT}}): add one line per scar, with the fix. Delete this line once
> there is a first entry.

## 11. Local overrides
> **CRITICAL DIRECTIVE FOR AGENTS:**
> These are the defaults for the whole repo. A `README.md` or `agent.md` inside
> a subdirectory you are working in always overrides them.
