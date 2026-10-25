#!/usr/bin/env bash
# Refuse to let personal data reach a committed file (agent.md §3).
#
# Scans tracked AND untracked-but-not-ignored files, so it tells the truth
# about what a commit would carry rather than only about what one already has.
#
# Two tiers, because a scanner nobody trusts is a scanner everybody disables:
#
#   HARD  credential shapes that are never a coincidence -- GitHub/OpenAI/
#         Anthropic/AWS/Google/npm/Slack keys, JWTs (a Home Assistant
#         long-lived token is one), Tailscale keys, PEM private key blocks,
#         and email addresses (in the house's apps an email is how a person
#         signs in), all but ones that belong to no one: GitHub noreply, any
#         noreply@ address, the example domains, .invalid, .test, .localhost,
#         or on a line that says it is an example. Scanned everywhere, scripts/pii-scan.exclude included; only this
#         script and the hook, which quote the patterns, are skipped. A hit
#         here is real; rotate the credential.
#
#   SOFT  things that are usually a fixture and occasionally a leak -- RFC1918
#         host addresses, MAC addresses, a password assigned a literal, GPS
#         coordinates. Scanned everywhere EXCEPT test paths, and skipped on
#         lines that are evidently an example (see $placeholder below).
#
# Structurally exempt, by construction rather than by exception list:
#   - documentation ranges 192.0.2.x / 198.51.100.x / 203.0.113.x (use these in
#     tests and docs -- they are reserved for exactly this and never route)
#   - .0 and .255 host octets, so network/broadcast addresses and CIDR blocks
#     (10.0.0.0/8, 192.168.0.0/16) read as topology, not as someone's device
#   - 127.0.0.1, 0.0.0.0, the all-zero and all-ff MACs, and the textbook
#     aa:bb:cc:dd:ee:ff
#
# Run it before every push. It is also the pre-push hook and a CI job.
# Exit 0 = clean, 1 = something was found, 2 = usage/setup error.
#
# False positive? Add a narrow pathspec to scripts/pii-scan.exclude with a
# comment saying why. Never widen it to a whole directory, and never weaken a
# pattern below to make a push go through.
#
# Two modes for a tree about to go public (scripts/mirror.sh sets both, and
# docs/publishing.md says why):
#
#   PII_SCAN_PUBLIC=1  no scripts/pii-scan.exclude, no self-excludes, no test
#         path or placeholder exemptions. They exist because a fixture in a
#         private repo harms no one; published, it is just a leak. Only the
#         structural exemptions above remain. It also refuses shapes that are
#         harmless in a private repo but say where the house is once public:
#         CGNAT (Tailscale) and private IPv6 addresses, .lan/.local/.internal/
#         .home.arpa host names, an email on a line that only says it is an
#         example, and a secret assigned an unquoted literal.
#
#   PII_SCAN_BLOCKLIST=<file>  also refuse any line holding one of the file's
#         fixed strings, in any case: the owner's names, hosts and addresses
#         that no pattern can know. One per line, '#' starts a comment, 4
#         characters at least. A missing or empty list is a setup error,
#         never a pass. Every hit then prints as file:line only, never the
#         line: it could carry a listed name into a CI log.
set -euo pipefail

root=$(git rev-parse --show-toplevel) || { echo "not a git repo" >&2; exit 2; }
cd "$root"

