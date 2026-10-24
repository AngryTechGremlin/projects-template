#!/usr/bin/env bash
# Scaffold a new project from ~/Projects/_template, or adopt the shared dev
# tooling into an existing one. See _template/README.md for the why.
set -euo pipefail

TEMPLATE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SKEL="$TEMPLATE_DIR/skel"
PROJECTS_DIR=$(dirname -- "$TEMPLATE_DIR")

owner=${GITHUB_OWNER:-AngryTechGremlin}
target=""
adopt=0
with_mcp=1
build_mcp=1
reuse_token=0
dry=0
name=""

usage() {
  cat <<'USAGE'
usage: new-project.sh <name> [options]
       new-project.sh --adopt [<path>] [options]

Creates ~/Projects/<name> from the template: agent.md, a thin CLAUDE.md, the
.env/.env.example/pi.md trio, the lean GitHub MCP server and its wiring, the
PII scan (script + pre-push hook + CI job), and a seed ADR.

options:
  --dir PATH        where to create it            (default ~/Projects/<name>)
  --owner NAME      GitHub owner for URLs         (default $GITHUB_OWNER)
  --adopt [PATH]    add only the MISSING shared tooling to an existing repo;
                    never overwrites a file that is already there
  --reuse-token     copy a sibling project's mcp/.env token; then add the new
                    repo to that fine-grained token's access on GitHub
  --no-mcp          skip the MCP server and its wiring
  --no-build        copy mcp/ but skip npm install && npm run build
  --dry-run         print what would happen, change nothing
  -h, --help        this
USAGE
}

die() { printf 'new-project: %s\n' "$1" >&2; exit 2; }
run() {
  if (( dry )); then printf '  would: %s\n' "${*//$target\//}"; else "$@"; fi
}
# For steps whose effect is already narrated by an "added:"/"kept:" line.
quiet() { (( dry )) || "$@"; }

while (( $# )); do
  case $1 in
    --dir)         target=${2:?--dir needs a path}; shift 2 ;;
    --owner)       owner=${2:?--owner needs a name}; shift 2 ;;
    --adopt)       adopt=1; shift
                   if [[ ${1:-} && ${1:-} != -* ]]; then target=$1; shift; fi ;;
    --reuse-token) reuse_token=1; shift ;;
    --no-mcp)      with_mcp=0; shift ;;
    --no-build)    build_mcp=0; shift ;;
    --dry-run)     dry=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "unknown option: $1" ;;
    *)             [[ -z $name ]] || die "unexpected argument: $1"; name=$1; shift ;;
  esac
done

[[ -d $SKEL ]] || die "template skeleton missing: $SKEL"

if (( adopt )); then
  [[ -n $target ]] || target=$PWD
  target=$(cd -- "$target" 2>/dev/null && pwd) || die "no such directory: $target"
  [[ -d $target/.git ]] || die "not a git repo (adopt only works on an existing project): $target"
  name=$(basename -- "$target")
