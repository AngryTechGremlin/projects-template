# GitHub MCP Server

A portable Model Context Protocol (MCP) server that allows AI agents to interact with GitHub repositories, issues, and pull requests.

## Features
- **Fetch Issues**: Get detailed information about a specific issue.
- **List PRs**: List all open pull requests for a repository.
- **Search Code**: Search across GitHub using the GitHub search API.
- **Post Comments**: Add comments to issues or pull requests.

## Setup & Installation

### 1. Prerequisites
- Node.js v18+
- A **fine-grained** GitHub personal access token. Repository access: **Only
  select repositories** → this project's repo alone. These repository
  permissions, and nothing else:

  | Permission | Access | For |
  |---|---|---|
  | Contents | Read and write | `git push` through `scripts/git-credential-github.sh` |
  | Issues | Read and write | `get_issue`, `create_comment` |
  | Pull requests | Read and write | `list_pull_requests`, comments on PRs, and the release PR `scripts/release.sh` opens |
  | Metadata | Read-only (always on) | `list_repositories` |
  | Actions | Read-only | a session can see whether CI passed, and why not; `scripts/release.sh` waits on it |

  `search_code` works with this set. **Never Actions: Read and write:** it
  would let a session start a workflow, and publishing a public copy is a
  workflow only the owner starts. **Workflows stays at no access** on
  purpose: a session can push code but cannot change CI or a deploy pipeline
  in `.github/workflows`; GitHub refuses that push until a person grants it.
  The one planned exception is a new repo's **first push**, which carries
  `.github/workflows/` (`ci.yml`, `weekly.yml`, and `publish.yml` where the
  repo publishes): grant Workflows *Read and write* for that push,
  then take it away (`~/Projects/_template/README.md`, "Putting a project on
  GitHub").
  Why not a classic `repo` token: a leaked one reaches every repo the account
  can see, and this one reaches one. It expires, and a lapsed token fails
  quietly (a 401 on the next push), so put the date in a reminder.

### 2. Local Configuration
1. Clone this repository into your project hub.
2. Navigate to the `mcp/` directory:
   ```bash
   cd mcp
   ```
3. Create a `.env` file from the example:
   ```bash
   cp .env.example .env
   ```
4. Open `.env` and add your token:
   ```dotenv
   GITHUB_PERSONAL_ACCESS_TOKEN=your_token_here
   ```

### 3. Build & Run
Install dependencies and build the project:
```bash
npm install
npm run build
```

## Integration with AI Hosts

**The token never goes in client config.** `src/github-service.ts` loads
`mcp/.env` itself via dotenv, so every host config below is token-free — which
is what lets these files be committed at all (`agent.md` §3, §8). A client
config carrying a live PAT is a secret in a file nobody thinks of as a secret,
and it is copied between machines far more casually than a `.env` is.

### Claude Code / any host that reads `.mcp.json`
Nothing to do. The repo ships a `.mcp.json` at its root pointing at
`mcp/build/index.js` by a **repo-relative** path, so a fresh clone works
wherever it is checked out.

### Claude Desktop
Claude Desktop does not read the repo's `.mcp.json`, so it needs its own entry
in `claude_desktop_config.json` — still with no `env` block:
```json
{
  "mcpServers": {
    "github": {
      "command": "node",
      "args": ["/absolute/path/to/{{PROJECT}}/mcp/build/index.js"]
    }
  }
}
```

### VS Code / Copilot
`.vscode/mcp.json` is already wired, using `${workspaceFolder}` so it stays
portable. Nothing to add.

## Development
- **Dev Mode**: Run `npm run dev` to start the server using `ts-node`.
- **Build**: Run `npm run build` to compile TypeScript to JavaScript in the `build/` folder.
