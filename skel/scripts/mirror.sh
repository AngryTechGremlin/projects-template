#!/usr/bin/env bash
# Publish this private repo's allowlisted files to its public counterpart as
# one fresh snapshot commit, and take outside PRs back in. docs/publishing.md
# says why; this says how.
#
#   scripts/mirror.sh check     run every gate and show what would go public
#   scripts/mirror.sh publish   the same, then commit and push the snapshot
#                               (CI only: publish.yml, on the owner's click)
#   scripts/mirror.sh pr <N>    apply public PR #N to a new contrib/pr-N branch
#
# Exit 0 = done or nothing to do, 1 = a gate refused, 2 = setup/usage error.
#
# What goes out is decided by PUBLISH in the commit, never the working tree,
# and only file by named file. Nothing is rewritten to fit: a file that cannot
# go out exactly as it is stops the publish. The snapshot is built and pushed
# from a scratch repo that only ever holds the published objects, so no bug in
# here can push private history: there is none there to push.
#
# Test hooks, for the template's own fixture (tests/mirror-gates.sh):
#   PUBLISH_TEST_REMOTE=<bare repo>  stands in for the public repo
#   PUBLISH_TEST_PATCH=<file>        stands in for the PR download
#   PUBLISH_BLOCKLIST=<file>         stands in for ~/.config/publish/blocklist
set -euo pipefail

# The one identity every snapshot carries: the owner's public handle at
# GitHub's noreply address, so no real name or mailbox is ever published.
pub_name=AngryTechGremlin
pub_email=AngryTechGremlin@users.noreply.github.com
pub_ident="$pub_name <$pub_email>|$pub_name <$pub_email>"   # author|committer

# github.com's ed25519 host key, pinned so the deploy key is only ever offered
# to GitHub. To refresh it: the ssh_keys list at https://api.github.com/meta,
# checked against the fingerprint on docs.github.com ("GitHub's SSH key
# fingerprints"; SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU in 2026).
github_host_key='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'

