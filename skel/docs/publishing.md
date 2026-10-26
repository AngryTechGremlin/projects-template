# Publishing a public copy

`{{PROJECT}}` is private. Some of its files are also published to a public
repo, `{{PUBLIC_OWNER}}/{{PROJECT}}`, as one fresh snapshot commit per
release. This page says why it works the way it does, and what the owner does
by hand. `scripts/mirror.sh` is the mechanism; `PUBLISH` says what goes out.

## Why a snapshot, and why it refuses instead of fixing

- **History is where personal data leaks.** A mirror, a fork, `filter-repo`
  or `subtree` would publish every old version of every allowed file, with
  every message and author. A snapshot publishes the files as they are now,
  and its one commit says only `chore: publish snapshot` and which private
  commit it came from (`Source:`).
- **Files go out byte for byte.** Nothing is rewritten on the way, so an
  outside PR made against the public copy applies straight back here with
  `git am -3`. A file that cannot go out exactly as it is stops the publish.
- **Publishing cannot be taken back.** Copies and caches outside GitHub keep
  what they saw. So every gate fails closed: a missing tool, list or answer
  stops the publish rather than skipping a check.
- **The public repo is written by one thing only:** the publish job, with a
  deploy key that the public repo's rulesets let through and nothing else.
  There is no `public` remote in any clone, and the pre-push hook refuses any
  URL but origin's, and any in the public org or naming the `PUBLISH` repo
  even when origin itself has been pointed there.

## `PUBLISH`: what goes out

```
[publish]
	repo = {{PUBLIC_OWNER}}/{{PROJECT}}
	path = README.md
	path = LICENSE
	path = src/app.py
```

- It is read **from the commit being published**, never the working tree, so
  what was reviewed is what ships.
- **One literal file path per `path` line.** No folders, no globs, no `..`, no
  leading `/`, no `:` pathspec magic; names use letters, digits and `. _ - + @`
  only, so rename a file with spaces. A new file goes public only when someone
  adds its line, so every newly public file is a one-line change a person
  reviewed. The check job marks it "new: permanently public".
- Each path must exist in the commit as a plain file (no symlink, no
  submodule), once. A stale line is an error, not a skip.
- **`LICENSE` and `README.md` are required.** So is `NOTICE` when the repo has
  one (Apache-2.0 §4(d) requires it to travel with the code).
- **No binaries yet.** Nothing proves an image or archive carries no metadata
  (EXIF, PNG text chunks, compressed streams). A checker comes when a repo
  needs one.
- **The hard deny list** applies whatever `PUBLISH` says: anything under
  `.github/`, `.githooks/`, `mcp/`, `.claude/`, `.cursor/`, `.vscode/` or
  `data/` at any depth; the agents' notes under any tool's name for them
  (`CLAUDE.md`, `CLAUDE.local.md`, `agent.md`, `AGENTS.md`, `.cursorrules`),
  `pi.md`, `.mcp.json`, `PUBLISH`, `.gitmodules`; `scripts/pii-scan.sh`,
  `scripts/pii-scan.exclude`,
  `scripts/mirror.sh`, `scripts/sandbox.sh`, `git-credential-github.sh`; env
  files (`.env*`, `*.env`, except `.env.example`); keys (`*.pem`, `*.key`,
  `*.p12`, `*.jks`, `*.keystore`, `local.properties`); and anything
  `scripts/pii-scan.exclude` keeps from the private scan.

## When it publishes

- **Every push** runs the `check` job of `.github/workflows/publish.yml`:
  every gate, and the exact list of files that would go public in the job
  summary, new ones marked. A red check means the next publish would refuse.
- **Only the owner's click publishes:** Actions, publish, Run workflow, on
  `main`. The job refuses any other branch, and refuses unless the commit is
  `main` as GitHub has it.
- **Why a click, not a push to main:** a free private repo cannot protect
  `main`, so one misread "approved" would publish for good. Sessions cannot
  click: their tokens have no Actions write and no Workflows permission. Keep
  both off.
