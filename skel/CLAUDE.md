@agent.md

**PII context:** real IPs, hostnames, serials and account details for this
machine live in `pi.md` — gitignored, never committed. Read it at session
start; committed files use placeholders per agent.md §3.

**Before every push:** `scripts/check.sh fast`, and treat what it reports as a
failing test (agent.md §6).

**Project-specific rules**
- TODO({{PROJECT}}): the handful of rules that are true here and nowhere else —
  the one invariant the code exists to hold, what must never be swapped for a
  convenient substitute, and anything an agent would otherwise get wrong.
