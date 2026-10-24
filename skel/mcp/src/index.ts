import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { 
  CallToolRequestSchema, 
  ListToolsRequestSchema 
} from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { GitHubService } from "./github-service.js";

let github: GitHubService | null = null;

function getGitHubService(): GitHubService {
  if (!github) {
    github = new GitHubService();
  }
  return github;
}

const server = new Server(
  {
    name: "github-mcp-server",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// Define Zod tool schemas for runtime validation
const ToolSchemas = {
  get_issue: z.object({
    owner: z.string(),
    repo: z.string(),
    issueNumber: z.number(),
  }),
  list_pull_requests: z.object({
    owner: z.string(),
    repo: z.string(),
  }),
  search_code: z.object({
    query: z.string(),
  }),
  create_comment: z.object({
    owner: z.string(),
    repo: z.string(),
    issueNumber: z.number(),
    body: z.string(),
  }),
  list_repositories: z.object({}),
};

// Register tools list with standard JSON Schemas
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "get_issue",
        description: "Fetch details of a specific GitHub issue",
        inputSchema: {
          type: "object",
          properties: {
            owner: { type: "string", description: "Repository owner (user or org)" },
            repo: { type: "string", description: "Repository name" },
            issueNumber: { type: "number", description: "Issue number" },
          },
          required: ["owner", "repo", "issueNumber"],
        },
      },
      {
        name: "list_pull_requests",
        description: "List open pull requests for a repository",
        inputSchema: {
          type: "object",
          properties: {
            owner: { type: "string", description: "Repository owner (user or org)" },
            repo: { type: "string", description: "Repository name" },
          },
          required: ["owner", "repo"],
        },
      },
      {
        name: "search_code",
        description: "Search for code across GitHub",
        inputSchema: {
          type: "object",
          properties: {
            query: { type: "string", description: "GitHub code search query" },
          },
          required: ["query"],
        },
      },
      {
        name: "create_comment",
        description: "Create a comment on a GitHub issue or PR",
        inputSchema: {
          type: "object",
          properties: {
            owner: { type: "string", description: "Repository owner (user or org)" },
            repo: { type: "string", description: "Repository name" },
            issueNumber: { type: "number", description: "Issue or PR number" },
            body: { type: "string", description: "Comment body markdown text" },
          },
          required: ["owner", "repo", "issueNumber", "body"],
        },
      },
      {
        name: "list_repositories",
        description: "List repositories for the authenticated user",
        inputSchema: {
          type: "object",
          properties: {},
        },
      },
    ],
  };
});

// Handle tool execution
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    const service = getGitHubService();

    switch (name) {
      case "get_issue": {
        const validated = ToolSchemas.get_issue.parse(args);
        const result = await service.getIssue(validated.owner, validated.repo, validated.issueNumber);
        return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
      }
      case "list_pull_requests": {
        const validated = ToolSchemas.list_pull_requests.parse(args);
        const result = await service.listPullRequests(validated.owner, validated.repo);
        return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
      }
      case "search_code": {
        const validated = ToolSchemas.search_code.parse(args);
        const result = await service.searchCode(validated.query);
        return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
      }
      case "create_comment": {
        const validated = ToolSchemas.create_comment.parse(args);
        const result = await service.createComment(validated.owner, validated.repo, validated.issueNumber, validated.body);
        return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
      }
      case "list_repositories": {
        const result = await service.listRepositories();
        return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
      }
      default:
        throw new Error(`Tool not found: ${name}`);
    }
  } catch (error: any) {
    return {
      isError: true,
      content: [{ type: "text", text: error.message || String(error) }],
    };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("GitHub MCP Server running on stdio");
}

main().catch((error) => {
  console.error("Fatal error in main():", error);
  process.exit(1);
});