- Both jobs run on this project's CI runner, never the prod box's. The public
  repo has no workflows at all.
- **The publisher is pinned by hash in `publish.yml`:** both jobs check
  `scripts/mirror.sh` and `scripts/pii-scan.sh` against the hashes written
  there before running either. A session can push a change to a script but
  not to a workflow, so a changed publisher stops the job until the owner,
  having read the change, pastes the new hashes. A refresh from the template
  that changes either script therefore needs that edit too.
- **Both jobs start from an empty workspace.** A house runner keeps its
  workspace between jobs, and an earlier job's code could have left a hook or
  a git setting in `.git` that runs during this one, with the key in reach.

## The gates, in order

1. `PUBLISH` from the commit; exactly one valid `repo`, which is not this
   repo's own origin.
2. `publish` only: `main`, in CI, at `origin/main`, with the deploy key.
3. The blocklist loads (below); the repo name and every path are checked
   against it before anything prints a path.
4. Every entry literal, unique, and a file in the commit.
5. The hard deny list.
6. Plain files only: no symlinks, no submodules.
7. The snapshot's tree, built from exactly the listed blobs in a throwaway
   index (never `git archive`, whose export-ignore drops files and
   export-subst writes private data into them).
8. No binaries: a NUL byte in the blob, or git calling it binary.
9. `LICENSE`, `README.md`, and `NOTICE` when there is one.
10. A scratch repo receives exactly the snapshot's objects, and nothing else
    from here: whatever it pushes cannot carry private history.
11. The strict scan over exactly the files that ship: `scripts/pii-scan.sh`
    from the commit, with `PII_SCAN_PUBLIC=1` (no exclusions, no test or
    placeholder exemptions, and the public-only shapes: CGNAT and private
    IPv6 addresses, `.lan`/`.local`/`.internal`/`.home.arpa` names, any email
    but GitHub's noreply ones and the example domains, unquoted secret
    assignments) and the blocklist.
12. (File names against the blocklist: done at 3.)
13. The public repo, read anonymously: its last commit must be the
    publisher's, with a full `Source:` that is an ancestor of this commit. An
    identical tree means "already published", and nothing happens.
14. The message: fixed text, `Source:`, and `Co-authored-by:` lines only from
    well-formed `Public-Credit:` trailers; then the message itself against the
    blocklist.
15. `check` stops here.
16. `publish` commits in the scratch repo as
    `AngryTechGremlin <AngryTechGremlin@users.noreply.github.com>`, in UTC,
    and checks the tree, the identity and that it adds exactly one commit.
17. It pushes that one commit to `main` with the deploy key, offered only to
    github.com's pinned host key. Never forced, no tags.

## The blocklist

The patterns in `scripts/pii-scan.sh` catch shapes: addresses, keys, tokens.
They cannot know the house's own words. The blocklist holds those.

- **Where:** `~/.config/publish/blocklist` on the CI box, for the runner's
  user. Mode 600. Never in a repo, a commit message or an issue.
- **Format:** one fixed string per line, matched anywhere in a line, in any
  case. `#` starts a comment; blank lines, surrounding spaces, CRs and a
  leading byte-order mark are ignored. Each entry is at least 4 characters:
  a shorter one matches everywhere. Prefer single words and fragments
  (`surname`, `host-`) to phrases: a phrase is missed when a line wraps
  between its words or a non-breaking space joins them.
- **What goes in:** the box hostnames in forms that cannot be a plain word
  (`name.`, `name-`, the full domain name); the house domain; the LAN prefixes
  (`192.168.N.`); the WAN address; Wi-Fi names; real MACs and serials;
  family full names and surnames; personal email addresses and their local
  parts; street and coordinate fragments; the names, addresses and phone
  numbers of any customer whose data a repo has seen; and
  `github.com/AngryTechGremlin/`, which catches links to private repos.
- A short entry also matches inside code and encoded data (`Mark` is in
  `bookmark`; any four letters turn up in a base64 font). Keep a short
  name that matters and read a hit's line before believing it; drop a short
  one that names little.
