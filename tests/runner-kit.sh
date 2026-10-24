#!/usr/bin/env bash
# Prove runners/add-runner.sh refuses what it must, before it downloads or
# registers anything: bad usage, a bad name, a runner already there, a prod
# folder root has not handed over. Nothing here touches the network, systemd
# or a real runner folder; the happy path needs a real token and is checked
# by hand (skel/docs/ci-runner.md).
#
#   tests/runner-kit.sh
#
# Exit 0 = every case behaved, 1 = at least one did not, 2 = setup error.
set -euo pipefail

tpl=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
kit=$tpl/runners/add-runner.sh
[[ -x $kit ]] || { echo "runner-kit: $kit is missing or not executable" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

rows=()
failed=0
# <want exit> <what> <command...>; stdin is never a terminal here.
expect() {
  local want=$1 what=$2 rc=0
  shift 2
  "$@" </dev/null >"$tmp/out" 2>&1 || rc=$?
  if (( rc == want )); then rows+=("PASS  $what (exit $rc)"); else rows+=("FAIL  $what: want exit $want, got $rc"); failed=1; fi
}

expect 0 "--help" "$kit" --help
expect 2 "no arguments" "$kit"
expect 2 "a mode but no repo" "$kit" ci
expect 2 "an unknown mode" "$kit" deploy x
expect 2 "a name with capitals and a space" "$kit" ci 'Bad Name'
expect 2 "a name with a slash" "$kit" ci a/b

mkdir -p "$tmp/ci/x-ci"
touch "$tmp/ci/x-ci/.runner"
expect 1 "ci: a registered runner is refused, not replaced" env ACTIONS_RUNNER_DIR="$tmp/ci" "$kit" ci x

expect 2 "prod: a folder root has not made yet" env PROD_RUNNER_DIR="$tmp/opt" "$kit" prod x
if grep -q 'sudo mkdir -p .* && sudo chown ' "$tmp/out"; then
  rows+=("PASS    ...and it prints the sudo line to run")
else
  rows+=("FAIL    ...and it prints the sudo line to run"); failed=1
fi
mkdir -p "$tmp/opt/y"
touch "$tmp/opt/y/.runner"
expect 1 "prod: a registered runner is refused, not replaced" env PROD_RUNNER_DIR="$tmp/opt" "$kit" prod y
mkdir -p "$tmp/opt/z"
touch "$tmp/opt/z/stray"
expect 1 "prod: a folder with files but no runner is refused" env PROD_RUNNER_DIR="$tmp/opt" "$kit" prod z

printf '  %s\n' "${rows[@]}"
exit "$failed"
