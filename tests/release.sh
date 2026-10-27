#!/usr/bin/env bash
# Prove skel/scripts/release.sh stops at each gate it should, and releases only
# by a fast-forward, against fixture repos and a fake GitHub API: a curl on
# PATH that answers from a state file. Nothing reaches the network.
#
#   tests/release.sh
#
# Each fixture's origin is "https://github.com/acme/widget.git" (what the
# script reads to find the repo), rewritten by insteadOf to a local bare repo,
# so the push in gate 5 is a real push. Its scripts/check.sh is a stand-in
# that records what it was asked and answers $FAKE_CHECK.
#
# Exit 0 = every case behaved, 1 = at least one did not, 2 = setup error.
#
# Single-quoted snippets run in a child bash with their own $1 (SC2016), and
# some helpers are only ever called through check() (SC2329).
# shellcheck disable=SC2016,SC2329
set -euo pipefail

tpl=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script=$tpl/skel/scripts/release.sh
[[ -x $script ]] || { echo "release: missing or not executable: $script" >&2; exit 2; }
command -v python3 >/dev/null || { echo "release: needs python3" >&2; exit 2; }

t=$(mktemp -d "${TMPDIR:-/tmp}/release-test.XXXXXX")
trap 'rm -rf -- "$t"' EXIT
export GIT_CONFIG_GLOBAL=$t/gitconfig GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE CHECK_RANGE
printf '[user]\n\tname = AngryTechGremlin\n\temail = AngryTechGremlin@users.noreply.github.com\n[init]\n\tdefaultBranch = main\n' \
  >"$GIT_CONFIG_GLOBAL"
fake=fixture-placeholder-value

# --- the fake GitHub -----------------------------------------------------------
mkdir -p "$t/bin"
cat >"$t/bin/curl" <<'PY'
#!/usr/bin/env python3
"""Answers the calls release.sh makes, from $FAKE_GH/state.json. Logs each."""
import json, os, re, sys
from urllib.parse import urlparse, parse_qs

gh = os.environ["FAKE_GH"]
state = json.load(open(os.path.join(gh, "state.json")))
a = sys.argv[1:]
method, out, fmt, data, auth, url = "GET", None, "", None, False, None
i = 0
while i < len(a):
    x = a[i]
    if x == "-K" and a[i + 1] == "-":
        auth = "Authorization: Bearer " in sys.stdin.read(); i += 2
    elif x == "-X": method = a[i + 1]; i += 2
    elif x == "-o": out = a[i + 1]; i += 2
    elif x == "-w": fmt = a[i + 1]; i += 2
    elif x == "--data-binary": data = open(a[i + 1][1:]).read(); i += 2
    elif x in ("-H", "-m"): i += 2
    elif x.startswith("-"): i += 1
    else: url = x; i += 1
u = urlparse(url)
q = {k: v[0] for k, v in parse_qs(u.query).items()}
with open(os.path.join(gh, "calls"), "a") as f:
    f.write(json.dumps({"method": method, "url": url, "auth": auth, "argv": a, "data": data}) + "\n")

code, body, loc = 200, {}, ""
p = u.path
runs_url = "https://github.com/acme/widget/actions/runs/"
if u.hostname == "logs.example.invalid":
    sys.stdout.write("".join("log line %d\n" % n for n in range(1, 41))); sys.exit(0)
if not state.get("token_ok", True):
    code, body = 401, {"message": "Bad credentials"}
elif m := re.fullmatch(r"/repos/acme/widget/actions/workflows/(\w+)\.yml/runs", p):
    c = state.get(m[1], {}).get(q.get("branch"))
    runs = []
    if c:
        done = c not in ("queued", "in_progress")
        rid = {"ci": 100, "deploy": 200}[m[1]] + len(q.get("branch", ""))
        runs = [{"id": rid, "status": "completed" if done else c, "conclusion": c if done else None,
                 "html_url": runs_url + str(rid)}]
    body = {"total_count": len(runs), "workflow_runs": runs}
elif re.fullmatch(r"/repos/acme/widget/actions/runs/\d+/jobs", p):
    body = {"jobs": [{"id": 7, "name": "hygiene", "conclusion": "failure",
                      "steps": [{"name": "house checks", "conclusion": "failure"}]}]}
elif p == "/repos/acme/widget/actions/jobs/7/logs":
    code, loc = 302, "https://logs.example.invalid/job/7"
elif p == "/repos/acme/widget/pulls" and method == "GET":
    body = state.get("pulls", [])
elif re.fullmatch(r"/repos/acme/widget/pulls(/\d+)?", p) and method in ("POST", "PATCH"):
    if state.get("pr_write", True):
        code = 201 if method == "POST" else 200
        body = {"number": 9, "html_url": "https://github.com/acme/widget/pull/9"}
    else:
        code, body = 403, {"message": "Resource not accessible by personal access token"}
