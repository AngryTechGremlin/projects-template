# {{PROJECT}}

> TODO({{PROJECT}}): one sentence — what this does and who it is for.

## Install

```bash
git clone https://github.com/{{OWNER}}/{{PROJECT}} ~/Projects/{{PROJECT}}
cd ~/Projects/{{PROJECT}}
cp .env.example .env        # fill in real values; never committed
git config core.hooksPath .githooks
```

## Configuration

Every knob lives in `.env`, documented in `.env.example` with the reason it
exists. Real values never appear in a tracked file.

## Development

```bash
# TODO({{PROJECT}}): the one command that runs the tests
scripts/pii-scan.sh          # run before every push (also a pre-push hook)
```

The agent contract for this repo is [`agent.md`](agent.md); architecture
decisions are in [`docs/adr/`](docs/adr/).

## Why it works this way

> TODO({{PROJECT}}): one section per non-obvious behaviour — what it fixes and
> what it trades off. Code explains how; this explains why.
