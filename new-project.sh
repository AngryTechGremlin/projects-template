#!/usr/bin/env bash
# Scaffold a new project from ~/Projects/_template, or adopt the shared dev
# tooling into an existing one. See _template/README.md for the why.
set -euo pipefail

TEMPLATE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SKEL="$TEMPLATE_DIR/skel"
PROJECTS_DIR=$(dirname -- "$TEMPLATE_DIR")

owner=${GITHUB_OWNER:-AngryTechGremlin}
# The org a public mirror publishes to. Only --publish uses it; the default
# is filled in below, once an adopted repo's own PUBLISH has had its say.
public_owner=${PUBLIC_OWNER:-}
target=""
adopt=0
refresh=0
publish=0
with_mcp=1
build_mcp=1
dry=0
name=""

usage() {
  cat <<'USAGE'
usage: new-project.sh <name> [options]
       new-project.sh --adopt [<path>] [--refresh] [options]

Creates ~/Projects/<name> from the template: agent.md, a thin CLAUDE.md, the
.env/.env.example/pi.md trio, the lean GitHub MCP server and its wiring, the
house checks (scripts/check.sh, run by the pre-push hook, CI and a weekly
vulnerability scan), and a seed ADR.

options:
  --dir PATH        where to create it            (default ~/Projects/<name>)
  --owner NAME      GitHub owner for URLs         (default $GITHUB_OWNER)
  --adopt [PATH]    add only the MISSING shared tooling to an existing repo;
                    never overwrites a file that is already there
  --refresh         with --adopt: overwrite the files the template manages
                    (check and scan scripts, pre-push hook, docs/ci-runner.md,
                    the mirror's scripts) and print each diff; print how the
                    customized ones (ci.yml, agent.md, ...) differ, to port by
                    hand. Refused while a managed file has uncommitted changes.
  --publish         add the public-mirror kit (PUBLISH, scripts/mirror.sh,
                    scripts/sandbox.sh, publish.yml, docs/publishing.md); a
                    repo that already has a PUBLISH file counts as --publish
  --public-owner NAME  GitHub org the mirror publishes to (default the org in
                    an existing PUBLISH, else $PUBLIC_OWNER, else techthatworks)
  --no-mcp          skip the MCP server and its wiring
  --no-build        copy mcp/ but skip npm install && npm run build
  --dry-run         print what would happen, change nothing
  -h, --help        this
USAGE
}

die() { printf 'new-project: %s\n' "$1" >&2; exit 2; }
# For steps whose effect is already narrated by an "added:"/"kept:" line.
quiet() { (( dry )) || "$@"; }

while (( $# )); do
  case $1 in
    --dir)          target=${2:?--dir needs a path}; shift 2 ;;
    --owner)        owner=${2:?--owner needs a name}; shift 2 ;;
    --adopt)        adopt=1; shift
                    if [[ ${1:-} && ${1:-} != -* ]]; then target=$1; shift; fi ;;
    --refresh)      refresh=1; shift ;;
    # Opt-in because only selected repos publish, and an unused publisher in
    # every repo is attack surface.
    --publish)      publish=1; shift ;;
    --public-owner) public_owner=${2:?--public-owner needs a name}; shift 2 ;;
    --no-mcp)       with_mcp=0; shift ;;
    --no-build)     build_mcp=0; shift ;;
    --dry-run)      dry=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             die "unknown option: $1" ;;
    *)              [[ -z $name ]] || die "unexpected argument: $1"; name=$1; shift ;;
  esac
done

