#!/usr/bin/env bash
# Fill the publish blocklist by answering questions, so its owner never has to
# know its format (skel/docs/publishing.md, "The blocklist", says what it is).
#
#   publish/add-to-blocklist.sh
#
# Run it in your own terminal, never from a Claude session (not even with
# `!`): the answers are the very words that must never reach a session, a log
# or a commit, so it refuses unless its input and output are a terminal.
#
# It first offers what this box already knows (its name, saved Wi-Fi networks,
# the names in ~/.ssh/config, /etc/hosts and the tailnet, house-only host names
# and email addresses in the projects' .env files, your account's name), then
# asks for what no box knows. Nothing is written until you confirm the list at
# the end, and answers are not kept in shell history. Run it again any time:
# it skips whatever the list already catches. To remove an entry, edit the
# file.
#
# Exit 0 = added (or nothing to add), 1 = you said no, 2 = setup error.
set -euo pipefail

die() { printf 'add-to-blocklist: %s\n' "$1" >&2; exit "${2:-2}"; }

[[ -t 0 && -t 1 ]] || die "run it in your own terminal: the answers must never pass through a session or a log"

bl=${PUBLISH_BLOCKLIST:-$HOME/.config/publish/blocklist}
projects=${PROJECTS_DIR:-$HOME/Projects}
umask 077
mkdir -p -- "$(dirname -- "$bl")"
[[ -e $bl ]] || : >"$bl"
chmod 600 -- "$bl"