- The login name of whoever runs the script is added on its own.
- **A hit prints as `file:line` only**, or for a name, its place in
  `PUBLISH`. Never the line, never the entry: CI logs live on GitHub. The
  owner opens the file at that line to see it.
- **A session builds it on the owner's word** (the owner's call, 2026-10-25):
  from what the house's gitignored files (`pi.md`, `.env`) and its memory
  already know, then from the box itself (host name, Wi-Fi names, account
  name), with each entry counted in the files that would go public and in
  every repo's tracked files, so a false alarm is caught before a publish
  meets it. The list then sits in that session's transcript; outside such a
  request, a session never reads it, and one that meets a hit asks the owner.
- Missing, empty, or holding a too-short entry: exit 2. The check job goes
  red and nothing publishes.

## Setting up the public side (the owner, in the browser)

### The org, once

- A free org, `{{PUBLIC_OWNER}}`, with no family name, domain or host name in
  its name, profile or description.
- Actions: **Disable for all repositories.** No runners, ever: a public repo
  must never reach a house runner.
- Block classic personal access tokens.
- Secret scanning and push protection on for new repositories.
- A public `{{PUBLIC_OWNER}}/.github` repo with `CONTRIBUTING.md`,
  `SECURITY.md` and `PULL_REQUEST_TEMPLATE.md`, written by hand and checked
  against the blocklist. They say: this is a published copy, one snapshot per
  release; PRs are tested privately and applied upstream with the contributor
  credited, then closed with a link (so they show as closed, not merged); one
  topic per PR, rebased on main, no `.github/` changes, no binaries; security
  reports go through private vulnerability reporting.

### Each public repo

- Create it **empty** and public: no README or licence from GitHub's form
  (the first publish refuses a `main` the publisher did not make), and never
  as a fork. Keep the description and topics free of house words.