else
  [[ -n $name ]] || { usage >&2; exit 2; }
  [[ $name =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "name must be lowercase letters, digits, . _ -: $name"
  [[ -n $target ]] || target="$PROJECTS_DIR/$name"
  if [[ -e $target ]]; then
    [[ -d $target ]] || die "exists and is not a directory: $target"
    [[ -z $(ls -A -- "$target") ]] || die "directory exists and is not empty: $target"
  fi
fi

project_env=$(printf '%s' "$name" | tr 'a-z.-' 'A-Z__')
today=$(date +%F)

substitute() {
  local f=$1
  sed -i \
    -e "s|{{PROJECT_ENV}}|$project_env|g" \
    -e "s|{{PROJECT}}|$name|g" \
    -e "s|{{OWNER}}|$owner|g" \
    -e "s|{{DATE}}|$today|g" \
    "$f"
}

# Everything the skeleton offers, as source:destination pairs.
shared=(
  scripts/pii-scan.sh
  scripts/pii-scan.exclude
  .githooks/pre-push
  .github/workflows/ci.yml
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
  docs/ci-runner.md
)

copy_one() { # src-relative-path -> $target, never clobbering in adopt mode
  local rel=$1
  local src="$SKEL/$rel"
  local dst="$target/$rel"
  [[ -e $src ]] || return 0
  if [[ -e $dst ]]; then
    printf '  kept (already present): %s\n' "$rel"
    return 0
  fi
  quiet mkdir -p -- "$(dirname -- "$dst")"
  quiet cp -a -- "$src" "$dst"
  (( dry )) || substitute "$dst"
  printf '  added: %s\n' "$rel"
}

printf '%s %s\n  at %s\n  owner %s\n\n' \
  "$( ((adopt)) && echo 'adopting shared tooling into' || echo 'creating' )" "$name" "$target" "$owner"

quiet mkdir -p -- "$target"

if (( adopt )); then
  for f in "${shared[@]}"; do copy_one "$f"; done
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
  if [[ -f $target/.github/workflows/ci.yml ]] \
     && ! grep -q 'pii-scan' "$target"/.github/workflows/*.yml 2>/dev/null; then
    printf '\n  note: no workflow calls scripts/pii-scan.sh — add this step to ci.yml:\n'
    printf '        - name: no personal data in tracked files\n          run: scripts/pii-scan.sh\n'
  fi

  # Make sure the ignore rules the tooling depends on are present.
  missing=()
  for pat in '.env' 'pi.md' 'mcp/.env' 'mcp/node_modules/' 'mcp/build/' '.claude/settings.local.json'; do
    grep -qxF -- "$pat" "$target/.gitignore" 2>/dev/null || missing+=("$pat")
  done
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
else
  for f in "${docs[@]}"; do copy_one "$f"; done
  for f in "${shared[@]}"; do copy_one "$f"; done
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

  if [[ ! -d $target/.git ]]; then
    quiet git -C "$target" init -q -b main
    printf '  added: git repo on main\n'
  fi
fi

quiet git -C "$target" config core.hooksPath .githooks
printf '  set:   core.hooksPath = .githooks (pre-push PII scan)\n'

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

if (( with_mcp )) && [[ -d $target/mcp ]]; then
  if [[ ! -e $target/mcp/.env ]]; then
    src=""
    if (( reuse_token )); then
      while IFS= read -r cand; do
        [[ $cand == "$target/mcp/.env" ]] && continue
        grep -qE '^GITHUB_PERSONAL_ACCESS_TOKEN=[^[:space:]<]{8,}' "$cand" && { src=$cand; break; }
      done < <(find "$PROJECTS_DIR" -maxdepth 3 -path '*/mcp/.env' -type f 2>/dev/null | sort)
    fi
    if [[ -n $src ]]; then
      quiet cp -- "$src" "$target/mcp/.env"
      quiet chmod 600 "$target/mcp/.env"
      printf '  added: mcp/.env (token reused from %s; add this repo to its access on GitHub)\n' "${src#"$PROJECTS_DIR"/}"
    else
      quiet cp -- "$target/mcp/.env.example" "$target/mcp/.env"
      quiet chmod 600 "$target/mcp/.env"
      printf '  added: mcp/.env (put a fine-grained token for this repo in it; mcp/README.md lists the permissions)\n'
    fi
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

if (( adopt )); then
  cat <<NEXT

done. next:
  cd $target
  scripts/pii-scan.sh          # should print "clean"; if not, fix before pushing
  git status                   # review, then commit as: chore: adopt shared dev tooling
  # no remote yet? ~/Projects/_template/README.md, "Putting a project on GitHub"
NEXT
else
  cat <<NEXT

done. next:
  cd $target
  grep -rn 'TODO($name)' --exclude-dir=node_modules .   # every one is a real decision
  \$EDITOR agent.md CLAUDE.md README.md .env.example
  scripts/pii-scan.sh                                   # should print "clean"
  git add -A && git commit -m 'chore: scaffold from the Projects template'
  # when ready: a private, empty repo on GitHub and a token for it alone —
  # ~/Projects/_template/README.md, "Putting a project on GitHub"
  git remote add origin https://github.com/$owner/$name.git && git push -u origin HEAD
NEXT
fi
printf '\nrestart the agent session in %s so .mcp.json is picked up.\n' "$target"