else:
    code, body = 404, {"message": "Not Found"}
if out:
    open(out, "w").write(json.dumps(body))
sys.stdout.write(fmt.replace("%{http_code}", str(code)).replace("%{redirect_url}", loc))
PY
chmod +x "$t/bin/curl"

# --- fixtures --------------------------------------------------------------------
# fixture [deploy]: a repo with main one commit behind dev, both on origin.
fixture() {
  rm -rf -- "$t/fx" "$t/widget.git" "$t/gh"
  mkdir -p "$t/gh"
  git init -q --bare "$t/widget.git"
  git init -q "$t/fx"
  local f=$t/fx
  git -C "$f" remote add origin https://github.com/acme/widget.git
  git -C "$f" config url."$t/widget.git".insteadOf https://github.com/acme/widget.git
  mkdir -p "$f/scripts" "$f/mcp" "$f/.github/workflows"
  printf 'mcp/.env\n' >"$f/.gitignore"
  printf 'GITHUB_PERSONAL_ACCESS_TOKEN=%s\n' "$fake" >"$f/mcp/.env"
  printf '#!/usr/bin/env bash\necho "CHECK_RANGE=$CHECK_RANGE $1" >>"$FAKE_GH/check"\nexit "${FAKE_CHECK:-0}"\n' \
    >"$f/scripts/check.sh"
  chmod +x "$f/scripts/check.sh"
  printf 'name: ci\n' >"$f/.github/workflows/ci.yml"
  if [[ ${1:-} == deploy ]]; then printf 'name: deploy\n' >"$f/.github/workflows/deploy.yml"; fi
  git -C "$f" add -A && git -C "$f" commit -q -m 'feat: one'
  git -C "$f" push -q origin HEAD:main
  git -C "$f" switch -q -c dev
  printf 'two\n' >"$f/two.md"
  git -C "$f" add -A && git -C "$f" commit -q -m 'feat: two'
  git -C "$f" push -q origin dev
  git -C "$f" fetch -q origin
  base=$(git -C "$f" rev-parse main) sha=$(git -C "$f" rev-parse dev)
  gh_state '{"ci": {"dev": "success", "main": "success"}, "deploy": {"main": "success"}}'
}
gh_state() { printf '%s\n' "$1" >"$t/gh/state.json"; }
origin_main() { git --git-dir="$t/widget.git" rev-parse main; }
calls() { cat "$t/gh/calls" 2>/dev/null || true; }

