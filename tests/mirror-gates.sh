#!/usr/bin/env bash
# Prove the public mirror's gates (skel/scripts/mirror.sh) on a throwaway
# fixture: a private repo made from the skeleton's own scripts, a made-up
# blocklisted word, a local bare repo standing in for the public one, and a
# fake contributor's patch. No network, no real repo, no real blocklist.
#
#   tests/mirror-gates.sh
#
# Exit 0 = every case behaved, 1 = at least one did not, 2 = setup error.
#
# Single-quoted snippets run in a child bash with their own $1 (SC2016), and
# some helpers are only ever called through check() (SC2329).
# shellcheck disable=SC2016,SC2329
set -euo pipefail

tpl=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
skel=$tpl/skel
for f in scripts/mirror.sh scripts/pii-scan.sh scripts/sandbox.sh scripts/pii-scan.exclude PUBLISH; do
  [[ -f $skel/$f ]] || { echo "mirror-gates: missing skel/$f" >&2; exit 2; }
done

t=$(mktemp -d "${TMPDIR:-/tmp}/mirror-gates.XXXXXX")
trap 'rm -rf -- "$t"' EXIT
# A step of the fixture itself failing is a broken test, not a failed gate.
trap 'echo "mirror-gates: the fixture broke at line $LINENO" >&2; exit 2' ERR

# None of this machine's git config, and made-up people, so the result does
# not depend on whose box runs it.
export GIT_CONFIG_GLOBAL=$t/gitconfig GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GITHUB_REF GITHUB_STEP_SUMMARY PUBLIC_DEPLOY_KEY \
  PUBLISH_TEST_REMOTE PUBLISH_TEST_PATCH PUBLISH_BLOCKLIST
cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = Fixture Owner
	email = owner@example.org
[init]
	defaultBranch = main
[advice]
	detachedHead = false
EOF

word=zorblatt-house     # made up; the blocklist's one entry
pub=$t/public.git       # stands in for the public repo
priv=$t/priv
ident='AngryTechGremlin <AngryTechGremlin@users.noreply.github.com>'
# A CR, padding, a comment and another case: normalising must still match.
printf '# made-up entries for the fixture\r\n   Zorblatt-House   # padded\r\n\r\n' >"$t/blocklist"

