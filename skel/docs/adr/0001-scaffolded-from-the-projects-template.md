# 0001 — Scaffolded from the Projects template

Date: {{DATE}} · Status: accepted · Principles touched: simplicity

## Context

Every project on this machine had converged on the same shape by hand —
`agent.md` as the contract, a thin `CLAUDE.md`, the `.env` / `.env.example` /
`pi.md` trio, a lean in-repo GitHub MCP server, Conventional Commits, and a
grep for personal data before every push. Rebuilding that by copy-paste from
whichever project was most recently correct meant each new repo inherited a
snapshot of someone else's half-finished conventions.

## Decision

`{{PROJECT}}` was scaffolded from `~/Projects/_template`, which holds the
canonical copy of all of it. Improvements to the shared parts (the MCP server,
`scripts/pii-scan.sh`, the CI hygiene job, the `agent.md` skeleton) are made in
the template and flow to the next project.

## Consequences

- The shared machinery is identical across repos, so a fix is written once.
- The template can drift from a project that has legitimately diverged. That is
  fine — this repo's `agent.md` always wins over the template it came from.
- The `TODO({{PROJECT}})` markers left by the scaffold are debt: an unanswered
  one means an agent is working from a generic default. `grep -rn 'TODO({{PROJECT}})' .`

## Revisit when

Three projects have made the same edit to a scaffolded file — that edit belongs
in the template.