# One .gitattributes line (`* -diff`, `*.py binary`) makes git call a file
# binary, and git grep -I then skips it: the whole scan blinded by a file the
# scan does not look at. Attributes are read from the empty tree instead,
# which git does from 2.40 on (GIT_ATTR_SOURCE); an older git would quietly
# not, so it is refused.
v=$(git version)
v=${v#git version }
IFS=. read -r major minor _ <<<"$v"
(( major > 2 || (major == 2 && minor >= 40) )) \
  || { echo "pii-scan: git $v is older than 2.40, which cannot be stopped from reading .gitattributes" >&2; exit 2; }
GIT_ATTR_SOURCE=$(git hash-object -t tree /dev/null)
export GIT_ATTR_SOURCE

public=${PII_SCAN_PUBLIC:-0}
[[ $public == [01] ]] || { echo "pii-scan: PII_SCAN_PUBLIC must be 0 or 1" >&2; exit 2; }
blocklist=${PII_SCAN_BLOCKLIST:-}

# This script and the hook quote the patterns themselves.
self=(':(exclude)scripts/pii-scan.sh' ':(exclude).githooks/pre-push')
base=("${self[@]}")
if [[ -f scripts/pii-scan.exclude ]]; then
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    base+=(":(exclude)${line%%[[:space:]]#*}")
  done < scripts/pii-scan.exclude
fi
# Whatever is excluded here would still be published.
(( public )) && self=() base=()

# What the scan covers, once the exclude file has had its say, counted for the
# last line. None at all is a scan that examined nothing, which must never
# say "clean": an exclude line such as a lone `*` switches the scan off.
scope=$(git ls-files --cached --others --exclude-standard -- . "${base[@]}") \
  || { echo "pii-scan: git ls-files failed (a bad line in scripts/pii-scan.exclude?)" >&2; exit 2; }
[[ -n $scope ]] \
  || { echo "pii-scan: no file left to scan (does scripts/pii-scan.exclude exclude them all?)" >&2; exit 2; }
scanned=$(wc -l <<<"$scope")

# Test fixtures are exempt from the SOFT patterns only. A real credential in a
# test is still a credential and is still caught by the HARD tier.
soft=("${base[@]}"
  ':(exclude)test' ':(exclude)tests' ':(exclude)*/test/*' ':(exclude)*/tests/*'
  ':(exclude)test/*' ':(exclude)tests/*'
  ':(exclude)*_test.*' ':(exclude)*.test.*' ':(exclude)*.spec.*' ':(exclude)*/testdata/*')
(( public )) && soft=()

# A line that says "this is an example" is taken at its word -- except in a
# public tree, where nobody is around to check that it is one.
# Not the bare word "example": a line such as "for the example cluster the
# token is ghp_..." would excuse itself (starboard found that, 11b7d66).
placeholder='your_|<[A-Za-z0-9_-]+>|changeme|CHANGEME|placeholder|PLACEHOLDER|REPLACE_?ME|example\.(com|org|net)|example-only|example-parent|EXAMPLE|[Ff]or example|sample|dummy|fixture|xxxx|XXXX|\.\.\.'
(( public )) && placeholder=''
mac_sentinel='00:00:00:00:00:00|[fF]{2}(:[fF]{2}){5}|[aA][aA]:[bB][bB]:[cC][cC]:[dD][dD]:[eE][eE]:[fF][fF]'

# Drop git-grep hits whose CONTENT matches the regex. Content only: a path such
# as tests/fixtures.py must never be what excuses a token on the line.
filter_content() {
  local re=$1 line body
  while IFS= read -r line; do
    body=${line#*:}; body=${body#*:}
    grep -qE -- "$re" <<<"$body" || printf '%s\n' "$line"
  done
}

fail=0
scan() { # <tier: hard|soft> <label> <pattern> [extra-skip-regex] [filter]
  local tier=$1 label=$2 pattern=$3 skip=${4:-} filter=${5:-} hits
  local -n specs="${tier}_specs"
  # --untracked so a file that has not been `git add`ed yet is still
  # scanned. Without it this checks only tracked files, which means it
  # passes vacuously on a repo with no commits -- reporting "clean" while
  # examining nothing, at exactly the moment a first commit is most likely
  # to carry a mistake. Ignored files are still skipped, so .env stays out.
  # git grep exits 1 for "no match" and 128/129 when it could not search at
  # all (a bad pathspec, or a pattern it read as an option). Only 1 is clean:
  # a scan that examined nothing must never print "clean", so anything else
  # stops the scan. -e keeps a pattern that starts with "-" (the private-key
  # one does) a pattern, not an option.
  local rc=0
  hits=$(git grep --untracked -nIE -e "$pattern" -- . "${specs[@]}") || rc=$?
  if ((rc == 1)); then
    return 0
  elif ((rc != 0)); then
    echo "pii-scan: git grep failed (exit $rc) while checking: $label" >&2
    exit 2
  fi
  if [[ -n $skip ]]; then
    hits=$(printf '%s\n' "$hits" | filter_content "$skip")
  fi
  if [[ -n $filter ]]; then
    hits=$(printf '%s\n' "$hits" | "$filter")
  fi
  [[ -n $hits ]] || return 0
  # With a blocklist in play the line may also hold a listed name: say where.
  [[ -z $blocklist ]] || hits=$(printf '%s\n' "$hits" | cut -d: -f1,2)
  printf '\n!! %s\n%s\n' "$label" "$hits"
  fail=1
}
# Reached by nameref from scan(), which shellcheck cannot follow.
# shellcheck disable=SC2034
hard_specs=("${self[@]}")
# shellcheck disable=SC2034
soft_specs=("${soft[@]}")

# --- hard --------------------------------------------------------------------
# No line excuses itself here: a real key next to the word "sample" is still a
# real key. A fake one in a test is built at run time, or is too short or too
# regular to match.
scan hard 'GitHub token' \
  '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}'
scan hard 'API key (OpenAI/Anthropic/AWS/Google)' \
  '\b(sk-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35})\b'
scan hard 'access token (JWT, e.g. a Home Assistant long-lived token)' \
  '\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
scan hard 'Tailscale key' \
  '\btskey-[a-z]+-[A-Za-z0-9]{6,}-[A-Za-z0-9]{10,}'
# An .npmrc that names ${NPM_TOKEN} is how it should be; a literal is a leak.
scan hard 'npm or Slack token' \
  '\bnpm_[A-Za-z0-9]{36}\b|_authToken[[:space:]]*=[[:space:]]*[A-Za-z0-9_-]{16,}|\bxox[abposr]-[A-Za-z0-9-]{10,}'
scan hard 'private key material' \
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'

# --- soft --------------------------------------------------------------------
# Host octet is 1-254: .0 and .255 are network/broadcast, not a device.
o='([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])'
h='([1-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])'
scan soft 'private (RFC1918) host address' \
  "\\b(10\\.$o\\.$o\\.$h|172\\.(1[6-9]|2[0-9]|3[01])\\.$o\\.$h|192\\.168\\.$o\\.$h)\\b" "$placeholder"
scan soft 'MAC address' \
  '\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b' "${placeholder:+$placeholder|}$mac_sentinel"
scan soft 'password/secret assigned a literal' \
  '(password|passwd|secret|api_?key|token)[[:space:]]*[=:][[:space:]]*["'\''][^"'\''<$]{8,}' "$placeholder"
# A home's coordinates are its street address. Four decimals is house-level
# (~11 m): a lat/long key given one, or a bare "lat, long" pair. The pair's
# first number needs two digits and the comma a space after it, so scores like
# 0.1234, 0.5678 and SVG path data (12.345678,-12.34567) pass.
scan soft 'GPS coordinates' \
  '\b(lat|latitude|lon|lng|long|longitude)["'\'']?[[:space:]]*[:=][[:space:]]*["'\'']?-?[0-9]{1,3}\.[0-9]{4,}|\b[1-8][0-9]\.[0-9]{4,},[[:space:]]+-?[0-9]{1,3}\.[0-9]{4,}\b' "$placeholder"

# --- public only ---------------------------------------------------------------
# Harmless in a private repo, where they are mostly docs about the house; once
# public they say where it is. Stricter, so they cost false alarms, and a
# false alarm here costs a rewrite of the line, which is the cheap direction.
# Every address but GitHub's noreply ones and the reserved example domains.
email_re='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
email_ok='^([A-Za-z0-9._%+-]+@users\.noreply\.github\.com|no-?reply@[A-Za-z0-9.-]+|git@github\.com|[A-Za-z0-9._%+-]+@(example\.(com|org|net)|[A-Za-z0-9.-]+\.(example|invalid|test|localhost)))$'
# Keep a hit only when one address on the line is not an allowed one: a
# line-wide skip would let a noreply address excuse a real one beside it.
not_allowed_emails() {
  local line path body
  while IFS= read -r line; do
    path=${line%%:*}; body=${line#*:}; body=${body#*:}
    # npm copies a package's own deprecation notice into the lockfile, and some
    # carry its maintainer's public address: not this house's, and rewritten on
    # every install, so no hand edit could keep it out (blockyard).
    [[ $path == *package-lock.json && $body == *'"deprecated":'* ]] && continue
    # A URL's user:password@host is a login, not an address (homecast).
    body=$(sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^/@[:space:]]*@#//#g' <<<"$body")
    if grep -oE -- "$email_re" <<<"$body" | grep -qvE -- "$email_ok"; then printf '%s\n' "$line"; fi
  done
}
# Docker's own names for the host and its gateway are the same on every
# machine, so they name no one's house. Like the emails: a hit stays when any
# other internal name is on the line.
internal_re='[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.(lan|local|internal|home\.arpa)\.?([^A-Za-z0-9.-]|$)'
internal_ok='^(host|gateway)\.docker\.internal'
not_docker_names() {
  local line body
  while IFS= read -r line; do
    body=${line#*:}; body=${body#*:}
    if grep -oE -- "$internal_re" <<<"$body" | grep -qvE -- "$internal_ok"; then printf '%s\n' "$line"; fi
  done
}
# Both modes, hard, so tests too: in the house's apps an email is how a person
# signs in (hallpass), and a real one belongs in a database row typed by hand,
# never in a file. Reserved names always pass (example domains, .invalid,
# .test, .localhost, GitHub's noreply); a private repo also takes a line that
# says it is an example at its word, a public copy does not.
email_skip=''
(( public )) || email_skip=$placeholder
scan hard 'email address (only noreply, example and reserved-domain ones)' \
  "$email_re" "$email_skip" not_allowed_emails

if (( public )); then
  scan hard 'CGNAT (Tailscale) host address' \
    "\\b100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.$o\\.$h\\b"
  scan hard 'private IPv6 address (unique-local fd.., link-local fe80)' \
    '\b([fF][dD][0-9a-fA-F]{2}|[fF][eE]80):[0-9a-fA-F:]*:[0-9a-fA-F]+'
  scan hard 'internal host name (.lan, .local, .internal, .home.arpa; not Docker'"'"'s host.docker.internal)' \
    '[A-Za-z0-9-]\.(lan|local|internal|home\.arpa)\.?([^A-Za-z0-9.-]|$)' '' not_docker_names
  # Config-file shape: the whole value one unquoted run with a digit in it, so
  # code such as `token = get_token` or `password = DEFAULT_PASSWORD` passes.
  scan hard 'password/secret assigned an unquoted literal' \
    '^[[:space:]]*(export[[:space:]]+)?["'\'']?[A-Za-z0-9_.-]*(password|passwd|secret|api_?key|token|PASSWORD|PASSWD|SECRET|API_?KEY|TOKEN)["'\'']?[[:space:]]*[=:][[:space:]]*[A-Za-z0-9_+/=!@%^&*~-]{8,}[[:space:]]*$' \
    '[=:][[:space:]]*[^0-9[:space:]]+[[:space:]]*$'
fi

# --- blocklist ---------------------------------------------------------------
# Never print the list or a matching line: both carry the names it guards.
if [[ -n $blocklist ]]; then
  [[ -f $blocklist && -r $blocklist ]] \
    || { echo "pii-scan: PII_SCAN_BLOCKLIST names no readable file" >&2; exit 2; }
  # A stray CR or trailing space, or the byte-order mark an editor puts first,
  # would make an entry silently never match.
  entries=$(sed -e "1s/^$(printf '\357\273\277')//" -e 's/\r//g' -e 's/#.*//' \
    -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$blocklist")
  [[ -n $entries ]] || { echo "pii-scan: the blocklist has no entries" >&2; exit 2; }
  short=$(awk 'length($0) < 4' <<<"$entries" | wc -l)
  (( short == 0 )) \
    || { echo "pii-scan: $short blocklist entries are under 4 characters; they match everywhere" >&2; exit 2; }
  # -z ends the path and line number with NUL, so cutting after the second
  # field drops the line's text even when the path holds a ':'.
  rc=0
  hits=$(git grep --untracked -n -z -i -F -f <(printf '%s\n' "$entries") -- . "${base[@]}" \
    | tr '\0' '\t' | cut -f1,2 | tr '\t' ':') || rc=$?
  if ((rc == 0)); then
    printf '\n!! %s\n%s\n' 'blocklisted string (where only; see the list)' "$hits"
    fail=1
  elif ((rc != 1)); then
    echo "pii-scan: git grep failed (exit $rc) while checking the blocklist" >&2
    exit 2
  fi
fi

# --- local -------------------------------------------------------------------
# What only this house knows to look for, and no pattern can: the family's
# names, the home's own words. One extended regex per line in the gitignored
# scripts/pii-scan.local, matched as a whole word in any case, in every file
# (homecast's tier, now every repo's). The list is personal data itself, so it
# must be gitignored and a hit prints where only, never the word. It runs
# where the list is (the owner's box, by the pre-push hook), not in CI.
local_list=scripts/pii-scan.local
local_n=0
if [[ -e $local_list ]]; then
  git check-ignore -q -- "$local_list" \
    || { echo "pii-scan: $local_list holds the house's own words but is not gitignored; add it to .gitignore" >&2; exit 2; }
  words=$(sed -e "1s/^$(printf '\357\273\277')//" -e 's/\r//g' -e '/^[[:space:]]*#/d' \
    -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$local_list")
  if [[ -n $words ]]; then
    local_n=$(grep -c . <<<"$words")
    rc=0
    hits=$(git grep --untracked -n -z -I -i -w -E -f <(printf '%s\n' "$words") -- . "${base[@]}" \
      | tr '\0' '\t' | cut -f1,2 | tr '\t' ':') || rc=$?
    if ((rc == 0)); then
      printf '\n!! %s\n%s\n' "a word from $local_list (where only; see the list)" "$hits"
      fail=1
    elif ((rc != 1)); then
      echo "pii-scan: git grep failed (exit $rc) on $local_list" >&2
      exit 2
    fi
  fi
fi

if (( fail )); then
  cat >&2 <<'MSG'

Personal data or a credential is present in a file a commit would carry. Move
the value to .env (gitignored) and leave a placeholder behind. If it is already
pushed, rotate the credential; git history keeps it forever.
MSG
  exit 1
fi

# The count is of the files scanned, after the exclude file, counted from the
# candidate set directly: `git grep -l ''` skips zero-byte files, and a
# security tool that misreports what it examined is the failure this exists
# to prevent. The modes are named so a caller can tell a strict pass from a
# plain one.
mode=""
(( public )) && mode+="; public mode"
[[ -z $blocklist ]] || mode+="; blocklist"
(( local_n == 0 )) || mode+="; local list"
echo "pii-scan: clean ($scanned files$mode)"