rows=()
failed=0
n=0
out=
pass() { rows+=("PASS  $1"); }
fail() { rows+=("FAIL  $1"); failed=1; }
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
release() { (cd "$t/fx" && PATH="$t/bin:$PATH" FAKE_GH=$t/gh bash "$script" --timeout 0 "$@"); }
expect() { # <exit> <output regex> <case> [release args...]
  local want=$1 re=$2 name=$3 rc=0
  shift 3
  out=$t/out.$((n += 1))
  release "$@" >"$out" 2>&1 || rc=$?
  if (( rc != want )); then
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
unmoved() { [[ $(origin_main) == "$base" ]]; }
no_pr_write() { ! calls | grep -qE '"method": "(POST|PATCH)"'; }

# --- gate 1: ready -----------------------------------------------------------------
fixture
git -C "$t/fx" switch -q main
expect 1 'STOP ready: on main, not dev' 'ready: refused off dev'
git -C "$t/fx" switch -q dev
printf 'x\n' >"$t/fx/stray.md"
expect 1 'STOP ready: the tree has changes not committed' 'ready: refused with an untracked file'
rm "$t/fx/stray.md"
git -C "$t/fx" commit -q --allow-empty -m 'feat: three'
expect 1 'STOP ready: dev is not what origin has' 'ready: refused with dev not pushed'
check "  ...and origin's main did not move" unmoved

fixture
git -C "$t/fx" switch -q -c hotfix main
git -C "$t/fx" commit -q --allow-empty -m 'fix: straight to main'
git -C "$t/fx" push -q origin hotfix:main
git -C "$t/fx" switch -q dev
expect 1 'cannot fast-forward' 'ready: refused when main has commits dev does not'

fixture
git --git-dir="$t/widget.git" update-ref -d refs/heads/main
git -C "$t/fx" fetch -q --prune origin
expect 1 'origin has no main yet' 'ready: refused with no main on origin'

# --- gate 2: tested ----------------------------------------------------------------
fixture
gh_state '{"ci": {"dev": "failure"}}'
expect 1 'STOP tested: ci on dev: failure' 'tested: refused when ci failed on dev'
check "  ...names the failed job and step" grep -q 'failed: hygiene (house checks)' "$out"
check "  ...shows the end of its log" grep -q '| log line 40' "$out"
check "  ...and not the start" bash -c '! grep -q "| log line 10$" "$1"' _ "$out"
check "  ...fetched the log link without the token" \
  bash -c 'grep logs.example.invalid "$1" | grep -q "\"auth\": false"' _ "$t/gh/calls"
check "  ...opened no PR" no_pr_write
check "  ...and main did not move" unmoved
gh_state '{"ci": {"dev": "queued"}}'
expect 1 'still queued after 0 minutes' 'tested: a queued run past the timeout stops'
check "  ...and asks whether the runner is up" grep -q 'is the runner up' "$out"
gh_state '{"ci": {}}'
expect 1 'no run for' 'tested: no run at all stops'

# --- gate 3: clean -----------------------------------------------------------------
fixture
FAKE_CHECK=1 expect 1 'STOP clean' 'clean: refused when check.sh fast fails'
check "  ...check.sh read exactly the commits main would gain" \
  grep -qxF "CHECK_RANGE=$base..$sha fast" "$t/gh/check"
check "  ...opened no PR" no_pr_write
check "  ...and main did not move" unmoved

# --- dry run -----------------------------------------------------------------------
fixture
expect 0 'would open a dev → main PR' 'dry run: passes 1–3 and stops' --dry-run
check "  ...lists the commits" grep -q 'feat: two' "$out"
check "  ...opened no PR" no_pr_write
check "  ...and main did not move" unmoved

# --- gate 4: on record -------------------------------------------------------------
fixture
gh_state '{"ci": {"dev": "success", "main": "success"}, "pr_write": false}'
expect 1 'needs Pull requests: Read and write' 'on record: a token without PR write stops before the push'
check "  ...and main did not move" unmoved

fixture
gh_state '{"token_ok": false}'
expect 1 'expired or was revoked' 'a revoked token stops at the first call'

fixture
rm "$t/fx/mcp/.env"
expect 2 'no GITHUB_PERSONAL_ACCESS_TOKEN' 'no token is a setup error'

# --- gates 5 and 6: the release ----------------------------------------------------
fixture
expect 0 'released: main is at' 'release: no deploy.yml, ci on main is the proof'
check "  ...origin's main is dev's own commit" test "$(origin_main)" = "$sha"
check "  ...said there is no deploy" grep -q 'no deploy.yml' "$out"
check "  ...opened the dev → main PR, the commits as its body" \
  python3 -I -c 'import json,sys
c = [json.loads(l) for l in open(sys.argv[1])]
p = [json.loads(x["data"]) for x in c if x["method"] == "POST"]
assert len(p) == 1 and p[0]["head"] == "dev" and p[0]["base"] == "main" and "feat: two" in p[0]["body"]' "$t/gh/calls"
check "  ...every API call carried the token" \
  python3 -I -c 'import json,sys
c = [json.loads(l) for l in open(sys.argv[1])]
assert all(x["auth"] for x in c if "api.github.com" in x["url"])' "$t/gh/calls"
check "  ...and never in argv" bash -c '! grep -qF "$1" "$2"' _ "$fake" "$t/gh/calls"
expect 0 'main is already at dev' 'release again: goes straight to the proof'
check "  ...and pushes nothing new" test "$(origin_main)" = "$sha"

fixture deploy
gh_state '{"ci": {"dev": "success", "main": "success"}, "deploy": {"main": "failure"}}'
expect 1 'STOP proof: deploy: failure' 'proof: a failed deploy is a failed release'
check "  ...after main moved" test "$(origin_main)" = "$sha"
gh_state '{"ci": {"dev": "success", "main": "success"}, "deploy": {"main": "success"}}'
expect 0 'ok   proof: deploy \(https://github.com/acme/widget/actions/runs/' 'proof: a green deploy, with its link'

fixture
gh_state '{"ci": {"dev": "success", "main": "failure"}}'
expect 1 'STOP proof: ci on main: failure' 'proof: ci red on main stops'

fixture
gh_state '{"ci": {"dev": "success", "main": "success"}, "pulls": [{"number": 4, "html_url": "https://github.com/acme/widget/pull/4"}]}'
expect 0 'on record: PR #4' 'on record: an open PR is updated, not a second one opened'
check "  ...by PATCH to #4, no POST" \
  bash -c 'grep -q "\"PATCH\".*pulls/4" "$1" && ! grep -q "\"POST\"" "$1"' _ "$t/gh/calls"

# Refusing a non-fast-forward is git's own job, not the script's; what the
# script must do is never ask git to force, nor ask GitHub to merge.
check "the script never forces a push" bash -c '! grep -nE "push.*(--force|-f |\+)" "$1"' _ "$script"
check "the script never calls the merge API" bash -c '! grep -nE "/merges?\b|/merge\"" "$1"' _ "$script"

printf '\nrelease\n'
printf '  %s\n' "${rows[@]}"
bad=$(printf '%s\n' "${rows[@]}" | grep -c '^FAIL' || true)
printf '\n%s of %s passed\n' "$(( ${#rows[@]} - bad ))" "${#rows[@]}"
exit "$failed"
