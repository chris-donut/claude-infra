import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

export interface IntelConfig {
  github_repos: string[];
  competitors_api_url: string;
  telegram_chat_id: string;
}

interface CompetitorsApiResponse {
  repos?: string[];
  github_repos?: string[];
}

function loadBaseConfig(): IntelConfig {
  const configPath = join(__dirname, "config.json");
  const raw = readFileSync(configPath, "utf-8");
  return JSON.parse(raw) as IntelConfig;
}

export async function loadConfig(): Promise<IntelConfig> {
  const base = loadBaseConfig();

  try {
    const response = await fetch(base.competitors_api_url, {
      signal: AbortSignal.timeout(3000),
    });

    if (!response.ok) throw new Error(`HTTP ${response.status}`);

    const data = (await response.json()) as CompetitorsApiResponse;
    const extraRepos: string[] = data.repos ?? data.github_repos ?? [];

    const merged = Array.from(new Set([...base.github_repos, ...extraRepos]));
    return { ...base, github_repos: merged };
  } catch {
    // Silently fallback — competitors API is optional
    return base;
  }
}
