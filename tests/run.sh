#!/usr/bin/env bash
# Every test of the template, in one run: what the template's CI runs, and
# what to run before pushing a change to the template.
#
#   tests/run.sh
#
#   1. tests/guard.sh         the deploy guard, against fake workspaces
#   2. tests/mirror-gates.sh  the public mirror's gates, on a throwaway fixture
#   3. tests/runner-kit.sh    runners/add-runner.sh refuses what it must, offline
#   4. the scaffold smoke     new-project.sh as a person runs it (new with
#      test, below            --publish, --adopt, --adopt --publish, --adopt
#                             --refresh) into a scratch folder, then the
#                             scaffold's own scripts/check.sh and pre-push hook
#                             on what it made. That is where the skeleton's
#                             workflows are linted: rendered, as a repo gets them.
#
# Needs git, docker (scripts/check.sh runs each linter in a pinned image) and
# bwrap (scripts/sandbox.sh). It touches no real repo, remote or token.
#
# Exit 0 = all passed, 1 = a test failed, 2 = a suite could not run.
set -euo pipefail

tpl=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

missing=()
for tool in git docker bwrap; do command -v "$tool" >/dev/null || missing+=("$tool"); done
(( ${#missing[@]} == 0 )) \
  || { echo "tests: missing ${missing[*]}; a suite that cannot run is not a pass" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/template-tests.XXXXXX")
trap 'rm -rf -- "$t"' EXIT

# --- the scaffold smoke test -----------------------------------------------------
# Runs in a subshell so its git settings stay its own. Called through suite(),
# which shellcheck cannot follow.
# shellcheck disable=SC2329
smoke() (
  set -eE
  # A step of the fixture itself failing is a broken test, not a failed check.
  trap 'echo "smoke: the fixture broke at line $LINENO" >&2; exit 2' ERR
  # None of this box's git config (a global hooksPath or signing key would
  # change the answer), and the house's fixed identity, which check.sh's
  # identity check holds every commit to.
  export GIT_CONFIG_GLOBAL=$t/gitconfig GIT_CONFIG_NOSYSTEM=1
  unset GITHUB_OWNER PUBLIC_OWNER GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE CHECK_RANGE CHECK_IMAGES
  printf '[user]\n\tname = AngryTechGremlin\n\temail = AngryTechGremlin@users.noreply.github.com\n[init]\n\tdefaultBranch = main\n' \
    >"$GIT_CONFIG_GLOBAL"

  np=$tpl/new-project.sh
  rows=()
  failed=0
  n=0
  out=""
  pass() { rows+=("PASS  $1"); }
  fail() { rows+=("FAIL  $1"); failed=1; }
  check() { # <case> <command...>: PASS when the command succeeds
    local name=$1
    shift
    if "$@"; then pass "$name"; else fail "$name"; fi
  }
  expect() { # <exit> <output regex> <case> <command...>; the output stays in $out
    local want=$1 re=$2 name=$3 rc=0
    shift 3
    out=$t/out.$((n += 1))
    "$@" >"$out" 2>&1 || rc=$?
    if (( rc != want )); then
      fail "$name: exit $rc, want $want"
    elif [[ -n $re ]] && ! grep -qE -- "$re" "$out"; then
      fail "$name: exit $rc, but no /$re/ in the output"
    else
      pass "$name (exit $rc)"
      return 0
    fi
    printf -- '--- %s\n' "$name" >&2
    sed 's/^/    | /' "$out" >&2
  }
  in_dir() { local d=$1; shift; (cd "$d" && "$@"); }
  # Workflows legitimately hold ${{ github.* }}, so only the template's own
  # placeholders, {{NAME}}, count as left behind.
  no_placeholders() {
    ! grep -rnE '\{\{[A-Z_]+\}\}' --exclude-dir=.git --exclude-dir=node_modules -- "$1" >&2
  }
  has_all() { # <dir> <path...>
    local d=$1 f gone=()
    shift
    for f; do [[ -e $d/$f ]] || gone+=("$f"); done
    (( ${#gone[@]} == 0 )) || { echo "missing: ${gone[*]}" >&2; return 1; }
  }
  has_none() { # <dir> <path...>
    local d=$1 f
    shift
    for f; do [[ ! -e $d/$f ]] || { echo "present: $f" >&2; return 1; }; done
  }
  all_exec() { # <dir> <path...>
    local d=$1 f
    shift
    for f; do [[ -x $d/$f ]] || { echo "not executable: $f" >&2; return 1; }; done
  }
  tracked_all() { # <repo> <path...>: each is in the index, so a commit carries it
    local d=$1 f gone=()
    shift
    for f; do git -C "$d" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || gone+=("$f"); done
    (( ${#gone[@]} == 0 )) || { echo "not committed (ignored?): ${gone[*]}" >&2; return 1; }
  }
  ignored_all() { # <repo> <path...>
    local d=$1 f
    shift
    for f; do git -C "$d" check-ignore -q -- "$f" || { echo "not ignored: $f" >&2; return 1; }; done
  }
  runs_on_only() { # <label> <workflow...>: every runs-on names that label alone
    local label=$1 f lines
    shift
    for f; do
      lines=$(grep 'runs-on:' "$f") || { echo "no runs-on in $f" >&2; return 1; }
      ! grep -vF "runs-on: [\"$label\"]" <<<"$lines" >&2 || { echo "^ a job in $f runs elsewhere" >&2; return 1; }
    done
  }
  lines_in() { # <file> <line...>: each is a whole line of the file
    local f=$1 l
    shift
    for l; do grep -qxF -- "$l" "$f" || { echo "no line '$l' in $f" >&2; return 1; }; done
  }
  no_branch() { ! git --git-dir="$1" show-ref -q --verify "refs/heads/$2"; }
  refreshed_nothing() { # <refresh output> <managed file count>
    [[ $(grep -c '^  unchanged: ' "$1") == "$2" ]] && ! grep -q 'refreshed: ' "$1"
  }
  commit() { git -C "$1" add -A && git -C "$1" commit -q -m "$2"; }
  # publish.yml's hash lines, checked against the scaffold's own scripts.
  pins_match() { # <repo>
    awk '/sha256sum --check/ { f = 1; next } f && /EOF/ { f = 0 } f { sub(/^ +/, ""); print }' \
      "$1/.github/workflows/publish.yml" | sort -u >"$t/pins"
    [[ $(wc -l <"$t/pins") == 2 ]] || { echo "want 2 pinned scripts in publish.yml" >&2; return 1; }
    (cd "$1" && sha256sum --check --strict --quiet "$t/pins")
  }

  # Everything a new scaffold with the mirror kit is meant to carry, and the
  # part of it a commit must never carry.
  ships=(agent.md CLAUDE.md README.md .env.example .gitignore .mcp.json .vscode/mcp.json
    .claude/settings.json docs/adr/README.md docs/adr/0001-scaffolded-from-the-projects-template.md
    docs/ci-runner.md docs/publishing.md PUBLISH .githooks/pre-push
    .github/workflows/ci.yml .github/workflows/weekly.yml .github/workflows/publish.yml
    scripts/pii-scan.sh scripts/pii-scan.exclude scripts/check.sh scripts/check-tools.env
    scripts/git-credential-github.sh scripts/mirror.sh scripts/sandbox.sh mcp/README.md mcp/package.json)
  private=(.env pi.md mcp/.env)
  execs=(.githooks/pre-push scripts/pii-scan.sh scripts/check.sh scripts/git-credential-github.sh
    scripts/mirror.sh scripts/sandbox.sh)
  kit=(PUBLISH scripts/mirror.sh scripts/sandbox.sh .github/workflows/publish.yml docs/publishing.md)

  # A flag that would hand one repo another's token is gone. --dir keeps even
  # a wrong turn inside the scratch folder.
  expect 2 'unknown option: --reuse-token' '--reuse-token is refused' \
    "$np" gone --dir "$t/gone" --reuse-token
  check "  ...and nothing was made" test ! -e "$t/gone"

  # --- new, with the mirror kit, so every skeleton workflow is rendered ---------
  s=$t/smoke
  expect 0 'git switch -c dev' 'new smoke --publish' "$np" smoke --dir "$s" --publish --no-build
  check "new: no {{PLACEHOLDER}} left" no_placeholders "$s"
  check "new: every skeleton file, and the gitignored trio" has_all "$s" "${ships[@]}" "${private[@]}"
  check "new: scripts and the hook are executable" all_exec "$s" "${execs[@]}"
  check "new: a repo on main, hooks from .githooks" \
    test "$(git -C "$s" symbolic-ref --short HEAD) $(git -C "$s" config core.hooksPath)" = "main .githooks"
  check "new: PUBLISH publishes to techthatworks/smoke" \
    test "$(git config --file "$s/PUBLISH" --get publish.repo)" = techthatworks/smoke
  check "new: every job runs on smoke-ci and nowhere else" \
    runs_on_only smoke-ci "$s"/.github/workflows/{ci,weekly,publish}.yml
  check "new: publish.yml's hashes pin this mirror.sh and pii-scan.sh" pins_match "$s"
  check "new: a publishing repo's ci.yml runs its tests in the sandbox, installs with no scripts" \
    lines_in "$s/.github/workflows/ci.yml" \
    '      #     scripts/sandbox.sh python -m unittest discover -s tests -v' \
    '      #     npm ci --ignore-scripts            # fails if package-lock.json and package.json disagree'
  expect 0 '^pii-scan: clean' "new: the scaffold's own scripts/pii-scan.sh is clean" in_dir "$s" scripts/pii-scan.sh
  git -C "$s" add -A
  check "new: .env, pi.md and mcp/.env stay ignored" ignored_all "$s" "${private[@]}"
  check "new: the first commit carries every skeleton file" tracked_all "$s" "${ships[@]}"
  # The next steps new-project.sh prints, with the attribution trailer a
  # session's commits carry (a tool's noreply@ address is a fine co-author).
  git -C "$s" commit -q -m 'chore: scaffold from the Projects template' \
    -m 'Co-Authored-By: Claude <noreply@anthropic.com>'
  git -C "$s" switch -q -c dev
  expect 0 'ok  actionlint \(3 workflows\)' 'new: scripts/check.sh fast passes and lints all 3 workflows' \
    in_dir "$s" scripts/check.sh fast
  check "  ...and zizmor read all 3" grep -qE 'ok  zizmor \(3 files\)' "$out"

  # --- the pre-push hook, on real pushes to local bare repos --------------------
  git init -q --bare "$t/origin.git"
  git init -q --bare "$t/other.git"
  git -C "$s" remote add origin "$t/origin.git"
  expect 0 'ok  commit identity' 'push: dev reaches origin after check.sh fast' git -C "$s" push origin dev
  check "  ...origin has dev" git --git-dir="$t/origin.git" show-ref -q --verify refs/heads/dev
  expect 1 'refusing to push' "push: any URL but origin's is refused" git -C "$s" push "$t/other.git" dev
  check "  ...the other repo got nothing" test -z "$(git --git-dir="$t/other.git" for-each-ref)"
  # A private address in a doc, built here so this file holds none.
  git -C "$s" switch -q -c leak
  printf 'The router is at %s.\n' "$(printf '192.168.%d.%d' 1 10)" >"$s/docs/network.md"
  commit "$s" 'docs: where the router is'
  expect 1 'FAIL pii-scan' 'push: a private address in docs/ is refused' git -C "$s" push origin leak
  check "  ...origin has no leak branch" no_branch "$t/origin.git" leak
  # Origin itself pointed at the public side: the hook still says no. The
  # URL is never contacted; the hook refuses before git would.
  git -C "$s" remote set-url --push origin https://github.com/techthatworks/smoke.git
  expect 1 'the public side' 'push: origin pointed at the public org is refused' \
    in_dir "$s" .githooks/pre-push origin https://github.com/techthatworks/smoke.git
  git -C "$s" config --unset remote.origin.pushurl

  # --- what check.sh fast catches beyond files ----------------------------------
  git -C "$s" switch -q -c probe dev
  printf 'notes\n' >"$s/notes.md"
  git -C "$s" add notes.md
  GIT_AUTHOR_NAME='Jane Q Realname' git -C "$s" commit -q -m "docs: notes from $(printf '192.168.%d.%d' 1 50)" \
    -m 'Co-authored-by: Pat <pat@example.com>'
  printf 'abc123:generic-api-key:x.txt:1\n' >"$s/.gitleaksignore"   # an allowlist CI never sees
  expect 1 'FAIL commit identity' "check: a real name, a non-noreply co-author, an address in a message, an uncommitted allowlist" \
    in_dir "$s" env CHECK_RANGE=dev..probe scripts/check.sh fast
  check "  ...the author's name is caught" grep -q 'author is not a GitHub handle' "$out"
  check "  ...the co-author is caught" grep -q 'Co-authored-by is neither' "$out"
  check "  ...the message's address is caught" grep -q 'FAIL commit messages' "$out"
  check "  ...the uncommitted .gitleaksignore is caught" grep -qE '^    \?\? \.gitleaksignore' "$out"
  rm -f -- "$s/.gitleaksignore"
  git -C "$s" reset -q --hard dev
  # One .gitattributes line once made git call every file binary, blinding
  # both the PII scan and gitleaks. The token is built here.
  printf 'TOKEN = "%s"\n' "ghp_$(printf '%s' aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hJ6)" >"$s/settings.py"
  printf '* -diff\n' >"$s/.gitattributes"
  commit "$s" 'chore: settings'
  expect 1 'FAIL gitleaks new commits' 'check: * -diff in .gitattributes blinds neither gitleaks nor the PII scan' \
    in_dir "$s" env CHECK_RANGE=dev..probe scripts/check.sh fast
  check "  ...the PII scan still sees the token" grep -q 'FAIL pii-scan' "$out"
  git -C "$s" reset -q --hard dev
  printf '*\n' >"$s/scripts/pii-scan.exclude"
  expect 2 'no file left to scan' 'pii-scan: an exclude file that excludes everything is an error' in_dir "$s" scripts/pii-scan.sh
  git -C "$s" checkout -q -- scripts/pii-scan.exclude
  git -C "$s" switch -q dev
  git -C "$s" branch -q -D probe

  # --- adopt an existing repo, then add the kit, then refresh --------------------
  a=$t/adopted
  git init -q "$a"
  printf '# adopted\n\nAn existing project.\n' >"$a/README.md"
  # *.env, as a dozen house repos have it: it would also ignore the tool pins.
  printf 'node_modules/\n*.env\n' >"$a/.gitignore"
  commit "$a" 'feat: an existing project'
  expect 0 'adopting shared tooling into adopted' 'adopt: an existing repo' "$np" --adopt "$a" --no-build
  check "adopt: its README.md is left alone" grep -qx 'An existing project.' "$a/README.md"
  check "adopt: the checks, the hook, the workflows and the runner doc" has_all "$a" \
    scripts/pii-scan.sh scripts/check.sh scripts/check-tools.env .githooks/pre-push \
    .github/workflows/ci.yml .github/workflows/weekly.yml docs/ci-runner.md
  check "adopt: no mirror kit unasked" has_none "$a" "${kit[@]}"
  check "adopt: the ignore rules the tooling needs were appended" lines_in "$a/.gitignore" .env pi.md mcp/.env
  check "adopt: no {{PLACEHOLDER}} left" no_placeholders "$a"
  commit "$a" 'chore: adopt shared dev tooling'
  check "adopt: a repo that ignores *.env still commits scripts/check-tools.env" tracked_all "$a" scripts/check-tools.env
  check "adopt: ci.yml's tests run plainly in a repo that does not publish" \
    lines_in "$a/.github/workflows/ci.yml" '      #     python -m unittest discover -s tests -v'
  expect 0 'ok  actionlint \(2 workflows\)' 'adopt: scripts/check.sh fast passes' in_dir "$a" scripts/check.sh fast

  expect 0 'publishes to techthatworks/adopted' 'adopt --publish: adds the mirror kit' \
    "$np" --adopt "$a" --publish --no-build
  check "adopt --publish: the five kit files" has_all "$a" "${kit[@]}"
  check "adopt --publish: no {{PLACEHOLDER}} left" no_placeholders "$a"
  commit "$a" 'chore: add the public-mirror kit'

  expect 0 'unchanged: docs/publishing\.md' 'refresh: straight after adopting' "$np" --adopt "$a" --refresh --no-build
  check "refresh: all 8 managed files unchanged, none rewritten" refreshed_nothing "$out" 8
  check "refresh: the tree is still clean" test -z "$(git -C "$a" status --porcelain)"
  printf '# a local edit\n' >>"$a/scripts/check.sh"
  expect 2 'refusing --refresh' 'refresh: refused while a managed file has uncommitted edits' \
    "$np" --adopt "$a" --refresh --no-build
  check "  ...and the edit is still there" grep -qx '# a local edit' "$a/scripts/check.sh"

  printf '\nscaffold smoke\n'
  printf '  %s\n' "${rows[@]}"
  bad=$(printf '%s\n' "${rows[@]}" | grep -c '^FAIL' || true)
  printf '\n%s of %s passed\n' "$(( ${#rows[@]} - bad ))" "${#rows[@]}"
  exit "$failed"
)

# --- run every suite ---------------------------------------------------------------
summary=()
worst=0
suite() { # <name> <command...>
  local name=$1 rc=0 start=$SECONDS
  shift
  printf '\n=== %s\n' "$name"
  # Not `"$@" || rc=$?`: bash ignores set -e for anything run from a || list,
  # and the smoke test relies on it to stop when its own fixture breaks.
  set +e
  "$@"
  rc=$?
  set -e
  case $rc in
    0) summary+=("PASS  $name ($((SECONDS - start)) s)") ;;
    1) summary+=("FAIL  $name") ; worst=1 ;;
    *) summary+=("ERROR $name could not run (exit $rc)") ; (( worst == 1 )) || worst=2 ;;
  esac
}

suite "deploy guard" bash "$tpl/tests/guard.sh"
suite "mirror gates" bash "$tpl/tests/mirror-gates.sh"
suite "runner kit" bash "$tpl/tests/runner-kit.sh"
suite "scaffold smoke" smoke

printf '\n=== summary\n'
printf '  %s\n' "${summary[@]}"
exit "$worst"
