import { Octokit } from "octokit";
import * as dotenv from "dotenv";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load .env from mcp root directory regardless of current working directory
dotenv.config({ path: path.resolve(__dirname, "../.env") });
dotenv.config();

export class GitHubService {
  private octokit: Octokit;

  constructor() {
    const token = process.env.GITHUB_PERSONAL_ACCESS_TOKEN;
    if (!token) {
      throw new Error("GITHUB_PERSONAL_ACCESS_TOKEN is not defined in environment variables or .env file.");
    }
    this.octokit = new Octokit({ auth: token });
  }

  async getIssue(owner: string, repo: string, issueNumber: number) {
    const { data } = await this.octokit.rest.issues.get({
      owner,
      repo,
      issue_number: issueNumber,
    });
    return data;
  }

  async listPullRequests(owner: string, repo: string) {
    const { data } = await this.octokit.rest.pulls.list({
      owner,
      repo,
      state: "open",
    });
    return data;
  }

  async searchCode(query: string) {
    const { data } = await this.octokit.rest.search.code({
      q: query,
    });
    return data;
  }

  async createComment(owner: string, repo: string, issueNumber: number, body: string) {
    const { data } = await this.octokit.rest.issues.createComment({
      owner,
      repo,
      issue_number: issueNumber,
      body,
    });
    return data;
  }

  async listRepositories() {
    const { data } = await this.octokit.rest.repos.listForAuthenticatedUser();
    return data;
  }
}