# What the list holds already, read the way mirror.sh reads it.
have=()
while IFS= read -r line || [[ -n $line ]]; do
  line=${line//$'\r'/}
  line=${line#$'\xef\xbb\xbf'}
  line=${line%%#*}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [[ -n $line ]] && have+=("$line")
done <"$bl"

# What must stay publishable: the identity every snapshot carries and each
# public repo's name. An entry inside one of them would stop every publish.
public=angrytechgremlin@users.noreply.github.com
for p in "$projects"/*/PUBLISH; do
  [[ -f $p ]] && public+=" $(git config --file "$p" --get publish.repo || true)"
done
public=${public,,}

new=()
declare -A seen=()

caught() { # <word>: true when an entry, old or new, already matches it
  local w=${1,,} e
  for e in "${have[@]}" "${new[@]}"; do
    [[ $w == *"${e,,}"* ]] && return 0
  done
  return 1
}

add() { # <entry>: queue it, or say why not
  local e=$1
  e=${e#"${e%%[![:space:]]*}"}
  e=${e%"${e##*[![:space:]]}"}
  [[ -n $e ]] || return 0
  if [[ $e == *'#'* ]]; then
    echo "     not added: '$e' holds a #, which starts a comment"
  elif (( ${#e} < 4 )); then
    echo "     not added: '$e' is under 4 characters and would match everywhere; type a longer form ('$e.', '$e-', or with the surname)"
  elif [[ $public == *"${e,,}"* ]]; then
    echo "     not added: '$e' is part of the public name every snapshot carries, so it would stop every publish"
  elif caught "$e"; then
    echo "     already caught: $e"
  else
    new+=("$e")
    echo "     + $e"
  fi
}

offer() { # <where it was found> <candidate>...: ask about each, once
  local why=$1 c a
  shift
  for c; do
    (( ${#c} >= 4 )) && [[ -z ${seen[${c,,}]:-} ]] || continue
    seen[${c,,}]=1
    caught "$c" && continue
    [[ $public == *"${c,,}"* ]] && continue
    read -r -e -p "  $c  ($why)  add? [y]es / [e]dit / [N]o: " a
    case ${a,,} in
      y | yes) add "$c" ;;
      e | edit) read -r -e -i "$c" -p "     as: " a && add "$a" ;;
    esac
  done
}

host_word() { # <host>: the part of a host name that names the house, if any
  local h=${1,,} skip='^[0-9.]+$|:|^localhost|^ip6-|[*?!]'
  h=${h%.}
  [[ $h =~ $skip ]] && return 0 # addresses are the scan's job; patterns name nothing
  case $h in
    *.lan | *.local | *.home | *.internal | *.home.arpa | *.localdomain | *.ts.net) printf '%s\n' "${h%%.*}" ;;
    github.com | *.github.com | gitlab.com | bitbucket.org) ;;
    *) printf '%s\n' "$h" ;;
  esac
}

offer_hosts() { # <where> <host>...
  local why=$1 h
  shift
  for h; do offer "$why" "$(host_word "$h")"; done
}

big_mail() { # <domain>: true for a mail provider's domain, which names no one
  case ${1,,} in
    gmail.com | googlemail.com | outlook.com | hotmail.com | live.com | msn.com | yahoo.com | icloud.com | me.com | mac.com | aol.com | proton.me | protonmail.com | gmx.com | fastmail.com) return 0 ;;
  esac
  return 1
}

offer_email() { # <where> <address>...: the part before the @, and a domain of your own
  local why=$1 a
  shift
  for a; do
    [[ ${a,,} == *noreply* || ${a,,} == *@example.* || ${a,,} == *.example ]] && continue
    offer "$why" "${a%@*}"
    big_mail "${a#*@}" || offer "$why, its domain" "${a#*@}"
  done
}

offer_name() { # <where> <full name>: the surname, then the first name
  local -a w
  read -r -a w <<<"$2"
  (( ${#w[@]} )) || return 0
  offer "$1, surname" "${w[-1]}"
  (( ${#w[@]} > 1 )) && offer "$1, first name" "${w[0]}"
  return 0
}

echo "The publish blocklist holds ${#have[@]} entries. Each one stops a publish when it"
echo "appears in a file going public, matched anywhere, in any case. A wrong entry"
echo "only stops a publish until it is removed; a missed one is public for good."
echo
echo "First, what this box knows. Nothing is written until the end."

offer_hosts "this box's name" "$(uname -n)"

if command -v nmcli >/dev/null; then
  while IFS= read -r -u 3 conn; do
    ssid=$(nmcli -g 802-11-wireless.ssid connection show id "$conn" 2>/dev/null || true)
    offer "a saved Wi-Fi network" "${ssid:-$conn}"
  done 3< <(nmcli -t -f NAME,TYPE connection show 2>/dev/null | sed -n 's/:802-11-wireless$//p' | sed 's/\\:/:/g')
fi

if [[ -r $HOME/.ssh/config ]]; then
  mapfile -t names < <(awk 'tolower($1) == "host" || tolower($1) == "hostname" { for (i = 2; i <= NF; i++) print $i }' "$HOME/.ssh/config")
  offer_hosts "in ~/.ssh/config" "${names[@]}"
fi

mapfile -t names < <(awk '$1 !~ /^(#|127\.|::1|f[ef]0)/ { for (i = 2; i <= NF && $i !~ /^#/; i++) print $i }' /etc/hosts 2>/dev/null)
offer_hosts "in /etc/hosts" "${names[@]}"

if command -v tailscale >/dev/null; then
  mapfile -t names < <(tailscale status --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("MagicDNSSuffix") or "")
for p in [d.get("Self") or {}, *(d.get("Peer") or {}).values()]:
    print(p.get("HostName") or "")' 2>/dev/null || true)
  offer_hosts "on the tailnet" "${names[@]}"
fi

# An address counts only where one starts: a password in user:pass@host is not one.
email_re='(^|[^A-Za-z0-9._%+:/-])([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+)'
for f in "$projects"/*/.env "$projects"/*/*/.env; do
  [[ -f $f ]] || continue
  where="in ${f#"$projects"/}"
  mapfile -t names < <(grep -ohiE '[a-z0-9-]+(\.[a-z0-9-]+)*\.(lan|local|home|internal|home\.arpa|localdomain|ts\.net)\b' "$f" || true)
  offer_hosts "$where" "${names[@]}"
  mapfile -t names < <(grep -ohE "$email_re" "$f" | sed -E "s#$email_re#\\2#" || true)
  offer_email "$where" "${names[@]}"
done

offer_email "git's user.email" "$(git config --global user.email || true)"
offer_name "git's user.name" "$(git config --global user.name || true)"
offer_name "this account's full name" "$(getent passwd "$(id -un)" | cut -d: -f5 | cut -d, -f1)"

ask() { # <question> <hint> <handler>: one answer per line until an empty one
  local a
  printf '\n%s\n  %s\n  (one per line; an empty line moves on)\n' "$1" "$2"
  while read -r -e -p "  > " a && [[ -n ${a//[[:space:]]/} ]]; do "$3" "$a"; done
}

person() { # <full name>: the surname, and each other name on a yes
  local -a w
  local n a
  read -r -a w <<<"$1"
  if (( ${#w[@]} == 1 )); then add "$1"; return 0; fi
  if (( ${#w[-1]} >= 4 )); then add "${w[-1]}"; else add "$1"; fi
  for n in "${w[@]:0:${#w[@]}-1}"; do
    if (( ${#n} < 4 )) || caught "$n"; then continue; fi
    read -r -e -p "     '$n' on its own too? Say no if it is also a common word (Will, Grace, Rose). [y/N]: " a
    [[ ${a,,} == y* ]] && add "$n"
  done
  return 0
}

email() { # <address>: the part before the @, and a domain of your own
  local a=$1
  if [[ $a != *@*.* ]]; then add "$a"; return 0; fi
  add "${a%@*}"
  big_mail "${a#*@}" || add "${a#*@}"
}

phone() { # <number>: its last seven digits written plain, with a dash and with a dot
  local d=${1//[^0-9]/}
  if (( ${#d} < 7 )); then echo "     not added: fewer than 7 digits"; return 0; fi
  d=${d: -7}
  add "$d"
  add "${d:0:3}-${d:3}"
  add "${d:0:3}.${d:3}"
}

echo
echo "Now what no box knows."
ask "Everyone in the household: full names." \
  "The surname goes in; you are asked about each first name." person
ask "Other family surnames: maiden names, grandparents, in-laws." \
  "Surnames alone are enough." add
ask "Handles and usernames: the kids' gamertags (Minecraft, Switch, Roblox), your other accounts." \
  "Not AngryTechGremlin or TechThatWorks: those are meant to be public." add
ask "Email addresses anyone in the house uses." \
  "Type the whole address; the part before the @ goes in, and the domain unless it is gmail or the like." email
ask "Phone numbers." \
  "Any format; the last seven digits go in, as 5551234, 555-1234 and 555.1234." phone
ask "Where you live: the street's distinctive word (Maplewood, not Maplewood Drive), town, county, subdivision." \
  "Each on its own line." add
ask "Box, device and network names not offered above: other computers, the NAS, router, printers, renamed TVs, the guest Wi-Fi." \
  "A name that is also a plain word goes in as 'name.' or 'name-', so it does not match the word." add
ask "Anything else that points at your family: schools, co-ops, workplaces, churches, teams, the house's name spelled other ways." \
  "Fragments are fine: one distinctive word each." add

echo
if (( ${#new[@]} == 0 )); then
  echo "Nothing new to add. The list holds ${#have[@]} entries."
  exit 0
fi
printf 'About to add %d entries to %s:\n' "${#new[@]}" "${bl/#"$HOME"/\~}"
printf '  %s\n' "${new[@]}"
read -r -p "Write them? [y/N]: " a
[[ ${a,,} == y* ]] || die "nothing written" 1
# A last line with no newline would swallow the first new entry.
[[ ! -s $bl || -z $(tail -c1 -- "$bl") ]] || echo >>"$bl"
{
  printf '#\n# Added %s by add-to-blocklist.sh:\n' "$(date +%F)"
  printf '%s\n' "${new[@]}"
} >>"$bl"
echo "Added ${#new[@]}; the list holds $(( ${#have[@]} + ${#new[@]} )) entries."
echo "Tell the session 'blocklist done': it runs the publish check, which shows only counts and file:line."
