#!/usr/bin/env bash
# Register a house GitHub Actions runner for one repo on this box
# (skel/docs/ci-runner.md says why it is shaped so).
#
#   runners/add-runner.sh ci   <repo>    on the CI box
#   runners/add-runner.sh prod <repo>    on the prod box
#
# Run it as the user the runner runs as, in a terminal: it asks for the
# registration token (the repo on GitHub -> Settings -> Actions -> Runners ->
# New self-hosted runner; single-use, valid for an hour). The token is typed at
# a hidden prompt, never passed as an argument, so it stays out of `ps` and
# shell history.
#
# ci:   $ACTIONS_RUNNER_DIR/<repo>-ci, named <repo>-ci with the one label
#       <repo>-ci and no default labels, so it never carries `self-hosted` and
#       a deploy job can never be handed to it. Runs as
#       ~/.config/systemd/user/<repo>-ci-runner.service, enabled, with linger
#       on so it keeps running with nobody logged in.
# prod: /opt/actions-runners/<repo> (the folder the deploy guard checks for),
#       named prod-<repo> with the default `self-hosted` label a deploy job's
#       `runs-on` asks for. Creating that folder and installing the system
#       service need root, which this script never uses: it prints those two
#       lines for the owner to run.
#
# Neither name carries a box name: GitHub shows it in every job log, and a
# deploy guard that names a host would put the host in a tracked file.
#
# Safe to re-run after a failure: an unpacked runner is not downloaded again,
# and a registered one is refused, never replaced. Without a terminal it stops
# at the token prompt, after the download.
#
# Exit 0 = registered (ci: and running), 1 = refused or failed (already
# registered, checksum mismatch, a different unit in the way, the service did
# not stay up), 2 = usage/setup error (bad name, wrong platform, missing tool,
# no terminal, no token, prod folder not prepared).
#
# Env: ACTIONS_RUNNER_DIR  where ci runners live (default ~/actions-runner;
#                          tests point it at a scratch folder)
#      PROD_RUNNER_DIR     where prod runners live (default
#                          /opt/actions-runners; tests only)
#      RUNNER_OWNER        the repo's GitHub owner (default AngryTechGremlin;
#                          for a repo under another account or org)
set -euo pipefail

# Bump: both values from the release's "SHA-256 Checksums" list (the linux-x64
# line) at github.com/actions/runner/releases. Only the first download uses
# them; a registered runner updates itself.
version=2.338.0
sha256=af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32

die() { printf 'add-runner: %s\n' "$1" >&2; exit "${2:-2}"; }
warn() { printf 'add-runner: warning: %s\n' "$1" >&2; }
usage() { echo 'usage: add-runner.sh ci|prod <repo>   (the GitHub repo name, e.g. book-companion)'; }

case $# in
  1) [[ $1 == -h || $1 == --help ]] && { usage; exit 0; }; usage >&2; exit 2 ;;
  2) ;;
  *) usage >&2; exit 2 ;;
esac
mode=$1
repo=$2
owner=${RUNNER_OWNER:-AngryTechGremlin}

