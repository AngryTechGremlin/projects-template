#!/usr/bin/env bash
# Prove refresh-all.sh brings a repo up to the template on its dev, on GitHub's
# copy only: a stand-in bare repo plays GitHub, the template is this commit.
# It must leave the working checkout alone (its uncommitted file, its unpushed
# commit), skip a repo with no dev, push nothing on a dry run, and stop early
# with --if-changed once a run has completed.
#
#   tests/refresh-all.sh
#
# Exit 0 = every case behaved, 1 = at least one did not, 2 = setup error.
#
# The bash -c bodies below are single-quoted on purpose: their $1 and $2 are
# the inner shell's own arguments.
# shellcheck disable=SC2016
set -euo pipefail

tpl=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf -- "$t"' EXIT
export PROJECTS_DIR=$t/projects XDG_STATE_HOME=$t/state REFRESH_TEMPLATE_REF=HEAD
mkdir -p -- "$PROJECTS_DIR"
ver=$(git -C "$tpl" rev-parse HEAD)
# Any other commit id will do as "an older template": CI checks out only the
# commit under test, so there is no real HEAD~1 to name.
old=0000000000000000000000000000000000000001
# Fixture commits skip the hooks: they are the stand-in history, not the test.
g() { git -c user.name=AngryTechGremlin -c user.email=AngryTechGremlin@users.noreply.github.com -c core.hooksPath=/dev/null "$@"; }

rows=()
failed=0
check() { # <case> <command...>
  local name=$1
  shift
  if "$@"; then rows+=("PASS  $name"); else rows+=("FAIL  $name"); failed=1; fi
}

# demo: adopted a while ago (an older template version, an older check.sh),
# on dev, with a session's uncommitted file and unpushed commit locally.
git init -q --bare "$t/demo.git"
d=$PROJECTS_DIR/demo
git init -q -b main "$d"
printf '# demo\n' >"$d/README.md"
"$tpl/new-project.sh" --adopt "$d" --no-mcp --no-build >/dev/null
printf '%s\n' "$old" >"$d/.template-version"
printf '# an older check.sh\n' >>"$d/scripts/check.sh"
g -C "$d" add -A && g -C "$d" commit -q -m 'chore: x'
g -C "$d" switch -q -c dev
g -C "$d" remote add origin "$t/demo.git"
g -C "$d" push -q origin main dev
g -C "$d" commit -q --allow-empty -m 'feat: a session commit not pushed yet'
printf 'wip\n' >"$d/wip.txt"
local_head=$(git -C "$d" rev-parse HEAD)
origin_dev=$(git -C "$t/demo.git" rev-parse dev)

# solo: has the checks, but no dev branch.
git init -q --bare "$t/solo.git"
s=$PROJECTS_DIR/solo
git init -q -b main "$s"
"$tpl/new-project.sh" --adopt "$s" --no-mcp --no-build >/dev/null
g -C "$s" add -A && g -C "$s" commit -q -m 'chore: x'
g -C "$s" remote add origin "$t/solo.git"
g -C "$s" push -q origin main

rc=0
"$tpl/refresh-all.sh" --dry-run >"$t/dry.out" 2>&1 || rc=$?
check "dry run: exit 0" test "$rc" = 0
check "  ...says it would push to demo's dev" grep -qE '^demo +would push [0-9a-f]+ to dev' "$t/dry.out"
check "  ...skips solo, which has no dev" grep -qE '^solo +skipped: no dev branch' "$t/dry.out"
check "  ...pushes nothing" test "$(git -C "$t/demo.git" rev-parse dev)" = "$origin_dev"

rc=0
"$tpl/refresh-all.sh" >"$t/run.out" 2>&1 || rc=$?
check "run: exit 0" test "$rc" = 0
check "  ...pushed to demo's dev" grep -qE '^demo +pushed [0-9a-f]+ to dev' "$t/run.out"
check "  ...dev records this template commit" test "$(git -C "$t/demo.git" show dev:.template-version)" = "$ver"
check "  ...dev's check.sh is the template's" \
  bash -c 'cmp -s <(git -C "$1" show dev:scripts/check.sh) <(git -C "$2" show HEAD:skel/scripts/check.sh)' _ "$t/demo.git" "$tpl"
check "  ...one commit on top of what GitHub had" test "$(git -C "$t/demo.git" rev-parse dev~1)" = "$origin_dev"
check "  ...the session's unpushed commit stayed local" \
  bash -c '! git -C "$1" log --format=%s dev | grep -q "not pushed yet"' _ "$t/demo.git"
check "  ...the working checkout is untouched" test "$(git -C "$d" rev-parse HEAD)" = "$local_head"
check "  ...and its uncommitted file is still there" test -f "$d/wip.txt"
check "  ...the run is recorded as complete" test "$(cat "$XDG_STATE_HOME/projects-template/last-complete")" = "$ver"

rc=0
"$tpl/refresh-all.sh" --if-changed >"$t/again.out" 2>&1 || rc=$?
check "--if-changed after a complete run: nothing to do" grep -q 'nothing to do' "$t/again.out"

rc=0
"$tpl/refresh-all.sh" demo >"$t/third.out" 2>&1 || rc=$?
check "a second run finds demo up to date" grep -qE '^demo +up to date' "$t/third.out"

printf '  %s\n' "${rows[@]}"
(( failed == 0 )) || { echo "--- dry run"; cat "$t/dry.out"; echo "--- run"; cat "$t/run.out"; }
exit "$failed"
