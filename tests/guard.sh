#!/usr/bin/env bash
# Prove the folder-based deploy guard (skel/docs/ci-runner.md, "The deploy
# guard") lets prod's runner through and nothing else, using fake workspaces.
# The snippet is read out of the docs, not copied here, so what is tested is
# what every repo pastes.
#
#   tests/guard.sh
#
# Exit 0 = every case behaved, 1 = at least one did not, 2 = setup error.
#
# The runner's own folder (/opt/actions-runners/x, nothing after it) passes,
# and that is right: it is still the folder only root can make for this repo.
# GitHub never runs a job there anyway; workspaces are under its _work/.
set -euo pipefail

tpl=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
doc=$tpl/skel/docs/ci-runner.md
readme=$tpl/README.md
# The literal text that opens the guard, not an expansion.
# shellcheck disable=SC2016
start='case "$GITHUB_WORKSPACE/" in'
[[ -f $doc ]] || { echo "guard: missing $doc" >&2; exit 2; }

# Every line that starts the guard, with its indent dropped.
snippets() { grep -F -- "$start" "$1" | sed 's/^[[:space:]]*//' || true; }
mapfile -t found < <(snippets "$doc")
(( ${#found[@]} == 1 )) \
  || { echo "guard: want the snippet once in skel/docs/ci-runner.md, found ${#found[@]}" >&2; exit 2; }
guard=${found[0]}

rows=()
failed=0
pass() { rows+=("PASS  $1"); }
fail() { rows+=("FAIL  $1"); failed=1; }

# The README shows the same line; a copy that drifted would teach the old one.
mapfile -t copies < <(snippets "$readme")
if (( ${#copies[@]} == 0 )); then
  fail "README.md shows the guard"
else
  same=1
  for c in "${copies[@]}"; do [[ $c == "$guard" ]] || same=0; done
  if (( same )); then pass "README.md's copy is the same line"; else fail "README.md's copy differs from ci-runner.md's"; fi
fi

# A runner runs a step as `bash -e {0}`, or `sh -e {0}` when a workflow sets
# no shell, with the job's variables and nothing else of ours. Both must agree.
run_guard() { # <shell> <repo or "-" for unset> <workspace>
  local env=(PATH="$PATH" RUNNER_NAME=fake-runner GITHUB_WORKSPACE="$3")
  [[ $2 == - ]] || env+=(GITHUB_REPOSITORY="$2")
  env -i "${env[@]}" "$1" -e -c "$guard" >/dev/null 2>&1
}
expect() { # <0 pass | 1 refuse> <case> <repo> <workspace>
  local want=$1 name=$2 sh rc
  for sh in bash sh; do
    rc=0
    run_guard "$sh" "$3" "$4" || rc=$?
    (( rc == want )) || { fail "$name: exit $rc under $sh, want $want"; return 0; }
  done
  pass "$name (exit $want)"
}

o=AngryTechGremlin
expect 0 "prod's runner: /opt/actions-runners/x/_work/x/x" "$o/x" /opt/actions-runners/x/_work/x/x
expect 0 "the runner's own folder, nothing after it" "$o/x" /opt/actions-runners/x
expect 0 "a dotted repo name: /opt/actions-runners/a.b/_work/a.b/a.b" "$o/a.b" /opt/actions-runners/a.b/_work/a.b/a.b
expect 1 "a CI runner: ~/actions-runner/x-ci/_work/x/x" "$o/x" "$HOME/actions-runner/x-ci/_work/x/x"
expect 1 "another repo's prod runner: /opt/actions-runners/xy/_work/xy/xy" "$o/x" /opt/actions-runners/xy/_work/xy/xy
expect 1 "a shorter name's prod runner: /opt/actions-runners/x/... for repo xy" "$o/xy" /opt/actions-runners/x/_work/x/x
expect 1 "the parent folder: /opt/actions-runners/" "$o/x" /opt/actions-runners/
expect 1 "the same path under another root: /tmp/opt/actions-runners/x/..." "$o/x" /tmp/opt/actions-runners/x/_work/x/x
expect 1 "an empty workspace" "$o/x" ''
expect 1 "GITHUB_REPOSITORY unset" - /opt/actions-runners/x/_work/x/x
expect 1 "GITHUB_REPOSITORY with an empty name part" "$o/" /opt/actions-runners/x/_work/x/x

# A refusal must say why, in the workflow's error format.
msg=$(env -i PATH="$PATH" RUNNER_NAME=fake-runner GITHUB_REPOSITORY="$o/x" \
  GITHUB_WORKSPACE=/tmp/w bash -e -c "$guard" 2>&1 || true)
if [[ $msg == "::error::"*fake-runner* ]]; then pass "a refusal prints ::error:: and the runner's name"; else fail "a refusal prints ::error:: and the runner's name (got: $msg)"; fi

printf '\ndeploy guard\n'
printf '  %s\n' "${rows[@]}"
bad=$(printf '%s\n' "${rows[@]}" | grep -c '^FAIL' || true)
printf '\n%s of %s passed\n' "$(( ${#rows[@]} - bad ))" "${#rows[@]}"
exit "$failed"