die() { printf 'mirror: %s\n' "$1" >&2; exit 2; }
refuse() { printf 'mirror: refused: %s\n' "$1" >&2; exit 1; }
# Gates collect every problem they find, then refuse once, so one run shows
# them all.
problems=()
gate_done() { # <what the gate requires>
  (( ${#problems[@]} )) || return 0
  printf 'mirror: refused: %s\n' "$1" >&2
  printf '  %s\n' "${problems[@]}" >&2
  exit 1
}
usage() {
  echo "usage: scripts/mirror.sh check | publish | pr <number>" >&2
  exit 2
}

cmd=${1:-}
case $cmd in
  check|publish) (( $# == 1 )) || usage ;;
  pr) (( $# == 2 )) || usage ;;
  *) usage ;;
esac

# A caller's GIT_DIR or GIT_INDEX_FILE would quietly aim every git call below,
# the scratch repo's included, somewhere else.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
# Nor may a caller's `git -c` settings ride along: a url.insteadOf among them
# would send the scratch repo's push somewhere else.
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
# Nothing here may ask for, or be handed, a credential: the house's credential
# helper answers for any github.com URL, and an askpass (an editor's terminal
# sets one) could hand over the owner's token for a "public" repo that is not.
unset GIT_ASKPASS SSH_ASKPASS GIT_SSH GIT_SSH_COMMAND
export GIT_TERMINAL_PROMPT=0

root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repo"
cd "$root"
case $(git rev-parse --show-object-format) in
  sha1) fmt=sha1 hexlen=40 ;;
  sha256) fmt=sha256 hexlen=64 ;;
  *) die "unknown object format" ;;
esac
empty=$(git hash-object -t tree /dev/null)

tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/mirror.XXXXXX")
patch=""   # pr's download, inside .git
trap 'rm -rf -- "$tmp" ${patch:+"$patch"}' EXIT
trap 'exit 2' INT TERM HUP

# --- helpers ------------------------------------------------------------------

read_publish() { # <commit>: sets $repo and $paths from <commit>:PUBLISH
  local rev=$1 keys key rc=0
  git cat-file -e "$rev:PUBLISH" 2>/dev/null \
    || die "no PUBLISH in $rev: this repo is not set up to publish (new-project.sh --publish)"
  # --no-includes: an [include] would pull in a file outside the commit.
  keys=$(git config --blob "$rev:PUBLISH" --no-includes --list --name-only) \
    || refuse "PUBLISH in $rev is not git-config syntax"
  while IFS= read -r key; do
    case $key in
      publish.repo|publish.path) ;;
      *) problems+=("PUBLISH has a setting other than [publish] repo and path (a typo is silently ignored otherwise)") ;;
    esac
  done <<<"$keys"
  repo=$(git config --blob "$rev:PUBLISH" --no-includes --get-all publish.repo) || rc=$?
  if (( rc )) || [[ $repo == *$'\n'* ]]; then
    problems+=("PUBLISH needs exactly one 'repo = <owner>/<name>'")
  elif [[ ! $repo =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ ]]; then
    problems+=("PUBLISH's repo is not <owner>/<name> (an unfilled placeholder?)")
  fi
  rc=0
  git config --blob "$rev:PUBLISH" --no-includes -z --get-all publish.path >"$tmp/paths" || rc=$?
  ((rc <= 1)) || refuse "PUBLISH in $rev is not git-config syntax"
  paths=()
  mapfile -d '' -t paths <"$tmp/paths"
  (( ${#paths[@]} )) || problems+=("PUBLISH lists no files")
}

# One literal file path: no folder, glob, '..', leading '/' or ':' pathspec
# magic, nothing a shell or git would read as more than the name it is.
literal_re='^[A-Za-z0-9._@+][A-Za-z0-9._@+-]*(/[A-Za-z0-9._@+][A-Za-z0-9._@+-]*)*$'
literal() { [[ $1 =~ $literal_re && /$1/ != */./* && /$1/ != */../* ]]; }

# Never public, whatever PUBLISH says: the house's tooling, the agents'
# notes, runtime data, secrets and the publisher itself.
denied() { # <path>
  local p=${1,,} dir
  dir=/${p%/*}/
  [[ $p == */* ]] || dir=/
  case $dir in */.github/*|*/.githooks/*|*/mcp/*|*/.claude/*|*/.cursor/*|*/.vscode/*|*/data/*) return 0 ;; esac
  case $p in
    publish|.gitmodules|scripts/pii-scan.sh|scripts/pii-scan.exclude|scripts/mirror.sh|scripts/sandbox.sh)
      return 0 ;;
  esac
  case ${p##*/} in
    .env.example) return 1 ;;
    # The agents' notes, under each tool's name for them.
    .mcp.json|claude.md|claude.local.md|agent.md|agents.md|.cursorrules|pi.md) return 0 ;;
    git-credential-github.sh|.env*|*.env) return 0 ;;
    *.pem|*.key|*.p12|*.jks|*.keystore|local.properties) return 0 ;;
  esac
  return 1
}

# A Public-Credit trailer is the only text from outside that reaches the
# public commit's message, so it is held to exactly "Name <email>".
credit_re='^[^<>[:cntrl:]]{1,100} <[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+>$'
valid_credit() { [[ $1 =~ $credit_re && $1 != [[:space:]]* ]]; }

# A NUL byte anywhere marks a binary. Checked on the blob itself, because git's
# own verdict (diff --numstat) can be overridden by .gitattributes.
has_nul() { # <blob>
  [[ $(git cat-file -s "$1") != "$(git cat-file blob "$1" | tr -d '\000' | wc -c | tr -d ' ')" ]]
}

ls_tree() { # <commit> <outfile>: fills the assoc array $listing (path -> "mode type oid")
  local rec
  git ls-tree -r -t -z --full-tree "$1" >"$2"
  listing=()
  while IFS= read -r -d '' rec; do
    listing[${rec#*$'\t'}]=${rec%%$'\t'*}
  done <"$2"
}

# Plain files only, and no binaries (phase 1: no checker yet proves an image
# or archive carries no metadata). Fills $problems.
check_files() { # <from-tree> <to-tree> <paths...>: checks each path as it is in <to-tree>'s $listing
  local from=$1 to=$2 p meta rec
  shift 2
  for p; do
    meta=${listing[$p]:-}
    [[ -n $meta ]] || continue
    case ${meta%% *} in
      100644|100755) has_nul "${meta##* }" && problems+=("$p: binary (a NUL byte); no binaries go public yet") ;;
      120000) problems+=("$p: a symlink; only plain files go public") ;;
      *) problems+=("$p: mode ${meta%% *} (a submodule?); only plain files go public") ;;
    esac
  done
  git diff --numstat -z --no-renames --no-textconv --no-ext-diff "$from" "$to" >"$tmp/numstat"
  while IFS= read -r -d '' rec; do
    [[ $rec == -$'\t'-$'\t'* ]] && problems+=("${rec#-$'\t'-$'\t'}: git sees a binary; no binaries go public yet")
  done <"$tmp/numstat"
  return 0
}