[[ -d $SKEL ]] || die "template skeleton missing: $SKEL"
# A new project has nothing of its own yet, so there is nothing to refresh.
if (( refresh && ! adopt )); then die "--refresh only works with --adopt"; fi
if (( adopt )); then
  [[ -n $target ]] || target=$PWD
  target=$(cd -- "$target" 2>/dev/null && pwd) || die "no such directory: $target"
  [[ -d $target/.git ]] || die "not a git repo (adopt only works on an existing project): $target"
  name=$(basename -- "$target")
  # The folder name is filled into files with sed and becomes the runner label.
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "folder name must be letters, digits, . _ -: $name"
  # A repo with a PUBLISH file has opted in; its mirror kit is shared tooling.
  if [[ -e $target/PUBLISH ]]; then
    publish=1
    # It has also chosen its org. Fill the kit in for that one, so a refresh
    # never quietly points the mirror's files at the default instead.
    chosen=$(git config --file "$target/PUBLISH" --get publish.repo 2>/dev/null) || chosen=""
    chosen=${chosen%%/*}
    if [[ -n $chosen ]]; then
      [[ -z $public_owner || $public_owner == "$chosen" ]] \
        || die "PUBLISH publishes to $chosen, not $public_owner"
      public_owner=$chosen
    fi
  fi
else
  [[ -n $name ]] || { usage >&2; exit 2; }
  [[ $name =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "name must be lowercase letters, digits, . _ -: $name"
  [[ -n $target ]] || target="$PROJECTS_DIR/$name"
  if [[ -e $target ]]; then
    [[ -d $target ]] || die "exists and is not a directory: $target"
    [[ -z $(ls -A -- "$target") ]] || die "directory exists and is not empty: $target"
  fi
fi

[[ -n $public_owner ]] || public_owner=techthatworks
# Both end up in URLs and in sed replacements, so hold them to GitHub's alphabet.
[[ $owner =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "not a GitHub owner name: $owner"
[[ $public_owner =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "not a GitHub org name: $public_owner"

project_env=$(printf '%s' "$name" | tr 'a-z.-' 'A-Z__')
today=$(date +%F)
# A repo that publishes takes outside PRs, so ci.yml's test commands run in
# scripts/sandbox.sh and its install step runs no package's scripts (it needs
# the network, so it cannot be sandboxed). Elsewhere both stay plain.
sandbox="" npm_ci_flags=""
if (( publish )); then sandbox="scripts/sandbox.sh " npm_ci_flags=" --ignore-scripts"; fi

substitute() {
  local f=$1
  sed -i \
    -e "s|{{PROJECT_ENV}}|$project_env|g" \
    -e "s|{{PROJECT}}|$name|g" \
    -e "s|{{PUBLIC_OWNER}}|$public_owner|g" \
    -e "s|{{OWNER}}|$owner|g" \
    -e "s|{{DATE}}|$today|g" \
    -e "s|{{SANDBOX}}|$sandbox|g" \
    -e "s|{{NPM_CI_FLAGS}}|$npm_ci_flags|g" \
    "$f"
}

# Everything the skeleton offers, as paths relative to skel/ and the project.
shared=(
  scripts/pii-scan.sh
  scripts/pii-scan.exclude
  scripts/check.sh
  scripts/check-tools.env
  .githooks/pre-push
  .github/workflows/ci.yml
  .github/workflows/weekly.yml
  docs/ci-runner.md
)
mcp_files=(
  .mcp.json
  .vscode/mcp.json
  .claude/settings.json
  # Reads the PAT from mcp/.env, so it belongs with MCP rather than in shared:
  # a --no-mcp project would get a helper with nothing to read.
  scripts/git-credential-github.sh
)
docs=(
  agent.md
  CLAUDE.md
  README.md
  .gitignore
  .env.example
  docs/adr/README.md
  docs/adr/0001-scaffolded-from-the-projects-template.md
)
# The public-mirror kit: --publish only (see the flag for why).
publish_files=(
  PUBLISH
  scripts/mirror.sh
  scripts/sandbox.sh
  .github/workflows/publish.yml
  docs/publishing.md
)

# For --refresh. Managed files belong to the template: no repo edits them, so
# a refresh overwrites them. Customized ones are meant to be edited per repo,
# so a refresh only shows the drift and a person ports what matters. Workflows
# count as customized: a change to one also needs the Workflows grant to push.
managed=(
  scripts/pii-scan.sh
  scripts/check.sh
  scripts/check-tools.env
  .githooks/pre-push
  docs/ci-runner.md
)
customized=(
  .github/workflows/ci.yml
  .github/workflows/weekly.yml
  agent.md
  CLAUDE.md
  README.md
  scripts/pii-scan.exclude
)
if (( publish )); then
  managed+=(scripts/mirror.sh scripts/sandbox.sh docs/publishing.md)
  customized+=(PUBLISH .github/workflows/publish.yml)
fi
# The MCP server's code and lockfile are the template's too (skel/mcp is the
# canonical copy), so a dependency fix there reaches every repo on a refresh.
# Its README names the repo, so it is the repo's.
if (( with_mcp )); then
  managed+=(mcp/package.json mcp/package-lock.json mcp/tsconfig.json mcp/src/index.ts mcp/src/github-service.ts)
fi
mcp_changed=0
pins_changed=0

# Check the template has every file this run copies before writing anything,
# so a template mid-edit fails here rather than leaving half a project.
need=("${shared[@]}")
if (( ! adopt )); then need+=("${docs[@]}"); fi
if (( with_mcp )); then need+=("${mcp_files[@]}" mcp/README.md); fi
if (( publish )); then need+=("${publish_files[@]}"); fi
if (( refresh )); then need+=("${customized[@]}"); fi
absent=()
for f in "${need[@]}"; do [[ -e $SKEL/$f ]] || absent+=("$f"); done
(( ${#absent[@]} == 0 )) || die "template is missing: ${absent[*]}"

# A refresh must be a diff someone can review on its own, so it never mixes
# with edits to the same files that nobody has committed yet.
if (( refresh )); then
  dirty=$(git -C "$target" status --porcelain --untracked-files=all -- "${managed[@]}") \
    || die "git status failed in $target"
  [[ -z $dirty ]] || die "refusing --refresh: commit or stash these first:
$dirty"
fi

# git records the executable bit, and a hook or script without it does not
# run, so set it whatever the template checkout lost (a zip download does).
wants_exec() { case $1 in scripts/*.sh|.githooks/*) return 0 ;; *) return 1 ;; esac; }

declare -A refreshed=()

copy_one() { # skel-relative path -> $target, never clobbering
  local rel=$1
  local src="$SKEL/$rel"
  local dst="$target/$rel"
  if [[ -e $dst || -L $dst ]]; then
    # --refresh has already said what it did with this one.
    [[ -n ${refreshed[$rel]:-} ]] || printf '  kept (already present): %s\n' "$rel"
    return 0
  fi
  quiet mkdir -p -- "$(dirname -- "$dst")"
  quiet cp -a -- "$src" "$dst"
  (( dry )) || substitute "$dst"
  if wants_exec "$rel"; then quiet chmod +x -- "$dst"; fi
  printf '  added: %s\n' "$rel"
}

# The template's copy with placeholders filled, so a diff shows real drift
# and not {{PROJECT}} against the project's name.
render() {
  rendered="$render_dir/file"
  cp -- "$SKEL/$1" "$rendered"
  substitute "$rendered"
}

differs() { # rel ours theirs -> true when they differ, the diff in $diff_out
  local rc=0
  diff_out=$(diff -u --label "$1 (this repo)" --label "$1 (template)" -- "$2" "$3") || rc=$?
  (( rc <= 1 )) || die "diff failed on $1"
  (( rc == 1 ))
}

refresh_one() { # overwrite a managed file with the template's, showing the change
  local rel=$1 dst="$target/$1"
  # Writing through a link could change a file outside this repo.
  if [[ -L $dst ]]; then refreshed[$rel]=1; printf '  skipped (a symlink): %s\n' "$rel"; return 0; fi
  [[ -e $dst ]] || return 0   # copy_one adds it
  refreshed[$rel]=1
  render "$rel"
  if differs "$rel" "$dst" "$rendered"; then
    printf '  %s: %s\n%s\n' "$( ((dry)) && echo 'would refresh' || echo 'refreshed')" "$rel" "$diff_out"
    quiet cp -- "$rendered" "$dst"
    [[ $rel != mcp/* ]] || mcp_changed=1
    [[ $rel != scripts/mirror.sh && $rel != scripts/pii-scan.sh ]] || pins_changed=1
  else
    printf '  unchanged: %s\n' "$rel"
  fi
  if wants_exec "$rel" && [[ ! -x $dst ]]; then
    quiet chmod +x -- "$dst"
    printf '  set:   +x on %s\n' "$rel"
  fi
}

compare_one() { # never overwrites: shows how this repo's copy has drifted
  local rel=$1 dst="$target/$1"
  [[ -e $dst ]] || return 0
  refreshed[$rel]=1
  render "$rel"
  if differs "$rel" "$dst" "$rendered"; then
    printf '  differs from template — port by hand: %s\n%s\n' "$rel" "$diff_out"
  else
    printf '  matches template: %s\n' "$rel"
  fi
}

if (( adopt )); then
  mode=$( ((refresh)) && echo 'refreshing shared tooling in' || echo 'adopting shared tooling into' )
else
  mode=creating
fi
printf '%s %s\n  at %s\n  owner %s\n' "$mode" "$name" "$target" "$owner"
if (( publish )); then printf '  publishes to %s/%s\n' "$public_owner" "$name"; fi
printf '\n'

quiet mkdir -p -- "$target"

if (( adopt )); then
  if (( refresh )); then
    render_dir=$(mktemp -d)
    trap 'rm -rf -- "$render_dir"' EXIT
    for f in "${managed[@]}"; do refresh_one "$f"; done
    for f in "${customized[@]}"; do compare_one "$f"; done
  fi
  for f in "${shared[@]}"; do copy_one "$f"; done
  if (( publish )); then
    for f in "${publish_files[@]}"; do copy_one "$f"; done
  fi
  if (( with_mcp )); then
    for f in "${mcp_files[@]}"; do copy_one "$f"; done
    if [[ -d $target/mcp ]]; then
      printf '  kept (already present): mcp/\n'
    else
      quiet mkdir -p -- "$target/mcp"
      quiet cp -a -- "$SKEL/mcp/." "$target/mcp/"
      (( dry )) || substitute "$target/mcp/README.md"
      printf '  added: mcp/\n'
    fi
  fi
  # A bare `run: scripts/check.sh full` would pass the identity check on
  # nothing: a fresh CI checkout has no commits "not on a remote". The skel's
  # step works out CHECK_RANGE from the event first.
  if [[ -f $target/.github/workflows/ci.yml ]] \
     && ! grep -q 'scripts/check.sh full' "$target"/.github/workflows/*.yml 2>/dev/null; then
    printf '\n  note: no workflow runs scripts/check.sh full (it runs the PII scan too) — port the\n'
    printf '        hygiene job from %s/.github/workflows/ci.yml into ci.yml,\n' "$SKEL"
    printf '        its "house checks" step whole: it sets CHECK_RANGE for the event\n'
  fi
  if (( publish )) && [[ -f $target/.github/workflows/ci.yml ]] \
     && ! grep -q 'scripts/sandbox.sh' "$target/.github/workflows/ci.yml"; then
    printf '\n  note: this repo publishes, so outside PRs land here: run every ci.yml step that\n'
    printf '        runs its code as scripts/sandbox.sh <command>, and install with no package\n'
    printf '        scripts (npm ci --ignore-scripts). The check job in %s/.github/workflows/ci.yml shows how.\n' "$SKEL"
  fi

  # Make sure the ignore rules the tooling depends on are present.
  missing=()
  for pat in '.env' 'pi.md' 'scripts/pii-scan.local' 'mcp/.env' 'mcp/node_modules/' 'mcp/build/' '.claude/settings.local.json'; do
    grep -qxF -- "$pat" "$target/.gitignore" 2>/dev/null || missing+=("$pat")
  done
  # A `*.env` rule also ignores the tool pins, and CI then has none and stops.
  if git -C "$target" check-ignore -q -- scripts/check-tools.env 2>/dev/null; then
    missing+=('!scripts/check-tools.env')
  fi
  if (( ${#missing[@]} )); then
    printf '\n  .gitignore is missing rules the tooling needs:\n'
    printf '    %s\n' "${missing[@]}"
    if (( dry )); then
      printf '  would append them under a marked block\n'
    else
      { printf '\n# --- added by _template/new-project.sh --adopt (%s) ---\n' "$today"
        printf '%s\n' "${missing[@]}"; } >> "$target/.gitignore"
      printf '  appended them to .gitignore\n'
    fi
  fi
  # A folder rule (scripts/) cannot be undone for one file inside it.
  if (( ! dry )) && git -C "$target" check-ignore -q -- scripts/check-tools.env 2>/dev/null; then
    printf '\n  !! scripts/check-tools.env is still ignored (%s): fix .gitignore by hand, or CI has no tool pins\n' \
      "$(git -C "$target" check-ignore -v -- scripts/check-tools.env | cut -f1)"
  fi
else
  for f in "${docs[@]}"; do copy_one "$f"; done
  for f in "${shared[@]}"; do copy_one "$f"; done
  if (( publish )); then
    for f in "${publish_files[@]}"; do copy_one "$f"; done
  fi
  if (( with_mcp )); then
    for f in "${mcp_files[@]}"; do copy_one "$f"; done
    quiet mkdir -p -- "$target/mcp"
    quiet cp -a -- "$SKEL/mcp/." "$target/mcp/"
    (( dry )) || substitute "$target/mcp/README.md"
    printf '  added: mcp/\n'
  else
    (( dry )) || sed -i '/^mcp\//d' "$target/.gitignore"
  fi

  # The gitignored side of the trio: created here because git never carries it.
  if [[ ! -e $target/.env ]]; then
    quiet cp -- "$target/.env.example" "$target/.env"
    printf '  added: .env (gitignored — fill in the real values)\n'
  fi
  if [[ ! -e $target/pi.md ]]; then
    if (( ! dry )); then
      cat > "$target/pi.md" <<PIMD
# $name — narrative context (NEVER COMMITTED)

Context no machine consumes: which device belongs to whom, why a decision was
made, what is still undecided. Real values live in \`.env\`; this file points at
them and never duplicates them.

## Hardware / accounts

## Open questions
PIMD
    fi
    printf '  added: pi.md (gitignored)\n'
  fi

  # Only main for now: a branch needs a commit, and the first commit is the
  # person's to make once the TODOs are read. The next steps add dev.
  if [[ ! -d $target/.git ]]; then
    quiet git -C "$target" init -q -b main
    printf '  added: git repo on main (dev comes after the first commit, below)\n'
  fi
fi

quiet git -C "$target" config core.hooksPath .githooks
printf '  set:   core.hooksPath = .githooks (pre-push runs scripts/check.sh fast)\n'

# Wire the credential helper here so nobody hand-rolls one by copying a
# sibling's — which is how a helper that answered for ANY host, over plain
# http included, got into a second project. It only has a token to find when
# there is an mcp/.env, so without MCP leave it unwired rather than leaving a
# dangling config entry.
if (( with_mcp )) && [[ -f $target/scripts/git-credential-github.sh ]]; then
  quiet chmod +x "$target/scripts/git-credential-github.sh"
  # Single quotes on purpose: git stores this string and expands it at push
  # time, so the checkout stays movable. Expanding it here would bake in
  # today's absolute path.
  # shellcheck disable=SC2016
  quiet git -C "$target" config credential.helper \
    '!"$(git rev-parse --show-toplevel)"/scripts/git-credential-github.sh'
  printf '  set:   credential.helper (pushes read the PAT from mcp/.env)\n'
fi

# One fine-grained token per repo, scoped to that repo alone: the file starts
# as the placeholder and the owner makes the token (never a sibling's copy).
if (( with_mcp )) && [[ -d $target/mcp ]]; then
  if [[ ! -e $target/mcp/.env ]]; then
    quiet cp -- "$target/mcp/.env.example" "$target/mcp/.env"
    quiet chmod 600 "$target/mcp/.env"
    printf '  added: mcp/.env (put a fine-grained token for this repo alone in it; mcp/README.md lists the permissions)\n'
  fi
  if (( build_mcp )) && command -v npm >/dev/null 2>&1; then
    printf '\n  building the MCP server...\n'
    if (( dry )); then
      printf '  would: npm install && npm run build in %s/mcp\n' "$target"
    else
      ( cd "$target/mcp" && npm install --silent && npm run build --silent ) \
        && printf '  built: mcp/build/index.js\n' \
        || printf '  !! npm build failed — run it by hand in %s/mcp\n' "$target"
    fi
  fi
fi

# Which template this repo's shared files came from, so the refresh job and
# the pre-push hook can tell when it is behind. TEMPLATE_VERSION wins: the
# refresh job builds from an export of the template's main, which has no .git.
template_version=${TEMPLATE_VERSION:-$(git -C "$TEMPLATE_DIR" rev-parse HEAD 2>/dev/null || true)}
if [[ $template_version =~ ^[0-9a-f]{40}$ ]] && (( ! dry )); then
  printf '%s\n' "$template_version" >"$target/.template-version"
  printf '  set:   .template-version = %s\n' "${template_version:0:12}"
fi

if (( adopt && refresh )); then
  cat <<NEXT

done. next:
  cd $target
  git diff                     # review every refreshed file; port the "port by hand" diffs above
  scripts/check.sh fast        # the checks pre-push and CI run; fix what it finds before pushing
  git status                   # then commit as: chore: refresh shared tooling from the template
NEXT
  if (( pins_changed && ! dry )) && [[ -f $target/.github/workflows/publish.yml ]]; then
    # publish.yml pins the publisher by hash, so a changed one is refused until
    # a person updates the pins there: the edit that says "publish with this".
    printf '\n  !! publish.yml pins the publisher by hash, and a refresh changed it. Until these lines\n'
    printf '     replace the old ones (both jobs), the publish check fails:\n'
    ( cd "$target" && sha256sum scripts/mirror.sh scripts/pii-scan.sh | sed 's/^/          /' )
  fi
  if (( mcp_changed )); then
    printf '  (cd mcp && npm ci --ignore-scripts && npm run build)   # the MCP server changed: rebuild it\n'
  fi
elif (( adopt )); then
  cat <<NEXT

done. next:
  cd $target
  scripts/check.sh fast        # the checks pre-push and CI run; fix what it finds before pushing
  git status                   # review, then commit as: chore: adopt shared dev tooling
  # no remote yet? ~/Projects/_template/README.md, "Putting a project on GitHub"
NEXT
else
  cat <<NEXT

done. next:
  cd $target
  grep -rn 'TODO($name)' --exclude-dir=node_modules .   # every one is a real decision
  \$EDITOR agent.md CLAUDE.md README.md .env.example
  scripts/pii-scan.sh                                   # "clean" before anything is committed
  git add -A && git commit -m 'chore: scaffold from the Projects template'
  git switch -c dev                                     # dev is the work branch; main is the release
  scripts/check.sh fast                                 # the checks pre-push and CI run
  # when ready: a private, empty repo on GitHub and a token for it alone —
  # ~/Projects/_template/README.md, "Putting a project on GitHub"
  git remote add origin https://github.com/$owner/$name.git && git push -u origin dev
NEXT
fi
if (( publish )); then
  printf '  # public mirror: list each public file in PUBLISH; docs/publishing.md has the rest\n'
fi
printf '\nrestart the agent session in %s so .mcp.json is picked up.\n' "$target"
