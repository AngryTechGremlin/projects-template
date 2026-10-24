#!/usr/bin/env bash
# Run a command with no network, no home folder, no sockets and no secrets:
# for every step that runs this repo's code, above all code from an outside PR.
#
#   scripts/sandbox.sh python3 -m unittest discover -s tests
#   scripts/sandbox.sh sh -c 'npm run build --if-present && npm test --if-present'
#
# Why: the CI runner's user is in the docker and lxd groups, which is root on
# the box in all but name. A test that ran `docker run -v /:/host` could read
# every token and key there, empty the publish blocklist, or wait in /proc for
# the publish step's deploy key. In here the filesystem is read-only; $HOME,
# /home, /run, /tmp and the other places a box keeps its state are empty;
# there is no network but loopback; other processes are out of sight; setuid
# does nothing, so neither does sudo; and only a short list of variables gets
# in, so no token in the environment does.
#
# The checkout is a throwaway copy: the command can write to it, and every
# write is gone when it exits. Otherwise it could leave a hook or an fsmonitor
# in .git, or a changed script, for the next command outside to run with
# everything this hides. The cost: nothing a run builds survives it, so build
# and test in one call (the second example). The gitignored files that hold
# secrets (.env, .env.*, mcp/.env, pi.md, data/) read as empty, as they are in
# a fresh clone.
#
# Exit 2 if bwrap is missing or too old (the throwaway copy needs 0.10), or
# user namespaces are off: running the command unsandboxed instead would be
# the one wrong answer.
set -euo pipefail

(( $# )) || { echo "usage: scripts/sandbox.sh <command> [args...]" >&2; exit 2; }
command -v bwrap >/dev/null \
  || { echo "sandbox: bwrap is not installed (apt install bubblewrap)" >&2; exit 2; }
# The checkout is the one place the command sees that is not empty; were it
# $HOME or above, the command would see everything the rest of this hides.
case "$HOME/" in
  "$PWD/"*) echo "sandbox: run it from the repo checkout, not from the home folder or above" >&2; exit 2 ;;
esac
[[ $PWD != / ]] || { echo "sandbox: run it from the repo checkout, not from /" >&2; exit 2; }

args=(--unshare-all --die-with-parent --new-session
  --ro-bind / / --dev /dev --proc /proc)
# Homes, runtime state, logs and mounted shares. /var/run is usually a link to
# /run, already hidden (a tmpfs cannot go over a link); the docker and lxd
# sockets live under it and the snap and lxd folders.
for d in /home "$HOME" /root /run /tmp /var/tmp /var/log /var/snap /var/lib/lxd /var/run /mnt /media /srv; do
  [[ -d $d && ! -L $d ]] && args+=(--tmpfs "$d")
done
# actions/setup-* install their interpreters here, under the hidden $HOME.
# Read-only, it holds nothing but toolchains; at $HOME or above it would
# bring the home folder back.
if [[ -n ${RUNNER_TOOL_CACHE:-} && -d ${RUNNER_TOOL_CACHE:-} ]]; then
  case "$HOME/" in
    "${RUNNER_TOOL_CACHE%/}/"*) echo "sandbox: RUNNER_TOOL_CACHE is the home folder or above it" >&2; exit 2 ;;
  esac
  args+=(--ro-bind "$RUNNER_TOOL_CACHE" "$RUNNER_TOOL_CACHE")
fi
args+=(--overlay-src "$PWD" --tmp-overlay "$PWD" --chdir "$PWD")
for f in .env .env.* mcp/.env pi.md; do
  [[ $f == .env.example || ! -f $f || -L $f ]] || args+=(--dev-bind /dev/null "$PWD/$f")
done
[[ -d data && ! -L data ]] && args+=(--tmpfs "$PWD/data")

# The environment starts empty. These are what a toolchain and a test need,
# and none of them carries a secret; add one here only with that said.
args+=(--clearenv --setenv HOME "$HOME" --setenv TMPDIR /tmp)
for v in PATH LANG LANGUAGE LC_ALL LC_CTYPE TERM TZ USER LOGNAME CI GITHUB_ACTIONS \
  VIRTUAL_ENV LD_LIBRARY_PATH PKG_CONFIG_PATH pythonLocation Python_ROOT_DIR Python3_ROOT_DIR \
  RUNNER_TOOL_CACHE; do
  [[ -z ${!v+set} ]] || args+=(--setenv "$v" "${!v}")
done

# Try it empty first, so a sandbox that cannot start is told apart from a
# command that failed inside one.
if ! err=$(bwrap "${args[@]}" -- true 2>&1); then
  printf 'sandbox: bwrap cannot start here (user namespaces off, or bwrap older than 0.10?): %s\n' "$err" >&2
  exit 2
fi
exec bwrap "${args[@]}" -- "$@"
