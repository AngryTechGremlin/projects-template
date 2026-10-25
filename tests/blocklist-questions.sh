#!/usr/bin/env bash
# Prove publish/add-to-blocklist.sh writes what was confirmed, in the form
# mirror.sh reads, and refuses what it must. It runs in a pseudo-terminal
# (util-linux script) inside bwrap, against made-up names only: a fake home,
# a fake /etc/hosts, and stand-ins for uname, nmcli, getent and tailscale, so
# nothing of the box running it is offered or printed.
#
#   tests/blocklist-questions.sh
#
# Exit 0 = every case behaved, 1 = at least one did not, 2 = setup error.
set -euo pipefail

tpl=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
kit=$tpl/publish/add-to-blocklist.sh
[[ -x $kit ]] || { echo "blocklist-questions: $kit is missing or not executable" >&2; exit 2; }
for tool in script bwrap timeout; do
  command -v "$tool" >/dev/null || { echo "blocklist-questions: missing $tool" >&2; exit 2; }
done
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
home=$tmp/home bin=$tmp/bin bl=$tmp/blocklist
mkdir -p "$home/.ssh" "$home/Projects/app" "$bin"

stub() { # <name> <body>
  printf '#!/bin/sh\n%s\n' "$2" >"$bin/$1"
  chmod +x "$bin/$1"
}
stub uname 'echo quillbox'
stub nmcli 'case "$*" in *802-11-wireless.ssid*) echo QuillNet ;; *) printf "QuillNet:802-11-wireless\nWired:802-3-ethernet\n" ;; esac'
stub getent 'echo "u:x:1000:1000:Ada Quillfeather,,,:/home/u:/bin/sh"'
stub tailscale 'echo "{}"'
printf 'Host quillnas\n  HostName quillnas.lan\nHost github.com\nHost *\n' >"$home/.ssh/config"
printf '[user]\n\tname = Ada Quillfeather\n\temail = ada@quill.test\n' >"$home/.gitconfig"
printf 'DB=postgres://app:notanaddress@db.lan/x\nMAIL=admin@quill.test\n' >"$home/Projects/app/.env"
printf '[publish]\n\trepo = SomeOrg/App\n' >"$home/Projects/app/PUBLISH"
printf '127.0.0.1 localhost\n203.0.113.9 quillprinter quillprinter.lan # printer\n::1 ip6-localhost\n' >"$tmp/hosts"

rows=()
failed=0
ok() { rows+=("PASS  $1"); }
no() { rows+=("FAIL  $1"); failed=1; }
holds() { # <what> <command...>: PASS when the command succeeds
  local what=$1
  shift
  if "$@"; then ok "$what"; else no "$what"; fi
}
# Only ever called through holds() (SC2329).
# shellcheck disable=SC2329
lacks() { # <regex> <file>: true when no line matches, in any case
  ! grep -qiE -- "$1" "$2"
}

# One answer per line, fed to the questions in a pseudo-terminal. A run that
# asks more than it is given waits for input, so each is bounded.
answer() { # <outfile> <answer...>
  local out=$1
  shift
  printf '%s\n' "$@" >"$tmp/answers"
  bwrap --dev-bind / / --ro-bind "$tmp/hosts" /etc/hosts -- \
    env HOME="$home" PROJECTS_DIR="$home/Projects" PUBLISH_BLOCKLIST="$bl" PATH="$bin:/usr/bin:/bin" \
    timeout 30 script -qec "$kit" /dev/null <"$tmp/answers" >"$out" 2>&1
}
# The entries as mirror.sh reads them: comments, blanks and padding dropped.
entries() { sed -e 's/\r//g' -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$bl" | grep -v '^$'; }

rc=0
env PUBLISH_BLOCKLIST="$bl" "$kit" </dev/null >"$tmp/out" 2>&1 || rc=$?
holds "refuses without a terminal (exit $rc)" test "$rc" = 2
holds "  ...and writes nothing" test ! -e "$bl"

printf '# a comment\nquillhouse\nlastline-no-newline' >"$bl"
chmod 644 "$bl"
# Offered, in order: quillbox (y), QuillNet (edit to QuillNet-guest),
# quillnas (y), quillprinter (n), admin and quill.test (y, y), and the
# surname Quillfeather (y); Ada is too short to offer. Then the questions, an
# empty answer ending each.
rc=0
answer "$tmp/run1" y e -guest y n y y y \
  "Bo Quillson" "Cassiopeia Quillson" y "" \
  ab SomeOrg "" \
  "has#hash" "" \
  "kid@quill.test" "" \
  "(555) 867-5309" "" \
  "quillhouse.lan" "" "" "" y || rc=$?
holds "a confirmed run exits 0 (exit $rc)" test "$rc" = 0
want='quillhouse
lastline-no-newline
quillbox
QuillNet-guest
quillnas
admin
quill.test
Quillfeather
Quillson
Cassiopeia
8675309
867-5309
867.5309'
holds "  ...adds what was confirmed, as entries mirror.sh reads, the last line kept whole" test "$(entries)" = "$want"
holds "  ...leaves the list readable by its owner only" test "$(stat -c %a "$bl")" = 600
holds "  ...skips the printer it was told no to, and db (too short to offer)" lacks '^(quillprinter|db)$' "$bl"
holds "  ...never offers a password from user:pass@host" lacks notanaddress "$tmp/run1"
holds "  ...refuses an entry under 4 characters" grep -q "'ab' is under 4 characters" "$tmp/run1"
holds "  ...refuses a word of a public name (it would stop every publish)" grep -q "'SomeOrg' is part of the public name" "$tmp/run1"
holds "  ...refuses an entry holding a #" grep -q "'has#hash' holds a #" "$tmp/run1"
holds "  ...says what the list already catches" grep -q 'already caught: quillhouse.lan' "$tmp/run1"

before=$(cksum <"$bl")
rc=0
# Offered again: QuillNet (only its -guest form went in) and quillprinter.
answer "$tmp/run2" n n "Dora Quillmore" n "" "" "" "" "" "" "" "" n || rc=$?
holds "saying no at the end exits 1 (exit $rc)" test "$rc" = 1
holds "  ...and writes nothing" test "$(cksum <"$bl")" = "$before"

printf '  %s\n' "${rows[@]}"
exit "$failed"
