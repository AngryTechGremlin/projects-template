#!/usr/bin/env bash
# Prove publish/add-public-key.sh makes one key per repo, keeps it private,
# prints the two pastes, and refuses what it must. Offline: the --done check
# that asks GitHub is exercised by hand (skel/docs/publishing.md).
#
#   tests/publish-key.sh
#
# Exit 0 = every case behaved, 1 = at least one did not, 2 = setup error.
set -euo pipefail

tpl=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
kit=$tpl/publish/add-public-key.sh
[[ -x $kit ]] || { echo "publish-key: $kit is missing or not executable" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export PROJECTS_DIR=$tmp/projects PUBLISH_KEYS_DIR=$tmp/keys GITHUB_OWNER=SomeOwner

rows=()
failed=0
ok() { rows+=("PASS  $1"); }
no() { rows+=("FAIL  $1"); failed=1; }
expect() { # <want exit> <what> <args...>; stdin is never a terminal here
  local want=$1 what=$2 rc=0
  shift 2
  "$kit" "$@" </dev/null >"$tmp/out" 2>&1 || rc=$?
  if (( rc == want )); then ok "$what (exit $rc)"; else no "$what: want exit $want, got $rc"; fi
}

expect 0 "--help" --help
expect 2 "no repo" ""
expect 2 "a name with capitals" Bad
expect 2 "a repo with no PUBLISH file" x

mkdir -p "$PROJECTS_DIR/x"
printf '[publish]\n\trepo = SomeOrg/X-Public\n\tpath = README.md\n' >"$PROJECTS_DIR/x/PUBLISH"
expect 0 "makes the key" x
holds() { # <what> <command...>: PASS when the command succeeds
  local what=$1
  shift
  if "$@"; then ok "$what"; else no "$what"; fi
}
holds "  ...readable by its owner only" test "$(stat -c %a "$PUBLISH_KEYS_DIR/x")" = 600
holds "  ...names the public repo's deploy-key page" grep -q 'https://github.com/SomeOrg/X-Public/settings/keys/new' "$tmp/out"
holds "  ...names the private repo's secret page" grep -q 'https://github.com/SomeOwner/x/settings/secrets/actions/new' "$tmp/out"
holds "  ...names the secret the publish job reads" grep -q 'PUBLIC_DEPLOY_KEY' "$tmp/out"
# The single quotes are for the inner shell, which expands $1 itself.
# shellcheck disable=SC2016
holds "  ...never prints the private half" bash -c '! grep -q -- "-----BEGIN" "$1"' _ "$tmp/out"
expect 1 "a second run refuses, never replacing a key" x
mkdir -p "$PROJECTS_DIR/y"
cp "$PROJECTS_DIR/x/PUBLISH" "$PROJECTS_DIR/y/PUBLISH"
expect 1 "--done with no key made yet has nothing to finish" --done y

printf '  %s\n' "${rows[@]}"
exit "$failed"
