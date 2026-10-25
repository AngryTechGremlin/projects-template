#!/usr/bin/env bash
# Bring every repo that uses this template up to the template's main: the
# files the template owns (check.sh, the scans, the hook, ci-runner.md, the
# MCP server) are refreshed on each repo's dev, checked, and pushed with that
# repo's own token. Each repo's CI then tests the change like any other push,
# and it reaches main only at that repo's next release, on the owner's word.
#
#   ./refresh-all.sh [--dry-run] [--if-changed] [repo...]
#
# --dry-run     do everything but the push, and say what would be pushed
# --if-changed  stop at once when the template's main is the one the last
#               complete run used (for the timer: most days nothing moved)
# repo...       only these (names under ~/Projects); default: every repo here
#               whose committed tree has scripts/check.sh
#
# Never touches a working checkout: each repo is refreshed in a scratch clone
# of its dev as GitHub has it, so a session's uncommitted or unpushed work is
# never read, carried or disturbed. Files a repo customizes (its workflows,
# agent.md, README, PUBLISH) are never edited; their drift from the template
# is reported, to be ported by hand. A repo with no dev branch is skipped.
#
# One line per repo, and the full log in
# ${XDG_STATE_HOME:-~/.local/state}/projects-template/.
# Exit 0 = every repo up to date or pushed, 1 = at least one needs a person,
# 2 = usage/setup error.
#
# Env: REFRESH_TRAILER, lines appended to each commit message (a session that
# runs this adds its attribution). Tests: PROJECTS_DIR, REFRESH_TEMPLATE_REF
# (default origin/main, after a fetch; with it set nothing is fetched),
# XDG_STATE_HOME.
set -euo pipefail
# Never stop at a password prompt: a missing or expired token is a row in the
# report, not a hang.
export GIT_TERMINAL_PROMPT=0

TEMPLATE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECTS_DIR=${PROJECTS_DIR:-$(dirname -- "$TEMPLATE_DIR")}
dry=0
if_changed=0
only=()
usage() { echo "usage: refresh-all.sh [--dry-run] [--if-changed] [repo...]"; }
while (( $# )); do
  case $1 in
    --dry-run) dry=1 ;;
    --if-changed) if_changed=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "refresh-all: not a repo name: $1" >&2; exit 2; }
       only+=("$1") ;;
  esac
  shift
done

state=${XDG_STATE_HOME:-$HOME/.local/state}/projects-template
mkdir -p -- "$state"
logfile=$state/refresh-$(date +%Y%m%d-%H%M%S).log
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

# The template as GitHub's main has it: main only moves once dev's CI is green,
# so what spreads to every repo is what the template's own tests passed.
ref=${REFRESH_TEMPLATE_REF:-}
if [[ -z $ref ]]; then
  git -C "$TEMPLATE_DIR" fetch -q origin main || { echo "refresh-all: cannot fetch the template's main" >&2; exit 2; }
  ref=origin/main
fi
ver=$(git -C "$TEMPLATE_DIR" rev-parse --verify -q "$ref^{commit}") || { echo "refresh-all: no template commit $ref" >&2; exit 2; }
if (( if_changed )) && [[ -f $state/last-complete && $(<"$state/last-complete") == "$ver" ]]; then
  echo "template main ${ver:0:12} is the one the last complete run used; nothing to do"
  exit 0
fi
tpl=$work/projects/_template
mkdir -p -- "$tpl"
git -C "$TEMPLATE_DIR" archive "$ver" | tar -x -C "$tpl"