[[ $mode == ci || $mode == prod ]] || { usage >&2; exit 2; }
[[ $repo =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "repo name must be lowercase letters, digits, . _ -: $repo"
[[ $owner =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "RUNNER_OWNER is not a GitHub account name: $owner"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] \
  || die "the pinned runner is linux-x64; this box is $(uname -sm)"
# config.sh refuses root too; and a root unit would not be a --user unit.
(( EUID != 0 )) || die "run it as the user the runner runs as, not as root"
me=$(id -un)
need=(curl sha256sum tar)
[[ $mode == prod ]] || need+=(systemctl loginctl)
for tool in "${need[@]}"; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done

if [[ $mode == ci ]]; then
  systemctl --user show --property=Version >/dev/null 2>&1 \
    || die "systemctl --user cannot reach your user manager; log in to the box as this user (not su/sudo)"
  runners=${ACTIONS_RUNNER_DIR:-$HOME/actions-runner}
  dir=$runners/$repo-ci
  name=$repo-ci
  labels=(--no-default-labels --labels "$repo-ci")
else
  runners=${PROD_RUNNER_DIR:-/opt/actions-runners}
  dir=$runners/$repo
  name=prod-$repo
  labels=()
  # Root makes the folder once and hands it over; everything after is this
  # user's, so the runner and its deploys never run as root.
  if [[ ! -d $dir || ! -O $dir ]]; then
    die "$dir must exist and be owned by $me first. Run, then re-run this:
  sudo mkdir -p $dir && sudo chown $me: $dir"
  fi
fi
unit=$repo-ci-runner.service
unit_file=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$unit
stage=""
trap '[[ -z $stage ]] || rm -rf -- "$stage"' EXIT

# The unit names this folder, and systemd reads a space or % in it as syntax.
[[ $dir =~ ^/[A-Za-z0-9/._-]+$ ]] || die "runner folder must be an absolute path of plain characters: $dir"
[[ ! -e $dir/.runner ]] \
  || die "$dir already holds a registered runner; remove it first (docs/ci-runner.md, \"Removing a runner\")" 1

if [[ $mode == ci ]]; then
  # The same unit the runners before this kit use; %h keeps the home folder out.
  unit_dir=$dir
  [[ $dir != "$HOME"/* ]] || unit_dir=%h/${dir#"$HOME"/}
  want_unit="[Unit]
Description=GitHub Actions runner for $repo CI
After=network-online.target

[Service]
WorkingDirectory=$unit_dir
ExecStart=$unit_dir/run.sh
Restart=always
RestartSec=10

[Install]
WantedBy=default.target"
  # Checked before registering, so a refusal here leaves nothing half done.
  if [[ -e $unit_file && $(cat -- "$unit_file") != "$want_unit" ]]; then
    die "$unit_file exists and differs from the unit this kit writes; read it, then move it aside" 1
  fi
fi

if [[ ! -x $dir/config.sh ]]; then
  # A prod folder is created empty by root; a ci one may not exist yet.
  [[ ! -d $dir || -z $(ls -A -- "$dir") ]] \
    || die "$dir has files but no runner; look at them, then remove them" 1
  mkdir -p -- "$runners"
  # Unpack beside the target and move it in whole, so an interrupted run
  # leaves nothing or a complete runner, never half of one. (Prod unpacks into
  # its own folder: /opt/actions-runners itself is root's.)
  if [[ $mode == ci ]]; then stage=$(mktemp -d "$runners/.$repo-ci.XXXXXX"); else stage=$(mktemp -d "$dir/.unpack.XXXXXX"); fi
  url=https://github.com/actions/runner/releases/download/v$version/actions-runner-linux-x64-$version.tar.gz
  echo "downloading runner v$version (about 230 MB)..."
  curl -fsSL --proto '=https' --tlsv1.2 -o "$stage/runner.tar.gz" "$url" || die "download failed: $url" 1
  printf '%s  %s\n' "$sha256" "$stage/runner.tar.gz" | sha256sum --check --status \
    || die "checksum mismatch: the download is not the pinned v$version runner; nothing was unpacked" 1
  mkdir -- "$stage/runner"
  tar -xzf "$stage/runner.tar.gz" -C "$stage/runner"
  [[ -x $stage/runner/config.sh ]] || die "the archive holds no config.sh; nothing was unpacked" 1
  if [[ $mode == ci ]]; then
    [[ ! -d $dir ]] || rmdir -- "$dir"
    mv -T -- "$stage/runner" "$dir"
  else
    # The folder stays (root made it); its new contents move in whole.
    find "$stage/runner" -mindepth 1 -maxdepth 1 -exec mv -t "$dir" -- {} +
  fi
  rm -rf -- "$stage"; stage=""
  echo "unpacked v$version (sha256 verified) into $dir"
fi

# Jobs see the service's PATH, not this shell's: for ci the user manager's,
# for prod the one config.sh saves from this shell into .path.
if [[ $mode == ci ]]; then
  svc_path=$(systemctl --user show-environment | sed -n 's/^PATH=//p')
  tools=(git curl python3 node docker bwrap)
else
  svc_path=$PATH
  tools=(git curl rsync docker)
fi
missing=()
for tool in "${tools[@]}"; do
  PATH=$svc_path command -v "$tool" >/dev/null || missing+=("$tool")
done
(( ${#missing[@]} == 0 )) || warn "not on the runner's PATH ($svc_path): ${missing[*]}
  Jobs that need them will fail. Install them system-wide, or put a full
  PATH= line in $dir/.env and restart the service."

# The token only ever comes from a terminal: an argument would show in `ps`
# and shell history, a pipe would mean it sat in a file or a variable first.
[[ -t 0 ]] || die "stdin is not a terminal: run this in a terminal on the box and type the
  token at the prompt (the download is done; a re-run skips it)"
token=""
read -rsp "Registration token for $owner/$repo: " token || true
echo >&2
[[ -n $token ]] || die "no token entered"

# ACTIONS_RUNNER_INPUT_TOKEN is the runner's own way to take an input from the
# environment instead of argv, so the token stays out of `ps` here too. From
# inside the folder: config.sh checks its own libraries by relative path.
(cd "$dir" && ACTIONS_RUNNER_INPUT_TOKEN=$token ./config.sh --unattended \
  --url "https://github.com/$owner/$repo" --name "$name" \
  ${labels[@]+"${labels[@]}"} --work _work) \
  || die "config.sh did not register the runner (its output is above); re-run with a fresh token" 1
token=""

if [[ $mode == prod ]]; then
  cat <<EOF

registered: $name (default labels, incl. self-hosted) in $dir
Last step is root's, so it is yours. Run:
  cd $dir && sudo ./svc.sh install $me && sudo ./svc.sh start
Then github.com/$owner/$repo -> Settings -> Actions -> Runners must list
"$name" as Idle. Its deploy.yml's first step checks this folder
(skel/docs/ci-runner.md, "Only prod's runner deploys").
EOF
  exit 0
fi

mkdir -p -- "$(dirname -- "$unit_file")"
[[ -e $unit_file ]] || printf '%s\n' "$want_unit" >"$unit_file"
started=$(date +%s)
systemctl --user daemon-reload
systemctl --user enable --now "$unit"

# Without linger a user's services stop at logout and do not start at boot.
if [[ $(loginctl show-user "$me" --property=Linger --value 2>/dev/null) != yes ]]; then
  loginctl enable-linger "$me" \
    || warn "could not turn on linger: until 'loginctl enable-linger $me' works, the runner stops when you log out"
fi

# A simple service is "active" the moment run.sh starts, and a runner that
# cannot connect drops out within seconds: it has to stay up 5 s in a row.
streak=0
for _ in $(seq 30); do
  if systemctl --user is-active --quiet "$unit"; then streak=$((streak + 1)); else streak=0; fi
  (( streak < 5 )) || break
  sleep 1
done
(( streak >= 5 )) || die "$unit did not stay up; read: journalctl --user -u $unit -n 50" 1
journalctl --user -u "$unit" --since "@$started" -n 5 -o cat --no-pager 2>/dev/null || true

cat <<EOF

runner up: $name, label $name only, service $unit
Next: github.com/$owner/$repo -> Settings -> Actions -> Runners must list
"$name" as Idle, with the one label "$name". A push to dev then runs CI.
EOF