rows=()
failed=0
pass() { rows+=("PASS  $1"); }
fail() { rows+=("FAIL  $1"); failed=1; }
check() { # <case> <command...>: PASS when the command succeeds
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

# The fixture's own copy of mirror.sh, run in the private repo. BL, PUB and
# PATCH override the blocklist, the public stand-in (empty: none) and the PR
# patch for one call.
mirror() { # <outfile> <mirror args...>
  local out=$1
  shift
  (
    cd "$priv"
    export TMPDIR=$t/mirror-tmp PUBLISH_BLOCKLIST=${BL:-$t/blocklist}
    unset RUNNER_TEMP
    if [[ -n ${PUB-$pub} ]]; then export PUBLISH_TEST_REMOTE=${PUB-$pub}; fi
    if [[ -n ${PATCH:-} ]]; then export PUBLISH_TEST_PATCH=$PATCH; fi
    exec scripts/mirror.sh "$@"
  ) >"$out" 2>&1
}
n=0
expect() { # <exit> <output regex> <case> <mirror args...>
  local want=$1 re=$2 name=$3 rc=0 out
  shift 3
  out=$t/out.$((n += 1))
  mirror "$out" "$@" || rc=$?
  if grep -qi -- "$word" "$out"; then
    fail "$name: the output printed the blocklisted word"
  elif (( rc != want )); then
    fail "$name: exit $rc, want $want"
  elif ! grep -qE -- "$re" "$out"; then
    fail "$name: exit $rc, but no /$re/ in the output"
  else
    pass "$name (exit $rc)"
    return 0
  fi
  printf -- '--- %s\n' "$name" >&2
  sed 's/^/    | /' "$out" >&2
}

g() { git -C "$priv" "$@"; }
publish_list() { # <path...>: PUBLISH listing exactly these
  { printf '[publish]\n\trepo = techthatworks/demo\n'; printf '\tpath = %s\n' "$@"; } >"$priv/PUBLISH"
}
on_case() { # a fresh branch off main, nothing left over from the last case
  g switch -q -f -C case main
  g clean -qfd
  mkdir -p "$priv/docs"
}
commit() { g add -A && g commit -q "$@"; }
pub_log() { git -C "$pub" log -1 --format="$1" main; }
same_tree() { # <public rev> <private rev> <paths...>: identical modes, blobs and names
  [[ $(git -C "$pub" ls-tree -r "$1") == "$(g ls-tree -r "$2" -- "${@:3}")" ]]
}
only_reachable() { # the public repo holds nothing its refs do not reach
  [[ -z $(comm -23 <(git -C "$pub" cat-file --batch-all-objects --batch-check='%(objectname)' | sort -u) \
    <(git -C "$pub" rev-list --objects --all | cut -d' ' -f1 | sort -u)) ]]
}
absent() { ! git -C "$pub" cat-file -e "$1" 2>/dev/null; }

# --- the fixture ---------------------------------------------------------------
mkdir "$t/mirror-tmp"
git init -q "$priv"
mkdir -p "$priv/scripts" "$priv/src" "$priv/tests" "$priv/docs" "$priv/.github/workflows"
cp "$skel"/scripts/{mirror.sh,pii-scan.sh,sandbox.sh,pii-scan.exclude} "$priv/scripts/"
printf '# demo\n\nA small fixture.\n' >"$priv/README.md"
printf 'MIT License\n\nCopyright (c) 2026 AngryTechGremlin\n' >"$priv/LICENSE"
printf 'def add(a, b):\n    return a + b\n' >"$priv/src/app.py"
printf 'HOST = "192.0.2.10"  # a documentation address\n' >"$priv/tests/test_app.py"
printf '.env\n' >"$priv/.gitignore"
printf 'notes for agents, never public\n' >"$priv/agent.md"
printf 'name: ci\n' >"$priv/.github/workflows/ci.yml"
printf 'only ever private\n' >"$priv/notes.txt"
base=(README.md LICENSE src/app.py tests/test_app.py .gitignore)
publish_list "${base[@]}"
commit -m 'feat: the fixture'
git init -q --bare "$t/origin.git"
g remote add origin "$t/origin.git"
g push -q origin main
git init -q --bare "$pub"

# The skeleton's PUBLISH, filled in as new-project.sh --publish fills it.
sed -e 's/{{PUBLIC_OWNER}}/techthatworks/g' -e 's/{{PROJECT}}/demo/g' "$skel/PUBLISH" >"$t/skel-PUBLISH"
check "skel PUBLISH reads as repo techthatworks/demo with README.md and LICENSE" \
  test "$(git config --file "$t/skel-PUBLISH" --get publish.repo) $(git config --file "$t/skel-PUBLISH" --get-all publish.path | tr '\n' ' ')" \
  = "techthatworks/demo README.md LICENSE "

# --- setup errors: exit 2 ----------------------------------------------------------
expect 2 'usage' 'no command'
expect 2 'usage' 'an unknown command' push
BL=$t/missing expect 2 'no blocklist at' 'a missing blocklist' check
printf '# only a comment\n\n' >"$t/bl-empty"
BL=$t/bl-empty expect 2 'no entries' 'a blocklist with no entries' check
printf 'abc\nlong-enough\n' >"$t/bl-short"
BL=$t/bl-short expect 2 'line\(s\) 1 are under 4' 'a blocklist entry under 4 characters' check
check "nothing reached the public stand-in yet" test -z "$(git -C "$pub" for-each-ref)"

# --- a clean publish, then a no-op -----------------------------------------------
priv1=$(g rev-parse main)
expect 0 '^published ' 'first publish' publish
p1=$(git -C "$pub" rev-parse -q --verify main || true)
check "first publish: one commit, no parent" test "$(git -C "$pub" rev-list --parents main 2>/dev/null)" = "$p1"
check "first publish: author and committer are the fixed noreply identity" test "$(pub_log '%an <%ae>|%cn <%ce>')" = "$ident|$ident"
check "first publish: both dates are +0000" bash -c '[[ $1 == *" +0000|"*" +0000" ]]' _ "$(pub_log '%ai|%ci')"
check "first publish: message is the fixed text and a full Source" \
  test "$(pub_log %B)" = "$(printf 'chore: publish snapshot\n\nSource: %s' "$priv1")"
check "first publish: tree is the PUBLISH files, byte for byte" same_tree main "$priv1" "${base[@]}"
check "first publish: no .github/, agent.md or private-only file" \
  test "$(git -C "$pub" ls-tree -r --name-only main | tr '\n' ' ')" = ".gitignore LICENSE README.md src/app.py tests/test_app.py "
check "first publish: the private commit is absent" absent "$priv1"
check "first publish: private-only blobs are absent" \
  bash -c 'for b; do ! git -C "'"$pub"'" cat-file -e "$b" 2>/dev/null || exit 1; done' _ \
  "$(g rev-parse main:notes.txt)" "$(g rev-parse main:agent.md)" "$(g rev-parse main:PUBLISH)"
check "first publish: the public repo holds only what main reaches" only_reachable
expect 0 'already published' 'a re-run is a no-op' publish
check "re-run: still one commit" test "$(git -C "$pub" rev-list --count main)" = 1
# A caller's `git -c url...insteadOf` would aim the scratch repo at another
# remote, which would then get a first publish of its own.
git init -q --bare "$t/elsewhere.git"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$t/elsewhere.git.insteadOf" GIT_CONFIG_VALUE_0="$pub" \
  expect 0 'already published' "a caller's git -c settings do not reach the scratch repo" publish
check "  ...and the other remote got nothing" test -z "$(git -C "$t/elsewhere.git" for-each-ref)"

# --- a second publish, with credit ------------------------------------------------
printf 'def add(a, b):\n    """Sum."""\n    return a + b\n' >"$priv/src/app.py"
commit -m 'docs: say what add does' -m 'Public-Credit: Ada Lovelace <ada@example.org>'
g push -q origin main
priv2=$(g rev-parse main)
expect 0 '^published ' 'second publish' publish
check "second publish: its parent is the first snapshot" test "$(git -C "$pub" rev-parse -q --verify main^ || true)" = "$p1"
check "second publish: Source plus Co-authored-by from Public-Credit" \
  test "$(pub_log %B)" = "$(printf 'chore: publish snapshot\n\nSource: %s\nCo-authored-by: Ada Lovelace <ada@example.org>' "$priv2")"
check "second publish: tree is the PUBLISH files" same_tree main "$priv2" "${base[@]}"
check "second publish: private commits are absent" absent "$priv2"
check "second publish: the public repo holds only what main reaches" only_reachable
p2=$(git -C "$pub" rev-parse main)

# --- publish only from main at origin/main, only in CI ----------------------------
on_case
printf 'more\n' >>"$priv/README.md"
commit -m 'docs: more'
expect 2 'not origin/main' 'publish from a commit that is not origin/main' publish
g switch -q -f main
PUB='' expect 2 'only on main, in CI' 'publish outside CI' publish
PUB='' GITHUB_REF=refs/heads/main expect 2 'PUBLIC_DEPLOY_KEY is not set' 'publish without the deploy key' publish

# --- check: the preview --------------------------------------------------------
on_case
printf '# Guide\n' >"$priv/docs/guide.md"
publish_list "${base[@]}" docs/guide.md
commit -m 'docs: a guide'
GITHUB_STEP_SUMMARY=$t/summary.md expect 0 'check passed: 6 files' 'check previews a new file' check
check "check: the job summary flags the new file as permanently public" \
  grep -qE 'A  docs/guide\.md .*permanently public' "$t/summary.md"
check "check: the job summary lists all 6 files that would be public" \
  test "$(sed -n '/<details>/,/<\/details>/p' "$t/summary.md" | grep -cxE '[^ <`].*')" = 6
check "check: nothing was pushed" test "$(git -C "$pub" rev-parse main)" = "$p2"
PUB=$t/not-made-yet.git expect 0 'WARNING: the public repo could not be read' \
  'check before the public repo exists: a flagged preview' check
g switch -q -f main
PUB=$t/not-made-yet.git expect 2 'cannot read .* anonymously' 'publish before the public repo exists' publish

# --- gates that must refuse: exit 1 -----------------------------------------------
on_case
printf 'Ask the %s admin.\n' "$word" >>"$priv/README.md"
commit -m 'docs: x'
expect 1 'README\.md:4' 'the word in a published file' check
# The byte-order mark some editors put first must not hide the first entry.
printf '\357\273\277Zorblatt-House\n' >"$t/bl-bom"
BL=$t/bl-bom expect 1 'README\.md:4' 'the word, with a byte-order mark before its blocklist entry' check

on_case
printf 'notes\n' >"$priv/docs/$word-notes.md"
publish_list "${base[@]}" "docs/$word-notes.md"
commit -m 'docs: x'
expect 1 'public name matches the blocklist' 'the word in a published file name' check

on_case
printf '# touched\n' >>"$priv/src/app.py"
commit -m 'fix: x' -m 'Public-Credit: Zorblatt-House Fan <fan@example.org>'
expect 1 'commit message matches the blocklist' 'the word in a Public-Credit trailer' check

on_case
printf '# touched\n' >>"$priv/src/app.py"
commit -m 'fix: x' -m 'Public-Credit: no address given'
expect 1 "is not 'Name <email>'" 'a malformed Public-Credit trailer' check

on_case
# Built here, so this file holds no private address of its own.
printf 'ROUTER = "%s"\n' "$(printf '10.%d.%d.%d' 1 2 3)" >>"$priv/tests/test_app.py"
commit -m 'test: x'
expect 1 'RFC1918' 'an RFC1918 address under tests/' check
check "  ...which the private scan exempts as a test path" bash -c 'cd "$1" && scripts/pii-scan.sh >/dev/null' _ "$priv"

on_case
printf 'The box is %s, mail pat@mail.test, the share example-box.lan.\n' "$(printf '100.%d.%d.%d' 101 102 103)" >>"$priv/README.md"
commit -m 'docs: x'
expect 1 'CGNAT' 'public-only shapes: a CGNAT address, an email, a .lan name' check
check "  ...each one named" bash -c 'grep -q "email address" "$1" && grep -q "internal host name" "$1"' _ "$t/out.$n"
check "  ...which the private scan lets through" bash -c 'cd "$1" && scripts/pii-scan.sh >/dev/null' _ "$priv"

on_case
printf 'GATEWAY_URL = "http://host.docker.internal:4000/v1"\n' >>"$priv/README.md"
commit -m 'docs: x'
expect 0 '.' "Docker's host.docker.internal names no one's house" check

on_case
printf 'Try host.docker.internal, else example-box.lan.\n' >>"$priv/README.md"
commit -m 'docs: x'
expect 1 'internal host name' '  ...but another internal name on the same line still fails' check

on_case
printf 'README.md working-tree-encoding=UTF-16LE\n' >"$priv/.gitattributes"
blob=$(printf '# demo\n\nAsk the %s admin.\n' "$word" | g hash-object -w --no-filters --stdin)
g update-index --cacheinfo "100644,$blob,README.md"
publish_list "${base[@]}" .gitattributes
g add PUBLISH .gitattributes
# The commit's index refresh cannot encode the plain README on disk; it says so
# and goes on, which is the point.
g commit -q -m 'chore: x' 2>/dev/null
expect 1 'README\.md:3' 'the word, hidden from a checkout by .gitattributes' check

on_case
publish_list "${base[@]}" agent.md
commit -m 'chore: x'
expect 1 'agent\.md: on the deny list' 'a denied path (agent.md)' check

on_case
printf 'notes for another agent\n' >"$priv/AGENTS.md"
publish_list "${base[@]}" AGENTS.md
commit -m 'chore: x'
expect 1 'AGENTS\.md: on the deny list' 'a denied path (AGENTS.md)' check

on_case
publish_list "${base[@]}" .github/workflows/ci.yml
commit -m 'chore: x'
expect 1 'ci\.yml: on the deny list' 'a denied path (.github/)' check

on_case
printf 'The ranges: 10.0.0.0/8.\n' >"$priv/docs/primer.md"
printf 'docs/primer.md   # the ranges are the subject\n' >>"$priv/scripts/pii-scan.exclude"
publish_list "${base[@]}" docs/primer.md
commit -m 'docs: x'
expect 1 'pii-scan\.exclude keeps from the scan' 'a path the private scan excludes' check

on_case
ln -s README.md "$priv/link.md"
publish_list "${base[@]}" link.md
commit -m 'chore: x'
expect 1 'link\.md: a symlink' 'a symlink' check

on_case
printf 'PK\003\004\000\000' >"$priv/asset.bin"
publish_list "${base[@]}" asset.bin
commit -m 'chore: x'
expect 1 'asset\.bin: binary' 'a binary' check

on_case
printf 'text\000more\n' >"$priv/blob.txt"
printf 'blob.txt diff\n' >"$priv/.gitattributes"
publish_list "${base[@]}" blob.txt
commit -m 'chore: x'
expect 1 'blob\.txt: binary' 'a binary that .gitattributes calls text' check

on_case
publish_list "${base[@]}" src
commit -m 'chore: x'
expect 1 'src: a folder' 'a folder entry' check

on_case
publish_list README.md LICENSE '*.py'
commit -m 'chore: x'
expect 1 'not a literal file path' 'a glob entry' check

on_case
publish_list "${base[@]}" src/../notes.txt
commit -m 'chore: x'
expect 1 'not a literal file path' "a '..' entry" check

on_case
publish_list "${base[@]}" ':(top)notes.txt'
commit -m 'chore: x'
expect 1 'not a literal file path' 'a pathspec-magic entry' check

on_case
publish_list "${base[@]}" gone.txt
commit -m 'chore: x'
expect 1 'gone\.txt: not in' 'a stale entry' check

on_case
publish_list "${base[@]}" README.md
commit -m 'chore: x'
expect 1 'listed twice' 'a duplicate entry' check

on_case
publish_list README.md src/app.py
commit -m 'chore: x'
expect 1 'LICENSE is not in PUBLISH' 'no LICENSE' check

on_case
printf '\tpaths = typo.txt\n' >>"$priv/PUBLISH"
commit -m 'chore: x'
expect 1 'other than \[publish\] repo and path' 'an unknown PUBLISH setting' check

on_case
sed -i 's|techthatworks/demo|{{PUBLIC_OWNER}}/demo|' "$priv/PUBLISH"
commit -m 'chore: x'
expect 1 'not <owner>/<name>' 'an unfilled repo placeholder' check

# The public side, as if someone wrote to it by hand. Each case gets its own
# copy, so the real stand-in keeps only what the publisher put there.
g switch -q -f main
side=$(g commit-tree -m 'a side line' "$(g rev-parse 'main^{tree}')")
g update-ref refs/heads/side "$side"
forge() { # <copy> <author> <message>: a hand-made commit on the copy's main
  local copy=$1 who=$2 msg=$3 c
  cp -a "$pub" "$copy"
  c=$(GIT_AUTHOR_NAME=${who% <*} GIT_AUTHOR_EMAIL=${who##*<} GIT_COMMITTER_NAME=${who% <*} \
    GIT_COMMITTER_EMAIL=${who##*<} git -C "$copy" commit-tree -p main -m "$msg" "main^{tree}")
  git -C "$copy" update-ref refs/heads/main "$c"
}
pubid="AngryTechGremlin <AngryTechGremlin@users.noreply.github.com"
forge "$t/f1.git" "$pubid" "$(printf 'chore: publish snapshot\n\nSource: %s' "$side")"
PUB=$t/f1.git expect 1 'is not an ancestor' 'a Source that is not an ancestor' check
forge "$t/f2.git" "$pubid" "$(printf 'chore: publish snapshot\n\nSource: %s' "$(printf '%040d' 7)")"
PUB=$t/f2.git expect 1 'not a commit in this repo' 'a Source that is no commit here' check
forge "$t/f3.git" "$pubid" "$(printf 'chore: publish snapshot\n\nSource: %.12s' "$priv2")"
PUB=$t/f3.git expect 1 'no single full-length Source' 'a short Source' check
forge "$t/f4.git" "Someone Else <someone@example.org" "$(printf 'fix: by hand\n\nSource: %s' "$priv2")"
PUB=$t/f4.git expect 1 'not made by this publisher' 'a public commit made by hand' check

# --- taking in an outside PR -----------------------------------------------------
g switch -q -f main
g branch -f dev main
g switch -q dev
contrib=$t/contrib
git clone -q "$pub" "$contrib"
git -C "$contrib" config user.name 'Pat Contributor'
git -C "$contrib" config user.email 'pat@example.org'
pr_patch() { # <outfile>: the contributor's last commit as GitHub serves a PR's .patch
  git -C "$contrib" format-patch -1 --stdout >"$1"
}
printf 'def add(a, b):\n    """Sum."""\n    return b + a\n' >"$contrib/src/app.py"
git -C "$contrib" commit -qam 'fix: add in the other order'
pr_patch "$t/pr1.patch"
PATCH=$t/pr1.patch expect 0 'NOTHING HAS RUN YET' 'pr: a fix to a published file' pr 1
msg=$(g log -1 --format=%B contrib/pr-1)
check "pr: contrib/pr-1 is remade as the fixed identity, author and committer" \
  test "$(g log --format='%an <%ae>|%cn <%ce>' dev..contrib/pr-1 | sort -u)" = "$ident|$ident"
check "pr: ...with the contributor's change and message intact" \
  test "$(g log -1 --format=%s contrib/pr-1) $(g diff dev contrib/pr-1 -- src/app.py | grep -c '^+    return b + a')" = "fix: add in the other order 1"

check "pr: a Public-PR trailer" grep -qx 'Public-PR: https://github.com/techthatworks/demo/pull/1' <<<"$msg"
check "pr: a Public-Credit trailer" grep -qx 'Public-Credit: Pat Contributor <pat@example.org>' <<<"$msg"
check "pr: only src/app.py changed" test "$(g diff --name-only dev contrib/pr-1)" = src/app.py
expect 2 'already exists' 'pr: the same number twice' pr 1
g switch -q dev

git -C "$contrib" reset -q --hard origin/main
printf 'new\n' >"$contrib/extra.txt"
git -C "$contrib" add extra.txt
git -C "$contrib" commit -qm 'feat: a new file'
pr_patch "$t/pr2.patch"
PATCH=$t/pr2.patch expect 1 'not in PUBLISH' 'pr: a file not in PUBLISH' pr 2
pr_undone() {
  ! g rev-parse -q --verify refs/heads/contrib/pr-2 >/dev/null \
    && [[ $(g symbolic-ref --short HEAD) == dev && -z $(g status --porcelain) && ! -e $priv/extra.txt ]]
}
check "pr refused: no branch left, back on dev, tree clean" pr_undone

git -C "$contrib" reset -q --hard origin/main
printf '# touched\n' >>"$contrib/src/app.py"
git -C "$contrib" commit -qam 'fix: x' -m 'Public-Credit: Mallory <mallory@example.org>'
pr_patch "$t/pr3.patch"
PATCH=$t/pr3.patch expect 1 'already carries a Public-Credit' 'pr: a contributor-written credit trailer' pr 3

# Git's own parser takes this as a trailer, and publish reads it with that.
git -C "$contrib" reset -q --hard origin/main
printf '# touched\n' >>"$contrib/src/app.py"
git -C "$contrib" commit -qam 'fix: x' -m 'Public-Credit : Mallory Forged <mallory@example.org>'
pr_patch "$t/pr3b.patch"
PATCH=$t/pr3b.patch expect 1 'already carries a Public-Credit' 'pr: a credit trailer with a space before its colon' pr 31

# A copy names only its destination: README.md here, filled from agent.md,
# a private file the contributor has never seen. They can write that patch by
# hand; git writes the same text here, from a branch that is then dropped.
g switch -q -c attack dev
g rm -q README.md
g commit -qm 'docs: drop the readme'
cp "$priv/agent.md" "$priv/README.md"
g add README.md
g commit -qm 'docs: a readme'
g format-patch -2 -C -C --stdout >"$t/pr5.patch"
g switch -q dev
g branch -q -D attack
check "the copy fixture is a copy of agent.md" grep -qx 'copy from agent.md' "$t/pr5.patch"
PATCH=$t/pr5.patch expect 1 'copies or renames a file' 'pr: a copy of a private file onto a published path' pr 5
check "  ...and nothing was applied" \
  bash -c '! git -C "$1" rev-parse -q --verify refs/heads/contrib/pr-5 >/dev/null' _ "$priv"

git -C "$contrib" reset -q --hard origin/main
git -C "$contrib" mv src/app.py src/sum.py
git -C "$contrib" commit -qm 'refactor: a better name'
git -C "$contrib" format-patch -1 -M --stdout >"$t/pr6.patch"
PATCH=$t/pr6.patch expect 1 'copies or renames a file' 'pr: a rename' pr 6

git -C "$contrib" reset -q --hard origin/main
sed -i 's/A small fixture./A fine fixture./' "$contrib/README.md"
git -C "$contrib" commit -qam 'docs: x'
pr_patch "$t/pr4.patch"
sed -i 's/A small fixture./A tiny fixture./' "$priv/README.md"
commit -m 'docs: meanwhile on dev'
PATCH=$t/pr4.patch expect 1 'rebase on public main' 'pr: a patch that no longer applies' pr 4
g reset -q --hard HEAD~1

# The whole intake: merge, release, publish; the contributor is credited.
g merge -q --ff-only contrib/pr-1
g switch -q main
g merge -q --ff-only dev
g push -q origin main
expect 0 '^published ' 'publish after taking in PR #1' publish
check "the contributor is a Co-authored-by on the public snapshot" \
  grep -qx 'Co-authored-by: Pat Contributor <pat@example.org>' <<<"$(pub_log %B)"
check "the published file is the contributor's change" same_tree main "$(g rev-parse main)" "${base[@]}"
check "the public repo still holds only what main reaches" only_reachable

# --- sandbox.sh ----------------------------------------------------------------------
sb() { (cd "$priv" && scripts/sandbox.sh "$@"); }
check "sandbox.sh: runs a command" sb true
check "sandbox.sh: no network but loopback" test "$(sb awk 'NR > 2 { print $1 }' /proc/net/dev 2>&1)" = "lo:"
# Empty but for the way down to what sandbox.sh binds under it on purpose: the
# checkout, and on a CI runner the read-only tool cache (RUNNER_TOOL_CACHE).
home_want=$(for p in "$priv" "${RUNNER_TOOL_CACHE:-}"; do
  [ -n "$p" ] && [ -d "$p" ] || continue; rel=${p#"$HOME"/}; [ "$rel" = "$p" ] || echo "${rel%%/*}"
done | sort -u | tr '\n' ' ')
check "sandbox.sh: the home folder is empty" \
  sb bash -c '[ "$(ls -A "$HOME" | sort -u | tr "\n" " ")" = "$1" ]' _ "$home_want"
check "sandbox.sh: no docker or lxd socket" \
  sb bash -c '! [ -e /run/docker.sock ] && ! [ -e /var/run/docker.sock ] && ! [ -e /var/snap/lxd/common/lxd/unix.socket ]'
check "sandbox.sh: other processes are out of sight" sb bash -c '[ "$(ls /proc | grep -c "^[0-9]")" -lt 10 ]'
check "sandbox.sh: the checkout takes writes inside" sb sh -c 'echo x >probe && [ -e probe ]'
check "  ...and none of them is left after" test ! -e "$priv/probe"
sb sh -c 'git config core.fsmonitor "touch planted"; printf "#!/bin/sh\ntouch planted\n" >.git/hooks/post-checkout
  chmod +x .git/hooks/post-checkout; echo "exec \"\$@\"" >scripts/sandbox.sh' || true
check "sandbox.sh: a hook, a git setting or a changed script planted inside is gone outside" \
  bash -c 'cd "$1" && [ ! -e .git/hooks/post-checkout ] && ! git config core.fsmonitor >/dev/null && ! grep -q "exec \"\$@\"" scripts/sandbox.sh' _ "$priv"
mkdir -p "$priv/mcp" "$priv/data"
printf 'SECRET=fixture\n' >"$priv/.env"; printf 'GITHUB_PERSONAL_ACCESS_TOKEN=fixture\n' >"$priv/mcp/.env"
printf 'notes\n' >"$priv/pi.md"; printf 'rows\n' >"$priv/data/rows"
check "sandbox.sh: .env, mcp/.env, pi.md and data/ read as empty" \
  sb sh -c '[ ! -s .env ] && [ ! -s mcp/.env ] && [ ! -s pi.md ] && [ -z "$(ls -A data)" ]'
rm -rf -- "${priv:?}/mcp" "${priv:?}/data" "$priv/.env" "$priv/pi.md"
check "sandbox.sh: a token in the environment does not get in" \
  env GH_TOKEN=fixture-token bash -c 'cd "$1" && scripts/sandbox.sh sh -c "[ -z \"\${GH_TOKEN:-}\" ] && [ -n \"\$PATH\" ]"' _ "$priv"
check "sandbox.sh: /var/log, /mnt and /media are empty" \
  sb sh -c 'for d in /var/log /mnt /media; do [ ! -d "$d" ] || [ -z "$(ls -A "$d")" ] || exit 1; done'
check "sandbox.sh: refuses to run from the home folder" \
  bash -c 'cd "$HOME" && "$1" true 2>/dev/null; [ $? -eq 2 ]' _ "$priv/scripts/sandbox.sh"

check "mirror.sh left no temporary files, keys or patches behind" \
  bash -c '[ -z "$(ls -A "$1")" ] && ! compgen -G "$2/.git/contrib-pr-*" >/dev/null' _ "$t/mirror-tmp" "$priv"

# --- the table -----------------------------------------------------------------------
printf '\nmirror gates\n'
printf '  %s\n' "${rows[@]}"
total=${#rows[@]}
bad=$(printf '%s\n' "${rows[@]}" | grep -c '^FAIL' || true)
printf '\n%s of %s passed\n' "$((total - bad))" "$total"
exit "$failed"
