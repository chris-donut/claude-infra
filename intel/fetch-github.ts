import { writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

export interface GithubRepoData {
  repo: string;
  stars: number;
  latestRelease: { tag: string; date: string } | null;
  recentIssues: string[];
}

async function githubFetch(path: string): Promise<unknown> {
  const token = process.env.GITHUB_TOKEN;
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
  };
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const response = await fetch(`https://api.github.com${path}`, { headers });
  if (!response.ok) throw new Error(`GitHub API ${response.status}: ${path}`);
  return response.json();
}

async function fetchRepo(repo: string): Promise<GithubRepoData> {
  const [repoData, releasesData, issuesData] = await Promise.allSettled([
    githubFetch(`/repos/${repo}`),
    githubFetch(`/repos/${repo}/releases?per_page=1`),
    githubFetch(`/repos/${repo}/issues?state=open&per_page=3&sort=created`),
  ]);

  const repoInfo = repoData.status === "fulfilled"
    ? (repoData.value as { stargazers_count: number })
    : null;

  const releases = releasesData.status === "fulfilled"
    ? (releasesData.value as Array<{ tag_name: string; published_at: string }>)
    : [];

  const issues = issuesData.status === "fulfilled"
    ? (issuesData.value as Array<{ title: string }>)
    : [];

  return {
    repo,
    stars: repoInfo?.stargazers_count ?? 0,
    latestRelease: releases[0]
      ? { tag: releases[0].tag_name, date: releases[0].published_at.slice(0, 10) }
      : null,
    recentIssues: issues.map((i) => i.title).slice(0, 3),
  };
}

export async function fetchGithub(repos: string[]): Promise<GithubRepoData[]> {
  const results: GithubRepoData[] = [];

  for (const repo of repos) {
    try {
      const data = await fetchRepo(repo);
      results.push(data);
      console.log(`  ✓ ${repo}: ⭐${data.stars.toLocaleString()}`);
    } catch (err) {
      console.error(`  ✗ ${repo}:`, (err as Error).message);
    }
  }

  const outputPath = join(__dirname, "raw", "github.json");
  mkdirSync(join(__dirname, "raw"), { recursive: true });
  writeFileSync(outputPath, JSON.stringify(results, null, 2));
  console.log(`GitHub data saved → ${results.length} repos`);

  return results;
}
