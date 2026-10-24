#!/usr/bin/env bash
# Answer git's HTTPS credential prompts from the same gitignored mcp/.env the
# GitHub MCP server reads — one token, one home. The token never appears in a
# tracked file, in .git/config, or in argv ({{PROJECT}}'s agent.md §3, §8);
# this script is committable precisely because it holds none of it.
#
# new-project.sh wires this for you. To do it by hand in an existing checkout:
#   git config credential.helper "!$PWD/scripts/git-credential-github.sh"
set -euo pipefail

# git invokes the helper with get|store|erase; only `get` answers, and an
# empty answer falls through to the next helper or an interactive prompt.
[[ "${1:-}" == "get" ]] || exit 0

# git describes the request as key=value lines on STDIN, terminated by a blank
# line. Read them and answer ONLY for github.com over https.
#
# This check is the whole security of the thing, and it is the part that is
# easy to leave out — a helper that ignores stdin still works perfectly for the
# one remote you tested it against. It would also hand the token to whatever
# else git asks about: a `url.<base>.insteadOf` rewrite, a submodule URL
# someone else controls, a typo'd remote, or a plain-http host that would put
# the token on the wire in clear. A token that can push is worth guarding.
protocol="" host=""
while IFS='=' read -r key value; do
  case "$key" in
  protocol) protocol="$value" ;;
  host) host="$value" ;;
  "") break ;;
  esac
done
[[ "$protocol" == "https" && "$host" == "github.com" ]] || exit 0

env_file="$(git rev-parse --show-toplevel)/mcp/.env"
token="$(sed -n 's/^GITHUB_PERSONAL_ACCESS_TOKEN=//p' "$env_file" 2>/dev/null || true)"
[[ -n "$token" ]] || exit 0
printf 'username=x-access-token\npassword=%s\n' "$token"
