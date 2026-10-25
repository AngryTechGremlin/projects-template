#!/usr/bin/env bash
# Give one private repo's publish job the right to push to its public copy,
# and nothing else (skel/docs/publishing.md says why it is a deploy key).
#
#   publish/add-public-key.sh <repo>          make the key, print the two pastes
#   publish/add-public-key.sh --done <repo>   prove the public side took it, then
#                                             delete the private half from disk
#
# <repo> is the private repo's name under $GITHUB_OWNER (default
# AngryTechGremlin); its PUBLISH file names the public repo. Run it in the
# private repo's checkout or anywhere under ~/Projects/<repo>.
#
# How the two sides meet: the public repo holds the key's public half as a
# deploy key with write access (it opens that one repo, and only for git), and
# the private repo holds the private half as the Actions secret
# PUBLIC_DEPLOY_KEY, which only its own workflows can read. The publish job,
# started by the owner's click, pushes with it. The public repo's ruleset lets
# that deploy key through and nobody else.
#
# The private half exists on disk only between the two runs, mode 600 in
# ~/.config/publish/keys/, so it can be copied into the secret; --done shreds
# it. A key that leaks reaches one public repo, so every repo gets its own.
#
# Exit 0 = done, 1 = refused or the check failed, 2 = usage/setup error.
set -euo pipefail

die() { printf 'add-public-key: %s\n' "$1" >&2; exit "${2:-2}"; }
usage() { echo 'usage: add-public-key.sh [--done] <repo>   (the private repo name, e.g. book-companion)'; }

done_mode=0
case ${1:-} in
  -h|--help) usage; exit 0 ;;
  --done) done_mode=1; shift ;;
esac
(( $# == 1 )) || { usage >&2; exit 2; }
repo=$1
owner=${GITHUB_OWNER:-AngryTechGremlin}
[[ $repo =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "repo name must be lowercase letters, digits, . _ -: $repo"
for tool in ssh ssh-keygen git shred; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done

checkout=${PROJECTS_DIR:-$HOME/Projects}/$repo
[[ -f $checkout/PUBLISH ]] || die "$checkout/PUBLISH is missing: add the mirror kit first (new-project.sh --adopt --publish)"
public=$(git config --file "$checkout/PUBLISH" --get publish.repo) \
  || die "PUBLISH names no publish.repo"
[[ $public =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "publish.repo is not <org>/<repo>: $public"

keys=${PUBLISH_KEYS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/publish/keys}
key=$keys/$repo

if (( done_mode )); then
  [[ -f $key ]] || die "no key at $key: nothing to finish (already done, or run without --done first)" 1
  # A deploy key answers GitHub's ssh greeting with the repo it opens; the
  # account key would answer with a user name, so this proves which key it is.
  greet=$(ssh -F /dev/null -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)
  shopt -s nocasematch
  [[ $greet == *"Hi $public!"* ]] \
    || die "GitHub does not know this key as $public's deploy key yet (step 1). It said: ${greet%%$'\n'*}" 1
  shopt -u nocasematch
  echo "ok  the public repo $public accepts this key"
  echo
  echo "Is the private half saved as the Actions secret PUBLIC_DEPLOY_KEY in $owner/$repo (step 2)?"
  echo "This deletes the only copy on disk; without the secret you would start over."
  [[ -t 0 ]] || die "stdin is not a terminal: answer the question in a terminal"
  read -rp "Type yes to delete it: " answer
  [[ $answer == yes ]] || die "kept $key; run --done again once the secret is saved" 1
  shred -u -- "$key"
  rm -f -- "$key.pub"
  echo "deleted the private half. $repo publishes with the secret from now on."
  exit 0
fi

[[ ! -e $key ]] || die "$key already exists: finish it with --done, or delete it and start again" 1
umask 077
mkdir -p -- "$keys"
ssh-keygen -q -t ed25519 -N '' -C "publish-$repo" -f "$key"

cat <<EOF
Made a publish key for $repo -> $public.

1. The public half goes on the public repo, with write access:
   https://github.com/$public/settings/keys/new
     Title:  publish
     Key:    $(cat -- "$key.pub")
     Tick "Allow write access".

2. The private half goes in the private repo's Actions secrets:
   https://github.com/$owner/$repo/settings/secrets/actions/new
     Name:   PUBLIC_DEPLOY_KEY
     Secret: everything this prints, BEGIN and END lines included:
             cat $key

3. Then: publish/add-public-key.sh --done $repo
   It checks the public repo took the key and deletes the private half here.
EOF
