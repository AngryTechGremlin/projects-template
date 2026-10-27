#!/usr/bin/env bash
# The release, as a script: fast-forward main to the dev commit CI already
# passed, then wait until it is proven on main (agent.md §5).
#
#   scripts/release.sh [--dry-run] [--timeout <minutes>]
#
# The owner's yes comes first: "ready to release?" → yes → this script. It
# cannot check that yes and does not try; what it removes is every place a
# session would otherwise improvise the mechanics. It stops at the first gate
# that fails and says why:
#
#   1. ready      on dev, nothing uncommitted, dev is what origin has, and
#                 main can fast-forward to it
#   2. tested     ci.yml passed on that exact commit, pushed to dev
#   3. clean      scripts/check.sh fast on the commits main is about to gain
#   4. on record  the open dev→main PR, opened if there is none, its body the
#                 commit list
#   5. release    git push origin <sha>:main, a plain push, so git itself
#                 refuses anything but a fast-forward
#   6. proof      ci.yml green on main, then the deploy.yml run for that
#                 commit where the repo has one; exit 0 only then
#
# --dry-run      gates 1–3, then say what 4 would do; changes nothing
# --timeout N    minutes to wait for each run in 2 and 6 (default 30); 0 looks once
#
# Why never GitHub's merge button or merge API: rebase, squash and merge
# commit all write new commits under an identity GitHub picks. On hallpass
# (2026-10-27) that put the owner's real name and address on main as
# committer, check.sh refused them, CI went red and nothing deployed. A
# fast-forward keeps dev's commits as they are, GitHub marks the PR merged by
# itself, and ci.yml's `seen` job skips the checks the commit already passed
# (docs/ci-runner.md, "A release does not test twice").
#
# After a timeout, run it again: with main already at dev it goes straight to 6.
#
# The token is the one in mcp/.env, the same one git-credential-github.sh
# hands git. It needs Pull requests: Read and write and Actions: Read-only
# (mcp/README.md), and goes to curl on stdin, never in argv.
#
# Exit 0 = released and proven (or a dry run that passed 1–3), 1 = a gate
# refused or a run failed, 2 = usage/setup error.
set -euo pipefail

usage() { echo "usage: scripts/release.sh [--dry-run] [--timeout <minutes>]" >&2; exit 2; }
setup() { echo "release.sh: $*" >&2; exit 2; }
ok() { printf 'ok   %s\n' "$*"; }
stop() { # <what failed> [what to do...]
  printf 'STOP %s\n' "$1"
  shift
  (( $# == 0 )) || printf '     %s\n' "$@"
  exit 1
}

dry=0 timeout=30
while (( $# )); do
  case $1 in
    --dry-run) dry=1; shift ;;
    --timeout) [[ ${2:-} =~ ^[0-9]+$ ]] || usage; timeout=$2; shift 2 ;;
    *) usage ;;
  esac
done

root=$(git rev-parse --show-toplevel 2>/dev/null) || setup "not inside a git repo"
cd "$root"
for tool in curl python3; do command -v "$tool" >/dev/null || setup "$tool is not installed"; done
[[ -x scripts/check.sh ]] || setup "scripts/check.sh is missing; run new-project.sh --adopt --refresh"

# owner/repo from origin as configured, not as an insteadOf rewrites it.
url=$(git config --get remote.origin.url) || setup "this repo has no origin"
[[ $url =~ github\.com[:/]([^/]+)/([^/]+)$ ]] || setup "origin is not a GitHub repo"
owner=${BASH_REMATCH[1]} repo=${BASH_REMATCH[2]%.git}
api=https://api.github.com/repos/$owner/$repo

token=$(sed -n 's/^GITHUB_PERSONAL_ACCESS_TOKEN=//p' mcp/.env 2>/dev/null || true)
[[ -n $token ]] || setup "no GITHUB_PERSONAL_ACCESS_TOKEN in mcp/.env (agent.md §4, step 2)"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# --- GitHub ------------------------------------------------------------------
# call <method> <path> [json file] [curl -w format]: the body lands in
# $tmp/resp, the -w value (by default the status code) on stdout. The token
# reaches curl as a config line on stdin, so it is never in argv.
call() {
  local fmt=${4:-}
  [[ -n $fmt ]] || fmt='%{http_code}'
  local args=(-sS -m 30 -X "$1" -o "$tmp/resp" -w "$fmt"
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
  [[ -z ${3:-} ]] || args+=(-H 'Content-Type: application/json' --data-binary "@$3")
  printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -K - "${args[@]}" "$api$2"
}
py() { python3 -I -c "$@"; }
# refused <status> <request> <what the token needs>: GitHub's own message, and the fix.
refused() {
  local msg
  msg=$(py 'import json,sys; print(json.load(sys.stdin).get("message", ""))' <"$tmp/resp" 2>/dev/null) || msg=
  case $1 in
    401) stop "GitHub refused the token in mcp/.env ($1: $msg)" "it has expired or was revoked: make a new one (mcp/README.md)" ;;
    403|404) stop "$2: $1 ${msg:-}" "the token in mcp/.env needs $3 (mcp/README.md)" ;;
    *) stop "$2: $1 ${msg:-}" ;;
  esac
}
# get <path> <what the token needs>: the JSON body in $tmp/resp. Never in a
# pipe or $(...): a refusal must stop the script, not a subshell.
get() {
  local code
  code=$(call GET "$1") || setup "could not reach api.github.com"
  [[ $code == 200 ]] || refused "$code" "GET $1" "$2"
}