- Issues on; Wiki, Projects and Discussions off. Private vulnerability
  reporting on. Push protection on. Dependabot *updates* off (they run on
  GitHub's cloud); Dependabot *alerts* belong on the private repo.
- **Rulesets on all branches and all tags:** restrict creations, updates and
  deletions, and block force pushes. Bypass: the deploy key only. If the free
  org's bypass list does not offer deploy keys: after the first publish, a
  ruleset that blocks creations, deletions and force pushes with no bypass,
  and leaves updates open.

### The deploy key, once per public repo

A deploy key reaches one repo, git only, never expires, and is the one
identity a ruleset can tell apart from the owner (who is an admin, so a token
of theirs would be let through everywhere).

1. `~/Projects/_template/publish/add-public-key.sh {{PROJECT}}` makes a key
   for this repo alone (mode 600, in `~/.config/publish/keys/`) and prints
   the two pastes with their links:
2. the public half on the public repo, Settings, Deploy keys, with **Allow
   write access**;
3. the private half in this repo's Settings, Secrets and variables, Actions,
   as `PUBLIC_DEPLOY_KEY`.
4. `add-public-key.sh --done {{PROJECT}}` asks GitHub which repo the key
   opens (a deploy key answers with the repo's name), then shreds the private
   half on disk once you confirm the secret is saved.

To rotate: the same steps with a new key, then delete the old deploy key.

## First publish

1. The blocklist exists on the CI box, and the template's mirror gates
   (`tests/mirror-gates.sh`) are green.
2. The public repo exists, empty and locked by its rulesets; the org shows
   Actions disabled.
3. The check job is green on `dev`, and the owner has read every listed file
   in full.
4. `LICENSE` names the handle. `README.md` stands alone: no links to private
   repos, nothing about the house.
5. The deploy key and the secret are set.
6. Release `dev` to `main` (the owner's approval), then click publish.
7. Afterwards: one commit, no parent, noreply author and committer, `+0000`,
   a `Source:` trailer, no `.github/`; the files equal the private ones;
   `https://github.com/{{PUBLIC_OWNER}}/{{PROJECT}}/commit/<private sha>` is a
   404; a test branch and a test tag pushed with the owner's own credentials
   are both rejected (push a one-file orphan commit from a scratch repo, never
   anything with private history).
8. Record the public counterpart in `~/Projects/CLAUDE.md`.

Every later publish: release as usual, read the check job's summary on
`main`, click publish. A file marked new is public for good.

## Taking in an outside PR

Code from a stranger runs only inside `scripts/sandbox.sh`, and not before the
CI runners have moved to their own unprivileged user (the owner's decision of
2026-10-24): that has to happen before the first outside PR.

1. On the box, with the owner present: `scripts/mirror.sh pr <N>`. It fetches
   the PR's patch anonymously and applies it on `contrib/pr-<N>` off `dev`,
   with hooks off. It refuses a copy or a rename (a copy names only its
   destination, so it could carry out a private file the contributor never
   saw), a path not in `PUBLISH` (or denied), a binary, a symlink, a commit
   that already carries a `Public-Credit` or `Public-PR` line (only `pr`
   writes those; git's own trailer parser is asked too), and a patch that
   does not apply: ask the contributor to rebase on public `main`.
2. **Nothing has run yet.** Read `git log -p --stat dev..contrib/pr-<N>` in
   full before anything runs it.
3. Push the branch. CI runs its tests inside `scripts/sandbox.sh` (a
   `--publish` scaffold's `ci.yml` does; an adopted one is ported to).
4. Merge into `dev`, release, click publish.
5. Close the PR by hand: "Applied upstream in `<public sha>`, thanks!"

A PR that adds a file: the owner first adds the path to `PUBLISH` in a private
commit of their own, after reading the file, then runs `pr` again.

## Credit

- `pr` remakes the contributor's commits as the house's fixed identity (the
  same trees, messages and dates), so their address never enters private
  history and the identity check lets the branch be pushed. It adds a
  `Public-Credit: Name <email>` trailer for each author, which becomes a
  `Co-authored-by:` line on the next public snapshot.
- To credit someone by hand, add that trailer to any commit before the
  release. Only the exact `Name <email>` form is taken; anything else stops
  the publish.
- Existing `Co-authored-by:` lines in private history are never harvested.

## Never on the public side

- House logs, hostnames, addresses or screenshots in an issue or a PR reply:
  they skip every gate.
- A workflow, a runner, a `public` remote, or a push by hand.
- A description, topic or org profile not checked against the blocklist.

## Running repo code: `scripts/sandbox.sh`

The CI runner's user is in the `docker` and `lxd` groups, which is root on the
box in all but name. Any step that runs this repo's code goes through
`scripts/sandbox.sh <command>`: no network but loopback; an empty `$HOME`,
`/home`, `/run`, `/tmp`, `/var/log`, `/mnt`, `/media` and `/srv`; no docker
or lxd socket; other processes out of sight; and only a short list of
variables, so no token in the environment gets in.

**The checkout is a throwaway copy:** the command can write to it, and every
write is gone when it exits. A writable checkout was a way out: code could
leave a hook or an `fsmonitor` in `.git`, or a changed script, for the next
git command or step outside to run with everything the sandbox hides. The
cost is that a build does not survive the call, so build and test in one
(`scripts/sandbox.sh sh -c 'npm run build && npm test'`). The gitignored
files that hold secrets (`.env`, `.env.*`, `mcp/.env`, `pi.md`, `data/`)
read as empty, as in a fresh clone.

It needs bwrap 0.10 or later (for the throwaway copy) and exits 2 rather
than run unsandboxed when `bwrap` is missing or older, or user namespaces
are off.

## If something leaked

Delete the public repo at once: GitHub keeps a removed commit reachable by its
SHA, so deleting the commit is not enough. Ask GitHub Support to purge cached
views, rotate anything that was a credential, add the string to the blocklist,
then create the repo again, empty, and publish again. Anything already cloned
or cached elsewhere stays out there, which is why every gate fails closed.
