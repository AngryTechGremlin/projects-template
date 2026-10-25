#!/usr/bin/env bash
# The house's checks, one entry point for the pre-push hook, CI and agents, so
# all three get the same answer from the same tools (agent.md §6).
#
#   scripts/check.sh fast   before every push (the pre-push hook runs it): the
#                           PII scan, commit identity, messages and secrets on
#                           the new commits, tool configs that differ from
#                           their committed copy, workflows, shell scripts
#   scripts/check.sh full   CI: fast, but secrets across ALL of history, plus
#                           Dockerfiles
#   scripts/check.sh vuln   weekly and on demand: known vulnerabilities in
#                           lockfiles, and in the images named in CHECK_IMAGES
#
# CHECK_RANGE   the commits the identity check (and fast's secrets check) read,
#               as git rev-list arguments: "A..B", "<sha> --not --remotes". The
#               hook and CI set it. Unset, it is the commits on no remote yet,
#               or all of history when there is no remote.
# CHECK_IMAGES  vuln only: local images to scan as well, space-separated, e.g.
#               the one compose builds. Unset, only lockfiles are scanned.
#
# Every tool is a Docker image pinned by digest in scripts/check-tools.env. It
# runs as the calling user, with the repo mounted read-only, no capabilities
# and no network: these tools read the house's code, so they get nothing else.
# Only trivy's database download has a network, and it never sees the repo.
#
# One line per check; under a failure, how to fix it and the tool's output.
# Exit 0 = clean, 1 = a check found something, 2 = usage/setup error.
#
# The checks are called by name through run(), which shellcheck cannot follow.
# shellcheck disable=SC2329
set -euo pipefail

usage() { echo "usage: scripts/check.sh fast|full|vuln" >&2; exit 2; }
setup() { echo "check.sh: $*" >&2; exit 2; }
(( $# == 1 )) || usage
tier=$1
case $tier in fast|full|vuln) ;; *) usage ;; esac

root=$(git rev-parse --show-toplevel 2>/dev/null) || setup "not inside a git repo"
cd "$root"
# The pins sit next to this script, wherever it is linked from.
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

[[ -f $here/check-tools.env ]] || setup "scripts/check-tools.env is missing; it pins every tool's image"
# shellcheck source=/dev/null
source "$here/check-tools.env"
for v in SHELLCHECK_IMAGE GITLEAKS_IMAGE ACTIONLINT_IMAGE ZIZMOR_IMAGE HADOLINT_IMAGE TRIVY_IMAGE; do
  [[ ${!v:-} == *@sha256:* ]] || setup "$v in scripts/check-tools.env is not an image pinned by digest"
done
[[ -f scripts/pii-scan.sh ]] || setup "scripts/pii-scan.sh is missing; the PII scan is not optional"
command -v docker >/dev/null || setup "docker is not installed; every tool runs in a pinned container"
docker version >/dev/null 2>&1 || setup "cannot reach the docker daemon (is it running, and may this user use it?)"

# A pin that is not here yet is pulled once; one that cannot be fetched stops
# everything, because a check that silently did not run is a pass nobody earned.
need() {
  local v
  for v in "$@"; do
    docker image inspect "${!v}" >/dev/null 2>&1 \
      || docker pull -q "${!v}" >/dev/null || setup "could not pull ${!v} ($v)"
  done
}
case $tier in
  fast) need SHELLCHECK_IMAGE GITLEAKS_IMAGE ACTIONLINT_IMAGE ZIZMOR_IMAGE ;;
  full) need SHELLCHECK_IMAGE GITLEAKS_IMAGE ACTIONLINT_IMAGE ZIZMOR_IMAGE HADOLINT_IMAGE ;;
  vuln) need TRIVY_IMAGE ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# The repo is mounted at its own path, so tool output names real paths. A git