# The run that decides: a green one if there is one (a redeploy after a
# failure counts), else the newest. "none" while GitHub has not made one yet.
pick_run='
import json, sys
runs = json.load(sys.stdin).get("workflow_runs", [])
green = [r for r in runs if r.get("conclusion") == "success"]
r = (green or runs or [None])[0]
print("none - - -" if r is None else "%s %s %s %s" % (r["status"], r.get("conclusion") or "-", r["id"], r["html_url"]))'

# why <run id>: the failed jobs and steps, and the end of the first one's log.
why() {
  local id name steps loc
  get "/actions/runs/$1/jobs?per_page=50" "Actions: Read-only"
  py '
import json, sys
for j in json.load(sys.stdin).get("jobs", []):
    if j.get("conclusion") not in ("success", "skipped", None):
        bad = [s["name"] for s in j.get("steps", []) if s.get("conclusion") == "failure"]
        print("%s\t%s\t%s" % (j["id"], j["name"], ", ".join(bad) or j["conclusion"]))' <"$tmp/resp" >"$tmp/jobs" || return 0
  while IFS=$'\t' read -r id name steps; do printf '     failed: %s (%s)\n' "$name" "$steps"; done <"$tmp/jobs"
  IFS=$'\t' read -r id _ <"$tmp/jobs" || return 0
  # The log endpoint answers with a redirect to a signed link. That host
  # refuses the API's Authorization header (401), and needs none.
  loc=$(call GET "/actions/jobs/$id/logs" '' '%{redirect_url}') || return 0
  [[ -n $loc ]] || return 0
  printf '     the end of its log:\n'
  curl -sS -m 60 "$loc" 2>/dev/null | tail -n 30 | sed 's/^/     | /' || true
}

# watch <workflow file> <query> <label>: wait until the run of that workflow
# for this commit is done, then pass on green and stop on anything else.
watch() {
  local wf=$1 query=$2 label=$3 deadline=$((SECONDS + timeout * 60)) said=
  local status conclusion id link
  while :; do
    get "/actions/workflows/$wf/runs?head_sha=$sha$query&per_page=20" "Actions: Read-only"
    read -r status conclusion id link <<<"$(py "$pick_run" <"$tmp/resp")"
    if [[ $status == completed ]]; then
      [[ $conclusion == success ]] && { ok "$label ($link)"; return 0; }
      printf 'STOP %s: %s\n     %s\n' "$label" "$conclusion" "$link"
      why "$id"
      exit 1
    fi
    if (( SECONDS >= deadline )); then
      case $status in
        none) stop "$label: no run for $short after $timeout minutes" "was it pushed? does $wf run on this branch?" ;;
        queued|waiting|pending) stop "$label: still $status after $timeout minutes ($link)" \
          "no runner has taken it: is the runner up (Settings → Actions → Runners)? Run scripts/release.sh again to keep watching" ;;
        *) stop "$label: still $status after $timeout minutes ($link)" "run scripts/release.sh again to keep watching" ;;
      esac
    fi
    [[ $said == "$status" ]] || { printf '..   %s: %s, waiting\n' "$label" "${status/none/no run yet}"; said=$status; }
    sleep 15
  done
}

proof() {
  watch ci.yml "&branch=main&event=push" "proof: ci on main"
  if git cat-file -e "$sha:.github/workflows/deploy.yml" 2>/dev/null; then
    watch deploy.yml "&branch=main" "proof: deploy"
  else
    ok "proof: no deploy.yml, so ci on main is the whole release"
  fi
  printf 'released: main is at %s\n' "$short"
}