blocklist_hits() { # <file>: the line numbers in <file> holding a blocklist entry
  local rc=0 hits
  hits=$(grep -niF -f "$bl" -- "$1" | cut -d: -f1) || rc=$?
  case $rc in
    0) printf '%s\n' "$hits" | paste -sd ' ' - ;;
    1) ;;
    *) die "grep failed (exit $rc) checking against the blocklist" ;;
  esac
}

# --- pr <N> --------------------------------------------------------------------

take_pr() {
  local n=$1 branch url orig dotgit p rc=0 hits authors=() a trailers=() changed=() summary c new
  local -A allowed=()
  [[ $n =~ ^[1-9][0-9]{0,8}$ ]] || die "pr takes a PR number"
  [[ -z $(git status --porcelain) ]] || die "the working tree is not clean; commit or stash first"
  git rev-parse -q --verify 'refs/heads/dev^{commit}' >/dev/null || die "no dev branch to apply onto"
  branch=contrib/pr-$n
  ! git rev-parse -q --verify "refs/heads/$branch" >/dev/null \
    || die "$branch already exists; delete it to start over"
  read_publish dev
  gate_done "PUBLISH on dev"
  url=https://github.com/$repo/pull/$n

  # Anonymous: curl sends no credential unless told to, and https only, even
  # through GitHub's redirect to its patch host.
  dotgit=$(git rev-parse --absolute-git-dir)
  patch=$dotgit/contrib-pr-$n.patch
  if [[ -n ${PUBLISH_TEST_PATCH:-} ]]; then
    cp -- "$PUBLISH_TEST_PATCH" "$patch"
  else
    command -v curl >/dev/null || die "curl is not installed"
    curl -fsSL --proto '=https' --proto-redir '=https' --max-time 60 --max-filesize 20000000 \
      -o "$patch" "$url.patch" || die "could not download $url.patch"
  fi

  # A copy names only its destination, so the path gate below would see a
  # published file and not the private one it was copied from: a stranger
  # could publish a file they have never seen. A rename is refused with it;
  # a PR that moves a file is the owner's to redo by hand.
  summary=$(git apply --summary -- "$patch") || die "cannot read PR #$n's patch"
  if grep -qE '^ (copy|rename) ' <<<"$summary"; then
    refuse "PR #$n copies or renames a file; only edits to published files are taken in"
  fi

  # Hooks off: until the owner has read it, nothing from the PR may run, and
  # applying it rewrites the working tree the hooks are read from.
  orig=$(git symbolic-ref -q --short HEAD) || orig=$(git rev-parse HEAD)
  undo() {
    git -c core.hooksPath=/dev/null am --abort >/dev/null 2>&1 || true
    git -c core.hooksPath=/dev/null switch -q -f "$orig" 2>/dev/null \
      || git -c core.hooksPath=/dev/null switch -q -f --detach "$orig"
    git branch -q -D "$branch"
  }
  git -c core.hooksPath=/dev/null switch -q -c "$branch" dev
  if ! git -c core.hooksPath=/dev/null am -q --3way "$patch"; then
    undo
    refuse "PR #$n does not apply to dev: ask the contributor to rebase on public main"
  fi

  # Only this script writes these trailers; one from the contributor would
  # put words of theirs into the public commit's message.
  # Both readings: git's own trailer parser, which is what publish uses and
  # which takes "Public-Credit : x" too, and a plain grep for anything else.
  hits=$(git log --format=%B dev..HEAD | grep -ciE '^(Public-Credit|Public-PR)[[:space:]]*:') || rc=$?
  if (( rc == 1 )) && [[ -z $(git log --format='%(trailers:key=Public-Credit)%(trailers:key=Public-PR)' dev..HEAD) ]]; then
    :
  elif (( rc <= 1 )); then
    undo
    refuse "a commit in PR #$n already carries a Public-Credit or Public-PR line"
  else
    undo
    die "grep failed (exit $rc) reading the PR's messages"
  fi

  # Path gate: a PR may change only files that are already public. A new
  # public file is the owner's decision, made in its own private commit.
  for p in "${paths[@]}"; do allowed[$p]=1; done
  git diff --no-renames --name-only -z dev HEAD >"$tmp/changed"
  mapfile -d '' -t changed <"$tmp/changed"
  (( ${#changed[@]} )) || problems+=("the PR changes nothing")
  for p in "${changed[@]}"; do
    if [[ -z ${allowed[$p]:-} ]]; then
      problems+=("$(printf %q "$p"): not in PUBLISH; a new public file needs its own private commit to PUBLISH first")
    elif denied "$p"; then
      problems+=("$p: on the deny list")
    fi
  done
  declare -A listing=()
  ls_tree HEAD "$tmp/ls-head"
  check_files dev HEAD "${changed[@]}"
  if (( ${#problems[@]} )); then
    undo
    gate_done "PR #$n"
  fi

  # Credit: each author becomes a Public-Credit trailer, and so a
  # Co-authored-by on the next public snapshot. The commits themselves are
  # remade as the house's fixed identity (same trees, messages and dates):
  # the contributor's address must not enter private history, and the
  # identity check would refuse it there (scripts/check.sh).
  mapfile -t authors < <(git log --reverse --format='%an <%ae>' dev..HEAD | awk '!seen[$0]++')
  trailers=(--trailer "Public-PR: $url")
  for a in "${authors[@]}"; do
    if valid_credit "$a"; then
      trailers+=(--trailer "Public-Credit: $a")
    else
      echo "mirror: an author's name or email does not fit 'Name <email>'; add their Public-Credit trailer by hand" >&2
    fi
  done
  export GIT_AUTHOR_NAME=$pub_name GIT_AUTHOR_EMAIL=$pub_email \
    GIT_COMMITTER_NAME=$pub_name GIT_COMMITTER_EMAIL=$pub_email
  new=$(git rev-parse dev)
  while IFS= read -r c; do
    new=$(GIT_AUTHOR_DATE=$(git log -1 --format=%ad --date=raw "$c") \
      git commit-tree --no-gpg-sign -p "$new" -F <(git log -1 --format=%B "$c") "$c^{tree}")
  done < <(git rev-list --reverse dev..HEAD)
  git update-ref "refs/heads/$branch" "$new"
  git -c core.hooksPath=/dev/null commit -q --amend --no-edit --no-verify "${trailers[@]}"

  cat <<EOF
Applied $url to $branch ($(git rev-list --count dev..HEAD) commits).

NOTHING HAS RUN YET — read git log -p --stat dev..$branch in full
before anything runs it: a test run is the contributor's code running here.

Then:
  1. git push -u origin $branch   (CI runs its tests inside scripts/sandbox.sh)
  2. merge it into dev, and release dev to main as usual
  3. the owner clicks publish: Actions, publish, Run workflow, on main
  4. close $url by hand: "Applied upstream in <public sha>, thanks!"
EOF
}

if [[ $cmd == pr ]]; then
  take_pr "$2"
  exit 0
fi

# --- check / publish --------------------------------------------------------

# 1. PUBLISH, from the commit: what is reviewed is what ships.
src=$(git rev-parse -q --verify 'HEAD^{commit}') || die "no commit to publish"
read_publish "$src"
gate_done "PUBLISH in $src"
origin=$(git remote get-url origin 2>/dev/null || true)
origin=${origin%/}
origin=${origin%.git}
[[ ${origin,,} != *github.com[:/]"${repo,,}" ]] || die "PUBLISH's repo is this private repo's own origin"

# 2. A publish is main, as main is on GitHub, and only from CI.
if [[ $cmd == publish ]]; then
  [[ ${GITHUB_REF:-} == refs/heads/main || -n ${PUBLISH_TEST_REMOTE:-} ]] \
    || die "publish runs only on main, in CI (publish.yml, on the owner's click)"
  [[ $(git rev-parse -q --verify 'refs/remotes/origin/main^{commit}' || true) == "$src" ]] \
    || die "HEAD is not origin/main: publish only what main holds"
  [[ -n ${PUBLISH_TEST_REMOTE:-} || -n ${PUBLIC_DEPLOY_KEY:-} ]] \
    || die "PUBLIC_DEPLOY_KEY is not set (publish.yml passes it from the repo's secrets)"
fi

# 3. The blocklist: the owner's names, hosts and addresses, kept outside every
# repo. Never printed; only its size is.
bl_file=${PUBLISH_BLOCKLIST:-$HOME/.config/publish/blocklist}
bl_shown=${bl_file/#"$HOME"/\~}
[[ -f $bl_file && -r $bl_file ]] || die "no blocklist at $bl_shown (docs/publishing.md, 'The blocklist')"
bl=$tmp/blocklist
: >"$bl"
short=()
n=0
while IFS= read -r line || [[ -n $line ]]; do
  n=$((n + 1))
  # A stray CR or trailing space, or the byte-order mark an editor puts
  # first, would make an entry silently never match.
  (( n > 1 )) || line=${line#$'\xef\xbb\xbf'}
  line=${line//$'\r'/}
  line=${line%%#*}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [[ -n $line ]] || continue
  if (( ${#line} < 4 )); then short+=("$n"); continue; fi
  printf '%s\n' "$line" >>"$bl"
done <"$bl_file"
(( ${#short[@]} == 0 )) \
  || die "blocklist line(s) ${short[*]} are under 4 characters; they would match everywhere"
[[ -s $bl ]] || die "the blocklist at $bl_shown has no entries"
login=$(id -un)
if (( ${#login} >= 4 )); then
  printf '%s\n' "$login" >>"$bl"
else
  echo "mirror: the login name is under 4 characters and is not added to the blocklist" >&2
fi
# Bytewise: a locale's collation can rank entries that differ only in
# punctuation (name. and name-) equal, and -u would drop one unchecked.
LC_ALL=C sort -u -o "$bl" "$bl"
echo "blocklist: $(wc -l <"$bl" | tr -d ' ') entries"

# (12, run here.) A path is printed by every gate below, so names are checked
# against the blocklist first, and a hit is shown only by its place in PUBLISH.
printf '%s\n' "$repo" "${paths[@]}" >"$tmp/names"
hits=$(blocklist_hits "$tmp/names")
[[ -z $hits ]] || refuse "a public name matches the blocklist: line(s) $hits of [the repo name, then each PUBLISH path in order]"

# 4. Literal, unique, and a file in the commit.
declare -A listing=() seen=()
ls_tree "$src" "$tmp/ls"
i=0
for p in "${paths[@]}"; do
  i=$((i + 1))
  if ! literal "$p"; then
    problems+=("path #$i $(printf %q "$p"): not a literal file path (no folders, globs, '..', leading '/' or ':')")
    continue
  fi
  if [[ -n ${seen[$p]:-} ]]; then problems+=("$p: listed twice"); continue; fi
  seen[$p]=1
  case ${listing[$p]:-} in
    "") problems+=("$p: not in $src (a stale entry?)") ;;
    *" tree "*) problems+=("$p: a folder; list its files one by one") ;;
  esac
done
gate_done "PUBLISH must list literal, unique files that exist in $src"

# 5. The hard deny list.
for p in "${paths[@]}"; do
  denied "$p" && problems+=("$p: on the deny list; it never goes public, whatever PUBLISH says")
done
gate_done "denied paths in PUBLISH"

# 6. Plain files only: a symlink could point anywhere, a submodule at anything.
for p in "${paths[@]}"; do
  case ${listing[$p]%% *} in
    100644|100755) ;;
    120000) problems+=("$p: a symlink; only plain files go public") ;;
    *) problems+=("$p: mode ${listing[$p]%% *}; only plain files go public") ;;
  esac
done
gate_done "file modes"

# 7. The snapshot's tree, from exactly the listed blobs, in a throwaway index.
# Never git archive: export-ignore drops files and export-subst writes private
# data into them.
idx=$tmp/index
GIT_INDEX_FILE=$idx git read-tree --empty
for p in "${paths[@]}"; do printf '%s\t%s\0' "${listing[$p]}" "$p"; done \
  | GIT_INDEX_FILE=$idx git update-index -z --index-info
tree=$(GIT_INDEX_FILE=$idx git write-tree)
[[ $(GIT_INDEX_FILE=$idx git ls-files | wc -l) -eq ${#paths[@]} ]] \
  || die "the snapshot's index does not hold exactly the PUBLISH files"
# The deny list's last part: what the private scan was told to skip.
if git cat-file -e "$src:scripts/pii-scan.exclude" 2>/dev/null; then
  specs=()
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    line=${line%%[[:space:]]#*}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n $line ]] && specs+=("$line")
  done < <(git cat-file blob "$src:scripts/pii-scan.exclude")
  if (( ${#specs[@]} )); then
    covered=$(GIT_INDEX_FILE=$idx git ls-files -- "${specs[@]}") \
      || die "scripts/pii-scan.exclude holds a pathspec git cannot read"
    [[ -z $covered ]] \
      || refuse "PUBLISH lists files that scripts/pii-scan.exclude keeps from the scan: ${covered//$'\n'/ }"
  fi
fi

# 8. No binaries.
check_files "$empty" "$tree" "${paths[@]}"
gate_done "binaries"

# 9. A licence, a README, and NOTICE when the private repo has one (Apache-2.0
# section 4(d) requires it to travel with the code).
[[ -n ${seen[LICENSE]:-} ]] || problems+=("LICENSE is not in PUBLISH: without one the code is not open to anyone")
[[ -n ${seen[README.md]:-} ]] || problems+=("README.md is not in PUBLISH")
if [[ -n ${listing[NOTICE]:-} && -z ${seen[NOTICE]:-} ]]; then
  problems+=("NOTICE is in the repo but not in PUBLISH")
fi
gate_done "required files"

# 10. The scratch repo: it receives exactly the snapshot's objects and nothing
# else from here, so whatever it pushes cannot carry private history. Its git
# reads no user or system config (no insteadOf, no helper, no hooks), and no
# attributes, so the files on disk are byte for byte the blobs that ship.
w=$tmp/w
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git init -q --template= --object-format="$fmt" "$w"
wgit() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1 GIT_ATTR_SOURCE=$empty \
    git --git-dir="$w/.git" --work-tree="$w" -C "$w" \
    -c core.hooksPath=/dev/null -c core.attributesFile=/dev/null -c credential.helper= "$@"
}
# The same, for the scan's own git calls below.
wgit config core.hooksPath /dev/null
wgit config core.attributesFile /dev/null
{ echo "$tree"; git ls-tree -r -t --format='%(objectname)' "$tree"; } \
  | git pack-objects --stdout -q | wgit index-pack --stdin >/dev/null
wgit read-tree -u --reset "$tree"
[[ $(wgit write-tree) == "$tree" ]] || die "the scratch repo's tree is not the snapshot's"
wgit ls-files -s -z >"$tmp/staged"
while IFS= read -r -d '' rec; do
  p=${rec#*$'\t'}
  oid=${rec#* }
  oid=${oid%% *}
  [[ $(wgit hash-object --no-filters -- "$p") == "$oid" ]] \
    || die "$p was checked out unlike its blob; the scan would not see what ships"
done <"$tmp/staged"

# 11. The strict scan, over exactly the files that ship. The scanner comes from
# the commit, like PUBLISH, and must say it ran in public mode with the
# blocklist over the right number of files: an older one would quietly not.
git cat-file -e "$src:scripts/pii-scan.sh" 2>/dev/null || die "no scripts/pii-scan.sh in $src"
git cat-file blob "$src:scripts/pii-scan.sh" >"$tmp/pii-scan.sh"
rc=0
out=$(cd "$w" && GIT_DIR=$w/.git GIT_WORK_TREE=$w GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_ATTR_NOSYSTEM=1 GIT_ATTR_SOURCE=$empty PII_SCAN_PUBLIC=1 PII_SCAN_BLOCKLIST=$bl \
  bash "$tmp/pii-scan.sh" 2>&1) || rc=$?
printf '%s\n' "$out"
case $rc in
  0) ;;
  1) refuse "the strict scan found personal data in a file that would be published (above)" ;;
  *) die "the strict scan could not run (exit $rc)" ;;
esac
scan_re='^pii-scan: clean \( *([0-9]+) files; public mode; blocklist\)$'
[[ $(tail -n 1 <<<"$out") =~ $scan_re ]] \
  || die "scripts/pii-scan.sh in $src has no public mode; refresh it from the template"
(( BASH_REMATCH[1] == ${#paths[@]} )) \
  || die "the strict scan examined ${BASH_REMATCH[1]} files, not the ${#paths[@]} that would ship"

# 12. File names against the blocklist ran before gate 4.

# 13. The public side, read anonymously. Its last commit must be this
# publisher's, made from an ancestor of this commit: anything else means the
# public repo was written by hand, or this is not main's line of history.
if [[ -n ${PUBLISH_TEST_REMOTE:-} ]]; then url=$PUBLISH_TEST_REMOTE; else url=https://github.com/$repo.git; fi
parent="" last_source="" unread=""
rc=0
heads=$(wgit ls-remote "$url" refs/heads/main 2>"$tmp/ls-remote.err") || rc=$?
if (( rc )); then
  cat "$tmp/ls-remote.err" >&2
  [[ $cmd == check ]] || die "cannot read $url anonymously: does it exist, and is it public?"
  # Before the owner has made the public repo, a red check on every push would
  # only teach everyone to ignore it. The preview says so instead; a publish
  # still refuses.
  unread=" (WARNING: the public repo could not be read anonymously, so this previews a first publish)"
  echo "mirror: warning: cannot read $url anonymously; previewing as a first publish" >&2
elif [[ -n $heads ]]; then
  wgit fetch -q --depth=1 --no-tags "$url" +refs/heads/main:refs/remotes/public/main
  parent=$(wgit rev-parse --verify 'refs/remotes/public/main^{commit}')
  [[ $(wgit log -1 --format='%an <%ae>|%cn <%ce>' "$parent") == "$pub_ident" ]] \
    || refuse "public main's last commit was not made by this publisher: was it written by hand?"
  mapfile -t sources < <(wgit log -1 --format='%(trailers:key=Source,valueonly,unfold)' "$parent" | sed '/^$/d')
  (( ${#sources[@]} == 1 )) && [[ ${sources[0]} =~ ^[0-9a-f]{$hexlen}$ ]] \
    || refuse "public main's last commit has no single full-length Source: trailer"
  last_source=${sources[0]}
  git cat-file -e "$last_source^{commit}" 2>/dev/null \
    || refuse "public main says Source: $last_source, which is not a commit in this repo"
  rc=0
  git merge-base --is-ancestor "$last_source" "$src" || rc=$?
  case $rc in
    0) ;;
    1) refuse "the last snapshot's Source ($last_source) is not an ancestor of $src: publish only from main's line" ;;
    *) die "git merge-base failed (exit $rc)" ;;
  esac
  if [[ $(wgit rev-parse "$parent^{tree}") == "$tree" ]]; then
    echo "already published: public main ($parent) holds exactly this snapshot"
    # shellcheck disable=SC2016 # backticks are Markdown code, not a command
    [[ -z ${GITHUB_STEP_SUMMARY:-} ]] \
      || printf '## Public snapshot\n\nAlready published: `%s` holds exactly this snapshot.\n' "$repo" >>"$GITHUB_STEP_SUMMARY"
    exit 0
  fi
fi
if [[ -n $parent ]]; then
  wgit diff --name-status --no-renames "$parent" "$tree" >"$tmp/changes"
else
  wgit ls-tree -r --name-only "$tree" | sed 's/^/A\t/' >"$tmp/changes"
fi
{
  printf 'Snapshot of %s for %s (%s files)%s%s:\n' "$src" "$repo" "${#paths[@]}" \
    "${parent:+, against public $parent}" "$unread"
  while IFS=$'\t' read -r st p; do
    if [[ $st == A ]]; then
      printf '  A  %s   <- new: permanently public once published\n' "$p"
    else
      printf '  %s  %s\n' "$st" "$p"
    fi
  done <"$tmp/changes"
} >"$tmp/report"
cat "$tmp/report"

# 14. The message: fixed text, the full Source, and credit only from
# well-formed Public-Credit trailers since the last snapshot. Existing
# Co-authored-by lines are never harvested: they are private history.
range=$src
[[ -z $last_source ]] || range=$last_source..$src
git log --format='%(trailers:key=Public-Credit,valueonly,unfold)' "$range" >"$tmp/credits"
credits=()
declare -A credited=()
while IFS= read -r c; do
  [[ -n $c ]] || continue
  if ! valid_credit "$c"; then
    problems+=("a Public-Credit trailer since the last snapshot is not 'Name <email>' (git log --grep=Public-Credit)")
    continue
  fi
  [[ -n ${credited[$c]:-} ]] || { credited[$c]=1; credits+=("$c"); }
done <"$tmp/credits"
gate_done "credit trailers"
{
  printf 'chore: publish snapshot\n\nSource: %s\n' "$src"
  for c in "${credits[@]}"; do printf 'Co-authored-by: %s\n' "$c"; done
} >"$tmp/msg"
hits=$(blocklist_hits "$tmp/msg")
[[ -z $hits ]] || refuse "the snapshot's commit message matches the blocklist on line(s) $hits (a Public-Credit trailer?)"

# 15. check ends here, with the list for the owner to read before clicking.
if [[ $cmd == check ]]; then
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    fence='```'
    {
      printf '## Public snapshot preview\n\n'
      printf 'Publishing is the owner'\''s click (Actions, publish, Run workflow, on main). '
      printf 'Every file marked new becomes public for good.\n\n%s\n' "$fence"
      cat "$tmp/report"
      printf '%s\n\n<details><summary>All %s files the public repo would hold</summary>\n\n%s\n' \
        "$fence" "${#paths[@]}" "$fence"
      printf '%s\n' "${paths[@]}" | sort
      printf '%s\n\n</details>\n' "$fence"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  echo "check passed: ${#paths[@]} files would publish to $repo"
  exit 0
fi

# 16. The commit, made in the scratch repo with a fixed identity and clock zone,
# and checked before anything leaves.
parent_args=()
[[ -z $parent ]] || parent_args=(-p "$parent")
commit=$(
  unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
  export TZ=UTC GIT_AUTHOR_NAME=$pub_name GIT_AUTHOR_EMAIL=$pub_email \
    GIT_COMMITTER_NAME=$pub_name GIT_COMMITTER_EMAIL=$pub_email
  wgit -c user.useConfigOnly=true commit-tree --no-gpg-sign "${parent_args[@]}" -F "$tmp/msg" "$tree"
)
[[ $(wgit rev-parse "$commit^{tree}") == "$tree" ]] || die "the new commit's tree is not the snapshot"
[[ $(wgit log -1 --format='%an <%ae>|%cn <%ce>' "$commit") == "$pub_ident" ]] \
  || die "the new commit does not carry the publisher's identity"
[[ $(wgit log -1 --format='%ai|%ci' "$commit") == *' +0000|'*' +0000' ]] || die "the new commit is not in UTC"
want=1
[[ -z $parent ]] || want=$(( $(wgit rev-list --count "$parent") + 1 ))
[[ $(wgit rev-list --count "$commit") -eq $want ]] || die "the new commit does not add exactly one to public main"
[[ $(wgit rev-list --parents -n 1 "$commit") == "$commit${parent:+ $parent}" ]] \
  || die "the new commit's parent is not public main"
stray=$(comm -23 <(wgit cat-file --batch-all-objects --batch-check='%(objectname)' | sort -u) \
  <(wgit rev-list --objects "$commit" | cut -d' ' -f1 | sort -u))
[[ -z $stray ]] || die "the scratch repo holds objects the snapshot does not reach"

# 17. The push, from the scratch repo only: one commit onto main, never forced,
# no tags. A real push uses the deploy key alone, offered only to github.com
# as pinned above; the ruleset on the public repo lets nothing else write.
if [[ -n ${PUBLISH_TEST_REMOTE:-} ]]; then
  wgit push -q --no-follow-tags "$url" "$commit:refs/heads/main"
else
  key=$tmp/deploy-key
  (umask 077 && printf '%s\n' "${PUBLIC_DEPLOY_KEY//$'\r'/}" >"$key")
  printf '%s\n' "$github_host_key" >"$tmp/known_hosts"
  GIT_SSH_COMMAND="ssh -F /dev/null -i $(printf %q "$key") -o IdentitiesOnly=yes -o IdentityAgent=none \
-o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$(printf %q "$tmp/known_hosts") \
-o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519 -o UpdateHostKeys=no" \
    wgit push -q --no-follow-tags "git@github.com:$repo.git" "$commit:refs/heads/main"
fi
echo "published $commit to $repo (Source: $src)"
# shellcheck disable=SC2016 # backticks are Markdown code, not a command
[[ -z ${GITHUB_STEP_SUMMARY:-} ]] \
  || printf '## Published\n\n`%s` is now at `%s` (Source: `%s`).\n' "$repo" "$commit" "$src" >>"$GITHUB_STEP_SUMMARY"