if (( ${#only[@]} == 0 )); then
  for d in "$PROJECTS_DIR"/*/; do
    d=${d%/}
    name=$(basename -- "$d")
    [[ $name != _template && -d $d/.git ]] || continue
    git -C "$d" cat-file -e HEAD:scripts/check.sh 2>/dev/null || continue
    only+=("$name")
  done
fi

rows=()
row() { rows+=("$(printf '%-16s %s' "$1" "$2")"); }
attention() { row "$1" "NEEDS A PERSON: $2"; }

{
echo "refresh-all: template ${ver:0:12} ($ref), $( ((dry)) && echo 'dry run' || echo 'pushing' ), $(date '+%F %T')"
for name in "${only[@]}"; do
  d=$PROJECTS_DIR/$name
  echo
  echo "=== $name"
  [[ -d $d/.git ]] || { attention "$name" "no repo at $d"; continue; }
  url=$(git -C "$d" remote get-url origin 2>/dev/null) || { attention "$name" "no origin remote"; continue; }
  c=$work/$name
  # A clone of the committed local repo, then pointed at GitHub: only what is
  # on GitHub's dev gets refreshed, never a session's unpushed commits.
  git clone -q --no-checkout -- "$d" "$c"
  git -C "$c" remote set-url origin "$url"
  git -C "$c" config user.name AngryTechGremlin
  git -C "$c" config user.email AngryTechGremlin@users.noreply.github.com
  if [[ $url == https://* ]]; then
    # Pushes read that repo's own token, the same file the repo's helper
    # reads; this job holds no token of its own.
    [[ -f $d/mcp/.env ]] || { attention "$name" "no mcp/.env with this repo's token"; continue; }
    mkdir -p -- "$c/mcp"
    install -m 600 -- "$d/mcp/.env" "$c/mcp/.env"
    # The repo's own helper, from its committed tree: it reads mcp/.env
    # beside the git dir it is called from, which is this clone's copy.
    helper=$work/$name.credential-helper
    git -C "$d" show HEAD:scripts/git-credential-github.sh >"$helper" 2>/dev/null \
      || { attention "$name" "no scripts/git-credential-github.sh to push with"; continue; }
    chmod 700 -- "$helper"
    git -C "$c" config credential.helper "!\"$helper\""
  fi
  if ! git -C "$c" ls-remote --exit-code --heads origin dev >/dev/null 2>&1; then
    row "$name" "skipped: no dev branch on origin (a single-branch repo is refreshed by hand)"
    continue
  fi
  git -C "$c" fetch -q origin dev || { attention "$name" "cannot fetch dev (token expired?)"; continue; }
  git -C "$c" switch -q -c refresh-from-template origin/dev
  was=$(head -c 40 "$c/.template-version" 2>/dev/null || true)
  if [[ $was == "$ver" ]]; then
    row "$name" "up to date (${ver:0:12})"
    continue
  fi
  if ! TEMPLATE_VERSION=$ver "$tpl/new-project.sh" --adopt "$c" --refresh --no-build >"$c.refresh" 2>&1; then
    sed 's/^/  /' "$c.refresh"
    attention "$name" "the refresh refused (log above)"
    continue
  fi
  sed 's/^/  /' "$c.refresh"
  # The clone has no MCP token beyond mcp/.env, which is gitignored; nothing
  # else here is uncommitted but what the refresh wrote.
  git -C "$c" add -A
  if git -C "$c" diff --cached --quiet; then
    row "$name" "up to date (${ver:0:12})"
    continue
  fi
  changed=$(git -C "$c" diff --cached --name-only | paste -sd ' ' -)
  msg="chore: refresh from projects-template ${ver:0:12}, so the house checks and shared files match the template's main

Template ${ver}. Refreshed: ${changed}."
  [[ -z ${REFRESH_TRAILER:-} ]] || msg+=$'\n\n'$REFRESH_TRAILER
  git -C "$c" commit -q -m "$msg"
  if ! (cd "$c" && CHECK_RANGE="HEAD --not origin/dev" scripts/check.sh fast); then
    attention "$name" "the house checks failed on the refreshed tree (log above); nothing was pushed"
    continue
  fi
  notes=()
  # A customized file always differs from the template (that is what makes it
  # customized), so only one whose template copy changed since the version this
  # repo was on needs a person; with no version recorded yet, all of them do.
  drift=()
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    if [[ $was =~ ^[0-9a-f]{40}$ ]] && git -C "$TEMPLATE_DIR" cat-file -e "$was^{commit}" 2>/dev/null \
       && git -C "$TEMPLATE_DIR" diff --quiet "$was" "$ver" -- "skel/$f"; then
      continue
    fi
    drift+=("$f")
  done < <(grep -oE 'port by hand: .*' "$c.refresh" | sed 's/port by hand: //')
  (( ${#drift[@]} == 0 )) || notes+=("port by hand: ${drift[*]}")
  grep -q 'publish.yml pins the publisher' "$c.refresh" && notes+=("publish.yml pins need the new hashes (log)")
  grep -q 'the MCP server changed' "$c.refresh" && notes+=("MCP server changed: rebuild it in the working checkout")
  if (( dry )); then
    row "$name" "would push $(git -C "$c" rev-parse --short HEAD) to dev: ${changed}${notes:+; ${notes[*]}}"
    continue
  fi
  # The hook in the clone checks this push like any other (origin only, then
  # check.sh fast). If dev moved meanwhile, rebase once and try again.
  git -C "$c" config core.hooksPath .githooks
  if ! git -C "$c" push -q origin HEAD:dev; then
    if git -C "$c" fetch -q origin dev && git -C "$c" rebase -q origin/dev && git -C "$c" push -q origin HEAD:dev; then
      :
    else
      attention "$name" "the push to dev failed (log above)"
      continue
    fi
  fi
  row "$name" "pushed $(git -C "$c" rev-parse --short HEAD) to dev: ${changed}${notes:+; ${notes[*]}}"
done
echo
printf '%s\n' "${rows[@]}"
} 2>&1 | tee "$logfile"

# The loop ran in the pipeline's subshell: the verdict is read back from the log.
if grep -q 'NEEDS A PERSON' "$logfile"; then
  echo "log: $logfile"
  exit 1
fi
(( dry )) || printf '%s\n' "$ver" >"$state/last-complete"
echo "log: $logfile"