# --- 1. ready ----------------------------------------------------------------
printf 'release %s/%s\n' "$owner" "$repo"
branch=$(git symbolic-ref -q --short HEAD) || branch=
[[ $branch == dev ]] || stop "ready: on ${branch:-a detached HEAD}, not dev" "git switch dev"
[[ -z $(git status --porcelain) ]] \
  || stop "ready: the tree has changes not committed" "commit or stash them: a release is what is committed, and check.sh reads the tree"
git fetch -q --prune origin || setup "could not fetch origin"
sha=$(git rev-parse dev) short=$(git rev-parse --short dev)
[[ $(git rev-parse -q --verify refs/remotes/origin/dev || true) == "$sha" ]] \
  || stop "ready: dev is not what origin has" "push dev and let CI pass on it (or pull, if origin is ahead), then run this again"
base=$(git rev-parse -q --verify refs/remotes/origin/main) \
  || stop "ready: origin has no main yet" "a repo's first main is made with the owner, not by this script"
if [[ $base == "$sha" ]]; then
  ok "ready: main is already at dev ($short)"
  (( ! dry )) || exit 0
  proof
  exit 0
fi
git merge-base --is-ancestor "$base" "$sha" \
  || stop "ready: main has commits dev does not, so it cannot fast-forward" \
    "git log --oneline dev..origin/main lists them; bring them into dev, push, let CI pass, then run this again"
n=$(git rev-list --count "$base..$sha")
ok "ready: dev $short is $n commit(s) ahead of main"
commits=$(git log --reverse --format='- %h %s' "$base..$sha")
printf '%s\n' "$commits" | sed 's/^/     /'

# --- 2. tested ---------------------------------------------------------------
watch ci.yml "&branch=dev&event=push" "tested: ci on dev"

# --- 3. clean ----------------------------------------------------------------
if ! CHECK_RANGE="$base..$sha" scripts/check.sh fast >"$tmp/check" 2>&1; then
  sed 's/^/     /' "$tmp/check"
  stop "clean: scripts/check.sh fast refused what main would gain" "fix it on dev, push, let CI pass, then run this again"
fi
ok "clean: scripts/check.sh fast on the $n commit(s)"

# --- 4. on record ------------------------------------------------------------
get "/pulls?state=open&base=main&head=$owner:dev&per_page=5" "Pull requests: Read and write"
pr=$(py 'import json,sys; p=json.load(sys.stdin); print("%s %s" % (p[0]["number"], p[0]["html_url"]) if p else "")' <"$tmp/resp")
if (( dry )); then
  if [[ -n $pr ]]; then ok "on record: would update PR #${pr%% *} (${pr#* })"; else ok "on record: would open a dev → main PR"; fi
  printf 'dry run: stopped before the push; main is still at %s\n' "$(git rev-parse --short "$base")"
  exit 0
fi
# The backticks are Markdown for GitHub, not a command (SC2016).
# shellcheck disable=SC2016
TITLE="release: dev $short to main ($n commit(s))" COMMITS=$commits SHA=$sha py '
import json, os
print(json.dumps({"title": os.environ["TITLE"], "head": "dev", "base": "main", "body":
  "Released by `scripts/release.sh`: main fast-forwards to %s, so these commits keep their SHAs "
  "and GitHub marks this PR merged on its own. Never merge it with the button: every merge "
  "method rewrites them under an identity GitHub picks.\n\n%s\n" % (os.environ["SHA"], os.environ["COMMITS"])}))' >"$tmp/pr.json"
if [[ -n $pr ]]; then
  code=$(call PATCH "/pulls/${pr%% *}" "$tmp/pr.json") || setup "could not reach api.github.com"
  [[ $code == 200 ]] || refused "$code" "update PR #${pr%% *}" "Pull requests: Read and write"
  ok "on record: PR #${pr%% *} (${pr#* })"
else
  code=$(call POST /pulls "$tmp/pr.json") || setup "could not reach api.github.com"
  [[ $code == 201 ]] || refused "$code" "open the dev → main PR" "Pull requests: Read and write"
  ok "on record: opened $(py 'import json,sys; p=json.load(sys.stdin); print("PR #%s (%s)" % (p["number"], p["html_url"]))' <"$tmp/resp")"
fi

# --- 5. release --------------------------------------------------------------
# No --force, ever: if main moved since the fetch, git refuses, and that is
# the answer. The pre-push hook runs here as on any push.
if ! git push origin "$sha:refs/heads/main" >"$tmp/push" 2>&1; then
  sed 's/^/     /' "$tmp/push"
  stop "release: origin refused the push to main" "nothing was released; read the reason above"
fi
ok "release: main is now $short"

# --- 6. proof ----------------------------------------------------------------
proof