# worktree keeps its objects in the main checkout's .git, so that is mounted
# too. safe.directory: git refuses a repo owned by someone else, and inside a
# container the owner can look like someone else. GIT_ATTR_SOURCE: attributes
# come from the empty tree, so a committed `* -diff` cannot turn gitleaks'
# view of history into "Binary files differ" (pii-scan.sh says the same).
mounts=(-v "$root:$root:ro")
common=$(git rev-parse --path-format=absolute --git-common-dir)
[[ $common == "$root"/* ]] || mounts+=(-v "$common:$common:ro")
empty_tree=$(git hash-object -t tree /dev/null)
box() { # [docker run options...] <image> [args...]
  docker run --rm --network none --user "$(id -u):$(id -g)" \
    --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp -e HOME=/tmp \
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e "GIT_CONFIG_VALUE_0=$root" \
    -e "GIT_ATTR_SOURCE=$empty_tree" "${mounts[@]}" -w "$root" "$@"
}
# A tool's own non-zero exit is a finding; docker failing to start it (125),
# or the command missing from the image (126, 127), means it never ran.
verdict() { case $1 in 125|126|127) return 2 ;; *) return 1 ;; esac; }
count() { printf '%d %s' "$1" "$2"; (( $1 == 1 )) || printf s; }

# Files a commit would carry: tracked, plus untracked but not ignored, so a
# brand-new repo with nothing committed is still checked, and .env never is.
files() { # [pathspec...]
  local f
  while IFS= read -r -d '' f; do
    if [[ -f $f ]]; then printf '%s\0' "$f"; fi   # a deleted-but-tracked path is not a file
  done < <(git ls-files -z --cached --others --exclude-standard -- "$@" | sort -zu)
}

if [[ -n ${CHECK_RANGE:-} ]]; then
  read -ra range <<<"$CHECK_RANGE"
elif ! git rev-parse -q --verify HEAD >/dev/null; then
  range=()                              # no commits yet
elif [[ -n $(git remote) ]]; then
  range=(HEAD --not --remotes)
else
  range=(HEAD)
fi
new=0
if (( ${#range[@]} )); then
  new=$(git rev-list --count "${range[@]}" 2>/dev/null) \
    || setup "CHECK_RANGE='${CHECK_RANGE:-}' is not a commit range git understands"
fi

# --- the checks --------------------------------------------------------------
# Each prints its tool's output and returns 0 clean, 1 found something, 2 could
# not run. It may set $note for the ok line.

check_pii() {
  local out rc=0
  out=$(bash scripts/pii-scan.sh 2>&1) || rc=$?
  printf '%s\n' "$out"
  note=${out##*$'\n'}; note=${note#pii-scan: clean (}; note=${note%)}
  return "$rc"
}

# Author and committer must both be a GitHub handle at its noreply address,
# name and all: a commit's name and email are published with it and kept
# forever, and a real name next to a noreply address is still a real name.
# GitHub's own web-flow identity (GitHub <noreply@github.com>) commits a merge
# made in the browser. A Co-authored-by line is published the same way, so it
# is held to the same, or to a tool's own noreply@ address.
noreply_re='^([0-9]+\+)?([A-Za-z0-9-]+)@users\.noreply\.github\.com$'
name_email_re='^(.+) <([^<>]+)>$'
handle_at_noreply() { # <name> <email>
  [[ $2 =~ $noreply_re && ${1,,} == "${BASH_REMATCH[2],,}" ]]
}
check_identity() {
  (( new )) || { note="no new commits"; return 0; }
  local log sha an ae cn ce subject co bad=0 c cname cmail
  log=$(git log --format='%h%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%s' "${range[@]}") || return 2
  while IFS=$'\x1f' read -r sha an ae cn ce subject; do
    if ! handle_at_noreply "$an" "$ae"; then
      echo "$sha author is not a GitHub handle at its @users.noreply.github.com address: $subject"; bad=1
    fi
    if ! handle_at_noreply "$cn" "$ce" && [[ "$cn <$ce>" != 'GitHub <noreply@github.com>' ]]; then
      echo "$sha committer is not a GitHub handle at its @users.noreply.github.com address: $subject"; bad=1
    fi
  done <<<"$log"
  log=$(git log --format='%h%x1f%(trailers:key=Co-authored-by,valueonly,unfold,separator=%x1f)' "${range[@]}") || return 2
  while IFS=$'\x1f' read -r -a co; do
    for c in "${co[@]:1}"; do
      [[ $c =~ $name_email_re ]] || { echo "${co[0]} Co-authored-by is not 'Name <email>'"; bad=1; continue; }
      cname=${BASH_REMATCH[1]} cmail=${BASH_REMATCH[2]}
      if ! handle_at_noreply "$cname" "$cmail" && [[ $cmail != noreply@* ]]; then
        echo "${co[0]} Co-authored-by is neither a GitHub handle at its noreply address nor a noreply@ address"; bad=1
      fi
    done
  done <<<"$log"
  note=$(count "$new" commit)
  return "$bad"
}

# A message is pushed with its commit and kept like a file, so the new
# commits' messages get the PII scan too: each is written to a file of its own
# in a scratch repo, and scripts/pii-scan.sh is run there.
check_messages() {
  (( new )) || { note="no new commits"; return 0; }
  local d=$tmp/messages rec rc=0
  git init -q --template= "$d" || return 2
  while IFS= read -r -d '' rec; do
    printf '%s\n' "${rec#*$'\x1f'}" >"$d/${rec%%$'\x1f'*}"
  done < <(git log -z --format='%H%x1f%B' "${range[@]}")
  # A hook runs with GIT_DIR set, which would aim the scan back at this repo.
  (cd "$d" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR && bash "$root/scripts/pii-scan.sh") || rc=$?
  note=$(count "$new" commit)
  return "$rc"
}

# A tool's config that is not committed as it is on disk changes what the
# check sees here and not in CI, which reads the committed copy: a local
# allowlist would turn a red CI run into a green hook.
tool_configs=(.gitleaks.toml .gitleaksignore .github/zizmor.yml .github/zizmor.yaml zizmor.yml zizmor.yaml
  .github/actionlint.yaml .github/actionlint.yml .hadolint.yaml .hadolint.yml .shellcheckrc
  .trivyignore .trivyignore.yaml trivy.yaml scripts/pii-scan.exclude)
check_tool_configs() {
  local out
  # Nothing is committed yet, so nothing can differ from what CI will read.
  git rev-parse -q --verify HEAD >/dev/null || { note="no commits yet"; return 0; }
  out=$(git status --porcelain --untracked-files=all --ignored -- "${tool_configs[@]}") || return 2
  [[ -z $out ]] || { printf '%s\n' "$out"; return 1; }
}

check_gitleaks() {
  local opts=(git --redact --no-banner --no-color --verbose) n
  if [[ $tier == fast ]]; then
    (( new )) || { note="no new commits"; return 0; }
    opts+=("--log-opts=${range[*]}")
    note=$(count "$new" commit)
  else
    n=$(git rev-list --all --count) || return 2
    (( n )) || { note="no commits yet"; return 0; }
    note=$(count "$n" commit)
  fi
  box "$GITLEAKS_IMAGE" "${opts[@]}" "$root" || verdict $?
}

mapfile -d '' workflows < <(files '.github/workflows/*.yml' '.github/workflows/*.yaml')

check_actionlint() {
  # Every house repo has .github/workflows/ci.yml, so none found means the file
  # list is broken, and a linter that examined nothing must not pass.
  if (( ${#workflows[@]} == 0 )); then
    echo "found no workflows, yet every house repo has .github/workflows/ci.yml"
    return 1
  fi
  local conf=()
  # The house's runners carry one label each, <repo>-ci (docs/ci-runner.md),
  # which actionlint would otherwise call unknown. A repo's own
  # .github/actionlint.yaml wins.
  if [[ ! -f .github/actionlint.yaml && ! -f .github/actionlint.yml ]]; then
    printf 'self-hosted-runner:\n  labels: ["*-ci"]\n' >"$tmp/actionlint.yaml"
    conf=(-v "$tmp/actionlint.yaml:/house/actionlint.yaml:ro" "$ACTIONLINT_IMAGE" -config-file /house/actionlint.yaml)
  else
    conf=("$ACTIONLINT_IMAGE")
  fi
  note=$(count "${#workflows[@]}" workflow)
  box "${conf[@]}" -no-color "${workflows[@]}" || verdict $?
}

check_zizmor() {
  local actions inputs
  mapfile -d '' actions < <(files ':(glob)**/action.yml' ':(glob)**/action.yaml')
  inputs=("${workflows[@]}" "${actions[@]}")
  (( ${#inputs[@]} )) || { echo "found no workflows or actions to read"; return 1; }
  note=$(count "${#inputs[@]}" file)
  box "$ZIZMOR_IMAGE" --offline --no-progress --color never -qq "${inputs[@]}" || verdict $?
}

check_shellcheck() {
  local sh=() f first shebang
  # *.sh and *.bash, plus any file whose first line is a sh/bash/dash shebang
  # (hooks, scripts without an extension). A link to a script in the repo is
  # skipped: the script is linted as itself.
  shebang='^#![[:space:]]*(/usr/bin/env[[:space:]]+(-S[[:space:]]+)?|/bin/|/usr/bin/|/usr/local/bin/)(ba|da)?sh([[:space:]]|$)'
  while IFS= read -r -d '' f; do
    if [[ -L $f && $(readlink -f -- "$f") == "$root"/* ]]; then continue; fi
    if [[ $f == *.sh || $f == *.bash ]]; then sh+=("$f"); continue; fi
    IFS= read -r -n 64 first <"$f" 2>/dev/null || continue
    if [[ $first =~ $shebang ]]; then sh+=("$f"); fi
  done < <(files)
  # This script is itself a shell script in the repo, so an empty list means
  # the list is broken, and a linter that examined nothing must not pass.
  if (( ${#sh[@]} == 0 )); then
    echo "found no shell scripts, yet scripts/check.sh is one: the file list is broken"
    return 1
  fi
  note=$(count "${#sh[@]}" script)
  for f in "${sh[@]}"; do bash -n "$f" || return 1; done
  box "$SHELLCHECK_IMAGE" "${sh[@]}" || verdict $?
}

check_hadolint() {
  local df=() f
  while IFS= read -r -d '' f; do
    [[ $f == *.dockerignore ]] || df+=("$f")
  done < <(files ':(glob)**/Dockerfile*' ':(glob)**/Containerfile*' ':(glob)**/*.Dockerfile')
  (( ${#df[@]} )) || { note="this repo has no Dockerfiles"; return 0; }
  note=$(count "${#df[@]}" file)
  box "$HADOLINT_IMAGE" /bin/hadolint --no-color "${df[@]}" || verdict $?
}

# A Dockerfile that copies its whole build context (COPY . .) takes whatever
# is lying in the folder unless a .dockerignore says otherwise: a local .venv,
# node_modules, .env, data/. hallpass's api image once carried a dev venv's
# old certifi (a CRITICAL) that way. So every such Dockerfile needs a
# .dockerignore beside it (or BuildKit's <Dockerfile>.dockerignore).
check_dockerignore() {
  local f dir bad=0 seen=0
  while IFS= read -r -d '' f; do
    [[ $f == *.dockerignore ]] && continue
    # COPY or ADD of "." or "./", flags allowed, but not --from: that copies
    # from another stage, not from the folder.
    grep -qiE '^[[:space:]]*(COPY|ADD)[[:space:]]+(--[a-z-]+(=[^[:space:]]+)?[[:space:]]+)*\.\/?[[:space:]]' "$f" || continue
    grep -iE '^[[:space:]]*(COPY|ADD)[[:space:]]' "$f" | grep -qviE -- '--from' || continue
    seen=$((seen + 1))
    dir=$(dirname -- "$f")
    if [[ ! -f $dir/.dockerignore && ! -f $f.dockerignore ]]; then
      echo "$f copies its whole folder, and $dir has no .dockerignore"
      bad=1
    fi
  done < <(files ':(glob)**/Dockerfile*' ':(glob)**/Containerfile*' ':(glob)**/*.Dockerfile')
  note="$(count "$seen" Dockerfile) copying its folder"
  return "$bad"
}

# The vulnerability database is fetched by a container that has a network and
# no repo; the scan runs in one that has the repo and no network. So nothing
# about the project can leave, whatever the scanner does. Only HIGH/CRITICAL
# with a fix released fail: an alert nobody can act on teaches people to
# ignore the weekly run.
trivy_cache=${XDG_CACHE_HOME:-$HOME/.cache}/trivy
trivy_db() {
  local what=(--download-db-only)
  # The Java index is large and only needed when there are jars to identify.
  if [[ -n $(files '*.jar' '*.war' '*.ear' | head -c1) ]]; then what+=(--download-java-db-only); fi
  mkdir -p "$trivy_cache" || setup "cannot create $trivy_cache"
  local w
  for w in "${what[@]}"; do
    if ! docker run --rm --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges \
      --read-only --tmpfs /tmp -e HOME=/tmp -v "$trivy_cache:/cache" "$TRIVY_IMAGE" \
      image "$w" --cache-dir /cache --no-progress --disable-telemetry --skip-version-check >"$tmp/db" 2>&1
    then
      sed 's/^/    /' "$tmp/db" >&2
      setup "could not update trivy's vulnerability database in $trivy_cache"
    fi
  done
  # The scans get the databases read-only, and a scratch cache for the layers
  # they analyse.
  dbs=(--tmpfs /cache -v "$trivy_cache/db:/cache/db:ro")
  if [[ -d $trivy_cache/java-db ]]; then dbs+=(-v "$trivy_cache/java-db:/cache/java-db:ro"); fi
}
# --include-dev-deps: a project's dev dependencies (test runners, bundlers,
# browsers) are what CI installs and runs on the house's CI box, so they are
# scanned too, not only what ships (teaching-tools' playwright).
trivy_scan=(--scanners vuln --cache-dir /cache --skip-db-update --skip-java-db-update --offline-scan
  --quiet --disable-telemetry --skip-version-check --severity "HIGH,CRITICAL" --ignore-unfixed
  --include-dev-deps --exit-code 1)
# A reviewed exception goes in .trivyignore.yaml, not a plain .trivyignore: an
# entry there can name the one file it excuses (paths: one binary inside an
# image), so excusing gosu in the postgres image does not also hide the same
# CVE in a Caddy that is reachable. Every entry also needs an expiry, after
# which trivy reports the finding again, and a statement saying why.
trivy_ignore() {
  [[ -f .trivyignore.yaml ]] || return 0
  local ids exp why
  ids=$(grep -cE '^[[:space:]]*-[[:space:]]+id:' .trivyignore.yaml || true)
  exp=$(grep -cE '^[[:space:]]+expired_at:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}' .trivyignore.yaml || true)
  why=$(grep -cE '^[[:space:]]+statement:[[:space:]]*[^[:space:]]' .trivyignore.yaml || true)
  (( ids > 0 && exp == ids && why == ids )) \
    || setup ".trivyignore.yaml: each of its $ids entries needs an expired_at date and a statement saying why"
  trivy_scan+=(--ignorefile "$root/.trivyignore.yaml")
}

check_trivy_fs() {
  local skip=() p
  # Scan what a commit carries, like every other check: git-ignored paths
  # (node_modules, data/, .env) are skipped, never walked.
  while IFS= read -r -d '' p; do
    if [[ $p == */ ]]; then skip+=(--skip-dirs "${p%/}"); else skip+=(--skip-files "$p"); fi
  done < <(git ls-files -z --others --ignored --exclude-standard --directory)
  # Say how many lockfiles there were: a scan that found none must not read
  # as a plain pass.
  local n
  n=$(files ':(glob)**/package-lock.json' ':(glob)**/yarn.lock' ':(glob)**/pnpm-lock.yaml' \
    ':(glob)**/requirements*.txt' ':(glob)**/Pipfile.lock' ':(glob)**/poetry.lock' ':(glob)**/uv.lock' \
    ':(glob)**/go.sum' ':(glob)**/Cargo.lock' ':(glob)**/Gemfile.lock' ':(glob)**/composer.lock' \
    ':(glob)**/gradle.lockfile' | tr -cd '\0' | wc -c)
  if (( n == 0 )); then note="no lockfiles in this repo"; else note=$(count "$n" lockfile); fi
  box "${dbs[@]}" "$TRIVY_IMAGE" fs "${trivy_scan[@]}" "${skip[@]}" . || verdict $?
}

check_trivy_image() { # <image>
  local rc=0
  docker image inspect "$1" >/dev/null 2>&1 || { echo "CHECK_IMAGES names $1, which is not a local image; build it first"; return 2; }
  # Exported to a file rather than read through the docker socket, which
  # would hand the scanner the whole daemon.
  if ! { mkdir -p "$tmp/image" && docker save -o "$tmp/image/image.tar" "$1"; }; then
    echo "could not export $1"; return 2
  fi
  box "${dbs[@]}" -v "$tmp/image:/image:ro" "$TRIVY_IMAGE" \
    image "${trivy_scan[@]}" --input /image/image.tar || rc=$?
  rm -f "$tmp/image/image.tar"
  (( rc == 0 )) || verdict "$rc"
}

# --- run them ----------------------------------------------------------------
failed=0
run() { # <name> <how to fix> <check function> [args...]
  local name=$1 fix=$2 rc=0
  shift 2
  note=
  "$@" >"$tmp/out" 2>&1 || rc=$?
  case $rc in
    0) printf 'ok  %s%s\n' "$name" "${note:+ ($note)}" ;;
    1) printf 'FAIL %s: %s\n' "$name" "$fix"; sed 's/^/    /' "$tmp/out"; failed=1 ;;
    *) sed 's/^/    /' "$tmp/out" >&2; setup "$name could not run (exit $rc)" ;;
  esac
}

if [[ $tier == vuln ]]; then
  trivy_db
  trivy_ignore
  run "trivy lockfiles" \
    "upgrade each package listed to its fixed version; a reviewed exception goes in .trivyignore.yaml (paths, expired_at, statement)" \
    check_trivy_fs
  read -ra images <<<"${CHECK_IMAGES:-}"
  for img in "${images[@]}"; do
    run "trivy image $img" \
      "rebuild on a patched base image, or upgrade the packages listed; a reviewed exception goes in .trivyignore.yaml, scoped to the one binary by paths, with expired_at and statement" \
      check_trivy_image "$img"
  done
else
  run "pii-scan" \
    "move the value to .env and leave a placeholder; a credential that was ever pushed must be rotated" \
    check_pii
  run "commit identity" \
    "set git config user.name AngryTechGremlin and user.email AngryTechGremlin@users.noreply.github.com, then rewrite the listed commits: git rebase -r --exec 'git commit --amend --no-edit --reset-author' <base>; a Co-authored-by line is reworded the same way, with --amend -m" \
    check_identity
  run "commit messages" \
    "reword the listed commits (by full SHA) before pushing: git commit --amend for the last one, git rebase -r --exec for older ones; a message is pushed with its commit and kept forever" \
    check_messages
  run "tool configs" \
    "commit each listed file as it is, or delete it: CI reads the committed copy, so an uncommitted one makes this check disagree with CI" \
    check_tool_configs
  if [[ $tier == fast ]]; then
    run "gitleaks new commits" \
      "rotate the credential, then rewrite the commits that carry it before pushing; a false positive goes in .gitleaksignore by fingerprint" \
      check_gitleaks
  else
    run "gitleaks all history" \
      "rotate the credential now: pushed history keeps it forever. A false positive goes in .gitleaksignore by fingerprint" \
      check_gitleaks
  fi
  run "actionlint" \
    "fix each line listed" \
    check_actionlint
  run "zizmor" \
    "pin uses: to a full commit SHA with a # vX.Y.Z comment, set persist-credentials: false, grant only needed permissions; each finding links its fix, and a reviewed exception is a '# zizmor: ignore[<audit>]' comment saying why" \
    check_zizmor
  run "shellcheck" \
    "fix each line listed; a deliberate exception is a '# shellcheck disable=SCxxxx' comment saying why" \
    check_shellcheck
  if [[ $tier == full ]]; then
    run "hadolint" \
      "pin the base image to a version (better, a digest) and the packages installed; a reviewed exception is a '# hadolint ignore=DLxxxx' comment saying why" \
      check_hadolint
    run ".dockerignore" \
      "add a .dockerignore beside each one listed, naming what an image must never carry: .git, .env*, data/, .venv, node_modules, build and test output" \
      check_dockerignore
  fi
fi

exit "$failed"
